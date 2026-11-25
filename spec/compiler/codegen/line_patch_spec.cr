require "../../spec_helper"

# A program whose `Model` module holds a plain method, a method with a
# block and a proc, a method made by a macro, and a method that raises.
private MODEL_SOURCE = <<-CRYSTAL
  # Comment line one.
  # Comment line two.
  # Comment line three.
  class Model
    def initialize(@base : Int32)
    end

    def total : Int32
      sum = @base
      [1, 2, 3].each do |step|
        sum &+= step
      end
      adder = ->(value : Int32) { value &+ @base }
      adder.call(sum)
    end

    define_reader answer, 42

    def narrow(value : Int32 | String) : Int32
      value.as(Int32)
    end

    def boom : Int32
      raise "boom in the model" if @base > 100
      @base
    end
  end
  CRYSTAL

private LIST_OF_SOURCES = {
  "macros.cr" => <<-CRYSTAL,
    macro define_reader(name, value)
      def {{name}} : Int32
        {{value}} &+ @base
      end
    end
    CRYSTAL
  "model.cr"     => MODEL_SOURCE,
  "bystander.cr" => <<-CRYSTAL,
    class Bystander
      def answer
        ARGV.size &+ 7
      end
    end
    CRYSTAL
  "program.cr" => <<-CRYSTAL,
    require "./macros"
    require "./model"
    require "./bystander"

    mode = ARGV[0]? || ""
    model = Model.new(mode == "boom" ? 1000 : 0)
    puts model.total
    puts model.answer
    puts model.narrow(mode == "cast" ? "text" : 3)
    puts model.boom
    puts Bystander.new.answer
    CRYSTAL
}

private EXPECTED_OUTPUT = "6\n42\n3\n0\n7\n"

private class LinePatchProgram
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

  def edit(name : String, before : String, after : String) : Nil
    path = File.join(@directory, name)
    source = File.read(path)
    raise "#{name} does not hold #{before.inspect}" unless source.includes?(before)

    File.write(path, source.sub(before, after))
    @edit_count += 1
    File.touch(path, Time.utc + (@edit_count * 5).seconds)
  end

  # The line of *text* in the file named *name*.
  def line_of(name : String, text : String) : Int32
    index = File.read(File.join(@directory, name)).lines.index(&.includes?(text)) || raise "#{name} does not hold #{text.inspect}"
    index + 1
  end

  def build(*, verify : Bool = false, line_patch : Bool = true, resident_modules : Int32 = 0) : {Crystal::IrSkip::Stats, Crystal::Compiler}
    compiler = Crystal::Compiler.new
    compiler.incremental = true
    compiler.n_threads = 2
    # With a limit, IR generation spills modules to disk in parts, and the
    # object of a module holds one line table per part.
    compiler.resident_modules = resident_modules
    compiler.line_patch = line_patch
    compiler.dsymutil = true
    ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
    previous_verify = ENV["CRYSTAL_LINE_PATCH_VERIFY"]?
    ENV["CRYSTAL_LINE_PATCH_VERIFY"] = verify ? "1" : nil
    begin
      compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
    ensure
      ENV["CRYSTAL_LINE_PATCH_VERIFY"] = previous_verify
    end
    {compiler.last_ir_skip_stats || raise("the build kept no keys"), compiler}
  end

  def output : String
    Process.capture(executable)
  end

  # What the program prints on its standard error in *mode*: `boom` makes
  # `Model#boom` raise, `cast` makes the cast in `Model#narrow` fail.
  def error_output(mode : String) : String
    error = IO::Memory.new
    Process.run(executable, [mode], output: Process::Redirect::Close, error: error)
    error.to_s
  end
end

private def patched?(stats : Crystal::IrSkip::Stats, module_name : String) : Bool
  stats.list_of_patched_units.includes?(module_name)
end

private def regenerated?(stats : Crystal::IrSkip::Stats, module_name : String) : Bool
  stats.list_of_regenerated_units.any?(&.starts_with?("#{module_name}: "))
end

private def with_line_patch_program(name : String, & : LinePatchProgram ->) : Nil
  with_tempfile(name) do |directory|
    line_patch_program = LinePatchProgram.new(directory)
    stats, _ = line_patch_program.build
    stats.skipped_units.should eq(0)
    line_patch_program.output.should eq(EXPECTED_OUTPUT)
    yield line_patch_program
  end
end

# The backtrace names `model.cr` at the line of the `raise` in `Model#boom`,
# and a failing cast names the line of the cast.
private def expect_exact_backtrace(line_patch_program : LinePatchProgram) : Nil
  {% if flag?(:darwin) || flag?(:linux) %}
    line = line_patch_program.line_of("model.cr", %(raise "boom in the model"))
    backtrace = line_patch_program.error_output("boom")
    backtrace.should contain("boom in the model")
    backtrace.should contain("model.cr:#{line}:")
  {% end %}
  cast_line = line_patch_program.line_of("model.cr", "value.as(Int32)")
  cast_message = line_patch_program.error_output("cast")
  cast_message.should contain("Cast from String to Int32 failed, at #{line_patch_program.directory}/model.cr:#{cast_line}:")
end

describe "Code gen: patching the lines of modules whose source only moved" do
  describe Crystal::LinePatch::LineMap do
    it "maps lines around an insertion and a deletion" do
      list_of_old = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
      list_of_new = [1_u64, 9_u64, 9_u64, 2_u64, 3_u64, 5_u64]
      map = Crystal::LinePatch::LineMap.diff(list_of_old, list_of_new) || raise "no map"
      map.map?(1).should eq(1)
      map.map?(2).should eq(4)
      map.map?(3).should eq(5)
      map.map?(4).should be_nil
      map.map?(5).should eq(6)
      map.unmap?(2).should be_nil
      map.unmap?(6).should eq(5)
      map.map?(0).should eq(0)
    end
  end

  it "keeps the object of a module shifted down and patches its lines" do
    with_line_patch_program("line_patch_down") do |line_patch_program|
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n# Added one.\n# Added two.\n# Added three.\n")
      stats, _ = line_patch_program.build

      patched?(stats, "Model").should be_true
      regenerated?(stats, "Model").should be_false
      regenerated?(stats, "Bystander").should be_false
      stats.shifted_functions.should be > 0
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
      expect_exact_backtrace(line_patch_program)
    end
  end

  it "keeps the object of a module shifted up and patches its lines" do
    with_line_patch_program("line_patch_up") do |line_patch_program|
      line_patch_program.edit("model.cr", "# Comment line two.\n# Comment line three.\n", "")
      stats, _ = line_patch_program.build

      patched?(stats, "Model").should be_true
      regenerated?(stats, "Model").should be_false
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
      expect_exact_backtrace(line_patch_program)

      # And back down: the patched object is patched again.
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n# Comment line two.\n# Comment line three.\n")
      stats, _ = line_patch_program.build
      patched?(stats, "Model").should be_true
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
      expect_exact_backtrace(line_patch_program)
    end
  end

  it "patches the lines of a block and a proc inside a shifted function, as a fresh build writes them" do
    with_line_patch_program("line_patch_block_proc") do |line_patch_program|
      # Lines move inside `total` too: between its block and its proc.
      line_patch_program.edit("model.cr", "    end\n    adder", "    end\n\n\n    adder")
      stats, compiler = line_patch_program.build(verify: true)

      patched?(stats, "Model").should be_true
      verification = compiler.last_line_patch_verification || raise "nothing was verified"
      verification[0].should be > 0
      verification[1].should be_empty
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "patches a method a macro made in a shifted region" do
    with_line_patch_program("line_patch_macro") do |line_patch_program|
      line_patch_program.edit("model.cr", "  define_reader answer, 42\n", "\n\n  define_reader answer, 42\n")
      stats, compiler = line_patch_program.build(verify: true)

      patched?(stats, "Model").should be_true
      verification = compiler.last_line_patch_verification || raise "nothing was verified"
      verification[1].should be_empty
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "patches an object built from parts, each with a line table of its own" do
    with_tempfile("line_patch_parts") do |directory|
      line_patch_program = LinePatchProgram.new(directory)
      line_patch_program.build(resident_modules: 1)
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
      Dir.glob(File.join(line_patch_program.cache_directory, "M-odel*.part1.bc")).should_not be_empty

      # Sixty lines: every row of the parts after the first moves by more
      # than a special opcode holds, and the first part's table grows.
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n" + "#\n" * 60)
      stats, compiler = line_patch_program.build(verify: true, resident_modules: 1)

      patched?(stats, "Model").should be_true
      stats.patch_refusals_by_cause.should be_empty
      verification = compiler.last_line_patch_verification || raise "nothing was verified"
      verification[1].should be_empty
      line_patch_program.output.should eq(EXPECTED_OUTPUT)

      line_patch_program.edit("model.cr", "#\n" * 30, "")
      stats, _ = line_patch_program.build(resident_modules: 1)
      patched?(stats, "Model").should be_true
      expect_exact_backtrace(line_patch_program)
    end
  end

  it "generates a module whose positions are on an edited line" do
    with_line_patch_program("line_patch_refused_position") do |line_patch_program|
      # The same code, with another column on the edited line.
      line_patch_program.edit("model.cr", "    sum = @base\n", "    sum =   @base\n")
      stats, _ = line_patch_program.build

      patched?(stats, "Model").should be_false
      regenerated?(stats, "Model").should be_true
      stats.unshifted_functions_by_cause["a position on an edited line"]?.should_not be_nil
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  it "generates a module whose patch the patcher refuses" do
    with_line_patch_program("line_patch_refused_object") do |line_patch_program|
      # `Model` starts at line 250: ten more lines move its declarations past
      # 255, which `DW_FORM_data1` cannot hold.
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n" + "#\n" * 246)
      line_patch_program.build
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n" + "#\n" * 10)
      stats, _ = line_patch_program.build

      patched?(stats, "Model").should be_false
      regenerated?(stats, "Model").should be_true
      stats.patch_refusals_by_cause.keys.any?(&.includes?("DW_FORM_data1")).should be_true
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
      expect_exact_backtrace(line_patch_program)
    end
  end

  it "regenerates moved modules as before when line patching is off" do
    with_line_patch_program("line_patch_off") do |line_patch_program|
      line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n# Added.\n")
      stats, _ = line_patch_program.build(line_patch: false)

      patched?(stats, "Model").should be_false
      regenerated?(stats, "Model").should be_true
      line_patch_program.output.should eq(EXPECTED_OUTPUT)
    end
  end

  describe "the main module" do
    it "patches the main module's object when only lines of the top-level code moved" do
      with_line_patch_program("line_patch_main") do |line_patch_program|
        line_patch_program.edit("program.cr", "require \"./bystander\"\n", "require \"./bystander\"\n\n# Added one.\n# Added two.\n")
        stats, _ = line_patch_program.build

        stats.main_module_outcome.should eq("lines moved, cached object patched")
        line_patch_program.output.should eq(EXPECTED_OUTPUT)
        {% if flag?(:darwin) || flag?(:linux) %}
          line = line_patch_program.line_of("program.cr", "puts model.boom")
          line_patch_program.error_output("boom").should contain("program.cr:#{line}:")
        {% end %}

        # Unchanged since: the patched object is reused as it is.
        line_patch_program.edit("bystander.cr", "ARGV.size &+ 7", "ARGV.size &+ 7 ")
        stats, _ = line_patch_program.build
        stats.main_module_outcome.should be_nil
        line_patch_program.output.should eq(EXPECTED_OUTPUT)
      end
    end

    it "patches the main module's object as a fresh build writes it" do
      with_line_patch_program("line_patch_main_verify") do |line_patch_program|
        line_patch_program.edit("program.cr", "mode = ARGV[0]? || \"\"\n", "\n\nmode = ARGV[0]? || \"\"\n")
        stats, compiler = line_patch_program.build(verify: true)

        stats.main_module_outcome.to_s.should start_with("compiled for verification")
        verification = compiler.last_line_patch_verification || raise "nothing was verified"
        verification[1].should be_empty
        line_patch_program.output.should eq(EXPECTED_OUTPUT)
      end
    end

    it "keeps the main module's object when an edit elsewhere adds types" do
      with_line_patch_program("line_patch_main_new_type") do |line_patch_program|
        # A new class, and a tuple type the program had not used: new type
        # ids, a new entry of `~metaclass` and of the class name map, all of
        # them in the type tables module.
        line_patch_program.edit("bystander.cr", "class Bystander\n",
          "class Badge\n  def initialize(@n : Int32)\n  end\n\n  def n\n    @n\n  end\nend\n\nclass Bystander\n")
        line_patch_program.edit("bystander.cr", "ARGV.size &+ 7",
          "Badge.new(ARGV.size).n &+ {ARGV.size, 'b', 2.5_f32}[0] &+ 7")
        stats, _ = line_patch_program.build

        stats.main_module_outcome.should be_nil
        line_patch_program.output.should eq(EXPECTED_OUTPUT)
      end
    end

    it "compiles the main module when a position of its code is on an edited line" do
      with_line_patch_program("line_patch_main_edited") do |line_patch_program|
        line_patch_program.edit("program.cr", "puts Bystander.new.answer", "\nputs Bystander.new.answer &+ 1")
        stats, _ = line_patch_program.build

        stats.main_module_outcome.to_s.should start_with("compiled: a position on an edited line")
        line_patch_program.output.should eq("6\n42\n3\n0\n8\n")
      end
    end
  end

  describe "verification" do
    it "passes when the patched objects match the fresh ones" do
      with_line_patch_program("line_patch_verify") do |line_patch_program|
        line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n# Added.\n")
        stats, compiler = line_patch_program.build(verify: true)

        stats.skipped_units.should eq(0)
        verification = compiler.last_line_patch_verification || raise "nothing was verified"
        verification[0].should be > 0
        verification[1].should be_empty
        line_patch_program.output.should eq(EXPECTED_OUTPUT)
      end
    end

    it "fails the build when a patched object differs from the fresh one" do
      with_line_patch_program("line_patch_verify_failure") do |line_patch_program|
        # The cached object of `Model` gets other machine code, behind a
        # record that still describes it: what a patch from a wrong object
        # looks like.
        cache_directory = line_patch_program.cache_directory
        object_filename = Dir.glob(File.join(cache_directory, "M-odel*.o")).first
        record_filename = object_filename.rchop(".o") + ".hash"
        record = Crystal::CachedObjectRecord.read?(record_filename) || raise "no record"
        manifest = Crystal::IrSkip::Manifest.load?(cache_directory, nil) || raise "no manifest"
        bytes = File.read(object_filename).to_slice.dup
        text = Crystal::LinePatch::ObjectFile.parse(bytes).section?(Crystal::LinePatch::SectionKind::Text) || raise "no code"
        bytes[text.file_offset] = bytes[text.file_offset] ^ 0xff_u8
        File.write(object_filename, bytes)
        Crystal::CachedObjectRecord.write(record_filename, manifest.units_by_name["Model"].list_of_part_hashes, [object_filename])
        record.module_hash.should_not be_empty

        line_patch_program.edit("model.cr", "# Comment line one.\n", "# Comment line one.\n# Added.\n")
        error = expect_raises(Crystal::CompilerError, "Line patch verification failed") do
          line_patch_program.build(verify: true)
        end
        error.message.to_s.should contain("Model: the machine code differs")
      end
    end
  end
end
