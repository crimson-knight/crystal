require "../../spec_helper"
require "file_utils"

# Builds a stand-in standard library (`<root>/src`, one symlink per entry of
# the real one, plus a macro run program) and points `CRYSTAL_PATH` at it.
# Then compiles the program into the cache once and copies that cache entry
# to `<root>/macro_run_seed`, as `scripts/seed_macro_run.cr` does for an
# installed compiler.
private def with_seeded_macro_run(&)
  real_stdlib_dir = File.dirname(Crystal::CrystalPath.new.find("prelude").first)
  with_tempfile("macro_run_seed") do |root|
    stdlib_dir = File.join(root, "src")
    Dir.mkdir_p(stdlib_dir)
    Dir.each_child(real_stdlib_dir) do |entry|
      File.symlink(File.join(real_stdlib_dir, entry), File.join(stdlib_dir, entry))
    end
    tool = File.join(stdlib_dir, "seeded_tool.cr")
    File.write(tool, %(print "seeded tool output"\n))

    with_env("CRYSTAL_PATH": stdlib_dir) do
      compiled = with_env("CRYSTAL_MACRO_RUN_SEED": "write") { new_program.macro_compile(tool) }
      compiled.reused.should be_false

      cache_entry = File.dirname(compiled.filename)
      seed_dir = File.join(root, "macro_run_seed", "seeded_tool.cr")
      Dir.mkdir_p(seed_dir)
      {"macro_run", "recorded_requires", "requires", "compiler", "source_digests"}.each do |file|
        FileUtils.cp(File.join(cache_entry, file), File.join(seed_dir, file))
      end
      FileUtils.rm_rf(cache_entry)

      yield tool, File.join(seed_dir, "macro_run")
    end
  end
end

private def new_program(flags = [] of String)
  compiler = Crystal::Compiler.new
  compiler.flags = flags
  program = Crystal::Program.new
  program.compiler = compiler
  program
end

describe "Program#macro_compile with a macro run seed" do
  it "runs the seeded program instead of compiling it into an empty cache" do
    with_seeded_macro_run do |tool, seeded_executable|
      compiled = new_program.macro_compile(tool)

      compiled.reused.should be_true
      compiled.filename.should eq(seeded_executable)
      Process.capture(compiled.filename).should eq("seeded tool output")
    end
  end

  it "compiles the program when a file it was built from has changed" do
    with_seeded_macro_run do |tool, seeded_executable|
      File.touch(tool, Time.utc + 1.hour)
      compiled = new_program.macro_compile(tool)

      compiled.reused.should be_false
      compiled.filename.should_not eq(seeded_executable)
    end
  end

  it "compiles the program when a file it was built from has new content and the same timestamp" do
    with_seeded_macro_run do |tool, seeded_executable|
      modification_time = File.info(tool).modification_time
      File.write(tool, %(print "edited tool output"\n))
      File.touch(tool, modification_time)
      compiled = new_program.macro_compile(tool)

      compiled.reused.should be_false
      Process.capture(compiled.filename).should eq("edited tool output")
    end
  end

  it "compiles the program while a seed is being written" do
    with_seeded_macro_run do |tool, seeded_executable|
      compiled = with_env("CRYSTAL_MACRO_RUN_SEED": "write") { new_program.macro_compile(tool) }

      compiled.reused.should be_false
      compiled.filename.should_not eq(seeded_executable)
    end
  end

  it "compiles the program when the build defines flags the seed was not built with" do
    with_seeded_macro_run do |tool, seeded_executable|
      compiled = new_program(flags: ["custom"]).macro_compile(tool)

      compiled.reused.should be_false
      compiled.filename.should_not eq(seeded_executable)
    end
  end

  it "compiles the program when another compiler built the seed" do
    with_seeded_macro_run do |tool, seeded_executable|
      File.write(File.join(File.dirname(seeded_executable), "compiler"), "Crystal 0.0.0\n")
      compiled = new_program.macro_compile(tool)

      compiled.reused.should be_false
      compiled.filename.should_not eq(seeded_executable)
    end
  end
end
