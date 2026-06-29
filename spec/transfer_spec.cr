require "./spec_helper"

describe Mqhole::Transfer do
  it "round trips binary data through chunked broker messages" do
    data = Bytes[0, 1, 255, 65, 66]
    broker = Mqhole::MemoryBroker.new

    sender = Mqhole::Sender.new(broker, chunk_size: 2)
    sender.send(IO::Memory.new(data), source_name: "payload.bin", size: data.size.to_u64)

    receiver = Mqhole::Receiver.new(broker)
    result = receiver.receive(timeout: 10.milliseconds)

    File.open(result.path) do |file|
      file.getb_to_end.should eq(data)
    end
    result.manifest.source_name.should eq("payload.bin")

    result.ack
    broker.acked_count.should eq(5)
  ensure
    result.try(&.cleanup)
  end

  it "round trips encrypted binary data with the passphrase" do
    data = Bytes[0, 1, 255, 65, 66]
    broker = Mqhole::MemoryBroker.new
    sender_encryption = Mqhole::Encryption::Context.generate("secret passphrase")

    sender = Mqhole::Sender.new(broker, chunk_size: 2, encryption: sender_encryption)
    sender.send(IO::Memory.new(data), source_name: "payload.bin", size: data.size.to_u64)

    receiver = Mqhole::Receiver.new(broker, decryption_passphrase: "secret passphrase")
    result = receiver.receive(timeout: 1.second)

    File.open(result.path) do |file|
      file.getb_to_end.should eq(data)
    end
    result.manifest.encryption.should_not be_nil
  ensure
    result.try(&.cleanup)
  end

  it "explains when encrypted data is received without a passphrase" do
    broker = Mqhole::MemoryBroker.new
    sender_encryption = Mqhole::Encryption::Context.generate("secret passphrase")
    sender = Mqhole::Sender.new(broker, encryption: sender_encryption)
    sender.send(IO::Memory.new("secret"), source_name: nil, size: 6_u64)

    receiver = Mqhole::Receiver.new(broker)

    expect_raises(Mqhole::Transfer::Error, /rerun receive with --encrypted/) do
      receiver.receive(timeout: 1.second)
    end
    broker.acked_count.should eq(0)
  end

  it "explains when the encrypted transfer passphrase is wrong" do
    broker = Mqhole::MemoryBroker.new
    sender_encryption = Mqhole::Encryption::Context.generate("right")
    sender = Mqhole::Sender.new(broker, encryption: sender_encryption)
    sender.send(IO::Memory.new("secret"), source_name: nil, size: 6_u64)

    receiver = Mqhole::Receiver.new(broker, decryption_passphrase: "wrong")

    expect_raises(Mqhole::Encryption::Error, /check the passphrase/) do
      receiver.receive(timeout: 1.second)
    end
    broker.acked_count.should eq(0)
  end
end
