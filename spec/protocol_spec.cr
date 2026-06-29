require "./spec_helper"

describe Mqhole::Protocol do
  describe ".queue_name" do
    it "derives a deterministic queue name without exposing the wormhole name" do
      first = Mqhole::Protocol.queue_name("daily database dump")
      second = Mqhole::Protocol.queue_name("daily database dump")

      first.should eq(second)
      first.should start_with("mqhole.v1.")
      first.should_not contain("daily")
    end

    it "distinguishes different wormhole names" do
      Mqhole::Protocol.queue_name("alpha").should_not eq(
        Mqhole::Protocol.queue_name("beta")
      )
    end
  end
end

describe Mqhole::CloudAMQP::Region do
  it "combines provider and region into the API identifier" do
    region = Mqhole::CloudAMQP::Region.new(
      provider: "digital-ocean",
      region: "ams3",
      name: "DigitalOcean - Amsterdam 3",
      has_shared_plans: false
    )

    region.identifier.should eq("digital-ocean::ams3")
  end
end
