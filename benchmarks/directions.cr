require "amqp-client"
require "digest/sha256"
require "json"
require "uuid"

# Keep client diagnostics separate from machine-readable benchmark results.
Log.setup(:info, Log::IOBackend.new(STDERR))

# Separate confirmed upload from download to locate a hosted throughput limit.
# Keep the payload below the smallest observed shared-plan queue byte limit.
path = ARGV[0]
chunk_size = ARGV[1]?.try(&.to_i) || 131_072
raise "chunk size must be positive" unless chunk_size.positive?
persistent = ARGV[2]? != "transient"
payload = File.read(path).to_slice
expected_hash = Digest::SHA256.hexdigest(payload)
raise "diagnostic payload must contain 1 byte to 8 MiB" unless (1..8 * 1024 * 1024).includes?(payload.size)
name = "mqhole-directions-#{UUID.random}"
AMQP::Client.start(ENV["AMQP_URL"]) do |connection|
  connection.channel do |channel|
    queue = channel.queue(name)
    begin
      confirmations = Channel(Bool).new(32)
      pending = 0
      props = AMQP::Client::Properties.new(delivery_mode: persistent ? 2_u8 : 1_u8)
      started = Time.instant
      offset = 0
      while offset < payload.size
        chunk = payload[offset, Math.min(chunk_size, payload.size - offset)]
        offset += chunk.size
        if pending == 32
          raise "publish rejected" unless confirmations.receive
          pending -= 1
        end
        pending += 1
        queue.publish(chunk, props: props) { |confirmed| confirmations.send(confirmed) }
      end
      pending.times { raise "publish rejected" unless confirmations.receive }
      upload_seconds = (Time.instant - started).total_seconds
      channel.prefetch(0)
      done = Channel(Nil).new(1)
      bytes = 0
      digest = Digest::SHA256.new
      started = Time.instant
      queue.subscribe(no_ack: false) do |message|
        body = message.body_io.to_slice
        digest.update(body)
        bytes += body.size
        channel.basic_ack(message.delivery_tag)
        done.send(nil) if bytes >= payload.size
      end
      select
      when done.receive
      when timeout(120.seconds)
        raise "download timed out"
      end
      download_seconds = (Time.instant - started).total_seconds
      raise "payload mismatch" unless bytes == payload.size && digest.hexfinal == expected_hash
      puts({bytes: bytes, chunk: chunk_size, persistent: persistent,
            frame_max: connection.frame_max, upload_seconds: upload_seconds,
            download_seconds: download_seconds, verified: true}.to_json)
    ensure
      queue.delete
    end
  end
end
