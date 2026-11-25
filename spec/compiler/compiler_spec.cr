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
          # `Crystal::Command.run` consumes its arguments: give each run a new array.
          build = ["build", "--incremental"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          Crystal::Command.run build.dup
          File.exists?(dwarf_path).should be_false
          executable_time = File.info(path).modification_time

          Crystal::Command.run build.dup.push("--dsymutil")
          File.info(path).modification_time.should eq(executable_time)
          Process.capture(path).should eq("Hello!")
          File.exists?(dwarf_path).should be_true
        end
      end

      it "removes the .dwarf file of the executable a new link replaces" do
        with_tempfile("compiler_spec_dsymutil_relink", "compiler_spec_dsymutil_relink.dwarf") do |path, dwarf_path|
          Crystal::Command.run ["build", "--dsymutil"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          File.exists?(dwarf_path).should be_true

          Crystal::Command.run ["build", "--no-debug"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])
          Process.capture(path).should eq("Hello!")
          File.exists?(dwarf_path).should be_false
        end
      end
    {% end %}
  end
end

describe "Crystal::Compiler.wasm_spill_and_asyncify_flags" do
  it "spills pointers before asyncify in a build with fibers and a collector" do
    flags = Crystal::Compiler.wasm_spill_and_asyncify_flags(skip_fibers: false, needs_pointer_spills: true)
    flags.should start_with("--spill-pointers --asyncify ")
    flags.should contain("--pass-arg=asyncify-removelist@_start")
  end

  it "spills pointers without fibers" do
    Crystal::Compiler.wasm_spill_and_asyncify_flags(skip_fibers: true, needs_pointer_spills: true)
      .should eq("--spill-pointers")
  end

  it "runs only asyncify with -Dgc_none" do
    Crystal::Compiler.wasm_spill_and_asyncify_flags(skip_fibers: false, needs_pointer_spills: false)
      .should start_with("--asyncify ")
  end

  it "runs neither without fibers and with -Dgc_none" do
    Crystal::Compiler.wasm_spill_and_asyncify_flags(skip_fibers: true, needs_pointer_spills: false).should be_nil
  end
end
