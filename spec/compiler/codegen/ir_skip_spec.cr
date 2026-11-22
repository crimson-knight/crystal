require "../../spec_helper"

# A program of several files, each with a module of its own. `User` reads
# the other types in every way that puts their code or layout into its own
# code; `Bystander` reads none of them.
private LIST_OF_SOURCES = {
  "helper.cr" => <<-CRYSTAL,
    module Helper
      LIMIT = 7

      def self.value
        111
      end

      def self.each_step(&)
        yield 1
        yield 2
      end

      def self.compute(n : Int32) : Int32
        ARGV.size &+ n &* 3
      end
    end
    CRYSTAL
  "shapes.cr" => <<-CRYSTAL,
    abstract class Shape
      abstract def area : Int32
    end

    class Circle < Shape
      def area : Int32
        ARGV.size &+ 3
      end
    end

    class Point
      def initialize(@x : Int32, @y : Int32)
      end

      def y
        @y
      end
    end
    CRYSTAL
  "user.cr" => <<-CRYSTAL,
    class User
      def literal
        Helper.value &+ ARGV.size
      end

      def steps
        sum = 0
        Helper.each_step { |step| sum &+= step }
        sum
      end

      def computed
        Helper.compute(2)
      end

      def limit
        Helper::LIMIT &+ ARGV.size
      end

      def point_y(point : Point)
        point.y
      end

      def area(shape : Shape)
        shape.area
      end
    end
    CRYSTAL
  "bystander.cr" => <<-CRYSTAL,
    class Bystander
      def answer
        ARGV.size &+ 42
      end
    end
    CRYSTAL
  "program.cr" => <<-CRYSTAL,
    require "./helper"
    require "./shapes"
    require "./user"
    require "./bystander"

    user = User.new
    list_of_shapes = [Circle.new] of Shape
    puts user.literal
    puts user.steps
    puts user.computed
    puts user.limit
    puts user.point_y(Point.new(1, 2))
    puts list_of_shapes.sum { |shape| user.area(shape) }
    puts Bystander.new.answer
    CRYSTAL
}

private EXPECTED_OUTPUT = "111\n3\n6\n7\n2\n3\n42\n"

private class SkipProgram
  getter directory : String
  @edit_count = 0

  def initialize(@directory : String)
    Dir.mkdir_p(@directory)
    LIST_OF_SOURCES.each { |name, source| File.write(File.join(@directory, name), source) }
  end

  def program : String
    File.join(@directory, "program.cr")
  end

  def executable : String
    File.join(@directory, "program")
  end

  def cache_directory : String
    Crystal::CacheDir.instance.directory_for(program)
  end

  # Replaces *before* with *after* in the file named *name*; the build
  # after it sees a file with a later modification time.
  def edit(name : String, before : String, after : String) : Nil
    path = File.join(@directory, name)
    source = File.read(path)
    raise "#{name} does not hold #{before.inspect}" unless source.includes?(before)

    File.write(path, source.sub(before, after))
    touch(name)
  end

  def touch(name : String) : Nil
    @edit_count += 1
    File.touch(File.join(@directory, name), Time.utc + (@edit_count * 5).seconds)
  end

  def build(verify : Bool = false) : Crystal::IrSkip::Stats
    compiler = Crystal::Compiler.new
    compiler.incremental = true
    compiler.n_threads = 2
    compiler.ir_skip_verify = verify
    ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
    compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
    compiler.last_ir_skip_stats || raise "the build kept no keys"
  end

  def output : String
    Process.capture(executable)
  end
end

private def regenerated?(stats : Crystal::IrSkip::Stats, module_name : String) : Bool
  stats.list_of_regenerated_units.any?(&.starts_with?("#{module_name}: "))
end

private def with_skip_program(name : String, & : SkipProgram ->) : Nil
  with_tempfile(name) do |directory|
    skip_program = SkipProgram.new(directory)
    first_build = skip_program.build
    first_build.skipped_units.should eq(0)
    skip_program.output.should eq(EXPECTED_OUTPUT)
    yield skip_program
  end
end

describe "Code gen: skipping IR generation for unchanged modules" do
  it "generates no module again when nothing its code is made from changed" do
    with_skip_program("ir_skip_unchanged") do |skip_program|
      skip_program.touch("bystander.cr")
      stats = skip_program.build

      stats.generated_units.should eq(0)
      stats.skipped_units.should be > 10
      stats.generated_functions.should eq(0)
      skip_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "generates only the module of a body that changed and is called" do
    with_skip_program("ir_skip_called_body") do |skip_program|
      skip_program.edit("helper.cr", "n &* 3", "n &* 4")
      stats = skip_program.build

      regenerated?(stats, "Helper").should be_true
      regenerated?(stats, "User").should be_false
      stats.generated_units.should eq(1)
      skip_program.output.should eq("111\n3\n8\n7\n2\n3\n42\n")
    end
  end

  it "generates a module again when a literal body it inlines changed" do
    with_skip_program("ir_skip_inlined_literal") do |skip_program|
      skip_program.edit("helper.cr", "111", "112")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Bystander").should be_false
      skip_program.output.should eq("112\n3\n6\n7\n2\n3\n42\n")
    end
  end

  it "generates a module again when a yielding def it inlines changed" do
    with_skip_program("ir_skip_inlined_yield") do |skip_program|
      skip_program.edit("helper.cr", "yield 2", "yield 5")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Bystander").should be_false
      skip_program.output.should eq("111\n6\n6\n7\n2\n3\n42\n")
    end
  end

  it "generates a module again when a constant it reads changed" do
    with_skip_program("ir_skip_constant") do |skip_program|
      skip_program.edit("helper.cr", "LIMIT = 7", "LIMIT = 9")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Bystander").should be_false
      skip_program.output.should eq("111\n3\n6\n9\n2\n3\n42\n")
    end
  end

  it "generates a module again when the layout of a type it reads changed" do
    with_skip_program("ir_skip_layout") do |skip_program|
      # `@y` moves: a module that kept its code would read `@x`.
      skip_program.edit("shapes.cr", "class Point\n", "class Point\n  @a : Int64 = 9_i64\n")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Point").should be_true
      regenerated?(stats, "Bystander").should be_false
      skip_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "generates a module again when a type it dispatches over got a subclass" do
    with_skip_program("ir_skip_subclass") do |skip_program|
      skip_program.edit("shapes.cr", "class Point\n", "class Square < Shape\n  def area : Int32\n    ARGV.size &+ 5\n  end\nend\n\nclass Point\n")
      skip_program.edit("program.cr", "[Circle.new] of Shape", "[Circle.new, Square.new] of Shape")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Bystander").should be_false
      skip_program.output.should eq("111\n3\n6\n7\n2\n8\n42\n")
    end
  end

  it "tells a module in which only source positions changed from the others" do
    with_skip_program("ir_skip_lines") do |skip_program|
      skip_program.edit("user.cr", "class User\n", "# One line.\n# Two lines.\nclass User\n")
      stats = skip_program.build

      regenerated?(stats, "User").should be_true
      regenerated?(stats, "Bystander").should be_false
      stats.regenerated_units_by_reason["SourcePosition"]?.should eq(1)
      stats.units_regenerated_for_source_position_alone.should eq(1)
      skip_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "generates a module again when it is asked for another function" do
    with_skip_program("ir_skip_new_function") do |skip_program|
      skip_program.edit("bystander.cr", "class Bystander\n", "class Bystander\n  def other\n    ARGV.size &+ 1\n  end\n\n")
      skip_program.edit("program.cr", "puts Bystander.new.answer", "puts Bystander.new.answer &+ Bystander.new.other")
      stats = skip_program.build

      regenerated?(stats, "Bystander").should be_true
      regenerated?(stats, "User").should be_false
      skip_program.output.should eq("111\n3\n6\n7\n2\n3\n43\n")
    end
  end

  describe "verification" do
    it "passes when every module whose key matched produced the recorded bitcode" do
      with_skip_program("ir_skip_verify") do |skip_program|
        skip_program.edit("helper.cr", "n &* 3", "n &* 4")
        stats = skip_program.build(verify: true)

        stats.skipped_units.should eq(0)
        stats.verified_units.should be > 10
        stats.list_of_verification_failures.should be_empty
        skip_program.output.should eq("111\n3\n8\n7\n2\n3\n42\n")
      end
    end

    it "fails the build when a module whose key matched produced other bitcode" do
      with_skip_program("ir_skip_verify_failure") do |skip_program|
        # Makes the manifest and the object record of `Bystander` agree on a
        # bitcode hash its code does not produce: what a key that misses an
        # input looks like.
        cache_directory = skip_program.cache_directory
        manifest = Crystal::IrSkip::Manifest.load?(cache_directory, nil) || raise "the build left no manifest"
        recorded_unit = manifest.units_by_name["Bystander"]
        recorded_unit.list_of_part_hashes = ["0" * 64]
        manifest.save(cache_directory)
        record_filename = Dir.glob(File.join(cache_directory, "B-ystander*.hash")).first
        object_filename = record_filename.rchop(".hash") + ".o"
        Crystal::CachedObjectRecord.write(record_filename, recorded_unit.list_of_part_hashes, [object_filename])

        skip_program.touch("bystander.cr")
        error = expect_raises(Crystal::CompilerError, "IR skip verification failed") do
          skip_program.build(verify: true)
        end
        error.message.to_s.should contain("Bystander: every key matched, but the bitcode differs")
      end
    end
  end
end
