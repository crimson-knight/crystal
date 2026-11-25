require "../../spec_helper"

# A program whose top-level code passes `Registry#draw` a long block, as an
# Amber app's `config/routes.cr` does: each `route` makes a proc and adds it
# with the receiver of `with ... yield`, and a variable of the file counts
# the routes. The block of the second `draw` raises when the program is
# started with `boom`, inside a `begin ... rescue`.
private ROUTE_COUNT = 48

private def routes_source(list_of_paths : Array(String)) : String
  String.build do |io|
    list_of_paths.each_with_index do |path, index|
      io << "    route " << path.inspect << ", " << index << "\n"
      io << "    count &+= 1\n" if index % 5 == 0
    end
  end
end

private def list_of_initial_paths : Array(String)
  Array.new(ROUTE_COUNT) { |index| "/r#{index}" }
end

private def registry_source : String
  <<-CRYSTAL
    class Registry
      getter list_of_entries = [] of String

      def draw(name : String, &)
        with self yield
        @list_of_entries << "drawn \#{name}"
      end

      def add(path : String, handler : Proc(Int32, Int32)) : Nil
        @list_of_entries << "\#{path}=\#{handler.call(2)}"
      end

      def fail_on(mode : String) : Nil
        raise "failed in \#{mode}" if ARGV[0]? == mode
      end
    end

    macro route(path, factor)
      %handler = ->(value : Int32) { value &* {{factor}} }
      %label = {{path}}
      add(%label, %handler)
    end
    CRYSTAL
end

private def program_source(list_of_paths : Array(String), inserted : Bool) : String
  <<-CRYSTAL
    require "./registry"

    count = 0
    registry = Registry.new
    registry.draw("main") do
    #{inserted ? %(    add("/inserted", ->(value : Int32) { value &* 0 })\n) : ""}#{routes_source(list_of_paths)}
      maybe = ARGV[0]? == "nil" ? nil : "kept"
      add(maybe || "none", ->(value : Int32) { value })
    end
    begin
      registry.draw("guarded") do
    #{routes_source(list_of_paths.map { |path| "/guarded#{path}" })}
        fail_on("boom")
    #{routes_source(list_of_paths.map { |path| "/after#{path}" })}
      end
    rescue error
      puts "rescued: \#{error.message}"
    end
    puts registry.list_of_entries.join(",")
    puts count
    CRYSTAL
end

# The output a program of *list_of_paths* prints, computed in Crystal.
private def expected_output(list_of_paths : Array(String), *, boom : Bool = false, inserted : Bool = false) : String
  list_of_entries = [] of String
  list_of_entries << "/inserted=0" if inserted
  count = 0
  add_routes = ->(list_of_drawn : Array(String)) do
    list_of_drawn.each_with_index do |path, index|
      list_of_entries << "#{path}=#{index * 2}"
      count += 1 if index % 5 == 0
    end
  end
  add_routes.call(list_of_paths)
  list_of_entries << "kept=2"
  list_of_entries << "drawn main"
  add_routes.call(list_of_paths.map { |path| "/guarded#{path}" })
  rescued = nil
  if boom
    rescued = "rescued: failed in boom\n"
  else
    add_routes.call(list_of_paths.map { |path| "/after#{path}" })
    list_of_entries << "drawn guarded"
  end
  "#{rescued}#{list_of_entries.join(",")}\n#{count}\n"
end

private class MainPartsProgram
  getter directory : String
  getter list_of_paths : Array(String)
  getter? inserted = false
  @edit_count = 0

  def initialize(@directory : String)
    Dir.mkdir_p(@directory)
    @list_of_paths = list_of_initial_paths
    File.write(File.join(@directory, "registry.cr"), registry_source)
    write_program
  end

  def inserted=(@inserted : Bool) : Bool
    write_program
    @inserted
  end

  def program : String
    File.join(@directory, "program.cr")
  end

  def executable : String
    File.join(@directory, "program")
  end

  def list_of_paths=(@list_of_paths : Array(String)) : Array(String)
    write_program
    @list_of_paths
  end

  private def write_program : Nil
    File.write(program, program_source(@list_of_paths, @inserted))
    @edit_count += 1
    File.touch(program, Time.utc + (@edit_count * 5).seconds)
  end

  def build(*, parts : Bool = true) : Crystal::Compiler
    compiler = Crystal::Compiler.new
    compiler.incremental = true
    compiler.n_threads = 2
    ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
    with_env("CRYSTAL_MAIN_PART_NODES", "50") do
      with_env("CRYSTAL_MAIN_PARTS", parts ? nil : "0") do
        compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
      end
    end
    compiler
  end

  def output(list_of_arguments : Array(String) = [] of String) : String
    Process.capture([executable] + list_of_arguments)
  end

  # The object files of the parts in the cache, by name, with their
  # modification times.
  def part_objects : Hash(String, Time)
    cache_directory = Crystal::CacheDir.instance.directory_for(program)
    Dir.glob(File.join(cache_directory, "126main126*.o")).to_h do |path|
      {File.basename(path), File.info(path).modification_time}
    end
  end
end

private def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  ENV[name] = value
  begin
    yield
  ensure
    ENV[name] = previous
  end
end

private def with_main_parts_program(name : String, & : MainPartsProgram ->) : Nil
  with_tempfile(name) do |directory|
    yield MainPartsProgram.new(directory)
  end
end

describe "Code gen: top-level code in parts" do
  it "runs a long block of top-level code in parts, as it runs in the main function" do
    with_main_parts_program("main_parts_run") do |main_parts_program|
      main_parts_program.build
      main_parts_program.part_objects.size.should be > 4
      main_parts_program.output.should eq(expected_output(main_parts_program.list_of_paths))
      main_parts_program.output(["boom"]).should eq(expected_output(main_parts_program.list_of_paths, boom: true))
      main_parts_program.output(["nil"]).should contain("none=2")
    end
  end

  it "keeps top-level code in the main function when parts are off" do
    with_main_parts_program("main_parts_off") do |main_parts_program|
      main_parts_program.build(parts: false)
      main_parts_program.part_objects.should be_empty
      main_parts_program.output.should eq(expected_output(main_parts_program.list_of_paths))
    end
  end

  it "compiles only the part of an edited statement" do
    with_main_parts_program("main_parts_edit") do |main_parts_program|
      main_parts_program.build
      list_of_paths = main_parts_program.list_of_paths.dup
      list_of_paths[ROUTE_COUNT // 2] = "/edited"
      main_parts_program.list_of_paths = list_of_paths
      compiler = main_parts_program.build

      list_of_compiled = compiler.main_part_outcomes.select { |name, outcome| outcome.starts_with?("compiled") && !name.includes?("index") }
      # The edited route is in one part of each of the three blocks, and
      # the index part of each block calls it under its new name.
      list_of_compiled.size.should be <= 3, compiler.main_part_outcomes.inspect
      compiler.main_module_outcome.to_s.should_not start_with("compiled")
      main_parts_program.part_objects.size.should be > 4
      main_parts_program.output.should eq(expected_output(list_of_paths))
    end
  end

  it "patches the parts below a statement added at the top" do
    with_main_parts_program("main_parts_insert") do |main_parts_program|
      main_parts_program.build
      list_of_paths = main_parts_program.list_of_paths
      main_parts_program.inserted = true
      compiler = main_parts_program.build

      list_of_compiled = compiler.main_part_outcomes.select { |name, outcome| outcome.starts_with?("compiled") && !name.includes?("index") }
      list_of_patched = compiler.main_part_outcomes.select { |_, outcome| outcome.includes?("patched") }
      list_of_compiled.size.should be <= 3, compiler.main_part_outcomes.inspect
      list_of_patched.size.should be > 0, compiler.main_part_outcomes.inspect
      # The parts are called from an index part whose name comes from the
      # block, so the main module is not compiled again.
      compiler.main_module_outcome.to_s.should_not start_with("compiled")
      compiler.main_part_outcomes.keys.any?(&.includes?("index")).should be_true, compiler.main_part_outcomes.inspect
      main_parts_program.output.should eq(expected_output(list_of_paths, inserted: true))
      main_parts_program.output(["boom"]).should eq(expected_output(list_of_paths, boom: true, inserted: true))
    end
  end
end
