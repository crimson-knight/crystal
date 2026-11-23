require "./spec_helper"
require "json"

# Builds with persisted type inference on (`CRYSTAL_INFER_PERSIST=1`): every
# build is a fresh compiler process that loads the snapshot the build before
# wrote to the cache folder. Verification is on: a build that reuses the
# loaded program also types the program from scratch and fails when the two
# differ.
private class InferPersistProject
  getter directory : String

  def initialize(@directory : String)
    Dir.mkdir_p(@directory)
  end

  def write(name : String, text : String) : Nil
    path = File.join(@directory, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def report_filename : String
    File.join(@directory, "report.json")
  end

  def cache_directory : String
    File.join(@directory, "cache")
  end

  # The snapshot files in the cache folder.
  def list_of_snapshots : Array(String)
    Dir.glob(File.join(cache_directory, "**", "infer_program.bin"))
  end

  # Builds `main.cr` and returns the build result, what the program printed
  # (or `nil` when the build failed) and the report of the type-inference
  # decision.
  def build(extra_env = {} of String => String) : {Process::Result, String?, JSON::Any}
    File.delete?(report_filename)
    env = {
      "CRYSTAL_CACHE_DIR"          => cache_directory,
      "CRYSTAL_INFER_PERSIST"      => "1",
      "CRYSTAL_INFER_REUSE_VERIFY" => "1",
      "CRYSTAL_INFER_REUSE_REPORT" => report_filename,
    }
    env.merge!(extra_env)
    result = Process.capture_result([crystal, "build", "--incremental", "main.cr", "-o", "app"], env: env, chdir: @directory)
    report = JSON.parse(File.exists?(report_filename) ? File.read(report_filename) : "{}")
    printed = result.status.success? ? Process.capture_result(File.join(@directory, "app")).output : nil
    {result, printed, report}
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
    project = InferPersistProject.new(directory)
    project.write("helper.cr", HELPER)
    project.write("main.cr", MAIN)
    yield project
  end
end

private def expect_build(project, expected_output, reused : Bool, extra_env = {} of String => String)
  result, printed, report = project.build(extra_env)
  result.should be_success
  printed.should eq(expected_output)
  report["reused"].as_bool.should eq(reused)
  if reused
    report["verify_differences"].as_i.should eq(0)
    report["snapshot_load_seconds"].as_f.should be > 0
  end
  report
end

# Replaces the header of the snapshot with what *block* makes of it.
private def rewrite_header(filename : String, & : JSON::Any -> String) : Nil
  bytes = File.read(filename).to_slice
  magic = 8
  size = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[magic, 4])
  header = JSON.parse(String.new(bytes[magic + 4, size]))
  new_header = yield header
  File.open(filename, "w") do |file|
    file.write(bytes[0, magic])
    file.write_bytes(new_header.bytesize.to_u32, IO::ByteFormat::LittleEndian)
    file.write(new_header.to_slice)
    file.write(bytes[(magic + 4 + size)..])
  end
end

describe "`crystal build --incremental` with persisted type inference (CRYSTAL_INFER_PERSIST=1)" do
  it "loads the typed program in a fresh process and re-types an edited body" do
    with_project("infer-persist-body") do |project|
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("no snapshot")
      project.list_of_snapshots.size.should eq(1)

      project.write("main.cr", MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")))
      report = expect_build(project, "Hi world\n11\n0\n", reused: true)
      report["retyped_instances"].as_i.should eq(1)

      # The build that reused wrote the snapshot again: the restore re-types
      # against the edited text, and so does an edit in another file.
      project.write("main.cr", MAIN)
      expect_build(project, "Hello world\n11\n0\n", reused: true)
      project.write("helper.cr", HELPER.sub("    1\n", "    5\n"))
      expect_build(project, "Hello world\n15\n0\n", reused: true)
    end
  end

  it "adds a method an edited body calls, and types a new class fresh" do
    with_project("infer-persist-new-method") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      added = MAIN.sub("  def total : Int32\n    Helper.value + 10\n", "  def bonus : Int32\n    5\n  end\n\n  def total : Int32\n    Helper.value + 10 + bonus\n")
      project.write("main.cr", added)
      report = expect_build(project, "Hello world\n16\n0\n", reused: true)
      report["added_methods"].as_i.should eq(1)

      project.write("main.cr", added + "class Other\nend\nputs Other.new.is_a?(Other)\n")
      report = expect_build(project, "Hello world\n16\n0\ntrue\n", reused: false)
      report["reason"].as_s.should contain("outside a method body")

      # The fresh build wrote a new snapshot.
      project.write("main.cr", (added + "class Other\nend\nputs Other.new.is_a?(Other)\n").sub("    5\n", "    6\n"))
      expect_build(project, "Hello world\n17\n0\ntrue\n", reused: true)
    end
  end

  it "types the program fresh when the snapshot is damaged" do
    with_project("infer-persist-corrupt") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      snapshot = project.list_of_snapshots.first
      bytes = File.read(snapshot).to_slice
      File.write(snapshot, bytes[0, bytes.size // 2])
      project.write("main.cr", MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")))
      report = expect_build(project, "Hi world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("could not be read")

      File.write(snapshot, "not a snapshot at all")
      project.write("main.cr", MAIN)
      report = expect_build(project, "Hello world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("not a snapshot file")
    end
  end

  it "types the program fresh for a snapshot from another compiler build" do
    with_project("infer-persist-compiler") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      rewrite_header(project.list_of_snapshots.first) do |header|
        hash = header.as_h.dup
        hash["compiler_identity"] = JSON::Any.new("another-compiler")
        hash.to_json
      end
      project.write("main.cr", MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")))
      report = expect_build(project, "Hi world\n11\n0\n", reused: false)
      report["reason"].as_s.should contain("another compiler build")
    end
  end

  it "types the program fresh when the compiler environment changes" do
    with_project("infer-persist-env") do |project|
      expect_build(project, "Hello world\n11\n0\n", reused: false)
      project.write("main.cr", MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")))
      report = expect_build(project, "Hi world\n11\n0\n", reused: false, extra_env: {"CRYSTAL_INFER_PERSIST_SPEC_SETTING" => "1"})
      report["reason"].as_s.should contain("environment differs")
    end
  end

  it "types the program fresh when a require finds other files" do
    with_project("infer-persist-require") do |project|
      project.write("parts/one.cr", "ONE = 1\n")
      project.write("main.cr", %(require "./parts/*"\n) + MAIN + "puts ONE\n")
      expect_build(project, "Hello world\n11\n0\n1\n", reused: false)
      project.write("parts/two.cr", "TWO = 2\n")
      project.write("main.cr", %(require "./parts/*"\n) + MAIN.sub(%("Hello \#{name}"), %("Hi \#{name}")) + "puts ONE\n")
      report = expect_build(project, "Hi world\n11\n0\n1\n", reused: false)
      report["reason"].as_s.should contain("finds other files")
    end
  end

  it "types the program fresh when a macro's program prints something else" do
    with_project("infer-persist-macro-run") do |project|
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
end
