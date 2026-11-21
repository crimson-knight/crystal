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

  it "hands modules that IR generation spilled to disk to the workers and reuses their objects" do
    with_tempfile("object-workers-spill-cache") do |cache_dir|
      with_temp_executable "object-workers-spill" do |output_path|
        first_build = build_multi_type(output_path, cache_dir, "--resident-modules", "2").should(be_success)
        first_build.output.should contain("object files were built by 4 worker processes")
        first_build.output.should contain("no previous .o files were reused")
        first_build.output.should match(/module parts written to disk: [1-9]\d\d/)
        first_build.output.should match(/modules made of several parts: [1-9]\d/)

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))

        # Every spill file became a bitcode file of its unit. The worker
        # linked a unit's parts into the one object next to its .bc file.
        Dir.glob(File.join(cache_dir, "**", "*.new.bc")).should be_empty
        list_of_bitcode_files = Dir.glob(File.join(cache_dir, "**", "*.bc"))
        list_of_part_files = list_of_bitcode_files.select(&.matches?(/\.part\d+\.bc\z/))
        list_of_part_files.size.should be > 10
        (list_of_bitcode_files - list_of_part_files).each do |bitcode_file|
          File.exists?(bitcode_file.rchop(".bc") + ".o").should be_true
        end

        second_build = build_multi_type(output_path, cache_dir, "--resident-modules", "2").should(be_success)
        second_build.output.should contain("all previous .o files were reused")
        Dir.glob(File.join(cache_dir, "**", "*.new.bc")).should be_empty

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

        host_target = Process.capture_result(crystal, "--version").output[/Default target: (\S+)/, 1]
        settings = {target_triple: host_target, mcpu: nil, mattr: nil,
                    optimization_mode: "O3", code_model: "Default"}
        job = {bitcode_filename: bitcode_file, object_filename: object_path}
        job_without_bitcode = {bitcode_filename: bitcode_file + ".missing", object_filename: object_path + ".missing"}
        input = IO::Memory.new("#{settings.to_json}\n#{job.to_json}\n#{job_without_bitcode.to_json}\n")

        result = Process.capture_result(crystal, "internal-codegen-worker", input: input).should(be_success)

        list_of_outcome_lines = result.output.lines
        list_of_outcome_lines.size.should eq(2)
        list_of_outcome_lines[0].should eq("{}")
        list_of_outcome_lines[1].should contain(%("error_message":))
        list_of_outcome_lines[1].should contain(".missing")
        File.size(object_path).should be > 0
        File.exists?(object_path + ".missing").should be_false
      end
    end
  end
end
