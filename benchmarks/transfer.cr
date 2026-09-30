require "../src/mqhole"
require "digest/sha256"

{% if flag?(:stream_benchmark) %}
  require "./stream_broker"
  alias BenchmarkBroker = StreamBroker
{% else %}
  alias BenchmarkBroker = Mqhole::AMQPBroker
{% end %}

# Runs multiple transfers on one connection, excluding provisioning and setup.
# The orchestrator verifies hashes and measures cold CLI transfers separately.
mode, name, path = ARGV[0], ARGV[1], ARGV[2]
count = ARGV[3]?.try(&.to_i) || 1
chunk_size = ARGV[4]?.try(&.to_i) || Mqhole::Transfer::DEFAULT_CHUNK_SIZE
BenchmarkBroker.open(ENV["AMQP_URL"], name) do |broker|
  STDERR.puts "ready"
  STDIN.gets if mode == "send"
  count.times do |index|
    started = Time.instant
    if mode == "send"
      File.open(path) do |file|
        encryption = if ENV["BENCH_ENCRYPTED"]?
                       Mqhole::Encryption::Context.generate("benchmark-only-passphrase")
                     end
        Mqhole::Sender.new(broker, chunk_size: chunk_size, encryption: encryption).send(file, File.basename(path), file.size.to_u64)
      end
      puts({index: index, seconds: (Time.instant - started).total_seconds}.to_json)
    else
      passphrase = ENV["BENCH_ENCRYPTED"]? ? "benchmark-only-passphrase" : nil
      result = Mqhole::Receiver.new(broker, decryption_passphrase: passphrase).receive((ENV["BENCH_TIMEOUT"]?.try(&.to_i) || 300).seconds)
      elapsed = (Time.instant - started).total_seconds
      digest = File.open(result.path) { |file| Digest::SHA256.hexdigest(file) }
      result.ack
      result.cleanup
      puts({index: index, seconds: elapsed, bytes: result.bytes_written, sha256: digest}.to_json)
    end
    STDOUT.flush
  end
end
