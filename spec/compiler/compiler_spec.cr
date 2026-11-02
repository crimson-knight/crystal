require "../spec_helper"
require "./spec_helper"

describe "Compiler" do
  it "has a valid version" do
    SemanticVersion.parse(Crystal::Config.version)
  end

  it "compiles a file" do
    with_temp_executable "compiler_spec_output" do |path|
      Crystal::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])

      File.exists?(path).should be_true

      Process.capture(path).should eq("Hello!")
    end
  end

  it "runs subcommand in preference to a filename " do
    Dir.cd compiler_datapath do
      with_temp_executable "compiler_spec_output" do |path|
        Crystal::Command.run ["build"].concat(program_flags_options).concat(["compiler_sample", "-o", path])

        File.exists?(path).should be_true

        Process.capture(path).should eq("Hello!")
      end
    end
  end

  describe "dsymutil" do
    it "is skipped for unoptimized builds and runs for optimized builds" do
      compiler = Crystal::Compiler.new
      compiler.dsymutil?.should be_false

      compiler.optimization_mode = Crystal::Compiler::OptimizationMode::O2
      compiler.dsymutil?.should be_true

      compiler = Crystal::Compiler.new
      compiler.release!
      compiler.dsymutil?.should be_true
    end

    it "follows an explicit setting" do
      compiler = Crystal::Compiler.new
      compiler.dsymutil = true
      compiler.dsymutil?.should be_true

      compiler = Crystal::Compiler.new
      compiler.release!
      compiler.dsymutil = false
      compiler.dsymutil?.should be_false
    end

    {% if flag?(:darwin) %}
      it "writes the .dwarf file only when asked for in a development build" do
        # The tempfile helper removes both files afterward.
        with_tempfile("compiler_spec_dsymutil", "compiler_spec_dsymutil.dwarf") do |path, dwarf_path|
          Crystal::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          Process.capture(path).should eq("Hello!")
          File.exists?(dwarf_path).should be_false

          Crystal::Command.run ["build", "--dsymutil"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          Process.capture(path).should eq("Hello!")
          File.exists?(dwarf_path).should be_true
        end
      end

      it "writes the .dwarf file when asked for after an incremental build that reuses the program" do
        with_tempfile("compiler_spec_dsymutil_incremental", "compiler_spec_dsymutil_incremental.dwarf") do |path, dwarf_path|
          build = ["build", "--incremental"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          Crystal::Command.run build
          File.exists?(dwarf_path).should be_false

          Crystal::Command.run build + ["--dsymutil"]
          Process.capture(path).should eq("Hello!")
          File.exists?(dwarf_path).should be_true
        end
      end
    {% end %}
  end
end
