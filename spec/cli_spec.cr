require "./spec_helper"

describe Mqhole::CLI do
  it "defaults to a shared LavinMQ-capable CloudAMQP region" do
    Mqhole::CLI::DEFAULT_REGION.should eq("scaleway::nl-ams")
  end

  it "marks when an encrypted receive passphrase has been read" do
    original_api_key = ENV["CLOUDAMQP_API_KEY"]?
    ENV.delete("CLOUDAMQP_API_KEY")
    input = IO::Memory.new("secret passphrase\n")
    output = IO::Memory.new
    error = IO::Memory.new

    status = Mqhole::CLI.run(["receive", "demo", "--encrypted"], input, output, error)

    status.should eq(64)
    error.to_s.should contain("Passphrase: ***")
  ensure
    if api_key = original_api_key
      ENV["CLOUDAMQP_API_KEY"] = api_key
    else
      ENV.delete("CLOUDAMQP_API_KEY")
    end
  end
end
