require "../../spec_helper"

# A program with one type that has many functions calling each other in
# both directions, so that with a tiny segment limit the type is compiled
# as many object files that have to link with each other. It uses what the
# segments of a type share: a string constant used by many functions, class
# variables, constants, instance variables, generic and block methods,
# closures, exceptions, virtual dispatch and recursion across segments.
private MODULE_SEGMENTS_PROGRAM = <<-CRYSTAL
  require "prelude"

  abstract class Entry
    abstract def amount : Int32
  end

  class Credit < Entry
    def initialize(@amount : Int32)
    end

    def amount : Int32
      @amount
    end
  end

  class Debit < Entry
    def initialize(@amount : Int32)
    end

    def amount : Int32
      -@amount
    end
  end

  class Ledger
    PREFIX = "step"
    @@steps_taken = 0

    def self.steps_taken : Int32
      @@steps_taken
    end

    def initialize
      @list_of_entries = [] of Entry
      @notes = {} of String => Int32
    end

    {% for index in 1..40 %}
      def step{{index}}(value : Int32) : Int32
        @@steps_taken += 1
        @notes["\#{PREFIX}{{index}}"] = value
        @list_of_entries << (value.odd? ? Credit.new(value) : Debit.new({{index}}))
        {% if index < 40 %}
          step{{index + 1}}(value + {{index}})
        {% else %}
          value
        {% end %}
      end

      def label{{index}} : String
        "shared label of the ledger, \#{PREFIX} {{index}}"
      end
    {% end %}

    # Recursion that goes back and forth between early and late functions.
    def descend(depth : Int32) : Int32
      depth == 0 ? balance : ascend(depth - 1) + 1
    end

    def balance : Int32
      @list_of_entries.sum(&.amount)
    end

    def each_note(& : String, Int32 ->) : Nil
      @notes.each { |key, value| yield key, value }
    end

    def largest(default : T) : T | Int32 forall T
      @notes.values.max? || default
    end

    def checked_step(value : Int32) : Int32
      raise ArgumentError.new("negative \#{value}") if value < 0
      step38(value)
    end

    def ascend(depth : Int32) : Int32
      depth == 0 ? balance : descend(depth - 1) + 1
    end

    def adder : Int32 -> Int32
      base = balance
      ->(number : Int32) { number + base + step40(1) }
    end
  end

  ledger = Ledger.new
  puts ledger.step1(1)
  puts ledger.balance, Ledger.steps_taken
  puts ledger.label1, ledger.label40
  puts ledger.descend(7)
  total = 0
  ledger.each_note { |key, value| total += value + key.size }
  puts total
  puts ledger.largest("none")
  puts Ledger.new.largest("none")
  puts (ledger.checked_step(-1) rescue "rescued")
  puts ledger.checked_step(5)
  puts ledger.adder.call(100)
  puts Ledger.steps_taken
  CRYSTAL

private MODULE_SEGMENTS_PROGRAM_OUTPUT = <<-OUTPUT
  781
  4950
  40
  shared label of the ledger, step 1
  shared label of the ledger, step 40
  4957
  10931
  781
  none
  rescued
  82
  5059
  44

  OUTPUT

private def compile_module_segments_program(directory, executable_name, module_segment_instructions, resident_modules = 0, source = MODULE_SEGMENTS_PROGRAM, debug = Crystal::Debug::Default)
  program = File.join(directory, "program.cr")
  File.write(program, source)
  executable = File.join(directory, executable_name)

  compiler = Crystal::Compiler.new
  compiler.module_segment_instructions = module_segment_instructions
  compiler.resident_modules = resident_modules
  compiler.resident_ir_megabytes = 0
  compiler.debug = debug
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  {executable, compiler}
end

private def module_segments_cache_directory(directory)
  Crystal::CacheDir.instance.directory_for(File.join(directory, "program.cr"))
end

# The object files of the segments of the type named *type_name* in
# *cache_directory*, with the time each was written.
private def segment_object_times(cache_directory, type_name, segment_count) : Hash(String, Time)
  list_of_unit_names = [type_name] + (1...segment_count).map { |index| Crystal::CodeGenVisitor.segment_module_name(type_name, index) }
  list_of_unit_names.to_h do |unit_name|
    object_name = Crystal::Compiler::CompilationUnit.file_basename(unit_name, Crystal::Compiler::OptimizationMode::O0) + ".o"
    {object_name, File.info(File.join(cache_directory, object_name)).modification_time}
  end
end

describe "Compiler#module_segment_instructions" do
  it "compiles every type as one object file with 0" do
    with_tempfile("module_segments_off") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_segments_program(directory, "one_module_per_type", 0)

      compiler.last_segmented_type_count.should eq(0)
      Dir.children(module_segments_cache_directory(directory)).count(&.starts_with?("L-edger-seg")).should eq(0)
      Process.capture(executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end

  it "compiles a type larger than the limit as several object files that link into a working program" do
    with_tempfile("module_segments_tiny") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_segments_program(directory, "tiny_segments", 40)

      compiler.last_segmented_type_count.should be > 5
      compiler.last_maximum_segment_count.should be > 10
      Process.capture(executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)

      # Each segment of `Ledger` is a unit with a bitcode file and an
      # object file of its own.
      list_of_cache_files = Dir.children(module_segments_cache_directory(directory))
      list_of_ledger_objects = list_of_cache_files.select { |name| name.matches?(/\AL-edger(-seg\d+)?\.o0\.o\z/) }
      list_of_ledger_objects.size.should be > 10
      list_of_ledger_objects.each do |object_name|
        list_of_cache_files.should contain(object_name.rchop(".o") + ".bc")
      end
    end
  end

  it "reuses every object file of an unchanged program" do
    with_tempfile("module_segments_reuse") do |directory|
      Dir.mkdir_p(directory)
      compile_module_segments_program(directory, "first", 40)
      cache_directory = module_segments_cache_directory(directory)
      list_of_objects = Dir.children(cache_directory).select(&.ends_with?(".o")).sort!
      list_of_first_build_times = list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }

      sleep 1.1.seconds
      rebuilt_executable, _ = compile_module_segments_program(directory, "rebuilt", 40)

      Dir.children(cache_directory).select(&.ends_with?(".o")).sort!.should eq(list_of_objects)
      list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }.should eq(list_of_first_build_times)
      Process.capture(rebuilt_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end

  it "keeps the segments of an unchanged type when another type changes" do
    with_tempfile("module_segments_stable") do |directory|
      Dir.mkdir_p(directory)
      _, compiler = compile_module_segments_program(directory, "first", 40)
      cache_directory = module_segments_cache_directory(directory)
      ledger_segment_count = Dir.children(cache_directory).count(&.matches?(/\AL-edger(-seg\d+)?\.o0\.o\z/))
      first_build_times = segment_object_times(cache_directory, "Ledger", ledger_segment_count)

      sleep 1.1.seconds
      changed_source = MODULE_SEGMENTS_PROGRAM.sub("-@amount", "0 - @amount")
      changed_source.should_not eq(MODULE_SEGMENTS_PROGRAM)
      changed_executable, _ = compile_module_segments_program(directory, "changed", 40, source: changed_source)

      segment_object_times(cache_directory, "Ledger", ledger_segment_count).should eq(first_build_times)
      debit_object = File.join(cache_directory, "D-ebit.o0.o")
      File.info(debit_object).modification_time.should be > first_build_times.values.max
      Process.capture(changed_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end

  it "rebuilds only the segment of a changed function when the type's other functions are unchanged" do
    with_tempfile("module_segments_change") do |directory|
      Dir.mkdir_p(directory)
      compile_module_segments_program(directory, "first", 40)
      cache_directory = module_segments_cache_directory(directory)
      ledger_segment_count = Dir.children(cache_directory).count(&.matches?(/\AL-edger(-seg\d+)?\.o0\.o\z/))
      first_build_times = segment_object_times(cache_directory, "Ledger", ledger_segment_count)

      sleep 1.1.seconds
      changed_source = MODULE_SEGMENTS_PROGRAM.sub("\"negative ", "\"below zero ")
      changed_source.should_not eq(MODULE_SEGMENTS_PROGRAM)
      changed_executable, _ = compile_module_segments_program(directory, "changed", 40, source: changed_source)

      changed_build_times = segment_object_times(cache_directory, "Ledger", ledger_segment_count)
      list_of_reused_objects = first_build_times.keys.select { |name| changed_build_times[name] == first_build_times[name] }
      list_of_reused_objects.size.should be >= ledger_segment_count // 2
      list_of_reused_objects.size.should be < ledger_segment_count
      Process.capture(changed_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end

  it "splits types into segments while modules are spilled to disk in parts" do
    with_tempfile("module_segments_spill") do |directory|
      Dir.mkdir_p(directory)
      executable, compiler = compile_module_segments_program(directory, "spilled_segments", 40, resident_modules: 2)

      compiler.last_maximum_segment_count.should be > 10
      module_spill = compiler.last_module_spill.should_not be_nil
      module_spill.spill_count.should be > 100
      Process.capture(executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)

      sleep 1.1.seconds
      cache_directory = module_segments_cache_directory(directory)
      list_of_objects = Dir.children(cache_directory).select(&.ends_with?(".o")).sort!
      list_of_first_build_times = list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }
      rebuilt_executable, _ = compile_module_segments_program(directory, "rebuilt", 40, resident_modules: 2)
      list_of_objects.map { |name| File.info(File.join(cache_directory, name)).modification_time }.should eq(list_of_first_build_times)
      Process.capture(rebuilt_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end

  it "builds segments with full debug info and without debug info" do
    with_tempfile("module_segments_debug") do |directory|
      Dir.mkdir_p(directory)
      full_debug_executable, _ = compile_module_segments_program(directory, "full_debug", 40, debug: Crystal::Debug::All)
      no_debug_executable, _ = compile_module_segments_program(directory, "no_debug", 40, debug: Crystal::Debug::None)

      Process.capture(full_debug_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
      Process.capture(no_debug_executable).should eq(MODULE_SEGMENTS_PROGRAM_OUTPUT)
    end
  end
end
