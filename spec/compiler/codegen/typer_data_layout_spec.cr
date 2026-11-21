require "../../spec_helper"

# Types whose layout depends on the size of other types: unions of structs,
# tuples in unions, generic structs, a recursive class and a C union.
private TYPER_DATA_LAYOUT_PROGRAM = <<-CRYSTAL
  require "prelude"

  record Wide, first : Int64, second : Int64, third : Int64, fourth : Int32

  struct Pair(A, B)
    def initialize(@first : A, @second : B)
    end
  end

  lib LibOverlay
    union Overlay
      number : Int32
      wide : Int64[3]
      byte : UInt8
    end
  end

  class Chain
    @following : Chain?
    @payload : Pair(Wide, Int32) | Wide | Int8 | Nil
    @overlay = LibOverlay::Overlay.new

    def initialize(@following = nil, @payload = nil)
    end
  end

  chain = Chain.new(Chain.new, Pair.new(Wide.new(1_i64, 2_i64, 3_i64, 4), 5))
  entry_or_nil = {"key" => Wide.new(1_i64, 2_i64, 3_i64, 4)}.first?
  tuple_or_nil = rand < 2 ? {Pair.new("text", Wide.new(1_i64, 2_i64, 3_i64, 4)), 1} : nil
  named_tuple_or_number = rand < 2 ? {wide: Wide.new(1_i64, 2_i64, 3_i64, 4), flag: true} : 1_u8
  CRYSTAL

private def collect_laid_out_types(scope : Crystal::Type, list_of_types : Array(Crystal::Type)) : Nil
  scope.types?.try &.each_value do |type|
    if type.is_a?(Crystal::GenericType)
      type.each_instantiated_type do |instance|
        list_of_types << instance if instance.is_a?(Crystal::InstanceVarContainer) && !instance.unbound?
      end
    elsif type.is_a?(Crystal::InstanceVarContainer)
      list_of_types << type
    end
    collect_laid_out_types(type, list_of_types)
  end
end

# Every class, struct, tuple and union of *program* that has a layout.
private def list_of_laid_out_types(program : Crystal::Program) : Array(Crystal::Type)
  list_of_types = [] of Crystal::Type
  collect_laid_out_types(program, list_of_types)
  program.unions.each_value do |union_type|
    next unless union_type.is_a?(Crystal::MixedUnionType)
    # A union inside a generic def that was never instantiated has no layout.
    next if union_type.union_types.any? { |member| member.is_a?(Crystal::TypeParameter) || member.unbound? }

    list_of_types << union_type
  end
  list_of_types
end

# The LLVM type that holds the fields of *type*: the struct behind the
# pointer for a class, the value type for everything else.
private def layout_type(typer : Crystal::LLVMTyper, type : Crystal::Type) : LLVM::Type
  if type.is_a?(Crystal::NonGenericClassType | Crystal::GenericClassInstanceType) && !type.struct? && !type.is_a?(Crystal::PrimitiveType)
    typer.llvm_struct_type(type)
  else
    typer.llvm_type(type)
  end
end

private def describe_layout(typer : Crystal::LLVMTyper, llvm_type : LLVM::Type, io : IO) : Nil
  io << typer.size_of(llvm_type) << '/' << typer.align_of(llvm_type)
  return unless llvm_type.kind.struct?

  io << '{'
  llvm_type.struct_element_types.each_with_index do |element_type, index|
    io << '@' << typer.offset_of(llvm_type, index) << ':'
    describe_layout(typer, element_type, io)
    io << ' '
  end
  io << '}'
end

# The size, alignment and field offsets of *type*, through every nested
# struct.
private def layout_of(typer : Crystal::LLVMTyper, type : Crystal::Type) : String
  String.build { |io| describe_layout(typer, layout_type(typer, type), io) }
end

# A module in a context of its own with the program's data layout, and a
# typer that computes sizes with that module's data layout, as the code
# generator makes them for each type.
private def new_module_and_typer(program : Crystal::Program, name : String) : {LLVM::Module, Crystal::LLVMTyper}
  context = LLVM::Context.new
  llvm_mod = context.new_module(name)
  llvm_mod.data_layout = program.target_machine.data_layout
  {llvm_mod, Crystal::LLVMTyper.new(program, context, data_layout: llvm_mod.data_layout)}
end

# Defines a global variable of each struct type among *list_of_types* to
# *llvm_mod* and returns the names of the globals.
private def add_global_of_each_struct(llvm_mod : LLVM::Module, typer : Crystal::LLVMTyper, list_of_types : Array(Crystal::Type), name_prefix : String) : Array(String)
  list_of_global_names = [] of String
  list_of_types.each_with_index do |type, index|
    llvm_type = layout_type(typer, type)
    next unless llvm_type.kind.struct?

    global_name = "#{name_prefix}#{index}"
    # With a value the global is a definition, which a link keeps.
    llvm_mod.globals.add(llvm_type, global_name).initializer = llvm_type.null
    list_of_global_names << global_name
  end
  list_of_global_names
end

describe "Crystal::LLVMTyper with the data layout of its module" do
  it "lays out every struct and union the same in a new context after other contexts were disposed" do
    program = semantic(TYPER_DATA_LAYOUT_PROGRAM).program
    list_of_types = list_of_laid_out_types(program)
    list_of_types.count(&.is_a?(Crystal::MixedUnionType)).should be > 100
    list_of_types.size.should be > 1000

    first_module, first_typer = new_module_and_typer(program, "first")
    list_of_expected_layouts = list_of_types.map { |type| layout_of(first_typer, type) }
    first_module.context.dispose

    # Each round's struct types are allocated where those of the round
    # before were freed. A rotating third of the types is laid out last, so
    # an address holds another struct in each round.
    4.times do |round|
      llvm_mod, typer = new_module_and_typer(program, "round#{round}")

      list_of_types.each_with_index do |type, index|
        layout_of(typer, type) unless index % 3 == round % 3
      end
      list_of_types.each_with_index do |type, index|
        layout_of(typer, type).should eq(list_of_expected_layouts[index]), "layout of #{type} in round #{round}"
      end

      llvm_mod.context.dispose
    end
  end

  it "sizes unions as the code generator's own typer for the program does" do
    program = semantic(TYPER_DATA_LAYOUT_PROGRAM).program
    list_of_types = list_of_laid_out_types(program)

    3.times do |round|
      llvm_mod, typer = new_module_and_typer(program, "round#{round}")
      list_of_types.rotate(round * 97).each do |type|
        next unless type.is_a?(Crystal::MixedUnionType)

        typer.size_of(typer.llvm_type(type)).should eq(program.size_of(type)), "size of #{type} in round #{round}"
      end
      llvm_mod.context.dispose
    end
  end
end

describe "Crystal::Compiler.parse_linked_bitcode_files" do
  it "links the parts of a module, written from separate contexts, into one module" do
    program = semantic(TYPER_DATA_LAYOUT_PROGRAM).program
    list_of_types = list_of_laid_out_types(program).first(600)

    with_tempfile("linked_part0.bc", "linked_part1.bc", "linked_part2.bc") do |first_path, second_path, third_path|
      list_of_paths = [first_path, second_path, third_path]
      list_of_global_names = [] of String
      list_of_paths.each_with_index do |path, part_index|
        llvm_mod, typer = new_module_and_typer(program, "Linked")
        # The parts share half of their types.
        list_of_part_types = list_of_types.each_with_index.select { |(_, index)| index % 2 == 0 || index % 3 == part_index }.map(&.first).to_a
        list_of_global_names.concat add_global_of_each_struct(llvm_mod, typer, list_of_part_types, "part#{part_index}_")
        llvm_mod.write_bitcode_to_file(path).should eq(0)
        llvm_mod.context.dispose
      end

      linked_context = LLVM::Context.new
      linked_module = Crystal::Compiler.parse_linked_bitcode_files(list_of_paths, linked_context)
      linked_module.verify
      list_of_global_names.count(&.starts_with?("part2_")).should be > 100
      list_of_global_names.each do |global_name|
        linked_module.globals[global_name]?.should_not be_nil, "global #{global_name} in the linked module"
      end
      linked_context.dispose
    end
  end
end
