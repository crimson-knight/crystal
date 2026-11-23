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
  def build(list_of_extra_args = [] of String) : {Process::Result, String?, JSON::Any}
    File.delete?(report_filename)
    env = {
      "CRYSTAL_CACHE_DIR"                 => File.join(@directory, "cache"),
      "CRYSTAL_INFER_REUSE"               => "1",
      "CRYSTAL_INFER_REUSE_VERIFY"        => "1",
      "CRYSTAL_INFER_REUSE_REPORT"        => report_filename,
      "CRYSTAL_INFER_SERVER_IDLE_SECONDS" => "120",
    }
    result = Process.capture_result(crystal, "build", "--incremental", *list_of_extra_args, "main.cr", "-o", "app", env: env, chdir: @directory)
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

private def expect_build(project, expected_output, reused : Bool, list_of_extra_args = [] of String)
  result, printed, report = project.build(list_of_extra_args)
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
      project.write("helper.cr", HELPER.sub("def self.value : Int32\n", "def self.value(offset : Int32 = 0) : Int32\n"))
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("removed method 'value' is still called")
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

  it "types the whole program again for a new overload called from outside a method" do
    with_project("infer-reuse-overload") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", MAIN.sub("  def total : Int32\n", "  def greet(name : Int32) : String\n    \"Number \#{name}\"\n  end\n\n  def total : Int32\n")
        .sub(%(puts counter.count\n), %(puts counter.count\nputs counter.greet(3)\n)))
      report = expect_build(project, "Hello world\n11\n0\nNumber 3\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")
    end
  end

  it "re-types a body that grew, with the lines after it moved" do
    with_project("infer-reuse-lines") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      grown = MAIN.sub("    Helper.value + 10\n", "    base = Helper.value\n    offset = 10\n    base + offset\n")
      project.write("main.cr", grown)
      report = expect_build(project, "Hello world\n11\n0\n", reused: true)
      report["reason"].as_s.should contain("lines moved")

      # A second move on top of the first, then back to the start.
      project.write("main.cr", grown.sub(%("Hello \#{name}"), %(greeting = "Hello"\n    "\#{greeting} \#{name}")))
      expect_build(project, "Hello world\n11\n0\n", reused: true)
      project.write("main.cr", MAIN)
      expect_build(project, "Hello world\n11\n0\n", reused: true)
    end
  end

  it "adds a method an edited body calls, and removes it again" do
    with_project("infer-reuse-new-method") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      added = MAIN.sub("  def total : Int32\n    Helper.value + 10\n", "  def bonus : Int32\n    5\n  end\n\n  def total : Int32\n    Helper.value + 10 + bonus\n")
      project.write("main.cr", added)
      report = expect_build(project, "Hello world\n16\n0\n", reused: true)
      report["added_methods"].as_i.should eq(1)

      # An overload of an existing method whose calls keep their target.
      overload = added.sub("  def bonus : Int32\n", "  def greet(name : Int32) : String\n    \"Number \#{name}\"\n  end\n\n  def bonus : Int32\n")
      project.write("main.cr", overload)
      report = expect_build(project, "Hello world\n16\n0\n", reused: true)
      report["added_methods"].as_i.should eq(1)

      project.write("main.cr", MAIN)
      report = expect_build(project, "Hello world\n11\n0\n", reused: true)
      report["removed_methods"].as_i.should eq(2)
    end
  end

  it "types the whole program again when a new method takes over an existing call" do
    with_project("infer-reuse-takeover") do |project|
      main = MAIN.sub("  def total : Int32\n", "  def describe(value) : String\n    \"any\"\n  end\n\n  def total : Int32\n") + "puts counter.describe(1)\n"
      project.write("main.cr", main)
      expect_build(project, "Hello world\n11\n0\nany\n", reused: false)
      project.write("main.cr", main.sub("  def total : Int32\n", "  def describe(value : Int32) : String\n    \"number\"\n  end\n\n  def total : Int32\n"))
      report = expect_build(project, "Hello world\n11\n0\nnumber\n", reused: false)
      report["reason"].as_s.should contain("matches the call")
    end
  end

  it "types the whole program again for a new method a responds_to? asks about" do
    with_project("infer-reuse-responds-to") do |project|
      main = MAIN + "puts counter.responds_to?(:bonus)\n"
      project.write("main.cr", main)
      expect_build(project, "Hello world\n11\n0\nfalse\n", reused: false)
      project.write("main.cr", main.sub("  def total : Int32\n", "  def bonus : Int32\n    5\n  end\n\n  def total : Int32\n"))
      report = expect_build(project, "Hello world\n11\n0\ntrue\n", reused: false)
      report["reason"].as_s.should contain("responds_to?")
    end
  end

  it "runs again the macros that list methods, and reuses when they write the same code" do
    with_project("infer-reuse-method-list") do |project|
      main = MAIN + "puts {{ Counter.methods.select(&.name.starts_with?(\"to\")).size }}\nputs {{ Counter.methods.size }}\n"
      project.write("main.cr", main)
      expect_build(project, "Hello world\n11\n0\n1\n3\n", reused: false)
      # One listing writes the same code with the new method, the other does not.
      project.write("main.cr", main.sub("  def total : Int32\n", "  def bonus : Int32\n    5\n  end\n\n  def total : Int32\n"))
      report = expect_build(project, "Hello world\n11\n0\n1\n4\n", reused: false)
      report["reason"].as_s.should contain("writes other code with the edit")

      selective = MAIN + "puts {{ Counter.methods.select(&.name.starts_with?(\"to\")).size }}\n"
      project.write("main.cr", selective)
      expect_build(project, "Hello world\n11\n0\n1\n", reused: false)
      project.write("main.cr", selective.sub("  def total : Int32\n", "  def bonus : Int32\n    5\n  end\n\n  def total : Int32\n"))
      report = expect_build(project, "Hello world\n11\n0\n1\n", reused: true)
      report["replayed_expansions"].as_i.should eq(1)
    end
  end

  it "types the whole program again for a new top-level method" do
    with_project("infer-reuse-top-level") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", MAIN.sub("class Counter\n", "def bonus : Int32\n  5\nend\n\nclass Counter\n"))
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("top-level method")
    end
  end

  it "re-types bodies with blocks, and methods of generic types" do
    with_project("infer-reuse-blocks-generics") do |project|
      main = <<-MAIN
        class Crate(T)
          def initialize(@value : T)
          end

          def describe : String
            "crate of \#{@value}"
          end
        end

        class Wrapper(U)
          def initialize(@item : U)
          end

          def item : U
            @item
          end
        end

        class Summer
          def total(list : Array(Int32)) : Int32
            sum = 0
            list.each { |item| sum += item }
            sum
          end

          def twice(& : Int32 -> Int32) : Int32
            yield(1) + yield(2)
          end

          def use_twice : Int32
            twice { |value| value * 10 }
          end
        end

        summer = Summer.new
        puts summer.total([1, 2, 3])
        puts summer.use_twice
        puts Crate.new(1).describe
        puts Crate.new("a").describe

        MAIN
      project.write("main.cr", main)
      expect_build(project, "6\n30\ncrate of 1\ncrate of a\n", reused: false)

      # A block in an edited body, and the block of a call to a method that yields.
      project.write("main.cr", main.sub("sum += item }", "sum += item * 2 }").sub("value * 10 }", "value * 100 }"))
      report = expect_build(project, "12\n300\ncrate of 1\ncrate of a\n", reused: true)
      report["retyped_instances"].as_i.should eq(2)

      # A method of a generic type: one instance per type argument (and the
      # two bodies above, back as they were).
      project.write("main.cr", main.sub(%("crate of \#{@value}"), %("a crate of \#{@value}")))
      report = expect_build(project, "6\n30\na crate of 1\na crate of a\n", reused: true)
      report["retyped_instances"].as_i.should eq(4)

      # One that needs a generic instance the program did not have.
      project.write("main.cr", main.sub(%("crate of \#{@value}"), %("crate of \#{Wrapper.new(@value).item}")))
      report = expect_build(project, "6\n30\ncrate of 1\ncrate of a\n", reused: false)
      report["reason"].as_s.should contain("new generic instances")

      # A method that yields.
      project.write("main.cr", main.sub("yield(1) + yield(2)", "yield(1) + yield(3)"))
      report = expect_build(project, "6\n40\ncrate of 1\ncrate of a\n", reused: false)
      report["reason"].as_s.should contain("takes a block")
    end
  end

  it "types the whole program again when a moved line holds __LINE__" do
    with_project("infer-reuse-line-constant") do |project|
      main = MAIN + "puts __LINE__\n"
      project.write("main.cr", main)
      line = main.lines.size
      expect_build(project, "Hello world\n11\n0\n#{line}\n", reused: false)
      project.write("main.cr", main.sub("    Helper.value + 10\n", "    base = Helper.value\n    base + 10\n"))
      report = expect_build(project, "Hello world\n11\n0\n#{line + 1}\n", reused: false)
      report["reason"].as_s.should contain("__LINE__")
    end
  end

  it "types the whole program again for a reopened class" do
    with_project("infer-reuse-reopen") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      # A reopening after the class: its method replaces the original.
      project.write("main.cr", MAIN.sub("counter = Counter.new\n", "class Counter\n  def greet(name : String) : String\n    \"Reopened \#{name}\"\n  end\nend\n\ncounter = Counter.new\n"))
      report = expect_build(project, "Reopened world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")
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

  it "re-types an edit in a method no macro read, when macros read other methods" do
    with_project("infer-reuse-macro-other") do |project|
      reading_main = MAIN + "puts {{ Counter.methods.map(&.body.stringify).join(\"|\").size }}\n"
      project.write("main.cr", reading_main)
      _, first_output, _ = project.build
      first_output.should_not be_nil

      project.write("helper.cr", HELPER.sub("    1\n", "    5\n"))
      result, printed, report = project.build
      result.should be_success
      report["reused"].as_bool.should be_true
      report["verify_differences"].as_i.should eq(0)
      printed.should eq(first_output.try &.sub("11\n", "15\n"))
    end
  end

  it "runs a macro's program again and types the program fresh when its output changes" do
    with_project("infer-reuse-macro-run") do |project|
      project.write("number.cr", "puts File.read(ARGV[0]).strip\n")
      project.write("number.txt", "7\n")
      run_main = MAIN + "puts {{ run(\"./number\", \"number.txt\") }}\n"
      project.write("main.cr", run_main)
      expect_build(project, "Hello world\n11\n0\n7\n", reused: false)

      project.write("helper.cr", HELPER.sub("    1\n", "    5\n"))
      expect_build(project, "Hello world\n15\n0\n7\n", reused: true)

      project.write("number.txt", "8\n")
      project.write("helper.cr", HELPER)
      report = expect_build(project, "Hello world\n11\n0\n8\n", reused: false)
      report["reason"].as_s.should contain("whose output changed")
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
      result.status.success?.should be_false
      printed.should be_nil
      result.error.should contain("expected argument #1 to 'Int32#+'")

      project.write("main.cr", MAIN.sub("Helper.value + 10", "Helper.value + 20"))
      expect_build(project, "Hello world\n21\n0\n", reused: true)
    end
  end

  it "prunes dispatch again when a re-typed body creates a type that was left out" do
    with_project("infer-reuse-prune-dispatch") do |project|
      main = <<-CRYSTAL
        module Greeter
          abstract def greet : Int32
        end

        class Plain
          include Greeter

          def greet : Int32
            1
          end
        end

        class NeverMade
          include Greeter

          def greet : Int32
            2
          end
        end

        module Factory
          def self.make : Greeter
            Plain.new
          end
        end

        puts Factory.make.greet
        CRYSTAL
      project.write("main.cr", main)
      flags = ["-Dprune_dispatch"]
      expect_build(project, "1\n", reused: false, list_of_extra_args: flags)

      project.write("main.cr", main.sub("    Plain.new\n", "    NeverMade.new\n"))
      expect_build(project, "2\n", reused: true, list_of_extra_args: flags)

      project.write("main.cr", main)
      expect_build(project, "1\n", reused: true, list_of_extra_args: flags)
    end
  end
end
