require "../../../spec_helper"

private def with_project(shard_yml : String?, files : Array(String), &)
  with_tempfile("project_main") do |dir|
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "shard.yml"), shard_yml) if shard_yml
    files.each do |file|
      path = File.join(dir, file)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
    yield dir
  end
end

describe "Crystal.project_main_file" do
  it "uses the main of the first target" do
    with_project(<<-YAML, ["src/first.cr", "src/second.cr"]) do |dir|
      name: app
      targets:
        # the server
        server:
          main: src/first.cr
        worker:
          main: "src/second.cr"
      YAML
      Crystal.project_main_file(dir).should eq(Crystal.relative_filename(File.join(dir, "src/first.cr")))
    end
  end

  it "skips a target whose main doesn't exist" do
    with_project(<<-YAML, ["src/second.cr"]) do |dir|
      name: app
      targets:
        server:
          main: src/first.cr
        worker:
          main: 'src/second.cr' # quoted
      YAML
      Crystal.project_main_file(dir).should eq(Crystal.relative_filename(File.join(dir, "src/second.cr")))
    end
  end

  it "falls back to src/<name>.cr" do
    with_project("name: app\nversion: 0.1.0\n", ["src/app.cr"]) do |dir|
      Crystal.project_main_file(dir).should eq(Crystal.relative_filename(File.join(dir, "src/app.cr")))
    end
  end

  it "is nil without a shard.yml or a main file" do
    with_project(nil, ["src/app.cr"]) do |dir|
      Crystal.project_main_file(dir).should be_nil
    end
    with_project("name: app\n", [] of String) do |dir|
      Crystal.project_main_file(dir).should be_nil
    end
  end
end
