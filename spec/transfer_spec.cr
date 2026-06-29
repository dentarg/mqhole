require "./spec_helper"

private class StopReceiveLoop < Exception
end

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

  it "keeps receiving transfers across idle waits" do
    broker = Mqhole::MemoryBroker.new
    sender = Mqhole::Sender.new(broker)
    sender.send(IO::Memory.new("one"), source_name: nil, size: 3_u64)

    spawn do
      sleep 20.milliseconds
      sender.send(IO::Memory.new("two"), source_name: nil, size: 3_u64)
    end

    receiver = Mqhole::Receiver.new(broker)
    payloads = [] of String

    expect_raises(StopReceiveLoop) do
      Mqhole::Transfer.receive_forever(receiver, 5.milliseconds) do |result|
        payloads << File.read(result.path)
        result.ack
        result.cleanup
        raise StopReceiveLoop.new if payloads.size == 2
      end
    end

    payloads.should eq(["one", "two"])
    broker.acked_count.should eq(6)
  end

  it "reports timeouts after a transfer has started" do
    broker = Mqhole::MemoryBroker.new
    manifest = Mqhole::Transfer::Manifest.new(
      id: "partial",
      version: 1,
      source_name: nil,
      size: nil,
      chunk_size: Mqhole::Transfer::DEFAULT_CHUNK_SIZE
    )
    broker.publish(
      Mqhole::Transfer::HEADER_TYPE,
      manifest.id,
      "#{manifest.id}:header",
      manifest.to_json.to_slice
    )

    receiver = Mqhole::Receiver.new(broker)

    expect_raises(Mqhole::Transfer::TimeoutError, /timed out waiting for transfer/) do
      Mqhole::Transfer.receive_forever(receiver, 5.milliseconds) do |result|
        result.cleanup
      end
    end
    broker.acked_count.should eq(0)
  end
end
