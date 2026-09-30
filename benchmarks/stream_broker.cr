require "../src/mqhole"

# Transport experiment only. Stream acknowledgements advance delivery credit;
# they do not delete data. This probe starts at the beginning of a fresh stream
# and does not implement persistent receiver offsets or production cleanup.
class StreamBroker < Mqhole::AMQPBroker
  def self.open(url : String, queue_name : String, & : StreamBroker -> _)
    AMQP::Client.start(url) do |connection|
      connection.channel do |channel|
        channel.prefetch(128)
        queue = channel.queue(queue_name, args: AMQP::Client::Arguments.new({"x-queue-type" => "stream"}))
        broker = new(channel, queue)
        begin
          yield broker
        ensure
          broker.close
        end
      end
    end
  end

  @stream_deliveries : Channel(Mqhole::BrokerMessage)?

  def close : Nil
    @stream_deliveries.try(&.close)
    super
  end

  def get(timeout : Time::Span) : Mqhole::BrokerMessage?
    deliveries = @stream_deliveries || subscribe_stream
    select
    when message = deliveries.receive
      message
    when timeout(timeout)
      nil
    end
  end

  private def subscribe_stream : Channel(Mqhole::BrokerMessage)
    deliveries = Channel(Mqhole::BrokerMessage).new(32)
    @stream_deliveries = deliveries
    @queue.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-offset" => 0_i64})) do |message|
      received = Mqhole::BrokerMessage.new(
        message.properties.type,
        message.properties.correlation_id,
        message.properties.message_id,
        message.body_io.to_slice
      ) { }
      begin
        deliveries.send(received)
        message.ack
      rescue Channel::ClosedError
      end
    end
    deliveries
  end
end
