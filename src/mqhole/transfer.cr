require "json"
require "random/secure"
require "./encryption"

module Mqhole
  module Transfer
    HEADER_TYPE = "mqhole.header.v1"
    CHUNK_TYPE  = "mqhole.chunk.v1"
    END_TYPE    = "mqhole.end.v1"

    DEFAULT_CHUNK_SIZE = 128 * 1024

    class Error < Exception
    end

    struct Manifest
      include JSON::Serializable

      getter id : String
      getter version : Int32
      getter source_name : String?
      getter size : UInt64?
      getter chunk_size : Int32
      getter encryption : Encryption::Metadata?

      def initialize(
        @id : String,
        @version : Int32,
        @source_name : String?,
        @size : UInt64?,
        @chunk_size : Int32,
        @encryption : Encryption::Metadata? = nil,
      )
      end
    end
  end

  class BrokerMessage
    getter type : String?
    getter correlation_id : String?
    getter message_id : String?
    getter body : Bytes

    def initialize(
      @type : String?,
      @correlation_id : String?,
      @message_id : String?,
      body : Bytes,
      &@ack_proc : -> Nil
    )
      @body = body.dup
      @acked = false
    end

    def ack : Nil
      return if @acked

      @ack_proc.call
      @acked = true
    end
  end

  abstract class Broker
    abstract def publish(type : String, correlation_id : String, message_id : String, body : Bytes) : Nil
    abstract def get(timeout : Time::Span) : BrokerMessage?
  end

  class MemoryBroker < Broker
    getter acked_count : Int32

    def initialize
      @messages = Deque(BrokerMessage).new
      @acked_count = 0
    end

    def publish(type : String, correlation_id : String, message_id : String, body : Bytes) : Nil
      @messages << BrokerMessage.new(type, correlation_id, message_id, body) do
        @acked_count += 1
      end
    end

    def get(timeout : Time::Span) : BrokerMessage?
      deadline = Time.instant + timeout
      loop do
        return @messages.shift? unless @messages.empty?
        return nil if Time.instant >= deadline

        sleep 1.millisecond
      end
    end
  end

  class Sender
    def initialize(
      @broker : Broker,
      @chunk_size : Int32 = Transfer::DEFAULT_CHUNK_SIZE,
      @encryption : Encryption::Context? = nil,
    )
      raise ArgumentError.new("chunk size must be positive") unless @chunk_size.positive?
    end

    def send(input : IO, source_name : String?, size : UInt64?) : Transfer::Manifest
      id = Random::Secure.hex(16)
      manifest = Transfer::Manifest.new(
        id: id,
        version: 1,
        source_name: source_name,
        size: size,
        chunk_size: @chunk_size,
        encryption: @encryption.try(&.metadata)
      )

      publish_json(Transfer::HEADER_TYPE, id, "#{id}:header", manifest)
      publish_chunks(input, manifest)
      @broker.publish(Transfer::END_TYPE, id, "#{id}:end", Bytes.empty)

      manifest
    end

    private def publish_json(type : String, correlation_id : String, message_id : String, object) : Nil
      @broker.publish(type, correlation_id, message_id, object.to_json.to_slice)
    end

    private def publish_chunks(input : IO, manifest : Transfer::Manifest) : Nil
      buffer = Bytes.new(@chunk_size)
      index = 0

      loop do
        bytes_read = input.read(buffer)
        break if bytes_read.zero?

        @broker.publish(
          Transfer::CHUNK_TYPE,
          manifest.id,
          "#{manifest.id}:chunk:#{index}",
          chunk_body(buffer[0, bytes_read], manifest, index)
        )
        index += 1
      end
    end

    private def chunk_body(chunk : Bytes, manifest : Transfer::Manifest, index : Int32) : Bytes
      if encryption = @encryption
        encryption.encrypt_chunk(chunk, manifest, index)
      else
        chunk.dup
      end
    end
  end

  class ReceiveResult
    getter manifest : Transfer::Manifest
    getter path : String
    getter bytes_written : UInt64

    def initialize(
      @manifest : Transfer::Manifest,
      @path : String,
      @bytes_written : UInt64,
      @messages : Array(BrokerMessage),
    )
      @acked = false
    end

    def ack : Nil
      return if @acked

      @messages.each(&.ack)
      @acked = true
    end

    def cleanup : Nil
      File.delete(@path) if File.exists?(@path)
    end
  end

  class Receiver
    def initialize(@broker : Broker, @decryption_passphrase : String? = nil)
    end

    def receive(timeout : Time::Span) : ReceiveResult
      deadline = Time.instant + timeout
      messages = [] of BrokerMessage
      temp = File.tempfile("mqhole", ".payload")

      header = next_message(deadline)
      validate_type(header, Transfer::HEADER_TYPE)
      messages << header

      manifest = Transfer::Manifest.from_json(String.new(header.body))
      decryption = decryption_context(manifest)
      bytes_written = receive_chunks(manifest, temp, messages, deadline, decryption)
      temp.close

      ReceiveResult.new(manifest, temp.path, bytes_written, messages)
    rescue ex
      temp.try &.close
      File.delete(temp.path) if temp && File.exists?(temp.path)
      raise ex
    end

    private def receive_chunks(
      manifest : Transfer::Manifest,
      temp : File,
      messages : Array(BrokerMessage),
      deadline : Time::Instant,
      decryption : Encryption::Context?,
    ) : UInt64
      bytes_written = 0_u64
      chunk_index = 0

      loop do
        message = next_message(deadline)
        validate_correlation(message, manifest.id)
        messages << message

        case message.type
        when Transfer::CHUNK_TYPE
          chunk = chunk_body(message.body, manifest, chunk_index, decryption)
          temp.write(chunk)
          bytes_written += chunk.size
          chunk_index += 1
        when Transfer::END_TYPE
          validate_size(manifest, bytes_written)
          return bytes_written
        else
          raise Transfer::Error.new("unexpected message type #{message.type.inspect}")
        end
      end
    end

    private def decryption_context(manifest : Transfer::Manifest) : Encryption::Context?
      metadata = manifest.encryption
      passphrase = @decryption_passphrase

      if metadata && passphrase
        return Encryption::Context.from_metadata(passphrase, metadata)
      end

      if metadata
        raise Transfer::Error.new("transfer is encrypted; rerun receive with --encrypted")
      end

      if passphrase
        raise Transfer::Error.new("transfer is not encrypted; rerun receive without --encrypted")
      end
    end

    private def chunk_body(
      body : Bytes,
      manifest : Transfer::Manifest,
      index : Int32,
      decryption : Encryption::Context?,
    ) : Bytes
      if decryption
        decryption.decrypt_chunk(body, manifest, index)
      else
        body
      end
    end

    private def next_message(deadline : Time::Instant) : BrokerMessage
      remaining = deadline - Time.instant
      raise Transfer::Error.new("timed out waiting for transfer") unless remaining.positive?

      @broker.get(remaining) || raise Transfer::Error.new("timed out waiting for transfer")
    end

    private def validate_type(message : BrokerMessage, expected : String) : Nil
      return if message.type == expected

      raise Transfer::Error.new("expected #{expected}, got #{message.type.inspect}")
    end

    private def validate_correlation(message : BrokerMessage, expected : String) : Nil
      return if message.correlation_id == expected

      raise Transfer::Error.new("transfer id mismatch")
    end

    private def validate_size(manifest : Transfer::Manifest, bytes_written : UInt64) : Nil
      expected = manifest.size
      return unless expected
      return if expected == bytes_written

      raise Transfer::Error.new("expected #{expected} bytes, received #{bytes_written}")
    end
  end
end
