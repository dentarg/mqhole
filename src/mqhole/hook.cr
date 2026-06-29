module Mqhole
  module Hook
    class Error < Exception
    end

    enum Mode
      Argument
      File

      def self.parse(value : String) : self
        case value
        when "argument", "arg"
          Argument
        when "file", "path"
          File
        else
          raise Error.new("unknown hook mode #{value.inspect}")
        end
      end
    end

    record Command, executable : String, arguments : Array(String)

    def self.command(command_line : String, mode : Mode, payload_path : String) : Command
      parts = Process.parse_arguments(command_line)
      raise Error.new("hook command is empty") if parts.empty?

      payload = case mode
                in Mode::Argument
                  payload_argument(payload_path)
                in Mode::File
                  payload_path
                end

      Command.new(parts.first, parts[1..] + [payload])
    end

    def self.run(command_line : String, mode : Mode, payload_path : String) : Nil
      command = command(command_line, mode, payload_path)
      status = Process.run(
        command.executable,
        command.arguments,
        input: Process::Redirect::Close,
        output: STDOUT,
        error: STDERR
      )
      raise Error.new("hook exited with status #{status.exit_code}") unless status.success?
    end

    private def self.payload_argument(path : String) : String
      bytes = File.open(path) { |file| file.getb_to_end }
      if bytes.includes?(0_u8)
        raise Error.new("payload contains NUL bytes and cannot be passed as an argument")
      end

      String.new(bytes)
    end
  end
end
