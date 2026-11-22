require "./spec_helper"
require "json"

# Builds with the build server on (`CRYSTAL_INFER_REUSE=1`) and its
# verification on: every build that reuses the kept typed program also types
# the program from scratch and fails when the two differ.
private class InferReuseProject
  getter directory : String
  getter list_of_server_pids = [] of Int64

  def initialize(@directory : String)
    Dir.mkdir_p(@directory)
  end

  def write(name : String, text : String) : Nil
    File.write(File.join(@directory, name), text)
  end

  def report_filename : String
    File.join(@directory, "report.json")
  end

  # Builds `main.cr` and returns the build result, what the program printed
  # (or `nil` when the build failed) and the build server's report.
  def build : {Process::Result, String?, JSON::Any}
    File.delete?(report_filename)
    env = {
      "CRYSTAL_CACHE_DIR"                 => File.join(@directory, "cache"),
      "CRYSTAL_INFER_REUSE"               => "1",
      "CRYSTAL_INFER_REUSE_VERIFY"        => "1",
      "CRYSTAL_INFER_REUSE_REPORT"        => report_filename,
      "CRYSTAL_INFER_SERVER_IDLE_SECONDS" => "120",
    }
    result = Process.capture_result(crystal, "build", "--incremental", "main.cr", "-o", "app", env: env, chdir: @directory)
    report = JSON.parse(File.exists?(report_filename) ? File.read(report_filename) : "{}")
    report["server_pid"]?.try { |pid| @list_of_server_pids << pid.as_i64 }
    printed = result.status.success? ? Process.capture_result(File.join(@directory, "app")).output : nil
    {result, printed, report}
  end

  def stop_servers : Nil
    @list_of_server_pids.uniq.each do |pid|
      Process.signal(Signal::TERM, pid) rescue nil
    end
  end
end

private HELPER = <<-CRYSTAL
  module Helper
    def self.value : Int32
      1
    end
  end

  CRYSTAL

private MAIN = <<-CRYSTAL
  require "./helper"

  class Counter
    @count : Int32 = 0

    def count : Int32
      @count
    end

    def greet(name : String) : String
      "Hello \#{name}"
    end

    def total : Int32
      Helper.value + 10
    end
  end

  counter = Counter.new
  puts counter.greet("world")
  puts counter.total
  puts counter.count

  CRYSTAL

private def with_project(name, &)
  with_tempfile(name) do |directory|
    project = InferReuseProject.new(directory)
    project.write("helper.cr", HELPER)
    project.write("main.cr", MAIN)
    begin
      yield project
    ensure
      project.stop_servers
    end
  end
end

private def expect_build(project, expected_output, reused : Bool)
  result, printed, report = project.build
  result.should be_success
  printed.should eq(expected_output)
  report["reused"].as_bool.should eq(reused)
  if reused
    report["verify_differences"].as_i.should eq(0)
  end
  report
end

describe "`crystal build --incremental` with the build server (CRYSTAL_INFER_REUSE=1)" do
  it "re-types an edited method body, and a restore, in the kept program" do
    with_project("infer-reuse-body") do |project|
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("no typed program")

      project.write("main.cr", MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")))
      report = expect_build(project, "Hi world\n11\n0\n", reused: true)
      report["retyped_instances"].as_i.should eq(1)

      project.write("main.cr", MAIN)
      expect_build(project, "Hello world\n11\n0\n", reused: true)

      # A body in another file.
      project.write("helper.cr", HELPER.sub("    1\n", "    5\n"))
      expect_build(project, "Hello world\n15\n0\n", reused: true)
    end
  end

  it "types the whole program again when a callee's signature changes" do
    with_project("infer-reuse-signature") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("helper.cr", HELPER.sub("def self.value : Int32\n    1", "def self.value : Int64\n    1_i64"))
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")
    end
  end

  it "types the whole program again when an instance variable's type changes" do
    with_project("infer-reuse-ivar") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)

      # A body that assigns an instance variable is not re-typed alone.
      project.write("main.cr", MAIN.sub("    @count\n", "    @count = 7\n"))
      report = expect_build(project, "Hello world\n11\n7\n", reused: false)
      report["reason"].as_s.should contain("assigns instance variable @count")

      project.write("main.cr", MAIN.sub("@count : Int32 = 0", "@count : Int32 | String = 0").sub("def count : Int32", "def count : Int32 | String"))
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")
    end
  end

  it "types the whole program again for a new overload" do
    with_project("infer-reuse-overload") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", MAIN.sub("  def total : Int32\n", "  def greet(name : Int32) : String\n    \"Number \#{name}\"\n  end\n\n  def total : Int32\n")
        .sub(%(puts counter.count\n), %(puts counter.count\nputs counter.greet(3)\n)))
      report = expect_build(project, "Hello world\n11\n0\nNumber 3\n", reused: false)
      report["reason"].as_s.should contain("lines")
    end
  end

  it "types the whole program again for a reopened class" do
    with_project("infer-reuse-reopen") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("helper.cr", HELPER + "class Counter\n  def greet(name : String) : String\n    \"Reopened \#{name}\"\n  end\nend\n")
      report = expect_build(project, "Reopened world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("lines")
    end
  end

  it "types the whole program again when a macro's output changes" do
    with_project("infer-reuse-macro") do |project|
      macro_main = MAIN + "macro make_value(n)\n  def made_value : Int32\n    {{n}}\n  end\nend\n\nmake_value(1)\nputs made_value\n"
      project.write("main.cr", macro_main)
      expect_build(project, "Hello world\n11\n0\n1\n", reused: false)

      # The macro's argument (outside any method body).
      project.write("main.cr", macro_main.sub("make_value(1)", "make_value(2)"))
      report = expect_build(project, "Hello world\n11\n0\n2\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")

      # The macro's own body.
      project.write("main.cr", macro_main.sub("make_value(1)", "make_value(2)").sub("    {{n}}\n", "    {{n}} + 1\n"))
      report = expect_build(project, "Hello world\n11\n0\n3\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")
    end
  end

  it "never reuses a program whose macros read method bodies" do
    with_project("infer-reuse-macro-body") do |project|
      reading_main = MAIN + "puts {{ Counter.methods.map(&.body.stringify).join(\"|\").size }}\n"
      project.write("main.cr", reading_main)
      _, first_output, _ = project.build
      project.write("main.cr", reading_main.sub(%("Hello \#{name}"), %("Hi there \#{name}")))
      result, printed, report = project.build
      result.should be_success
      report["reused"].as_bool.should be_false
      report["reason"].as_s.should contain("read the body")
      printed.should_not eq(first_output)
    end
  end

  it "types the whole program again when an edited body changes the method's type" do
    with_project("infer-reuse-return-type") do |project|
      untyped_main = MAIN.sub("def total : Int32", "def total")
      project.write("main.cr", untyped_main)
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", untyped_main.sub("Helper.value + 10", "\"ten\""))
      report = expect_build(project, "Hello world\nten\n0\n", reused: false)
      report["reason"].as_s.should contain("now returns")
    end
  end

  it "reports an error in an edited body and keeps serving" do
    with_project("infer-reuse-error") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", MAIN.sub("Helper.value + 10", "Helper.value + \"x\""))
      result, printed, _ = project.build
      result.should_not be_success
      printed.should be_nil
      result.error.should contain("expected argument #1 to 'Int32#+'")

      project.write("main.cr", MAIN.sub("Helper.value + 10", "Helper.value + 20"))
      expect_build(project, "Hello world\n21\n0\n", reused: true)
    end
  end
end
