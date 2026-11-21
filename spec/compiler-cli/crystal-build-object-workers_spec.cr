require "./spec_helper"
require "json"

private MULTI_TYPE_OUTPUT = <<-OUTPUT
  circle 3.14
  rectangle 7.0
  circle 0.79
  total 10.93
  {"shapes" => 3}

  OUTPUT

private def build_multi_type(output_path, cache_dir, *extra_args)
  Process.capture_result(crystal, "build", "-O3", "--threads", "4", "--stats", *extra_args,
    "-o", output_path, fixture_path("multi-type.cr"),
    env: {"CRYSTAL_CACHE_DIR" => cache_dir})
end

describe "`crystal build` with object file workers" do
  it "builds a multi-module program in worker processes and reuses its objects" do
    with_tempfile("object-workers-cache") do |cache_dir|
      with_temp_executable "object-workers" do |output_path|
        first_build = build_multi_type(output_path, cache_dir).should(be_success)
        first_build.output.should contain("object files were built by 4 worker processes")
        first_build.output.should contain("no previous .o files were reused")

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))

        list_of_bitcode_files = Dir.glob(File.join(cache_dir, "**", "*.bc"))
        list_of_bitcode_files.size.should be > 4
        list_of_bitcode_files.each do |bitcode_file|
          File.exists?(bitcode_file.rchop(".bc") + ".o").should be_true
        end

        second_build = build_multi_type(output_path, cache_dir).should(be_success)
        second_build.output.should contain("all previous .o files were reused")
        second_build.output.should_not contain("worker processes")

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))
      end
    end
  end

  it "builds an object file from a bitcode file in the worker subcommand" do
    with_tempfile("object-worker-cache", "object-worker.o") do |cache_dir, object_path|
      with_temp_executable "object-worker" do |output_path|
        build_multi_type(output_path, cache_dir).should(be_success)
        bitcode_file = Dir.glob(File.join(cache_dir, "**", "*.bc")).sort!.first

        version_lines = Process.capture(crystal, "--version").lines
        host_target = version_lines.find!(&.starts_with?("Default target: ")).lchop("Default target: ")
        settings = {target_triple: host_target, mcpu: nil, mattr: nil,
                    optimization_mode: "O3", code_model: "Default"}
        jobs = [
          {bitcode_filename: bitcode_file, object_filename: object_path},
          {bitcode_filename: bitcode_file + ".missing", object_filename: object_path + ".missing"},
        ]
        input = IO::Memory.new([settings, *jobs].join('\n', &.to_json) + "\n")

        result = Process.capture_result(crystal, "internal-codegen-worker", input: input).should(be_success)

        list_of_outcomes = result.output.lines.map { |line| JSON.parse(line)["error_message"].as_s? }
        list_of_outcomes.size.should eq(2)
        list_of_outcomes[0].should be_nil
        list_of_outcomes[1].to_s.should contain(".missing")
        File.size(object_path).should be > 0
        File.exists?(object_path + ".missing").should be_false
      end
    end
  end
end
