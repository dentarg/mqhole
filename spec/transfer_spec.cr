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
end
