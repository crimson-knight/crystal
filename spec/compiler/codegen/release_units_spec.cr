require "../../spec_helper"

# Release builds are split on macOS and Linux hosts only.
{% skip_file unless flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}

private RELEASE_UNITS_PROGRAM = <<-CRYSTAL
  class Counter
    @@count = 0

    @[NoInline]
    def self.bump
      @@count += 1
    end

    def self.count
      @@count
    end
  end

  LOOKUP = {"alpha" => 1, "beta" => BETA}

  def risky(number)
    raise ArgumentError.new("bad \#{number}") if number.odd?
    number * 2
  end

  5.times { Counter.bump }
  puts Counter.count, LOOKUP["beta"]
  puts (1..4).map { |number| risky(number) rescue "rescued" }.inspect
  CRYSTAL

private def compile_release_units_program(directory, release_units, executable_name, beta = 2)
  program = File.join(directory, "program.cr")
  File.write(program, "BETA = #{beta}\n#{RELEASE_UNITS_PROGRAM}")
  executable = File.join(directory, executable_name)

  compiler = Crystal::Compiler.new
  compiler.release!
  compiler.release_units = release_units
  compiler.n_threads = 8
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  result = compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  {executable, result}
end

# The part objects of the release build of `directory/program.cr` in the compiler cache.
private def release_part_objects(directory)
  cache_directory = Crystal::CacheDir.instance.directory_for(File.join(directory, "program.cr"))
  Dir.children(cache_directory).select(&.matches?(/\A_main\.o3\.p\d+of\d+\.o\z/)).sort
end

private def expected_release_units_output(beta = 2)
  "5\n#{beta}\n[\"rescued\", 4, \"rescued\", 8]\n"
end

# On macOS the linker leaves the promoted private symbols out; on Linux the
# compiler removes them with objcopy, when it is installed.
private def private_symbols_are_removed? : Bool
  {% if flag?(:darwin) %}
    true
  {% else %}
    {"objcopy", "llvm-objcopy"}.any? { |tool| Process.find_executable(tool) }
  {% end %}
end

# The Crystal functions of the executable's code section, in address order.
private def function_names_by_address(nm, executable)
  Process.capture([nm, "-n", executable]).lines.compact_map do |line|
    fields = line.chomp.split(3)
    next unless fields.size == 3

    _, kind, name = fields
    name if kind.in?("T", "t") && (name.includes?("::") || name.includes?("#"))
  end.uniq
end

private def symbol_names(nm, executable)
  Process.capture([nm, executable]).lines.map { |line| line.split(' ', 3).last.chomp }
end

# The names of the functions (text symbols, `T` or `t`) in an executable.
private def function_symbol_names(nm, executable)
  Process.capture([nm, executable]).lines.compact_map do |line|
    if match = line.chomp.match(/^\S*\s+[Tt]\s+(.+)$/)
      match[1]
    end
  end
end

describe "Compiler#release_units" do
  it "defaults to emitting the optimized module as eight parts" do
    Crystal::Compiler.new.release_units.should eq(8)
  end

  it "builds a release program from parts that behaves like the single-object build" do
    with_tempfile("release_units") do |directory|
      Dir.mkdir_p(directory)
      single_executable, _ = compile_release_units_program(directory, 1, "single")
      release_part_objects(directory).should be_empty
      parts_executable, _ = compile_release_units_program(directory, 4, "parts")
      release_part_objects(directory).should eq(%w[_main.o3.p0of4.o _main.o3.p1of4.o _main.o3.p2of4.o _main.o3.p3of4.o])

      Process.capture(single_executable).should eq(expected_release_units_output)
      Process.capture(parts_executable).should eq(expected_release_units_output)
    end
  end

  it "uses at most --threads parts" do
    with_tempfile("release_units_threads") do |directory|
      Dir.mkdir_p(directory)
      program = File.join(directory, "program.cr")
      File.write(program, "BETA = 2\n#{RELEASE_UNITS_PROGRAM}")
      compiler = Crystal::Compiler.new
      compiler.release!
      compiler.release_units = 8
      compiler.n_threads = 2
      compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), File.join(directory, "two_threads"))

      release_part_objects(directory).should eq(%w[_main.o3.p0of2.o _main.o3.p1of2.o])
      Process.capture(File.join(directory, "two_threads")).should eq(expected_release_units_output)
    end
  end

  it "rebuilds an unchanged program and a program whose part count changed" do
    with_tempfile("release_units_rebuild") do |directory|
      Dir.mkdir_p(directory)
      compile_release_units_program(directory, 3, "first")
      unchanged_executable, _ = compile_release_units_program(directory, 3, "unchanged")
      more_parts_executable, _ = compile_release_units_program(directory, 5, "more_parts")

      Process.capture(unchanged_executable).should eq(expected_release_units_output)
      Process.capture(more_parts_executable).should eq(expected_release_units_output)
      release_part_objects(directory).should eq(%w[_main.o3.p0of5.o _main.o3.p1of5.o _main.o3.p2of5.o _main.o3.p3of5.o _main.o3.p4of5.o])
    end
  end

  it "never links the parts of an older program after an interrupted change of part count" do
    with_tempfile("release_units_interrupted") do |directory|
      Dir.mkdir_p(directory)
      compile_release_units_program(directory, 4, "old_program", beta: 2)
      compile_release_units_program(directory, 3, "new_program", beta: 7)
      release_part_objects(directory).should eq(%w[_main.o3.p0of3.o _main.o3.p1of3.o _main.o3.p2of3.o])

      # A build of the new program with 4 parts that stopped right after it
      # recorded its flags, before it replaced any object.
      cache_directory = Crystal::CacheDir.instance.directory_for(File.join(directory, "program.cr"))
      flags_file = File.join(cache_directory, "bc_flags.o3")
      File.write(flags_file, File.read(flags_file).sub("|parts=3", "|parts=4"))

      retried_executable, _ = compile_release_units_program(directory, 4, "retried", beta: 7)
      Process.capture(retried_executable).should eq(expected_release_units_output(7))
    end
  end

  it "lists the same symbols as the single-object build, without the promoted private ones" do
    nm = Process.find_executable("nm")
    pending! "nm is not installed" unless nm

    with_tempfile("release_units_symbols") do |directory|
      Dir.mkdir_p(directory)
      single_executable, _ = compile_release_units_program(directory, 1, "single")
      parts_executable, _ = compile_release_units_program(directory, 4, "parts")

      single_symbols = symbol_names(nm, single_executable)
      parts_symbols = symbol_names(nm, parts_executable)

      list_of_private_symbols = parts_symbols.select(&.includes?("__crystal_private."))
      list_of_private_symbols.should be_empty if private_symbols_are_removed?
      list_of_crystal_method_symbols = single_symbols.select(&.includes?("Counter::bump"))
      list_of_crystal_method_symbols.should_not be_empty
      (list_of_crystal_method_symbols - parts_symbols).should be_empty

      # Only functions are compared by count. The single-object build keeps
      # local data symbols (`$Slice:N` literals, constant tables such as
      # Mica's encoding tables) that the parted build promotes to
      # `__crystal_private.` names and then strips, so data symbols differ by
      # an amount that depends on how much constant data the standard library
      # carries, not on what the parts link.
      list_of_single_functions = function_symbol_names(nm, single_executable)
      list_of_parts_functions = function_symbol_names(nm, parts_executable).reject(&.includes?("__crystal_private."))
      list_of_parts_functions.size.should be_close(list_of_single_functions.size, list_of_single_functions.size // 10)
    end
  end

  it "lays out the functions in the order of the single-object build" do
    nm = Process.find_executable("nm")
    pending! "nm is not installed" unless nm

    with_tempfile("release_units_order") do |directory|
      Dir.mkdir_p(directory)
      single_executable, _ = compile_release_units_program(directory, 1, "single")
      parts_executable, _ = compile_release_units_program(directory, 4, "parts")

      single_order = function_names_by_address(nm, single_executable)
      parts_order = function_names_by_address(nm, parts_executable)
      list_of_shared_names = single_order & parts_order
      list_of_shared_names.size.should be > 100
      (parts_order & list_of_shared_names).should eq(list_of_shared_names)
    end
  end
end
