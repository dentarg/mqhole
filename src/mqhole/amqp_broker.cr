require "amqp-client"
require "./transfer"

module Mqhole
  class AMQPBroker < Broker
    def self.open(url : String, queue_name : String, confirm_window : Int32 = 32, & : AMQPBroker -> _)
      AMQP::Client.start(url) do |connection|
        connection.channel do |channel|
          channel.prefetch(16)
          queue = channel.queue(queue_name)
          yield new(queue, confirm_window)
        end
      end
    end

    @pending = 0
    @confirmations : Channel(Bool)

    def initialize(@queue : AMQP::Client::Queue, @confirm_window : Int32 = 32)
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

    def get(timeout : Time::Span) : BrokerMessage?
      deadline = Time.instant + timeout

      loop do
        if message = @queue.get(no_ack: false)
          body = message.body_io.tap(&.rewind).getb_to_end
          return BrokerMessage.new(
            message.properties.type,
            message.properties.correlation_id,
            message.properties.message_id,
            body,
            -> { message.ack },
            ->(requeue : Bool) { message.reject(requeue) }
          )
        end

        return nil if Time.instant >= deadline

        sleep 100.milliseconds
      end
    end
  end
end
