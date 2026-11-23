require "./codegen"

class Crystal::CodeGenVisitor
  # The value of a bounded type parameter in a method typed once for every
  # instance of a generic class (see `semantic/generic_type_once.cr`): the
  # metaclass the receiver's own instance has for it, read from the
  # receiver's type id.
  def visit(node : ErasedTypeVar)
    @last = erased_type_var_value(node, node.owner)
    false
  end

  private def erased_type_var_value(node : ErasedTypeVar, owner : Type) : LLVM::Value
    # The answer depends on every instance of the generic class, which no
    # trace records: the function is generated in every build.
    mark_ir_trace_unreplayable("a type parameter read at run time")

    name = node.name
    self_var = context.vars["self"]? || raise "BUG: #{node} read at run time without a receiver"
    receiver_type_id = load(llvm_context.int32, self_var.pointer)
    func = erased_type_var_fun(owner, name)
    call func, [receiver_type_id] of LLVM::Value
  end

  # The function, defined in the main module on first use, that maps the type
  # id of an object whose class has *owner*'s generic class in its ancestry
  # to the type id of the metaclass of its type argument *name*.
  private def erased_type_var_fun(owner : Type, name : String) : LLVMTypedFunction
    fun_name = "~type_var:#{owner.llvm_name}:#{name}"
    func = typed_fun?(@main_mod, fun_name) || create_erased_type_var_fun(fun_name, owner, name)
    check_main_fun fun_name, func
  end

  private def create_erased_type_var_fun(fun_name : String, owner : Type, name : String) : LLVMTypedFunction
    generic = owner.as(GenericInstanceType).generic_type
    id_to_metaclass = Hash(Int32, Int32).new
    generic.instantiated_types.each do |instance|
      next unless instance.is_a?(GenericClassInstanceType)
      next if instance.unbound?
      var_type = instance.type_vars[name]?.try(&.type?) || next
      metaclass_id = @program.llvm_id.type_id(var_type.devirtualize.metaclass)
      id_to_metaclass[@program.llvm_id.type_id(instance)] ||= metaclass_id
      instance.all_subclasses.each do |subclass|
        next if subclass.unbound?
        id_to_metaclass[@program.llvm_id.type_id(subclass)] ||= metaclass_id
      end
    end

    in_main do
      define_main_function(fun_name, [llvm_context.int32], llvm_context.int32) do |func|
        set_internal_fun_debug_location(func, fun_name)
        arg = func.params.first
        current_block = insert_block

        cases = {} of LLVM::Value => LLVM::BasicBlock
        id_to_metaclass.to_a.sort_by!(&.[0]).each do |(type_id, metaclass_id)|
          block = new_block "type_#{type_id}"
          cases[int32(type_id)] = block
          position_at_end block
          ret int32(metaclass_id)
        end

        otherwise = new_block "otherwise"
        position_at_end otherwise
        unreachable

        position_at_end current_block
        @builder.switch arg, otherwise, cases
      end
    end
  end
end

class Crystal::CodeGenVisitor
  # Whether *type* is an erased instance (or its metaclass) that typed-once
  # methods of a generic class are typed against.
  private def erased_instance_receiver?(type : Type) : Bool
    type = type.instance_type if type.is_a?(GenericClassInstanceMetaclassType)
    type.is_a?(GenericClassInstanceType) && @program.erased_type_vars_by_instance.has_key?(type.object_id)
  end
end
