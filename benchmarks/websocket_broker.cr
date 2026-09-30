require "../src/mqhole"

# Compare the provider's HTTPS relay with its native AMQPS endpoint. Keep the
# production queue, confirmation and acknowledgement behavior unchanged.
class WebSocketBroker < Mqhole::AMQPBroker
  def self.open(url : String, queue_name : String, & : WebSocketBroker -> _)
    uri = URI.parse(url)
    tls = OpenSSL::SSL::Context::Client.new
    tls.verify_mode = OpenSSL::SSL::VerifyMode::PEER
    headers = HTTP::Headers{"Sec-WebSocket-Protocol" => "amqp"}
    socket = HTTP::WebSocket.new(uri.hostname.not_nil!, path: "/ws/amqp",
      port: 443, tls: tls, headers: headers)
    io = AMQP::Client::WebSocketIO.new(socket)
    info = AMQP::Client::ConnectionInformation.new("mqhole-benchmark", "1", "Crystal", Crystal::VERSION, "websocket")
    connection = AMQP::Client::Connection.start(io, uri.user.to_s, uri.password.to_s,
      URI.decode_www_form(uri.path[1..]), 1024_u16, 131_072_u32, 0_u16, info)
    connection.channel do |channel|
      queue = channel.queue(queue_name)
      broker = new(channel, queue)
      begin
        yield broker
      ensure
        broker.close
      end
    end
  ensure
    connection.try &.close
    io.try &.close
  end
end
