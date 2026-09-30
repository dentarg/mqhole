require "./spec_helper"

private class BrokerRetryCLI < Mqhole::CLI
  getter attempts = 0

  def exercise(url : String, queue_name : String) : Nil
    with_ready_broker(url, queue_name, 100.milliseconds, 1.millisecond) do |_broker|
      @attempts += 1
      raise AMQP::Client::Error.new("simulated transfer failure")
    end
  end
end

# Opt-in integration check: use a disposable broker, never a production queue.
if url = ENV["MQHOLE_TEST_AMQP_URL"]?
  describe Mqhole::AMQPBroker do
    it "does not replay a transfer when an established broker fails" do
      queue_name = "mqhole-spec-#{Random::Secure.hex(12)}"
      cli = BrokerRetryCLI.new(IO::Memory.new, IO::Memory.new, IO::Memory.new)

      expect_raises(AMQP::Client::Error, "simulated transfer failure") do
        cli.exercise(url, queue_name)
      end
      cli.attempts.should eq(1)
    ensure
      if queue_name
        AMQP::Client.start(url) do |connection|
          connection.channel { |channel| channel.queue_delete(queue_name) }
        end
      end
    end

    it "stops waiting when the connection closes without a channel callback" do
      queue_name = "mqhole-spec-#{Random::Secure.hex(12)}"
      connection = AMQP::Client.new(url).connect
      channel = connection.channel
      broker = Mqhole::AMQPBroker.new(channel, channel.queue(queue_name))
      spawn do
        sleep 50.milliseconds
        connection.close
      end
      started = Time.instant

      expect_raises(Mqhole::Transfer::Error, "broker consumer closed") do
        broker.get(10.seconds)
      end
      (Time.instant - started).should be < 2.seconds
    ensure
      broker.try(&.close)
      connection.try(&.close)
      if queue_name
        AMQP::Client.start(url) do |cleanup|
          cleanup.channel { |ch| ch.queue_delete(queue_name) }
        end
      end
    end

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
