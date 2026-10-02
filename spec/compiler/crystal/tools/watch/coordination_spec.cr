require "../../../../spec_helper"
require "../../../../../src/compiler/crystal/tools/watch/coordination"

describe Crystal::Watch::Coordination do
  it "holds until released" do
    with_tempfile("watch_coordination") do |root|
      Dir.mkdir_p(root)
      Crystal::Watch::Coordination.held?(root).should be_nil

      Crystal::Watch::Coordination.hold(root, "claude")
      Crystal::Watch::Coordination.held?(root).should eq("claude")
      File.read(File.join(root, ".crystal-watch", ".gitignore")).should eq("*\n")

      Crystal::Watch::Coordination.release(root)
      Crystal::Watch::Coordination.held?(root).should be_nil
    end
  end

  it "ignores a hold that wasn't renewed" do
    with_tempfile("watch_coordination") do |root|
      Dir.mkdir_p(root)
      Crystal::Watch::Coordination.hold(root, "claude")
      old = Time.utc - Crystal::Watch::Coordination::HOLD_TIMEOUT - 1.minute
      File.utime(old, old, Crystal::Watch::Coordination.hold_file(root))
      Crystal::Watch::Coordination.held?(root).should be_nil
    end
  end

  it "writes and reads the status" do
    with_tempfile("watch_coordination") do |root|
      Dir.mkdir_p(root)
      Crystal::Watch::Coordination.read_status(root).should be_nil

      Crystal::Watch::Coordination.request(root, "abc")
      Crystal::Watch::Coordination.requested(root).should eq("abc")

      status = Crystal::Watch::Coordination::Status.new(
        state: "failed", build: 3, request: "abc", pid: 42_i64, updated_at: Time.utc, message: "Compilation failed", errors: "Error: x")
      Crystal::Watch::Coordination.write_status(root, status)

      read = Crystal::Watch::Coordination.read_status(root).not_nil!
      read.state.should eq("failed")
      read.build.should eq(3)
      read.request.should eq("abc")
      read.errors.should eq("Error: x")
      read.finished?.should be_true
    end
  end
end
