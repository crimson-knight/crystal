require "../spec_helper"

private def build_incrementally(program : String, executable : String) : Crystal::Compiler
  compiler = Crystal::Compiler.new
  compiler.incremental = true
  # Two or more threads compile each module on a worker thread with an
  # isolated LLVM context, the path that disposes contexts.
  compiler.n_threads = 2
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  compiler
end

describe "Compiler with --incremental" do
  it "rebuilds an edited program while it skips the modules of unchanged files" do
    with_tempfile("edited_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      # A body the code generator does not inline, so its module is mapped to
      # this file and the rebuild can skip the modules of the other files.
      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 1\n  end\nend\n")
      File.write(program, %(require "./helper"\nputs Helper.value\n))

      build_incrementally(program, executable)
      Process.capture(executable).should eq("1\n")

      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 999\n  end\nend\n")
      File.touch(helper, Time.utc + 5.seconds)
      rebuild = build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
      rebuild.@last_modules_skipped.should be > 0

      build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
    end
  end
end
