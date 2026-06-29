require "./spec_helper"

describe Mqhole::Encryption do
  it "encrypts and decrypts a chunk with a passphrase-derived key" do
    sender = Mqhole::Encryption::Context.generate("correct horse battery staple")
    receiver = Mqhole::Encryption::Context.from_metadata(
      "correct horse battery staple",
      sender.metadata
    )
    manifest = Mqhole::Transfer::Manifest.new(
      id: "transfer-id",
      version: 1,
      source_name: "payload.bin",
      size: 3_u64,
      chunk_size: 128,
      encryption: sender.metadata
    )

    encrypted = sender.encrypt_chunk(Bytes[1, 2, 3], manifest, 0)

    encrypted.should_not eq(Bytes[1, 2, 3])
    receiver.decrypt_chunk(encrypted, manifest, 0).should eq(Bytes[1, 2, 3])
  end

  it "rejects the wrong passphrase" do
    sender = Mqhole::Encryption::Context.generate("right")
    receiver = Mqhole::Encryption::Context.from_metadata("wrong", sender.metadata)
    manifest = Mqhole::Transfer::Manifest.new(
      id: "transfer-id",
      version: 1,
      source_name: nil,
      size: 3_u64,
      chunk_size: 128,
      encryption: sender.metadata
    )
    encrypted = sender.encrypt_chunk(Bytes[1, 2, 3], manifest, 0)

    expect_raises(Mqhole::Encryption::Error, /check the passphrase/) do
      receiver.decrypt_chunk(encrypted, manifest, 0)
    end
  end
end
