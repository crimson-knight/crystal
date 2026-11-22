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
  it "rebuilds an edited program and reuses the object files of unchanged modules" do
    with_tempfile("edited_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      # A body the code generator does not inline: only the module of
      # `Helper` changes.
      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 1\n  end\nend\n")
      File.write(program, %(require "./helper"\nputs Helper.value\n))

      build_incrementally(program, executable)
      Process.capture(executable).should eq("1\n")

      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 999\n  end\nend\n")
      File.touch(helper, Time.utc + 5.seconds)
      rebuild = build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
      rebuild.@last_modules_total.should be > 1

      build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
    end
  end

  it "rebuilds a module that inlines a body another file changed" do
    with_tempfile("inlined_body_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      user = File.join(directory, "user.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      # `Helper.value` is inlined into `User#show`, in the module of `User`,
      # whose own defs are all in user.cr. `Helper.other` is not inlined, so
      # helper.cr has a module of its own as well.
      helper_source = "module Helper\n  def self.value\n    1\n  end\n\n  def self.other(x)\n    x > 0 ? 10 : 20\n  end\nend\n"
      File.write(helper, helper_source)
      File.write(user, "class User\n  def initialize(@n : Int32)\n  end\n\n  def show\n    puts Helper.value + Helper.other(@n)\n  end\nend\n")
      File.write(program, %(require "./helper"\nrequire "./user"\nUser.new(ARGV.size).show\n))

      build_incrementally(program, executable)
      Process.capture(executable).should eq("21\n")

      File.write(helper, helper_source.sub("    1\n", "    100\n"))
      File.touch(helper, Time.utc + 5.seconds)
      build_incrementally(program, executable)
      Process.capture(executable).should eq("120\n")
    end
  end
end
