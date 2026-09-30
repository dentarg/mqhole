require "./spec_helper"

# Opt-in integration check: use a disposable broker, never a production queue.
if url = ENV["MQHOLE_TEST_AMQP_URL"]?
  describe Mqhole::AMQPBroker do
    it "confirms a windowed transfer and requeues it until delivery succeeds" do
      queue_name = "mqhole-spec-#{Random::Secure.hex(12)}"
      data = Random::Secure.random_bytes(1024 * 1024)

      Mqhole::AMQPBroker.open(url, queue_name, confirm_window: 2) do |broker|
        Mqhole::Sender.new(broker, chunk_size: 8192).send(IO::Memory.new(data), nil, data.size.to_u64)
      end

      # A failed output/hook must leave the entire transfer available to retry.
      Mqhole::AMQPBroker.open(url, queue_name) do |broker|
        result = Mqhole::Receiver.new(broker).receive(10.seconds)
        File.read(result.path).to_slice.should eq(data)
        result.cleanup
      end

      Mqhole::AMQPBroker.open(url, queue_name) do |broker|
        result = Mqhole::Receiver.new(broker).receive(10.seconds)
        File.read(result.path).to_slice.should eq(data)
        result.ack
        result.cleanup
      end
    ensure
      if queue_name
        AMQP::Client.start(url) do |connection|
          connection.channel { |channel| channel.queue_delete(queue_name) }
        end
      end
    end
  end
end
