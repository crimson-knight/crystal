require "../../spec_helper"

# A program whose classes inherit methods that take the class itself, so
# every inherited function has its own text after the owner separator
# (`*Inheritor3@Ancestor#step1<Inheritor3>:Int32`): *classes* times
# *methods* distinct texts. Linked for an ELF target with `@` in those
# names, each text became a version definition of the executable; past
# 32,767 of them (Grant300 had about 65,000) the C library's versions
# wrapped onto them and the program stopped at start.
private def inheritor_program(classes : Int32, methods : Int32) : String
  String.build do |io|
    io << "abstract class Ancestor\n"
    io << "  getter number : Int32\n\n"
    io << "  def initialize(@number : Int32)\n  end\n"
    methods.times do |step|
      io << "\n  def step" << step << "(other) : Int32\n"
      io << "    other.number &+ " << step << "\n  end\n"
    end
    io << "end\n"
    classes.times do |index|
      io << "\nclass Inheritor" << index << " < Ancestor\n"
      io << "  def total : Int32\n    "
      methods.times do |step|
        io << " &+ " if step > 0
        io << "step" << step << "(self)"
      end
      io << "\n  end\nend\n"
    end
    io << "\nsum = 0\n"
    classes.times { |index| io << "sum &+= Inheritor" << index << ".new(" << index << ").total\n" }
    io << "puts sum\n"
  end
end

private def inheritor_sum(classes : Int32, methods : Int32) : Int32
  (0...classes).sum { |index| (0...methods).sum { |step| index + step } }
end

private def build_inheritor_program(directory : String, classes : Int32, methods : Int32) : String
  code = inheritor_program(classes, methods)
  program = File.join(directory, "program.cr")
  File.write(program, code)
  executable = File.join(directory, "program")
  compiler = Crystal::Compiler.new
  compiler.debug = Crystal::Debug::None
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, code), executable)
  executable
end

# The defined symbols of *executable* whose names contain *text*.
private def defined_symbols_with(nm : String, executable : String, text : String) : Array(String)
  Process.capture([nm, "--defined-only", executable]).lines.select(&.includes?(text))
end

private INHERITED_STEP = <<-CRYSTAL
  abstract class Ancestor
    def step(other) : Int32
      1
    end
  end

  class Inheritor1 < Ancestor
  end

  Inheritor1.new.step(Inheritor1.new)
  CRYSTAL

private def program_for(triple : String) : Crystal::Program
  program = Crystal::Program.new
  program.codegen_target = Crystal::Codegen::Target.new(triple)
  program
end

describe "Code generation: symbol names on ELF targets" do
  it "writes the owner separator of an inherited method as ~at~ for ELF targets" do
    name = "*Inheritor3@Ancestor#step1<Inheritor3>:Int32"
    Crystal.safe_mangling(program_for("aarch64-unknown-linux-gnu"), name).should eq("*Inheritor3~at~Ancestor#step1<Inheritor3>:Int32")
    Crystal.safe_mangling(program_for("x86_64-unknown-freebsd14.0"), name).should eq("*Inheritor3~at~Ancestor#step1<Inheritor3>:Int32")
    Crystal.safe_mangling(program_for("aarch64-linux-android31"), name).should eq("*Inheritor3~at~Ancestor#step1<Inheritor3>:Int32")
  end

  it "keeps the owner separator of an inherited method as @ for macOS" do
    name = "*Inheritor3@Ancestor#step1<Inheritor3>:Int32"
    Crystal.safe_mangling(program_for("aarch64-apple-darwin25.0.0"), name).should eq(name)
  end

  it "names the function of an inherited method with the target's separator" do
    result = semantic(INHERITED_STEP, inject_primitives: true)
    names = [] of String
    result.program.codegen(result.node, debug: Crystal::Debug::None).each_value do |unit|
      unit.mod.functions.each { |function| names << function.name if function.name.includes?("Ancestor#step") }
    end
    expected_separator = result.program.codegen_target.elf? ? "~at~" : "@"
    names.should eq(["*Inheritor1#{expected_separator}Ancestor#step<Inheritor1>:Int32"])
  end

  {% if flag?(:linux) || flag?(:bsd) || flag?(:android) || flag?(:solaris) %}
    it "links a program with many inherited methods without a version definition per method" do
      readelf = Process.find_executable("readelf")
      nm = Process.find_executable("nm")
      pending! "readelf and nm are not installed" unless readelf && nm

      with_tempfile("elf_symbol_names") do |directory|
        Dir.mkdir_p(directory)
        executable = build_inheritor_program(directory, 40, 8)
        Process.capture(executable).should eq("#{inheritor_sum(40, 8)}\n")

        # Before the escape this program defined 320 versions, one per
        # inherited function; the overflow needs 32,767, and every inherited
        # method of any program adds one.
        versions = Process.capture([readelf, "-V", "-W", executable])
        versions.should_not contain("Version definition section")
        versions.should_not contain("Ancestor#step")
        defined_symbols_with(nm, executable, "@").should be_empty
        defined_symbols_with(nm, executable, "~at~Ancestor#step").size.should eq(40 * 8)
      end
    end
  {% else %}
    it "keeps @ in the symbols of inherited methods on targets without symbol versions" do
      nm = Process.find_executable("nm")
      pending! "nm is not installed" unless nm

      with_tempfile("elf_symbol_names") do |directory|
        Dir.mkdir_p(directory)
        executable = build_inheritor_program(directory, 40, 8)
        Process.capture(executable).should eq("#{inheritor_sum(40, 8)}\n")
        defined_symbols_with(nm, executable, "@Ancestor#step").size.should eq(40 * 8)
        defined_symbols_with(nm, executable, "~at~").should be_empty
      end
    end
  {% end %}
end
