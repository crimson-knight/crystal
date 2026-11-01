require "../../spec_helper"

describe "Program#host_compiler" do
  it "compiles macro run programs without optimizations, one module per type" do
    program = Crystal::Program.new
    host_compiler = program.host_compiler

    host_compiler.optimization_mode.should eq(Crystal::Compiler::OptimizationMode::O0)
    host_compiler.single_module?.should be_false
  end

  it "keeps macro run programs unoptimized when the program itself is a release build" do
    compiler = Crystal::Compiler.new
    compiler.release!
    program = Crystal::Program.new
    program.compiler = compiler
    host_compiler = program.host_compiler

    host_compiler.optimization_mode.should eq(Crystal::Compiler::OptimizationMode::O0)
    host_compiler.single_module?.should be_false
    host_compiler.n_threads.should eq(compiler.n_threads)
  end

  it "gives macro run programs the release flag, without adding it to the program's compiler" do
    compiler = Crystal::Compiler.new
    compiler.flags = ["custom"]
    program = Crystal::Program.new
    program.compiler = compiler
    host_compiler = program.host_compiler

    host_compiler.flags.should eq(["custom", "release"])
    compiler.flags.should eq(["custom"])
  end

  {false, true}.each do |release|
    it "compiles a macro run program that sees the release flag (#{release ? "release" : "debug"} build)" do
      with_tempfile("macro_run_release_flag_#{release ? "release" : "debug"}") do |directory|
        Dir.mkdir_p(directory)
        File.write(File.join(directory, "print_release_flag.cr"), %(print "macro run release flag: ", {{ flag?(:release) }}\n))
        program = File.join(directory, "program.cr")
        File.write(program, %(puts {{ run("./print_release_flag").stringify }}\n))
        executable = File.join(directory, "program")

        compiler = Crystal::Compiler.new
        compiler.release! if release
        ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
        result = compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)

        # The helper was compiled by this build, not reused from the cache.
        result.program.compiled_macros_cache.values.map(&.reused).should eq([false])
        Process.capture(executable).should eq("macro run release flag: true\n")
      end
    end
  end
end
