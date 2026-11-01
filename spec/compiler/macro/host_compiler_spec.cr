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
end
