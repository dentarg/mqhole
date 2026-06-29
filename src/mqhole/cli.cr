require "option_parser"
require "./amqp_broker"
require "./cloudamqp"
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
    rescue ex : CloudAMQP::APIError | Transfer::Error | Hook::Error | AMQP::Client::Error | IO::Error
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

      parser = OptionParser.new do |parser|
        parser.banner = "Usage: mqhole send NAME [FILE] [options]"
        parser.on("--api-key KEY", "CloudAMQP team API key") { |value| api_key = value }
        parser.on("--region REGION", "CloudAMQP region") { |value| region = value }
        parser.on("--file PATH", "Read payload from a file") { |value| file_path = value }
        parser.on("--data DATA", "Read payload from an argument") { |value| data = value }
        parser.on("--chunk-size BYTES", "AMQP payload chunk size") { |value| chunk_size = value.to_i }
      end
      parse_options(parser, argv)

      name = argv.shift? || raise UsageError.new("missing NAME")
      if positional_file = argv.shift?
        raise UsageError.new("file supplied twice") if file_path

        file_path = positional_file
      end
      raise UsageError.new("too many arguments") unless argv.empty?
      raise UsageError.new("--file and --data are mutually exclusive") if file_path && data

      if payload = data
        bytes = payload.to_slice
        io = IO::Memory.new(bytes)
        send_payload(api_key, region, name, io, nil, bytes.size.to_u64, chunk_size)
      elsif path = file_path
        File.open(path) do |file|
          send_payload(api_key, region, name, file, File.basename(path), File.size(path).to_u64, chunk_size)
        end
      else
        send_payload(api_key, region, name, @input, nil, nil, chunk_size)
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
      end
      parse_options(parser, argv)

      name = argv.shift? || raise UsageError.new("missing NAME")
      raise UsageError.new("too many arguments") unless argv.empty?
      raise UsageError.new("--timeout must be positive") unless timeout.positive?

      receive_payload(api_key, region, name, output_path, hook, hook_mode, echo, timeout)
    end

    private def send_payload(
      api_key : String?,
      region : String,
      name : String,
      input : IO,
      source_name : String?,
      size : UInt64?,
      chunk_size : Int32,
    ) : Nil
      raise UsageError.new("--chunk-size must be positive") unless chunk_size.positive?

      with_broker(api_key, region, name) do |broker, instance|
        manifest = Sender.new(broker, chunk_size: chunk_size).send(input, source_name, size)
        bytes = manifest.size.try(&.to_s) || "unknown"
        @error.puts logfmt(
          event: "sent",
          transfer_id: manifest.id,
          bytes: bytes,
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
    ) : Nil
      with_broker(api_key, region, name) do |broker, instance|
        result = Receiver.new(broker).receive(timeout)

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

          result.ack
          @error.puts logfmt(
            event: "received",
            transfer_id: result.manifest.id,
            bytes: result.bytes_written.to_s,
            region: region,
            instance_id: instance.id.to_s
          )
        ensure
          result.cleanup
        end
      end
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

    private def logfmt(**fields : String) : String
      String.build do |io|
        io << "at=info"
        fields.each do |key, value|
          io << ' ' << key << '=' << value
        end
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
