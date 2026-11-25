require "./spec_helper"

# A plain incremental build (no build server) keeps the previous executable
# when no file of the previous compilation changed. These are changes to the
# program that no such file shows.
private class IncrementalProject
  getter directory : String
  getter cache_directory : String

  def initialize(@directory : String, @cache_directory : String)
    Dir.mkdir_p(@directory)
  end

  def write(name : String, text : String) : Nil
    path = File.join(@directory, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # Builds `main.cr` and returns the build result and what the program
  # printed (`nil` when the build failed).
  def build : {Process::Result, String?}
    result = Process.capture_result([crystal, "build", "--incremental", "--stats", "main.cr", "-o", "app"],
      env: {"CRYSTAL_CACHE_DIR" => @cache_directory}, chdir: @directory)
    printed = result.status.success? ? Process.capture_result(File.join(@directory, "app")).output : nil
    {result, printed}
  end
end

private NO_CHANGES_LINE = "No source changes detected"

describe "`crystal build --incremental` without a build server" do
  it "builds again when a glob require finds a new file" do
    with_tempfile("glob-project", "glob-cache") do |project_dir, cache_dir|
      project = IncrementalProject.new(project_dir, cache_dir)
      project.write("main.cr", %(require "./parts/*"\nputs "main"\n))
      project.write("parts/a.cr", %(puts "a"\n))

      result, printed = project.build
      result.should be_success
      printed.should eq("a\nmain\n")

      result, printed = project.build
      result.output.should contain(NO_CHANGES_LINE)
      printed.should eq("a\nmain\n")

      project.write("parts/b.cr", %(puts "b"\n))
      result, printed = project.build
      result.should be_success
      result.output.should_not contain(NO_CHANGES_LINE)
      printed.should eq("a\nb\nmain\n")

      File.delete(File.join(project_dir, "parts", "a.cr"))
      result, printed = project.build
      result.should be_success
      result.output.should_not contain(NO_CHANGES_LINE)
      printed.should eq("b\nmain\n")
    end
  end

  it "builds again when a file a macro program reads changes" do
    with_tempfile("run-project", "run-cache") do |project_dir, cache_dir|
      project = IncrementalProject.new(project_dir, cache_dir)
      project.write("main.cr", %({{ run("./tools/generate", "data/greeting.txt") }}\n))
      project.write("tools/generate.cr", %(print "puts \#{File.read(ARGV[0]).strip.inspect}"\n))
      project.write("data/greeting.txt", "hello\n")

      result, printed = project.build
      result.should be_success
      printed.should eq("hello\n")

      result, printed = project.build
      result.output.should contain(NO_CHANGES_LINE)
      printed.should eq("hello\n")

      project.write("data/greeting.txt", "goodbye\n")
      result, printed = project.build
      result.should be_success
      result.output.should_not contain(NO_CHANGES_LINE)
      printed.should eq("goodbye\n")
    end
  end
end
