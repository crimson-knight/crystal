require "./spec_helper"

private LARGE_TYPE_OUTPUT = <<-OUTPUT
  436
  4525
  36
  32

  OUTPUT

private def build_large_type(output_path, cache_dir, *extra_args)
  Process.capture_result(crystal, "build", "--threads", "4", "--stats", *extra_args,
    "-o", output_path, fixture_path("large-type.cr"),
    env: {"CRYSTAL_CACHE_DIR" => cache_dir})
end

private def list_of_ledger_files(cache_dir, extension) : Array(String)
  Dir.glob(File.join(cache_dir, "**", "L-edger*#{extension}")).select(&.matches?(/\/L-edger(35\d+)?\.o\w#{Regex.escape(extension)}\z/))
end

describe "`crystal build --module-segment-instructions`" do
  it "has object file workers build a large type as several object files, and the program runs" do
    with_tempfile("segments-cache") do |cache_dir|
      with_temp_executable "segments" do |output_path|
        build = build_large_type(output_path, cache_dir, "--module-segment-instructions", "40").should(be_success)

        build.output.should match(/types compiled as several object files: [1-9]\d* \(\d+ segments, at most \d\d+ for one type\)/)
        build.output.should contain("object files were built by 4 worker processes")
        build.output.should match(/longest object file job: \d+\.\d s \(\d+\.\d s of processor time\), /)
        list_of_ledger_files(cache_dir, ".o").size.should be > 10
        list_of_ledger_files(cache_dir, ".o").size.should eq(list_of_ledger_files(cache_dir, ".bc").size)

        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(LARGE_TYPE_OUTPUT))

        unchanged_build = build_large_type(output_path, cache_dir, "--module-segment-instructions", "40").should(be_success)
        unchanged_build.output.should contain("all previous .o files were reused")
      end
    end
  end

  it "builds the same program with one object file per type from 0" do
    with_tempfile("segments-off-cache") do |cache_dir|
      with_temp_executable "segments-off" do |output_path|
        build = build_large_type(output_path, cache_dir, "--module-segment-instructions", "0").should(be_success)

        build.output.should_not contain("types compiled as several object files")
        list_of_ledger_files(cache_dir, ".o").size.should eq(1)
        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(LARGE_TYPE_OUTPUT))
      end
    end
  end

  it "builds segments of modules spilled in parts, optimized, and reuses them" do
    with_tempfile("segments-spill-cache") do |cache_dir|
      with_temp_executable "segments-spill" do |output_path|
        list_of_flags = {"-O3", "--module-segment-instructions", "40", "--resident-modules", "2"}
        build = build_large_type(output_path, cache_dir, *list_of_flags).should(be_success)

        build.output.should match(/modules made of several parts: [1-9]/)
        list_of_ledger_files(cache_dir, ".o").size.should be > 10
        Process.capture_result(output_path)
          .should(be_success)
          .output.should(eq(LARGE_TYPE_OUTPUT))

        unchanged_build = build_large_type(output_path, cache_dir, *list_of_flags).should(be_success)
        unchanged_build.output.should contain("all previous .o files were reused")
      end
    end
  end

  it "rejects a negative limit" do
    with_tempfile("segments-negative-cache") do |cache_dir|
      with_temp_executable "segments-negative" do |output_path|
        build = build_large_type(output_path, cache_dir, "--module-segment-instructions", "-1")
        build.status.success?.should be_false
      end
    end
  end
end
