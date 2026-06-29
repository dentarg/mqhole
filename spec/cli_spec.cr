require "./spec_helper"

describe Mqhole::CLI do
  it "defaults to a shared LavinMQ-capable CloudAMQP region" do
    Mqhole::CLI::DEFAULT_REGION.should eq("scaleway::nl-ams")
  end
end
