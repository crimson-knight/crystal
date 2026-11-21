require "./spec_helper"

private MULTI_TYPE_OUTPUT = <<-OUTPUT
  circle 3.14
  rectangle 7.0
  circle 0.79
  total 10.93
  {"shapes" => 3}

  OUTPUT

private HANDOFF_STATS_LINE = "object files were built and linked by a compiler process of their own"

private def build_with_four_threads(fixture_name, output_path, cache_dir, *extra_args)
  Process.capture_result(crystal, "build", "--threads", "4", "--stats", *extra_args,
    "-o", output_path, fixture_path(fixture_name),
    env: {"CRYSTAL_CACHE_DIR" => cache_dir})
end

private def list_of_cache_files(cache_dir, pattern) : Array(String)
  Dir.glob(File.join(cache_dir, "**", pattern))
end

describe "`crystal build` with the object stage handoff" do
  it "builds, links and reports from the process that takes over, and the program runs" do
    with_tempfile("handoff-cache") do |cache_dir|
      with_temp_executable "handoff" do |output_path|
        build = build_with_four_threads("multi-type.cr", output_path, cache_dir, "-O3", "--progress").should(be_success)

        build.output.should contain(HANDOFF_STATS_LINE)
        build.output.should contain("object files were built by 4 worker processes")
        build.output.should contain("no previous .o files were reused")
        build.output.should match(/modules in flight at most: \d+\.\d MB of bitcode, estimated \d+ MB of worker memory \(budget \d+ MB\)/)

        # Every stage is timed once, in the order of a build without handoff.
        list_of_stage_names = build.output.split(/[\r\n]/).compact_map { |line| line.match(/^([A-Za-z][^:\[]*): +\d\d:\d\d:\d\d\.\d+ \(/).try(&.[1]) }
        list_of_stage_names.count("Codegen (crystal)").should eq(1)
        list_of_stage_names.count("Codegen (bc+obj)").should eq(1)
        list_of_stage_names.count("Codegen (linking)").should eq(1)
        list_of_stage_names.last(4).should eq(["Codegen (crystal)", "Codegen (bc+obj)", "Codegen (linking)", "dsymutil"])
        build.output.should match(/\[\d+\/16\] \[\d+\/\d+\] Codegen \(bc\+obj\)/)

        list_of_cache_files(cache_dir, "object-stage-handoff.json").should be_empty
        {% if flag?(:darwin) %}
          File.exists?("#{output_path}.dwarf").should be_true
        {% end %}

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))
      end
    end
  end

  it "hands over modules that IR generation spilled to disk in several parts" do
    with_tempfile("handoff-spill-cache") do |cache_dir|
      with_temp_executable "handoff-spill" do |output_path|
        build = build_with_four_threads("multi-type.cr", output_path, cache_dir, "--resident-modules", "2").should(be_success)
        build.output.should contain(HANDOFF_STATS_LINE)
        build.output.should match(/modules made of several parts: [1-9]\d/)
        build.output.should contain("no previous .o files were reused")

        # Every unit has one object, built from all of its parts.
        list_of_bitcode_files = list_of_cache_files(cache_dir, "*.bc")
        list_of_part_files = list_of_bitcode_files.select(&.matches?(/\.part\d+\.bc\z/))
        list_of_part_files.size.should be > 10
        (list_of_bitcode_files - list_of_part_files).each do |bitcode_file|
          File.size(bitcode_file.rchop(".bc") + ".o").should be > 0
        end

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))

        unchanged_build = build_with_four_threads("multi-type.cr", output_path, cache_dir, "--resident-modules", "2").should(be_success)
        unchanged_build.output.should contain("all previous .o files were reused")
      end
    end
  end

  it "reuses the object files of an unchanged build and rebuilds only a missing one" do
    with_tempfile("handoff-reuse-cache") do |cache_dir|
      with_temp_executable "handoff-reuse" do |output_path|
        build_with_four_threads("multi-type.cr", output_path, cache_dir).should(be_success)
        list_of_object_files = list_of_cache_files(cache_dir, "*.o")
        list_of_object_files.size.should be > 4

        unchanged_build = build_with_four_threads("multi-type.cr", output_path, cache_dir).should(be_success)
        unchanged_build.output.should contain("all previous .o files were reused")
        unchanged_build.output.should_not contain("worker processes")
        unchanged_build.output.should_not contain(HANDOFF_STATS_LINE)

        circle_object_file = list_of_object_files.find!(&.includes?("C-ircle"))
        File.delete(circle_object_file)

        partial_build = build_with_four_threads("multi-type.cr", output_path, cache_dir).should(be_success)
        partial_build.output.should contain("#{list_of_object_files.size - 1}/#{list_of_object_files.size} .o files were reused")
        partial_build.output.should match(/These modules were not reused:\n - Circle \(C-ircle\S*\.bc\)\n/)
        partial_build.output.should contain("object files were built by 1 worker processes")
        partial_build.output.should contain(HANDOFF_STATS_LINE)
        File.size(circle_object_file).should be > 0

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))
      end
    end
  end

  it "exits with the status and the message of a build without handoff when the link fails" do
    with_tempfile("handoff-link-failure-cache", "handoff-link-failure-cache-in-process") do |cache_dir, in_process_cache_dir|
      with_temp_executable "handoff-link-failure" do |output_path|
        missing_library = "--link-flags=-lobject_stage_handoff_spec_missing_library"

        handed_off_build = build_with_four_threads("multi-type.cr", output_path, cache_dir, missing_library)
        in_process_build = build_with_four_threads("multi-type.cr", output_path, in_process_cache_dir,
          missing_library, "--no-object-stage-handoff")

        handed_off_build.status.success?.should be_false
        handed_off_build.status.should eq(in_process_build.status)
        handed_off_build.error.should contain("Error: execution of command failed with exit status")
        handed_off_build.error.should contain("object_stage_handoff_spec_missing_library")
        handed_off_build.output.should_not contain(HANDOFF_STATS_LINE)
        handed_off_build.output.should contain("Codegen (bc+obj):")
        in_process_build.error.should contain("Error: execution of command failed with exit status")
        File.exists?(output_path).should be_false
      end
    end
  end

  it "reports the warnings of the build after the handoff, and fails on them when asked to" do
    with_tempfile("handoff-warning-cache") do |cache_dir|
      with_temp_executable "handoff-warning" do |output_path|
        build = build_with_four_threads("deprecated-call.cr", output_path, cache_dir).should(be_success)
        build.output.should contain(HANDOFF_STATS_LINE)
        build.error.should contain("Deprecated ::old_greeting")
        build.error.should contain("A total of 1 warnings were found.")

        File.delete(output_path)
        strict_build = build_with_four_threads("deprecated-call.cr", output_path, cache_dir,
          "--error-on-warnings", "--no-cache").should(be_failure)
        strict_build.output.should contain(HANDOFF_STATS_LINE)
        strict_build.error.should contain("A total of 1 warnings were found.")
        Process.capture_result(output_path).should(be_success).output.should eq("hello\n")
      end
    end
  end

  it "builds in the compiler process itself with --no-object-stage-handoff" do
    with_tempfile("handoff-off-cache") do |cache_dir|
      with_temp_executable "handoff-off" do |output_path|
        build = build_with_four_threads("multi-type.cr", output_path, cache_dir,
          "--no-object-stage-handoff", "--object-memory-budget", "1").should(be_success)
        build.output.should_not contain(HANDOFF_STATS_LINE)

        # A budget below any module's estimate lets one module run at a time.
        build.output.should contain("object files were built by 1 worker processes")
        build.output.should contain("(budget 1 MB)")

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(MULTI_TYPE_OUTPUT))
      end
    end
  end

  it "hands over an incremental build, whose cache takes effect once the executable is linked" do
    with_tempfile("handoff-incremental-cache", "handoff-incremental-program") do |cache_dir, program_dir|
      with_temp_executable "handoff-incremental" do |output_path|
        Dir.mkdir_p(program_dir)
        program_path = File.join(program_dir, "program.cr")
        build_program = ->(list_of_extra_args : Array(String)) do
          Process.capture_result(crystal, "build", "--incremental", "--threads", "4", "--stats", *list_of_extra_args,
            "-o", output_path, program_path, env: {"CRYSTAL_CACHE_DIR" => cache_dir})
        end

        File.write(program_path, "class Greeter\n  def greeting(count)\n    count > 0 ? \"hello again\" : \"hello\"\n  end\nend\nputs Greeter.new.greeting(ARGV.size)\n")
        first_build = build_program.call([] of String).should(be_success)
        first_build.output.should contain(HANDOFF_STATS_LINE)
        first_build.output.should contain("Parse cache:")
        list_of_cache_files(cache_dir, "incremental_cache.json").size.should eq(1)
        list_of_cache_files(cache_dir, "incremental_cache.pending.json").should be_empty
        Process.capture_result(output_path).should(be_success).output.should eq("hello\n")

        unchanged_build = build_program.call([] of String).should(be_success)
        unchanged_build.output.should contain("No source changes detected")

        # The edited program fails to link: the cache of the first build
        # stays, so the next build compiles the edit instead of keeping the
        # executable of the first build.
        File.write(program_path, "class Greeter\n  def greeting(count)\n    count > 0 ? \"goodbye again\" : \"goodbye\"\n  end\nend\nputs Greeter.new.greeting(ARGV.size)\n")
        File.touch(program_path, Time.utc + 5.seconds)
        build_program.call(["--link-flags=-lobject_stage_handoff_spec_missing_library"]).should(be_failure)

        edited_build = build_program.call([] of String).should(be_success)
        edited_build.output.should_not contain("No source changes detected")
        Process.capture_result(output_path).should(be_success).output.should eq("goodbye\n")
      end
    end
  end
end
