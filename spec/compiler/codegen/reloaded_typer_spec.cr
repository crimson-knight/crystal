require "../../spec_helper"

# Types whose layout depends on the size of other types: unions of structs,
# tuples in unions, generic structs, a recursive class and a C union.
private RELOADED_TYPER_PROGRAM = <<-CRYSTAL
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
  if llvm_type.kind.struct? && llvm_type.opaque_struct?
    io << "(struct without a body)"
    return
  end

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

# Parses the bitcode of *llvm_mod* into a new context, as a reload does.
private def reload(llvm_mod : LLVM::Module) : LLVM::Module
  bitcode = llvm_mod.write_bitcode_to_memory_buffer
  begin
    LLVM::Module.parse(bitcode, LLVM::Context.new)
  ensure
    bitcode.dispose
  end
end

private def add_global_of_each_struct(llvm_mod : LLVM::Module, typer : Crystal::LLVMTyper, list_of_types : Array(Crystal::Type), name_prefix : String) : Nil
  list_of_types.each_with_index do |type, index|
    llvm_type = layout_type(typer, type)
    llvm_mod.globals.add(llvm_type, "#{name_prefix}#{index}") if llvm_type.kind.struct?
  end
end

describe "Crystal::LLVMTyper in a context loaded from bitcode" do
  it "lays out every struct and union exactly as a typer in a new context" do
    program = semantic(RELOADED_TYPER_PROGRAM).program
    list_of_types = list_of_laid_out_types(program)
    list_of_types.count(&.is_a?(Crystal::MixedUnionType)).should be > 100
    list_of_types.size.should be > 1000

    new_context = LLVM::Context.new
    written_module = new_context.new_module("written")
    written_module.data_layout = program.target_machine.data_layout
    new_typer = Crystal::LLVMTyper.new(program, new_context, data_layout: written_module.data_layout)
    list_of_expected_layouts = list_of_types.map { |type| layout_of(new_typer, type) }
    list_of_expected_layouts.should_not contain("(struct without a body)")

    # A third of the types are used by the module that is written, a third
    # are known to the loaded context by name only, a third are unknown to it.
    list_of_types_in_module = list_of_types.each_slice(3).map(&.first).to_a
    list_of_types_without_body = list_of_types.each_slice(3).compact_map(&.[1]?).to_a
    add_global_of_each_struct(written_module, new_typer, list_of_types_in_module, "first")

    loaded_module = reload(written_module)
    loaded_context = loaded_module.context
    list_of_types_without_body.each do |type|
      llvm_type = layout_type(new_typer, type)
      next unless llvm_type.kind.struct?
      next unless struct_name = llvm_type.struct_name
      next if loaded_context.named_struct?(struct_name)

      LibLLVM.struct_create_named(loaded_context, struct_name)
    end

    reloaded_typer = Crystal::LLVMTyper.new(program, loaded_context, adopts_existing_structs: true, data_layout: loaded_module.data_layout)
    list_of_reloaded_layouts = list_of_types.reverse.map { |type| layout_of(reloaded_typer, type) }.reverse!
    list_of_reloaded_layouts.each_with_index do |layout, index|
      layout.should eq(list_of_expected_layouts[index]), "layout of #{list_of_types[index]}"
    end
    reloaded_typer.completed_struct_count.should be > 100
    reloaded_typer.list_of_mismatched_struct_names.should be_empty

    # The structs of the loaded module are the ones the typer hands out.
    list_of_types_in_module.each do |type|
      llvm_type = layout_type(reloaded_typer, type)
      next unless llvm_type.kind.struct?
      next unless struct_name = llvm_type.struct_name

      loaded_context.named_struct?(struct_name).should eq(llvm_type)
    end

    # A second reload, of a module that grew after the first one.
    add_global_of_each_struct(loaded_module, reloaded_typer, list_of_types_without_body, "second")
    loaded_module.verify
    twice_loaded_module = reload(loaded_module)
    twice_reloaded_typer = Crystal::LLVMTyper.new(program, twice_loaded_module.context, adopts_existing_structs: true,
      data_layout: twice_loaded_module.data_layout)
    list_of_types.rotate(list_of_types.size // 2).each do |type|
      index = list_of_types.index!(type)
      layout_of(twice_reloaded_typer, type).should eq(list_of_expected_layouts[index]), "layout of #{type} after two reloads"
    end
    twice_reloaded_typer.list_of_mismatched_struct_names.should be_empty
  end

  it "computes the same sizes after other contexts were disposed" do
    program = semantic(RELOADED_TYPER_PROGRAM).program
    list_of_types = list_of_laid_out_types(program)
    list_of_expected_layouts = nil

    # Each round's struct types are allocated where those of the round
    # before were freed. Every third type is skipped in a rotating way, so
    # an address holds another struct in each round.
    4.times do |round|
      context = LLVM::Context.new
      llvm_mod = context.new_module("round#{round}")
      llvm_mod.data_layout = program.target_machine.data_layout
      typer = Crystal::LLVMTyper.new(program, context, data_layout: llvm_mod.data_layout)

      list_of_types.each_with_index do |type, index|
        layout_of(typer, type) unless index % 3 == round % 3
      end
      list_of_layouts = list_of_types.map { |type| layout_of(typer, type) }
      list_of_expected_layouts ||= list_of_layouts
      list_of_layouts.each_with_index do |layout, index|
        layout.should eq(list_of_expected_layouts[index]), "layout of #{list_of_types[index]} in round #{round}"
      end

      context.dispose
    end
  end
end
