require "../../spec_helper"

private RELEASE_UNITS_PROGRAM = <<-CRYSTAL
  class Counter
    @@count = 0

    def self.bump
      @@count += 1
    end

    def self.count
      @@count
    end
  end

  LOOKUP = {"alpha" => 1, "beta" => 2}

  def risky(number)
    raise ArgumentError.new("bad \#{number}") if number.odd?
    number * 2
  end

  5.times { Counter.bump }
  puts Counter.count, LOOKUP["beta"]
  puts (1..4).map { |number| risky(number) rescue "rescued" }.inspect
  CRYSTAL

private def compile_release_units_program(directory, release_units, executable_name)
  program = File.join(directory, "program.cr")
  File.write(program, RELEASE_UNITS_PROGRAM)
  executable = File.join(directory, executable_name)

  compiler = Crystal::Compiler.new
  compiler.release!
  compiler.release_units = release_units
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  result = compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  {executable, result}
end

describe "Compiler#release_units" do
  it "defaults to emitting the optimized module as one object" do
    Crystal::Compiler.new.release_units.should eq(1)
  end

  it "builds a release program from parts that behaves like the single-object build" do
    with_tempfile("release_units") do |directory|
      Dir.mkdir_p(directory)
      single_executable, _ = compile_release_units_program(directory, 1, "single")
      parts_executable, _ = compile_release_units_program(directory, 4, "parts")

      expected_output = "5\n2\n[\"rescued\", 4, \"rescued\", 8]\n"
      Process.capture(single_executable).should eq(expected_output)
      Process.capture(parts_executable).should eq(expected_output)
    end
  end

  it "rebuilds an unchanged program and a program whose part count changed" do
    with_tempfile("release_units_rebuild") do |directory|
      Dir.mkdir_p(directory)
      compile_release_units_program(directory, 3, "first")
      unchanged_executable, _ = compile_release_units_program(directory, 3, "unchanged")
      more_parts_executable, _ = compile_release_units_program(directory, 5, "more_parts")

      Process.capture(unchanged_executable).should eq("5\n2\n[\"rescued\", 4, \"rescued\", 8]\n")
      Process.capture(more_parts_executable).should eq("5\n2\n[\"rescued\", 4, \"rescued\", 8]\n")
    end
  end
end
