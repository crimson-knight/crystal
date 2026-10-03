require "../spec_helper"
require "./spec_helper"
require "../support/env"

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

  it "accepts an unannotated method by default and enforces opt-in strict signatures" do
    compiler_executable = File.expand_path(".build/crystal")
    with_tempdir("compiler_strict_opt_in") do
      File.write("main.cr", "def answer\n  42\nend\nputs answer\n")

      with_env("CRYSTAL_STRICT_SIGNATURES": nil) do
        errors = IO::Memory.new
        status = Process.run(compiler_executable, ["build", "main.cr", "-o", "main"], error: errors)
        status.success?.should be_true, errors.to_s
        Process.capture("./main").should eq("42\n")

        errors.clear
        status = Process.run(compiler_executable, ["build", "--strict-signatures", "main.cr", "-o", "main"], error: errors)
        status.success?.should be_false
        errors.to_s.should contain("strict signatures")
      end

      with_env("CRYSTAL_STRICT_SIGNATURES": "1") do
        errors = IO::Memory.new
        status = Process.run(compiler_executable, ["build", "main.cr", "-o", "main"], error: errors)
        status.success?.should be_false
        errors.to_s.should contain("strict signatures")

        errors.clear
        status = Process.run(compiler_executable, ["build", "--no-strict-signatures", "main.cr", "-o", "main"], error: errors)
        status.success?.should be_true, errors.to_s
        Process.capture("./main").should eq("42\n")
      end
    end
  end

  describe "incremental compilation (on by default)" do
    it "rebuilds when the output was replaced by another build" do
      with_tempfile("incremental_a.cr", "incremental_b.cr") do |a, b|
        File.write(a, %(puts "A"))
        File.write(b, %(puts "B"))

        with_temp_executable "incremental_replaced" do |path|
          Crystal::Command.run ["build"].concat(program_flags_options).concat([a, "-o", path])
          Crystal::Command.run ["build"].concat(program_flags_options).concat([b, "-o", path])
          Process.capture(path).should eq("B\n")

          # Nothing in a.cr changed, but the output is b's binary now
          Crystal::Command.run ["build"].concat(program_flags_options).concat([a, "-o", path])
          Process.capture(path).should eq("A\n")
        end
      end
    end

    it "rebuilds when only the build settings changed" do
      with_tempfile("incremental_settings.cr") do |source|
        File.write(source, %(puts {{ flag?(:debug) }}))

        with_temp_executable "incremental_settings" do |path|
          Crystal::Command.run ["build"].concat(program_flags_options).concat([source, "-o", path])
          Process.capture(path).should eq("true\n")

          Crystal::Command.run ["build", "--no-debug"].concat(program_flags_options).concat([source, "-o", path])
          Process.capture(path).should eq("false\n")
        end
      end
    end

    it "rebuilds when a macro read external state" do
      with_tempfile("incremental_env.cr") do |source|
        File.write(source, %(puts {{ env("CRYSTAL_INCREMENTAL_SPEC_VALUE") }}))

        with_temp_executable "incremental_env" do |path|
          {"one", "two"}.each do |value|
            with_env("CRYSTAL_INCREMENTAL_SPEC_VALUE": value) do
              Crystal::Command.run ["build"].concat(program_flags_options).concat([source, "-o", path])
            end
            Process.capture(path).should eq("#{value}\n")
          end
        end
      end
    end

    it "skips a build that used `run`, and rebuilds when a file it read changes" do
      with_tempfile("incremental_run_sources") do |dir|
        Dir.mkdir_p(dir)
        main = File.join(dir, "main.cr")
        data = File.join(dir, "data.txt")
        hidden = File.join(dir, "hidden.txt")
        File.write(File.join(dir, "reader.cr"), <<-CRYSTAL)
          # Declares a file it reads beyond its arguments
          File.write(ENV["CRYSTAL_MACRO_RUN_DEPFILE"], "#{hidden}\n")
          print "\#{File.read(ARGV[0]).strip} + \#{File.read("#{hidden}").strip}".inspect
          CRYSTAL
        File.write(main, %(puts {{ run("./reader", "#{data}") }}))
        File.write(data, "one")
        File.write(hidden, "a")

        with_temp_executable "incremental_run" do |path|
          build = -> { Crystal::Command.run ["build"].concat(program_flags_options).concat([main, "-o", path]) }

          build.call
          Process.capture(path).should eq("one + a\n")

          mtime = File.info(path).modification_time
          build.call
          File.info(path).modification_time.should eq(mtime)

          File.write(data, "two")
          build.call
          Process.capture(path).should eq("two + a\n")

          File.write(hidden, "b")
          build.call
          Process.capture(path).should eq("two + b\n")
        end
      end
    end

    it "relinks correctly when a changed file drops an instantiation in another module" do
      with_tempfile("incremental_instantiation_main.cr", "incremental_instantiation_foo.cr") do |main, foo|
        File.write(main, %(require "./#{File.basename(foo)}"\nFoo.run))
        File.write(foo, <<-CRYSTAL)
          enum Color
            Green
          end

          module Foo
            def self.run
              puts String.build { |s| s << Color::Green }
            end
          end
          CRYSTAL

        with_temp_executable "incremental_instantiation" do |path|
          Crystal::Command.run ["build"].concat(program_flags_options).concat([main, "-o", path])
          Process.capture(path).should eq("Green\n")

          File.write(foo, <<-CRYSTAL)
            enum Color
              Green
            end

            module Foo
              def self.run
                puts "no color"
              end
            end
            CRYSTAL
          Crystal::Command.run ["build"].concat(program_flags_options).concat([main, "-o", path])
          Process.capture(path).should eq("no color\n")
        end
      end
    end

    it "doesn't reuse the output of a different in-memory source" do
      with_tempfile("incremental_in_memory.cr") do |filename|
        with_temp_executable "incremental_in_memory" do |path|
          flags = program_flags_options.select(&.starts_with?("-D")).map(&.lchop("-D"))

          {"1", "2"}.each do |value|
            compiler = create_spec_compiler
            compiler.flags.concat flags
            compiler.incremental = true
            compiler.compile Crystal::Compiler::Source.new(filename, "puts #{value}"), path
            Process.capture(path).should eq("#{value}\n")
          end
        end
      end
    end
  end
end
