require "../../spec_helper"

# A program with many types that call into each other, so that with a tiny
# resident set most modules are spilled in several parts. It uses what the
# parts of a module have to agree on: struct and tuple values passed across
# modules, unions sized by structs, generics, closures, string constants,
# class variables, constants, exceptions and virtual dispatch.
private MODULE_SPILL_PROGRAM = <<-CRYSTAL
  require "prelude"

  record Point, x : Int32, y : Int32 do
    def +(other : Point) : Point
      Point.new(x + other.x, y + other.y)
    end
  end

  abstract class Shape
    @@created = 0

    def self.created
      @@created
    end

    def initialize(@origin : Point)
      @@created += 1
    end

    abstract def area : Int32
    abstract def label : String

    def describe : String
      "\#{label} at \#{@origin.x},\#{@origin.y} with area \#{area}"
    end
  end

  {% for index in 1..24 %}
    class Shape{{index}} < Shape
      SIDE = {{index}}

      def area : Int32
        SIDE * SIDE + Registry{{index}}.bonus
      end

      def label : String
        "shape{{index}}"
      end
    end

    module Registry{{index}}
      @@visits = 0

      def self.bonus : Int32
        @@visits += 1
        {% if index > 1 %}
          Registry{{index - 1}}.bonus + 1
        {% else %}
          1
        {% end %}
      end

      def self.visits : Int32
        @@visits
      end
    end

    struct Box{{index}}(T)
      def initialize(@content : T, @corner : Point)
      end

      def unwrap : {T, Point}
        {@content, @corner + Point.new({{index}}, {{index}})}
      end
    end
  {% end %}

  class Tally(T)
    def initialize
      @counts = Hash(T, Int32).new(0)
    end

    def add(item : T) : Nil
      @counts[item] += 1
    end

    def report : String
      @counts.to_a.sort_by! { |pair| pair[0].to_s }.map { |(item, count)| "\#{item}=\#{count}" }.join(",")
    end
  end

  def risky(number : Int32) : Int32 | String
    raise ArgumentError.new("odd \#{number}") if number.odd?
    number > 2 ? "big" : number
  end

  list_of_shapes = [] of Shape
  {% for index in 1..24 %}
    list_of_shapes << Shape{{index}}.new(Point.new({{index}}, {{index * 2}}))
  {% end %}

  total_area = list_of_shapes.sum(&.area)
  puts list_of_shapes.first.describe, list_of_shapes.last.describe, total_area, Shape.created
  puts Registry1.visits, Registry24.visits

  content, corner = Box7(String).new("seven", Point.new(1, 2)).unwrap
  nested, nested_corner = Box12(Box3(Int32)).new(Box3(Int32).new(3, Point.new(0, 0)), Point.new(5, 5)).unwrap
  puts content, corner.x, corner.y, nested.unwrap[0], nested.unwrap[1].y, nested_corner.x

  tally_of_labels = Tally(String).new
  tally_of_sides = Tally(Int32).new
  list_of_shapes.each do |shape|
    tally_of_labels.add(shape.label[0, 6])
    tally_of_sides.add(shape.area % 3)
  end
  puts tally_of_labels.report, tally_of_sides.report

  offset = 10
  add_offset = ->(number : Int32) { number + offset }
  puts (1..4).map { |number| (value = risky(number)).is_a?(Int32) ? add_offset.call(value) : value rescue "rescued" }.inspect

  # A union whose size comes from a struct inside a tuple: a module created
  # after others were freed must lay it out as large as the first modules.
  record Wide, first : Int64, second : Int64, third : Int64, fourth : Int64 do
    def sum : Int64
      first + second + third + fourth
    end
  end

  class Shelf(T)
    @last : {T, Int32}?

    def initialize
      @slots = {} of String => T
    end

    def put(key : String, value : T) : Nil
      @slots[key] = value
      @last = {value, @slots.size}
    end

    def last : {T, Int32}?
      @last
    end

    def first_entry : {String, T}?
      @slots.first?
    end
  end

  shelf = Shelf(Wide).new
  puts shelf.last.inspect
  {% for index in 1..6 %}
    shelf.put("slot{{index}}", Wide.new({{index}}_i64, 2_i64, 3_i64, 4_i64))
  {% end %}
  if last = shelf.last
    puts last[0].sum, last[1]
  end
  if first_entry = shelf.first_entry
    puts first_entry[0], first_entry[1].sum
  end
  CRYSTAL

private MODULE_SPILL_PROGRAM_OUTPUT = <<-OUTPUT
  shape1 at 1,2 with area 2
  shape24 at 24,48 with area 600
  5200
  0
  26
  2
  seven
  8
  9
  3
  3
  17
  shape1=11,shape2=6,shape3=1,shape4=1,shape5=1,shape6=1,shape7=1,shape8=1,shape9=1
  0=16,2=8
  ["rescued", 12, "rescued", "big"]
  nil
  15
  6
  slot1
  10

  OUTPUT

private def compile_module_spill_program(directory, resident_modules, executable_name, debug = Crystal::Debug::Default, n_threads = 1, resident_ir_megabytes = 0)
  program = File.join(directory, "program.cr")
  File.write(program, MODULE_SPILL_PROGRAM)
  executable = File.join(directory, executable_name)

  compiler = Crystal::Compiler.new
  compiler.resident_modules = resident_modules
  compiler.resident_ir_megabytes = resident_ir_megabytes
  compiler.debug = debug
  compiler.n_threads = n_threads
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  {executable, compiler}
end

private def module_spill_cache_directory(directory)
  Crystal::CacheDir.instance.directory_for(File.join(directory, "program.cr"))
end

describe "Compiler#resident_modules and Compiler#resident_ir_megabytes" do
  it "limit the IR in memory by its size by default, not the number of modules" do
    Crystal::Compiler.new.resident_modules.should eq(0)
    Crystal::Compiler.new.resident_ir_megabytes.should eq(Crystal::Compiler::DEFAULT_RESIDENT_IR_MEGABYTES)
  end

  it "builds a program with many types from 1 megabyte of resident IR" do
    with_tempfile("module_spill_bytes") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_spill_program(directory, 0, "one_megabyte", resident_ir_megabytes: 1)

      module_spill = compiler.last_module_spill.should_not be_nil
      module_spill.spill_count.should be > 100
      module_spill.multi_part_module_count.should be > 10
      module_spill.peak_resident_ir_bytes.should be < 32 * 1024 * 1024
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "generates the functions of a deep chain of calls after the chain, not inside it" do
    with_tempfile("module_spill_deep_chain") do |directory|
      Dir.mkdir_p(directory)
      # Registry24.bonus calls Registry23.bonus and so on: a chain of 24
      # functions in 24 modules.
      executable, compiler = compile_module_spill_program(directory, 0, "deep_chain", resident_ir_megabytes: 1)

      module_spill = compiler.last_module_spill.should_not be_nil
      module_spill.deferred_fun_count.should be > 0
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "keeps every module in memory with 0" do
    with_tempfile("module_spill_off") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_spill_program(directory, 0, "all_resident", resident_ir_megabytes: 0)

      compiler.last_module_spill.should be_nil
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "builds a program with many types from a resident set of 2 modules" do
    with_tempfile("module_spill_tiny") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_spill_program(directory, 2, "tiny_resident_set")

      module_spill = compiler.last_module_spill.should_not be_nil
      module_spill.spill_count.should be > 100
      module_spill.multi_part_module_count.should be > 10
      module_spill.peak_resident_count.should be < 40
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)

      # Every spill file became a cached bitcode file of its unit: the
      # first part is the unit's .bc file, next to the unit's one object.
      list_of_cache_files = Dir.children(module_spill_cache_directory(directory))
      list_of_cache_files.select(&.ends_with?(".new.bc")).should be_empty
      list_of_part_files = list_of_cache_files.select(&.matches?(/\.part\d+\.bc\z/))
      list_of_part_files.size.should be > 10
      (list_of_cache_files.count(&.ends_with?(".bc")) - list_of_part_files.size).should eq(list_of_cache_files.count(&.ends_with?(".o")))
    end
  end

  it "replaces the cached parts of a module when a later build keeps it in memory" do
    with_tempfile("module_spill_then_resident") do |directory|
      Dir.mkdir_p(directory)
      compile_module_spill_program(directory, 2, "spilled")
      cache_directory = module_spill_cache_directory(directory)
      Dir.children(cache_directory).count(&.matches?(/\.part\d+\.bc\z/)).should be > 10

      executable, compiler = compile_module_spill_program(directory, 0, "resident")

      compiler.last_module_spill.should be_nil
      Dir.children(cache_directory).count(&.matches?(/\.part\d+\.bc\z/)).should eq(0)
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "builds with full debug info and without debug info from a resident set of 1 module" do
    with_tempfile("module_spill_debug") do |directory|
      Dir.mkdir_p(directory)
      full_debug_executable, _ = compile_module_spill_program(directory, 1, "full_debug", debug: Crystal::Debug::All)
      no_debug_executable, _ = compile_module_spill_program(directory, 1, "no_debug", debug: Crystal::Debug::None)

      Process.capture(full_debug_executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
      Process.capture(no_debug_executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "compiles spilled modules to objects on several threads" do
    with_tempfile("module_spill_threads") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_spill_program(directory, 2, "several_threads", n_threads: 4)

      compiler.last_module_spill.should_not be_nil
      Process.capture(executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end

  it "reuses the objects of an unchanged program whose modules were spilled" do
    with_tempfile("module_spill_rebuild") do |directory|
      Dir.mkdir_p(directory)
      compile_module_spill_program(directory, 2, "first")
      cache_directory = module_spill_cache_directory(directory)
      list_of_objects = Dir.children(cache_directory).select(&.ends_with?(".o")).sort!
      list_of_first_build_times = list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }

      sleep 1.1.seconds
      rebuilt_executable, _ = compile_module_spill_program(directory, 2, "rebuilt")

      list_of_rebuild_times = list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }
      list_of_rebuild_times.should eq(list_of_first_build_times)
      Dir.children(cache_directory).select(&.ends_with?(".new.bc")).should be_empty
      Process.capture(rebuilt_executable).should eq(MODULE_SPILL_PROGRAM_OUTPUT)
    end
  end
end
