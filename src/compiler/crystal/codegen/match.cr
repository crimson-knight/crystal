require "./codegen"

class Crystal::CodeGenVisitor
  def match_type_id(type, restriction, type_id)
    match_type_id_impl(type.remove_indirection, restriction.remove_indirection, type_id)
  end

  private def match_type_id_impl(type, restriction : Program, type_id)
    llvm_true
  end

  private def match_type_id_impl(type, restriction : FileModule, type_id)
    llvm_true
  end

  private def match_type_id_impl(type : UnionType | VirtualType | VirtualMetaclassType, restriction, type_id)
    match_any_type_id(restriction, type_id)
  end

  private def match_type_id_impl(type : AliasType, restriction, type_id)
    match_type_id type.aliased_type, restriction, type_id
  end

  private def match_type_id_impl(type, restriction, type_id)
    equal? type_id(restriction), type_id
  end

  def match_any_type_id(type, type_id)
    match_any_type_id_impl(type.remove_indirection, type_id)
  end

  private def match_any_type_id_impl(type : UnionType | VirtualType | VirtualMetaclassType, type_id)
    match_any_type_id_with_function(type, type_id)
  end

  private def match_any_type_id_impl(type, type_id)
    equal? type_id(type), type_id
  end

  private def match_any_type_id_with_function(type, type_id)
    record_ir_type_effect(IrSkip::TraceKind::Match, type)
    call match_fun(type), [type_id] of LLVM::Value
  end

  # The function that tells whether a type id is that of *type* or of one
  # of its subtypes, in the module code is being generated into: one of the
  # type tables (see `TypeTables`).
  def match_fun(type : UnionType | VirtualType | VirtualMetaclassType) : LLVMTypedFunction
    match_fun_name = "~match<#{type.llvm_name}>"
    @type_table_requests.match_type_by_fun_name[match_fun_name] ||= type unless type_tables_home
    type_table_fun(match_fun_name, LLVM::Type.function([llvm_context.int32], llvm_context.int1)) do
      create_match_fun(match_fun_name, type)
    end
  end

  # Makes sure the subtype check of *type* is defined, without declaring it
  # in the module code is being generated into. A replayed trace asks this way.
  def request_match_fun(type : UnionType | VirtualType | VirtualMetaclassType) : Nil
    if home = type_tables_home
      in_module(home) { match_fun(type) }
    else
      @type_table_requests.match_type_by_fun_name["~match<#{type.llvm_name}>"] ||= type
    end
  end

  private def create_match_fun(name, type)
    in_module(type_tables_home || raise "BUG: #{name} is defined before the type tables are generated") do
      define_main_function(name, ([llvm_context.int32]), llvm_context.int1) do |func|
        set_internal_fun_debug_location(func, name)
        type_id = func.params.first
        create_match_fun_body(type, type_id)
      end
    end
  end

  private def create_match_fun_body(type : UnionType, type_id)
    result = nil
    type.expand_union_types.each do |sub_type|
      sub_type_cond = match_any_type_id(sub_type, type_id)
      result = result ? or(result, sub_type_cond) : sub_type_cond
    end
    ret result.not_nil!
  end

  private def create_match_fun_body(type : VirtualType, type_id)
    # One range when the subtypes were numbered right before the type, and
    # more when ids are kept from an earlier build (see `LLVMId`).
    result = nil
    @program.llvm_id.id_ranges(type.base_type).each do |(min, max)|
      in_range = and(
        builder.icmp(LLVM::IntPredicate::SGE, type_id, int(min)),
        builder.icmp(LLVM::IntPredicate::SLE, type_id, int(max))
      )
      result = result ? or(result, in_range) : in_range
    end
    ret(result || raise "BUG: #{type.base_type} has no type id")
  end

  private def create_match_fun_body(type, type_id)
    result = nil
    type.each_concrete_type do |sub_type|
      sub_type_cond = equal? type_id(sub_type), type_id
      result = result ? or(result, sub_type_cond) : sub_type_cond
    end
    ret result.not_nil!
  end
end
