require "option_parser"
require "./amqp_broker"
require "./cloudamqp"
require "./encryption"
require "./hook"
require "./protocol"
require "./transfer"

module Mqhole
  class CLI
    DEFAULT_REGION            = "scaleway::nl-ams"
    DEFAULT_TIMEOUT           = 300.seconds
    DEFAULT_PROVISION_TIMEOUT = 3.minutes

    class UsageError < Exception
    end

    class HelpShown < Exception
    end

    def self.run(argv = ARGV, input : IO = STDIN, output : IO = STDOUT, error : IO = STDERR) : Int32
      new(input, output, error).run(argv.dup)
    end

    def initialize(@input : IO, @output : IO, @error : IO)
    end

    def run(argv : Array(String)) : Int32
      command = argv.shift?

      case command
      when nil, "-h", "--help"
        write_global_help
      when "--version"
        @output.puts VERSION
      when "regions"
        run_regions(argv)
      when "send"
        run_send(argv)
      when "receive", "recv"
        run_receive(argv)
      else
        raise UsageError.new("unknown command #{command.inspect}")
      end

      0
    rescue HelpShown
      0
    rescue ex : UsageError
      @error.puts "error: #{ex.message}"
      64
    rescue ex : CloudAMQP::APIError | Encryption::Error | Transfer::Error | Hook::Error | AMQP::Client::Error | IO::Error
      @error.puts "error: #{ex.message}"
      1
    end

    private def run_regions(argv : Array(String)) : Nil
      api_key = nil
      provider = nil
      shared_only = false

      parser = OptionParser.new do |parser|
        parser.banner = "Usage: mqhole regions [PROVIDER] [options]"
        parser.on("--api-key KEY", "CloudAMQP team API key") { |value| api_key = value }
        parser.on("--provider PROVIDER", "Filter by CloudAMQP provider") { |value| provider = value }
        parser.on("--shared-only", "Show only regions with shared plans") { shared_only = true }
      end
      parse_options(parser, argv)

      provider ||= argv.shift?
      raise UsageError.new("too many arguments") unless argv.empty?

      regions = cloudamqp(api_key).regions(provider: provider)
      regions = regions.select(&.has_shared_plans) if shared_only

      regions.each do |region|
        @output.puts "#{region.identifier}\tshared=#{region.has_shared_plans}\t#{region.name}"
      end
    end

    private def run_send(argv : Array(String)) : Nil
      api_key = nil
      region = DEFAULT_REGION
      file_path = nil
      data = nil
      chunk_size = Transfer::DEFAULT_CHUNK_SIZE
      encrypted = false
      verbose = false

      parser = OptionParser.new do |parser|
        parser.banner = "Usage: mqhole send NAME [FILE] [options]"
        parser.on("--api-key KEY", "CloudAMQP team API key") { |value| api_key = value }
        parser.on("--region REGION", "CloudAMQP region") { |value| region = value }
        parser.on("--file PATH", "Read payload from a file") { |value| file_path = value }
        parser.on("--data DATA", "Read payload from an argument") { |value| data = value }
        parser.on("--chunk-size BYTES", "AMQP payload chunk size") { |value| chunk_size = value.to_i }
        parser.on("--encrypted", "Encrypt payload and print passphrase") { encrypted = true }
        parser.on("--verbose", "Write progress log lines") { verbose = true }
      end
      parse_options(parser, argv)

      name = argv.shift? || raise UsageError.new("missing NAME")
      if positional_file = argv.shift?
        raise UsageError.new("file supplied twice") if file_path

        file_path = positional_file
      end
      raise UsageError.new("too many arguments") unless argv.empty?
      raise UsageError.new("--file and --data are mutually exclusive") if file_path && data

      encryption = generated_encryption(encrypted)

      if payload = data
        bytes = payload.to_slice
        io = IO::Memory.new(bytes)
        send_payload(api_key, region, name, io, nil, bytes.size.to_u64, chunk_size, encryption, verbose)
      elsif path = file_path
        File.open(path) do |file|
          send_payload(
            api_key,
            region,
            name,
            file,
            File.basename(path),
            File.size(path).to_u64,
            chunk_size,
            encryption,
            verbose
          )
        end
      else
        send_payload(api_key, region, name, @input, nil, nil, chunk_size, encryption, verbose)
      end
    end

    private def run_receive(argv : Array(String)) : Nil
      api_key = nil
      region = DEFAULT_REGION
      output_path = nil
      hook = nil
      hook_mode = Hook::Mode::File
      echo = nil
      timeout = DEFAULT_TIMEOUT
      encrypted = false
      listen = false
      verbose = false

      parser = OptionParser.new do |parser|
        parser.banner = "Usage: mqhole receive NAME [options]"
        parser.on("--api-key KEY", "CloudAMQP team API key") { |value| api_key = value }
        parser.on("--region REGION", "CloudAMQP region") { |value| region = value }
        parser.on("-o PATH", "--output PATH", "Write payload to a file") { |value| output_path = value }
        parser.on("--echo", "Write payload to stdout") { echo = true }
        parser.on("--no-echo", "Do not write payload to stdout") { echo = false }
        parser.on("--hook COMMAND", "Run command with payload argument") { |value| hook = value }
        parser.on("--hook-mode MODE", "Use file or argument hook mode") do |value|
          hook_mode = Hook::Mode.parse(value)
        end
        parser.on("--timeout SECONDS", "Receive wait timeout") { |value| timeout = value.to_f.seconds }
        parser.on("--encrypted", "Prompt for payload decryption passphrase") { encrypted = true }
        parser.on("--listen", "Keep receiving until interrupted") { listen = true }
        parser.on("--verbose", "Write progress log lines") { verbose = true }
      end
      parse_options(parser, argv)

      name = argv.shift? || raise UsageError.new("missing NAME")
      raise UsageError.new("too many arguments") unless argv.empty?
      raise UsageError.new("--timeout must be positive") unless timeout.positive?

      decryption_passphrase = encrypted ? read_passphrase : nil
      receive_payload(
        api_key,
        region,
        name,
        output_path,
        hook,
        hook_mode,
        echo,
        timeout,
        decryption_passphrase,
        listen,
        verbose
      )
    end

    private def send_payload(
      api_key : String?,
      region : String,
      name : String,
      input : IO,
      source_name : String?,
      size : UInt64?,
      chunk_size : Int32,
      encryption : Encryption::Context?,
      verbose : Bool,
    ) : Nil
      raise UsageError.new("--chunk-size must be positive") unless chunk_size.positive?

      with_broker(api_key, region, name) do |broker, instance|
        started_at = Time.instant
        reporter = progress_reporter("send_progress", started_at, verbose: verbose, inline: !verbose && error_tty?)
        bytes_sent = 0_u64
        manifest = begin
          Sender.new(broker, chunk_size: chunk_size, encryption: encryption).send(input, source_name, size) do |progress|
            bytes_sent = progress.bytes
            reporter[:call].call(progress)
          end
        ensure
          reporter[:finish].call
        end
        duration = Time.instant - started_at
        rate = rate_bytes_per_second(bytes_sent, duration)
        bytes = manifest.size.try(&.to_s) || bytes_sent.to_s
        @error.puts logfmt(
          event: "sent",
          transfer_id: manifest.id,
          bytes: bytes,
          rate: rate.round.to_i64.to_s,
          rate_human: "#{human_bytes(rate)}/s",
          region: region,
          instance_id: instance.id.to_s
        )
      end
    end

    private def receive_payload(
      api_key : String?,
      region : String,
      name : String,
      output_path : String?,
      hook : String?,
      hook_mode : Hook::Mode,
      echo : Bool?,
      timeout : Time::Span,
      decryption_passphrase : String?,
      listen : Bool,
      verbose : Bool,
    ) : Nil
      with_broker(api_key, region, name) do |broker, instance|
        receiver = Receiver.new(broker, decryption_passphrase: decryption_passphrase)

        if listen
          listen_for_payloads(receiver, output_path, hook, hook_mode, echo, timeout, region, instance, verbose)
        else
          receive_one(receiver, output_path, hook, hook_mode, echo, timeout, region, instance, verbose)
        end
      end
    end

    private def listen_for_payloads(
      receiver : Receiver,
      output_path : String?,
      hook : String?,
      hook_mode : Hook::Mode,
      echo : Bool?,
      timeout : Time::Span,
      region : String,
      instance : CloudAMQP::Instance,
      verbose : Bool,
    ) : Nil
      loop do
        begin
          receive_one(receiver, output_path, hook, hook_mode, echo, timeout, region, instance, verbose)
        rescue Transfer::IdleTimeoutError
        rescue ex : Transfer::ReceiveError
          ex.reject(requeue: false)
          @error.puts logfmt(
            "error",
            event: "receive_failed",
            transfer_id: ex.transfer_id || "unknown",
            error: ex.message || ex.class.name,
            action: "dropped"
          )
        end
      end
    end

    private def receive_one(
      receiver : Receiver,
      output_path : String?,
      hook : String?,
      hook_mode : Hook::Mode,
      echo : Bool?,
      timeout : Time::Span,
      region : String,
      instance : CloudAMQP::Instance,
      verbose : Bool,
    ) : Nil
      started_at = Time.instant
      reporter = progress_reporter("receive_progress", started_at, verbose: verbose, inline: false)
      result = begin
        receiver.receive(timeout) do |progress|
          reporter[:call].call(progress)
        end
      ensure
        reporter[:finish].call
      end

      deliver_result(result, output_path, hook, hook_mode, echo, region, instance, started_at)
    end

    private def deliver_result(
      result : ReceiveResult,
      output_path : String?,
      hook : String?,
      hook_mode : Hook::Mode,
      echo : Bool?,
      region : String,
      instance : CloudAMQP::Instance,
      started_at : Time::Instant,
    ) : Nil
      begin
        delivered = false

        if path = output_path
          copy_file(result.path, path)
          delivered = true
        end

        if command = hook
          Hook.run(command, hook_mode, result.path)
          delivered = true
        end

        should_echo = echo.nil? ? !delivered : echo
        if should_echo
          File.open(result.path) { |file| IO.copy(file, @output) }
        end

        duration = Time.instant - started_at
        rate = rate_bytes_per_second(result.bytes_written, duration)
        result.ack
        @error.puts logfmt(
          event: "received",
          transfer_id: result.manifest.id,
          bytes: result.bytes_written.to_s,
          rate: rate.round.to_i64.to_s,
          rate_human: "#{human_bytes(rate)}/s",
          region: region,
          instance_id: instance.id.to_s
        )
      ensure
        result.cleanup
      end
    end

    private def progress_reporter(
      event : String,
      started_at : Time::Instant,
      verbose : Bool,
      inline : Bool,
    )
      last_report_at = started_at
      inline_width = 0
      inline_active = false

      report = ->(progress : Transfer::Progress) do
        now = Time.instant
        if progress.complete || now - last_report_at >= 1.second
          last_report_at = now
          elapsed = now - started_at
          rate = rate_bytes_per_second(progress.bytes, elapsed)

          if verbose
            @error.puts progress_log_line(event, progress, rate)
          elsif inline
            text = inline_progress_text(event, progress, rate)
            padding = inline_width > text.size ? inline_width - text.size : 0
            inline_width = Math.max(inline_width, text.size)
            inline_active = true
            @error.print "\r#{text}#{" " * padding}"
            @error.flush
          end
        end
      end

      finish = -> do
        if inline && inline_active
          @error.print "\r#{" " * inline_width}\r"
          @error.flush
        end
      end

      {call: report, finish: finish}
    end

    private def progress_log_line(event : String, progress : Transfer::Progress, rate : Float64) : String
      if total = progress.total
        percent = progress.percent
        logfmt(
          event: event,
          transfer_id: progress.transfer_id,
          bytes: progress.bytes.to_s,
          total: total.to_s,
          percent: percent ? sprintf("%.1f", percent) : "unknown",
          rate: rate.round.to_i64.to_s,
          rate_human: "#{human_bytes(rate)}/s"
        )
      else
        logfmt(
          event: event,
          transfer_id: progress.transfer_id,
          bytes: progress.bytes.to_s,
          total: "unknown",
          rate: rate.round.to_i64.to_s,
          rate_human: "#{human_bytes(rate)}/s"
        )
      end
    end

    private def inline_progress_text(event : String, progress : Transfer::Progress, rate : Float64) : String
      verb = event == "send_progress" ? "Sending" : "Receiving"

      if total = progress.total
        current_percent = progress.percent
        percent = current_percent ? sprintf("%.1f", current_percent) : "unknown"
        "#{verb} #{human_bytes(progress.bytes.to_f64)} / #{human_bytes(total.to_f64)} (#{percent}%) at #{human_bytes(rate)}/s"
      else
        "#{verb} #{human_bytes(progress.bytes.to_f64)} at #{human_bytes(rate)}/s"
      end
    end

    private def rate_bytes_per_second(bytes : UInt64?, elapsed : Time::Span) : Float64
      return 0.0 unless bytes

      seconds = elapsed.total_seconds
      return 0.0 unless seconds.positive?

      bytes.to_f64 / seconds
    end

    private def human_bytes(bytes : Float64) : String
      units = ["B", "KiB", "MiB", "GiB", "TiB"]
      amount = bytes
      unit_index = 0

      while amount >= 1024.0 && unit_index < units.size - 1
        amount /= 1024.0
        unit_index += 1
      end

      value = if unit_index.zero?
                amount.round.to_i64.to_s
              elsif amount >= 10
                sprintf("%.1f", amount)
              else
                sprintf("%.2f", amount)
              end
      "#{value} #{units[unit_index]}"
    end

    private def error_tty? : Bool
      if error = @error.as?(IO::FileDescriptor)
        error.tty?
      else
        false
      end
    end

    private def generated_encryption(enabled : Bool) : Encryption::Context?
      return unless enabled

      passphrase = Encryption.generate_passphrase
      @error.puts logfmt(event: "encryption_passphrase", passphrase: passphrase)
      Encryption::Context.generate(passphrase)
    end

    private def read_passphrase : String
      @error.print "Passphrase: "
      passphrase = if input = @input.as?(IO::FileDescriptor)
                     read_passphrase(input)
                   else
                     @input.gets.try(&.chomp)
                   end
      passphrase ||= raise UsageError.new("missing encryption passphrase")
      raise UsageError.new("missing encryption passphrase") if passphrase.empty?
      @error.puts "***"

      passphrase
    end

    private def read_passphrase(input : IO::FileDescriptor) : String?
      return input.gets.try(&.chomp) unless input.tty?

      passphrase = input.noecho do
        input.gets.try(&.chomp)
      end
      passphrase
    end

    private def with_broker(api_key : String?, region : String, name : String, & : Broker, CloudAMQP::Instance -> _) : Nil
      instance = cloudamqp(api_key).ensure_instance(
        region,
        wait_timeout: DEFAULT_PROVISION_TIMEOUT,
        poll_interval: 5.seconds
      )
      url = instance.connection_url || raise UsageError.new("CloudAMQP instance has no AMQP URL")
      queue_name = Protocol.queue_name(name)

      with_ready_broker(url, queue_name, DEFAULT_PROVISION_TIMEOUT, 5.seconds) do |broker|
        yield broker, instance
      end
    end

    private def with_ready_broker(
      url : String,
      queue_name : String,
      timeout : Time::Span,
      poll_interval : Time::Span,
      & : Broker -> _
    ) : Nil
      deadline = Time.instant + timeout

      loop do
        begin
          AMQPBroker.open(url, queue_name) do |broker|
            yield broker
          end
          return
        rescue ex : AMQP::Client::Error
          raise ex if Time.instant >= deadline

          sleep poll_interval
        end
      end
    end

    private def cloudamqp(api_key : String?) : CloudAMQP::Client
      resolved = api_key || ENV["CLOUDAMQP_API_KEY"]?
      raise UsageError.new("missing --api-key or CLOUDAMQP_API_KEY") unless resolved

      CloudAMQP::Client.with_api_key(resolved)
    end

    private def copy_file(source : String, destination : String) : Nil
      File.open(source) do |input|
        File.open(destination, "w") do |output|
          IO.copy(input, output)
        end
      end
    end

    private def parse_options(parser : OptionParser, argv : Array(String)) : Nil
      parser.on("-h", "--help", "Show help") do
        @output.puts parser
        raise HelpShown.new
      end
      parser.invalid_option do |flag|
        raise UsageError.new("invalid option #{flag}")
      end
      parser.missing_option do |flag|
        raise UsageError.new("missing value for #{flag}")
      end

      parser.parse(argv)
    end

    private def logfmt(level : String = "info", **fields : String) : String
      String.build do |io|
        io << "at=" << level
        fields.each do |key, value|
          io << ' ' << key << '='
          write_logfmt_value(io, value)
        end
      end
    end

    private def write_logfmt_value(io : IO, value : String) : Nil
      unless logfmt_quoted?(value)
        io << value
        return
      end

      io << '"'
      value.each_char do |char|
        case char
        when '\\', '"'
          io << '\\' << char
        when '\n'
          io << "\\n"
        when '\r'
          io << "\\r"
        when '\t'
          io << "\\t"
        else
          io << char
        end
      end
      io << '"'
    end

    private def logfmt_quoted?(value : String) : Bool
      return true if value.empty?

      value.each_char.any? do |char|
        char.whitespace? || char == '=' || char == '"' || char == '\\'
      end
    end

    private def write_global_help : Nil
      @output.puts <<-TEXT
      Usage: mqhole COMMAND [options]

      Commands:
        regions   List CloudAMQP regions
        send      Send stdin, data, or a file
        receive   Receive and echo, write, or hook payload data
      TEXT
    end
  end
end
