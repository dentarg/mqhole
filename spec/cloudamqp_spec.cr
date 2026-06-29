require "./spec_helper"

private class FakeCloudAMQPTransport < Mqhole::CloudAMQP::Transport
  getter requests = [] of Mqhole::CloudAMQP::Request

  def initialize(@responses : Deque(Mqhole::CloudAMQP::Response))
  end

  def request(request : Mqhole::CloudAMQP::Request) : Mqhole::CloudAMQP::Response
    @requests << request
    @responses.shift
  end
end

describe Mqhole::CloudAMQP::Client do
  it "filters listed regions by provider" do
    transport = FakeCloudAMQPTransport.new(Deque{
      Mqhole::CloudAMQP::Response.new(200, <<-JSON),
        [
          {
            "provider": "digital-ocean",
            "region": "ams3",
            "name": "DigitalOcean - Amsterdam 3",
            "has_shared_plans": false
          }
        ]
        JSON
    })
    client = Mqhole::CloudAMQP::Client.new(transport)

    regions = client.regions(provider: "digital-ocean")

    regions.first.identifier.should eq("digital-ocean::ams3")
    transport.requests.first.path.should eq("/regions?provider=digital-ocean")
  end

  it "reuses an existing mqhole instance in the selected region" do
    transport = FakeCloudAMQPTransport.new(Deque{
      Mqhole::CloudAMQP::Response.new(200, <<-JSON),
        [
          {
            "id": 17,
            "name": "mqhole-lavinmq-amazon-web-services-eu-west-1",
            "plan": "lemming",
            "region": "amazon-web-services::eu-west-1"
          }
        ]
        JSON
      Mqhole::CloudAMQP::Response.new(200, <<-JSON),
        {
          "id": 17,
          "name": "mqhole-lavinmq-amazon-web-services-eu-west-1",
          "plan": "lemming",
          "region": "amazon-web-services::eu-west-1",
          "url": "amqps://user:pass@example/vhost",
          "ready": true
        }
        JSON
    })
    client = Mqhole::CloudAMQP::Client.new(transport)

    instance = client.ensure_instance("amazon-web-services::eu-west-1")

    instance.id.should eq(17)
    instance.connection_url.should eq("amqps://user:pass@example/vhost")
    transport.requests.map(&.path).should eq([
      "/instances",
      "/instances/17",
    ])
  end

  it "creates the shared LavinMQ instance when it does not exist" do
    transport = FakeCloudAMQPTransport.new(Deque{
      Mqhole::CloudAMQP::Response.new(200, "[]"),
      Mqhole::CloudAMQP::Response.new(200, <<-JSON),
        {
          "id": 23,
          "url": "amqps://user:pass@example/vhost",
          "apikey": "instance-key"
        }
        JSON
    })
    client = Mqhole::CloudAMQP::Client.new(transport)

    instance = client.ensure_instance("amazon-web-services::eu-west-1")

    instance.id.should eq(23)
    post = transport.requests.last
    post.method.should eq("POST")
    post.path.should eq("/instances")
    body = post.body.not_nil!
    body.should contain(%("plan":"lemming"))
    body.should contain(%("region":"amazon-web-services::eu-west-1"))
  end

  it "raises API errors with the CloudAMQP message" do
    transport = FakeCloudAMQPTransport.new(Deque{
      Mqhole::CloudAMQP::Response.new(400, %({"error":"plan unavailable"})),
    })
    client = Mqhole::CloudAMQP::Client.new(transport)

    expect_raises(Mqhole::CloudAMQP::APIError, /plan unavailable/) do
      client.instances
    end
  end
end
