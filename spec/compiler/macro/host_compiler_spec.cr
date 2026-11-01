require "../../spec_helper"
require "../spec_helper"

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

  [[] of String, ["--release"]].each do |mode_options|
    it "builds a program whose macro run program checks the release flag (#{mode_options.join(" ").presence || "debug"})" do
      with_temp_executable "macro_run_release_flag" do |path|
        Crystal::Command.run ["build"].concat(program_flags_options).concat(mode_options).concat([compiler_datapath("macro_run", "release_flag.cr"), "-o", path])

        Process.capture(path).should eq("macro run release flag: true\n")
      end
    end
  end
end
