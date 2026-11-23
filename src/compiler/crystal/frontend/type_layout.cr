require "../types"

# Pure-Crystal ABI layout engine.
#
# This is a drop-in replacement for the sizing half of `LLVMTyper`
# (`Program#size_of`, `#align_of`, `#instance_size_of`, `#instance_align_of`,
# `#offset_of`, `#instance_offset_of`) that does NOT touch libLLVM.
# It exists so that a frontend-only compiler (parse + semantic + diagnostics)
# can be built with `-Dwithout_llvm` and no LLVM symbols linked, which in turn
# makes a wasm32-wasi build of the frontend possible.
#
# The mapping from Crystal types to layout mirrors `LLVMTyper#create_llvm_type`
# / `#create_llvm_struct_type` (codegen/llvm_typer.cr and codegen/unions.cr)
# exactly, always with `wants_size: true` semantics (classes and pointers
# short-circuit to pointer size, which also guarantees termination on
# recursive types). Sizes/alignments follow LLVM's data layout rules for the
# targets Crystal supports with LLVM >= 18:
#
# * i1 -> 1/1, i8 -> 1/1, i16 -> 2/2, i32 -> 4/4, i64 -> 8/8, i128 -> 16/16
#   (generic iN: ABI align = next power of two >= byte size, capped at 16)
# * float 4/4, double 8/8
# * pointer size/alignment from `Target#pointer_bit_width`
# * structs use standard C layout (packed structs: no padding, align 1)
# * arrays: n * elem size, elem alignment
#
# NOT supported: targets where i64/f64 alignment differs from 8 (i386) —
# nothing in Crystal's tier-1 matrix (x86_64/aarch64 darwin/linux/windows,
# wasm32, arm, aarch64) needs it, except i386 which is best-effort anyway.
module Crystal
  class TypeLayout
    record Info, size : UInt64, align : UInt32 do
      def self.scalar(size : Int, align : Int) : Info
        new(size.to_u64, align.to_u32)
      end
    end

    def initialize(@program : Program)
      @cache = {} of Type => Info
      @instance_cache = {} of Type => Info
    end

    private def pointer_bytes : UInt32
      (@program.codegen_target.pointer_bit_width // 8).to_u32
    end

    private def pointer_info : Info
      Info.scalar(pointer_bytes, pointer_bytes)
    end

    private def int_info(bits : Int) : Info
      bytes = (bits + 7) // 8
      align = 1_u32
      while align < bytes && align < 16
        align *= 2
      end
      Info.new(align_to(bytes.to_u64, align), align)
    end

    private def align_to(size : UInt64, align : UInt32) : UInt64
      return size if align <= 1
      (size + align - 1) // align * align
    end

    # C struct layout over already-computed member layouts.
    private def struct_info(members : Array(Info), packed : Bool = false) : Info
      size = 0_u64
      align = 1_u32
      members.each do |m|
        unless packed
          size = align_to(size, m.align)
          align = {align, m.align}.max
        end
        size += m.size
      end
      align = 1_u32 if packed
      Info.new(align_to(size, align), align)
    end

    private def struct_offsets(members : Array(Info), packed : Bool = false) : Array(UInt64)
      offsets = Array(UInt64).new(members.size)
      size = 0_u64
      members.each do |m|
        size = align_to(size, m.align) unless packed
        offsets << size
        size += m.size
      end
      offsets
    end

    # Equivalent of `LLVMTyper#size_of(llvm_type(type))`.
    def size_of(type : Type) : UInt64
      info(type).size
    end

    # Equivalent of `LLVMTyper#align_of(llvm_type(type))`.
    def align_of(type : Type) : UInt32
      info(type).align
    end

    # Equivalent of `LLVMTyper#size_of(llvm_struct_type(type))`.
    def instance_size_of(type : Type) : UInt64
      instance_info(type).size
    end

    # Equivalent of `LLVMTyper#align_of(llvm_struct_type(type))`.
    def instance_align_of(type : Type) : UInt32
      instance_info(type).align
    end

    # Equivalent of `LLVMTyper#offset_of(llvm_type(type), element_index)`:
    # only meaningful for value aggregates (structs, tuples, named tuples,
    # mixed unions).
    def offset_of(type : Type, element_index) : UInt64
      members, packed = aggregate_members(type.remove_indirection)
      struct_offsets(members, packed)[element_index.to_i]
    end

    # Equivalent of `LLVMTyper#offset_of(llvm_struct_type(type), element_index)`
    # where element_index already accounts for the type id header of classes.
    def instance_offset_of(type : Type, element_index) : UInt64
      members, packed = instance_members(type.remove_indirection)
      struct_offsets(members, packed)[element_index.to_i]
    end

    def info(type : Type) : Info
      type = type.remove_indirection
      @cache[type] ||= compute(type)
    end

    def instance_info(type : Type) : Info
      type = type.remove_indirection
      @instance_cache[type] ||= compute_instance(type)
    end

    # --- mirrors LLVMTyper#create_llvm_type (wants_size: true) ---

    private def compute(type : NoReturnType) : Info
      Info.scalar(0, 1) # llvm void
    end

    private def compute(type : VoidType) : Info
      Info.scalar(0, 1) # llvm void
    end

    private def compute(type : NilType) : Info
      Info.scalar(0, 1) # empty struct
    end

    private def compute(type : BoolType) : Info
      Info.scalar(1, 1) # i1
    end

    private def compute(type : CharType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : IntegerType) : Info
      int_info(8 * type.bytes)
    end

    private def compute(type : FloatType) : Info
      type.bytes == 4 ? Info.scalar(4, 4) : Info.scalar(8, 8)
    end

    private def compute(type : SymbolType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : EnumType) : Info
      info(type.base_type)
    end

    private def compute(type : ProcInstanceType) : Info
      # struct { void*, void* }
      Info.new(2_u64 * pointer_bytes, pointer_bytes)
    end

    private def compute(type : InstanceVarContainer) : Info
      # wants_size semantics: a class is represented by a pointer
      return pointer_info unless type.struct?
      instance_info(type)
    end

    private def compute(type : MetaclassType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : LibType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : GenericClassInstanceMetaclassType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : GenericModuleInstanceMetaclassType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : VirtualMetaclassType) : Info
      Info.scalar(4, 4) # i32
    end

    private def compute(type : PointerInstanceType) : Info
      pointer_info
    end

    private def compute(type : StaticArrayInstanceType) : Info
      elem = embedded_info(type.element_type)
      n = type.size.as(NumberLiteral).value.to_u64
      Info.new(elem.size * n, elem.align)
    end

    private def compute(type : TupleInstanceType) : Info
      struct_info(type.tuple_types.map { |tuple_type| embedded_info(tuple_type) })
    end

    private def compute(type : NamedTupleInstanceType) : Info
      struct_info(type.entries.map { |entry| embedded_info(entry.type) })
    end

    private def compute(type : NilableType) : Info
      info(type.not_nil_type)
    end

    private def compute(type : ReferenceUnionType) : Info
      pointer_info
    end

    private def compute(type : NilableReferenceUnionType) : Info
      pointer_info
    end

    private def compute(type : NilableProcType) : Info
      Info.new(2_u64 * pointer_bytes, pointer_bytes)
    end

    private def compute(type : TypeDefType) : Info
      info(type.typedef)
    end

    private def compute(type : VirtualType) : Info
      pointer_info
    end

    private def compute(type : AliasType) : Info
      info(type.remove_alias)
    end

    private def compute(type : ReferenceStorageType) : Info
      instance_info(type.reference_type)
    end

    private def compute(type : NonGenericModuleType | GenericClassType) : Info
      # Only reached when the module/generic class has no implementors: i1
      Info.scalar(1, 1)
    end

    # mirrors LLVMTyper#create_llvm_type(MixedUnionType) in codegen/unions.cr:
    # struct { i32, [value_size x i(max_alignment*8)] }
    private def compute(type : MixedUnionType) : Info
      max_size = 0_u64
      max_alignment = pointer_bytes

      type.expand_union_types.each do |subtype|
        unless subtype.void?
          sub = info(subtype)
          max_size = {sub.size, max_size}.max
          max_alignment = {sub.align, max_alignment}.max
        end
      end

      value_size = {(max_size + (max_alignment - 1)) // max_alignment, 1_u64}.max
      payload = Info.new(value_size * max_alignment, max_alignment)
      struct_info([Info.scalar(4, 4), payload])
    end

    private def compute(type : Type) : Info
      raise "BUG: called TypeLayout#compute for #{type}"
    end

    # --- mirrors LLVMTyper#llvm_embedded_type / #llvm_embedded_c_type ---

    private def embedded_info(type : Type, extern : Bool = false) : Info
      type = type.remove_indirection
      case type
      when NoReturnType, VoidType
        Info.scalar(1, 1) # i8
      when ProcInstanceType
        # inside extern (lib) structs a proc is just a function pointer
        return pointer_info if extern
        info(type)
      else
        info(type)
      end
    end

    # --- mirrors LLVMTyper#create_llvm_struct_type ---

    private def compute_instance(type : StaticArrayInstanceType) : Info
      info(type)
    end

    private def compute_instance(type : TupleInstanceType) : Info
      info(type)
    end

    private def compute_instance(type : NamedTupleInstanceType) : Info
      info(type)
    end

    private def compute_instance(type : InstanceVarContainer) : Info
      if type.extern_union?
        return c_union_info(type)
      end

      members, packed = instance_members(type)
      struct_info(members, packed)
    end

    private def compute_instance(type : Type) : Info
      raise "BUG: called TypeLayout#compute_instance for #{type}"
    end

    # Member layouts of the *instance* struct of `type`
    # (type id header included for classes), matching
    # LLVMTyper#create_llvm_struct_type(InstanceVarContainer).
    private def instance_members(type : InstanceVarContainer) : {Array(Info), Bool}
      members = [] of Info
      members << Info.scalar(4, 4) unless type.struct? # type id

      is_extern = type.extern?
      type.all_instance_vars.each do |name, ivar|
        members << embedded_info(ivar.type, extern: is_extern)
      end

      {members, type.packed?}
    end

    private def instance_members(type : Type) : {Array(Info), Bool}
      raise "BUG: called TypeLayout#instance_members for #{type}"
    end

    # Member layouts of the *value* representation of an aggregate,
    # matching what LLVMTyper#llvm_type returns for value types.
    private def aggregate_members(type : TupleInstanceType) : {Array(Info), Bool}
      {type.tuple_types.map { |tuple_type| embedded_info(tuple_type) }, false}
    end

    private def aggregate_members(type : NamedTupleInstanceType) : {Array(Info), Bool}
      {type.entries.map { |entry| embedded_info(entry.type) }, false}
    end

    private def aggregate_members(type : MixedUnionType) : {Array(Info), Bool}
      max_size = 0_u64
      max_alignment = pointer_bytes

      type.expand_union_types.each do |subtype|
        unless subtype.void?
          sub = info(subtype)
          max_size = {sub.size, max_size}.max
          max_alignment = {sub.align, max_alignment}.max
        end
      end

      value_size = {(max_size + (max_alignment - 1)) // max_alignment, 1_u64}.max
      payload = Info.new(value_size * max_alignment, max_alignment)
      {[Info.scalar(4, 4), payload], false}
    end

    private def aggregate_members(type : InstanceVarContainer) : {Array(Info), Bool}
      instance_members(type)
    end

    private def aggregate_members(type : Type) : {Array(Info), Bool}
      raise "BUG: called TypeLayout#aggregate_members for #{type}"
    end

    # mirrors LLVMTyper#create_llvm_c_union_struct_type:
    # { [filler_size x i(max_align*8)] (, [pad x i8]) }
    private def c_union_info(type : InstanceVarContainer) : Info
      max_size = 0_u64
      max_align = 0_u32
      max_align_type_size = 0_u64

      type.instance_vars.each do |name, var|
        var_type = var.type
        unless var_type.void?
          member = embedded_info(var_type, extern: true)
          if member.size > max_size
            max_size = member.size
          end
          if member.align > max_align
            max_align = member.align
            max_align_type_size = member.size
          end
        end
      end

      return Info.scalar(0, 1) if max_align == 0

      Info.new(align_to(max_size, max_align), max_align)
    end
  end
end

{% if flag?(:without_llvm) %}
  # Frontend-only replacements for the Program sizing API normally provided
  # by codegen/codegen.cr (which requires LLVM). Semantics mirror those
  # definitions exactly.
  class Crystal::Program
    @type_layout : TypeLayout?

    def type_layout
      @type_layout ||= TypeLayout.new(self)
    end

    def size_of(type)
      if type.void?
        # sizeof(Void) is 1 because Pointer(Void).malloc must work like
        # Pointer(UInt8).malloc
        1_u64
      else
        type_layout.size_of(type)
      end
    end

    def instance_size_of(type)
      type_layout.instance_size_of(type)
    end

    def align_of(type)
      if type.void?
        1_u32
      else
        type_layout.align_of(type)
      end
    end

    def instance_align_of(type)
      type_layout.instance_align_of(type)
    end

    def offset_of(type, element_index)
      return 0_u64 if type.extern_union? || type.is_a?(StaticArrayInstanceType)
      type_layout.offset_of(type, element_index)
    end

    def instance_offset_of(type, element_index)
      type_layout.instance_offset_of(type, element_index + 1)
    end
  end
{% end %}
