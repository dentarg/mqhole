require "amqp-client"
require "./transfer"

module Mqhole
  class AMQPBroker < Broker
    def self.open(url : String, queue_name : String, confirm_window : Int32 = 32, & : AMQPBroker -> _)
      AMQP::Client.start(url) do |connection|
        connection.channel do |channel|
          channel.prefetch(16)
          queue = channel.queue(queue_name)
          broker = new(channel, queue, confirm_window)
          begin
            yield broker
          ensure
            broker.close
          end
        end
      end
    end

    @pending = 0
    @confirmations : Channel(Bool)

    def initialize(@channel : AMQP::Client::Channel, @queue : AMQP::Client::Queue, @confirm_window : Int32 = 32)
      raise ArgumentError.new("confirm window must be positive") unless @confirm_window.positive?
      @confirmations = Channel(Bool).new(@confirm_window)
    end

    def publish(type : String, correlation_id : String, message_id : String, body : Bytes) : Nil
      props = AMQP::Client::Properties.new(
        type: type,
        correlation_id: correlation_id,
        message_id: message_id,
        delivery_mode: 2_u8
      )
      wait_for_confirmation if @pending >= @confirm_window
      @pending += 1
      @queue.publish(body, props: props) do |confirmed|
        @confirmations.send(confirmed)
      end
    end

    def flush : Nil
      while @pending > 0
        wait_for_confirmation
      end
    end

    private def wait_for_confirmation : Nil
      select
      when confirmed = @confirmations.receive
        @pending -= 1
        raise Transfer::Error.new("broker rejected a published message") unless confirmed
      when timeout(30.seconds)
        raise Transfer::TimeoutError.new("timed out waiting for publisher confirmation")
      end
    end

    @deliveries : Channel(BrokerMessage)?

    def close : Nil
      @deliveries.try(&.close)
    end

    def get(timeout : Time::Span) : BrokerMessage?
      deliveries = @deliveries || subscribe
      select
      when message = deliveries.receive
        message
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      raise Transfer::Error.new("broker consumer closed")
    end

    private def subscribe : Channel(BrokerMessage)
      deliveries = Channel(BrokerMessage).new(32)
      @deliveries = deliveries
      # A transfer is acknowledged only after output/hooks succeed. A finite
      # broker prefetch would deadlock any transfer larger than that limit.
      @channel.prefetch(0)
      @channel.on_close { |_code, _reason| deliveries.close }
      @channel.on_cancel { |_tag| deliveries.close }
      @queue.subscribe(no_ack: false) do |message|
        channel = @channel
        tag = message.delivery_tag
        received = BrokerMessage.new(
          message.properties.type,
          message.properties.correlation_id,
          message.properties.message_id,
          message.body_io.to_slice,
          -> { channel.basic_ack(tag) },
          ->(requeue : Bool) { channel.basic_reject(tag, requeue: requeue) }
        )
        begin
          deliveries.send(received)
        rescue Channel::ClosedError
          # Closing the AMQP channel requeues outstanding deliveries.
        end
      end
      deliveries
    end
  end
end
