require "./spec_helper"

describe Mqhole::Hook do
  it "appends text payloads as a process argument" do
    file = File.tempfile("mqhole-hook", ".txt")
    file.print("hello")
    file.close

    command = Mqhole::Hook.command("printf %s", Mqhole::Hook::Mode::Argument, file.path)

    command.executable.should eq("printf")
    command.arguments.should eq(["%s", "hello"])
  ensure
    File.delete(file.path) if file && File.exists?(file.path)
  end

  it "appends the temporary path in file mode" do
    command = Mqhole::Hook.command("cat", Mqhole::Hook::Mode::File, "/tmp/payload")

    command.executable.should eq("cat")
    command.arguments.should eq(["/tmp/payload"])
  end

  it "rejects NUL bytes in argument mode" do
    file = File.tempfile("mqhole-hook", ".bin")
    file.write(Bytes[65, 0, 66])
    file.close

    expect_raises(Mqhole::Hook::Error, /NUL/) do
      Mqhole::Hook.command("printf %s", Mqhole::Hook::Mode::Argument, file.path)
    end
  ensure
    File.delete(file.path) if file && File.exists?(file.path)
  end
end
