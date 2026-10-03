require "../../../../spec_helper"
require "../../../../support/env"
require "../../../../../src/compiler/crystal/tools/watch/coordination"

private def wait_for_watch_build(root : String, minimum_build : Int32) : Crystal::Watch::Coordination::Status
  deadline = Time.instant + 60.seconds
  loop do
    if status = Crystal::Watch::Coordination.read_status(root)
      return status if status.build >= minimum_build && status.finished?
    end
    raise "watch build #{minimum_build} timed out" if Time.instant >= deadline
    sleep 50.milliseconds
  end
end

describe Crystal::Watch::Coordination do
  it "prints hook commands using the installed fork name" do
    compiler_executable = File.expand_path(".build/crystal")
    hooks = Process.capture(compiler_executable, "watch", "hooks")
    hooks.should contain(%("command": "crystal-alpha watch hold claude"))
    hooks.should contain(%("command": "crystal-alpha watch release"))

    with_tempdir("watch_hooks_alias") do
      File.symlink(compiler_executable, "acrystal")
      alias_hooks = Process.capture("./acrystal", "watch", "hooks")
      alias_hooks.should contain(%("command": "acrystal watch hold claude"))
      alias_hooks.should contain(%("command": "acrystal watch release"))
    end
  end

  it "rebuilds an edited method body with strict signatures off by default" do
    compiler_executable = File.expand_path(".build/crystal")
    with_tempdir("watch_unannotated_method") do
      File.write("main.cr", "def value\n  \"old\"\nend\nputs value\n")
      File.open("watch.log", "w") do |log|
        with_env("CRYSTAL_STRICT_SIGNATURES": nil) do
          watcher = Process.new(compiler_executable, ["watch", "--poll", "--poll-interval", "50", "main.cr"], output: log, error: log)
          begin
            first = wait_for_watch_build(Dir.current, 1)
            first.state.should eq("ok"), File.read("watch.log")
            Process.capture("./main").should eq("old\n")

            File.write("main.cr", "def value\n  \"new\"\nend\nputs value\n")
            second = wait_for_watch_build(Dir.current, 2)
            second.state.should eq("ok"), File.read("watch.log")
            Process.capture("./main").should eq("new\n")

            File.write("main.cr", "def value\n  42\nend\nputs value\n")
            third = wait_for_watch_build(Dir.current, 3)
            third.state.should eq("ok"), File.read("watch.log")
            Process.capture("./main").should eq("42\n")
            File.read("watch.log").should contain("Full compilation:")
          ensure
            watcher.terminate
            watcher.wait
          end
        end
      end
    end
  end

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
