require "amqp-client"
require "./transfer"

module Mqhole
  class AMQPBroker < Broker
    def self.open(url : String, queue_name : String, & : AMQPBroker -> _)
      AMQP::Client.start(url) do |connection|
        connection.channel do |channel|
          channel.prefetch(16)
          queue = channel.queue(queue_name)
          yield new(queue)
        end
      end
    end

    def initialize(@queue : AMQP::Client::Queue)
    end

    def publish(type : String, correlation_id : String, message_id : String, body : Bytes) : Nil
      props = AMQP::Client::Properties.new(
        type: type,
        correlation_id: correlation_id,
        message_id: message_id,
        delivery_mode: 2_u8
      )
      confirmed = @queue.publish_confirm(body, props: props)
      raise Transfer::Error.new("broker did not confirm #{message_id}") unless confirmed
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
