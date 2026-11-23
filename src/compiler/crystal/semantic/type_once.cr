require "./call"

# `@[TypeOnce]`: a method that is typed once, against the types its signature
# declares, and reused by every caller.
#
# Without the annotation a method is typed once per combination of receiver
# and argument types that reaches it: `def touch(record : Record)` called with
# 300 subclasses of `Record` is typed 300 times. With it the parameter is typed
# as `Record+` (the declared class and its subclasses), calls inside the body
# dispatch at run time, and the 300 callers share one typed copy and one
# generated function.
#
# Rules (checked by `StrictDefChecker`, in `strict_files.cr`):
#
# * every parameter has a type restriction and the method declares its return
#   type, so the signature says everything a caller can observe;
# * no free variables (`forall`), no splat that collects arguments, no `yield` (a captured block with
#   a declared proc type, written out or named through an `alias`, is fine);
# * the body holds no macro expression (`{% %}`, `{{ }}`): those read the
#   concrete receiver through `@type`;
# * not `abstract`, not `initialize`.
#
# What is typed once:
#
# * a parameter whose restriction names a class (`Record`), the class itself
#   as a value (`Record.class`) or a union of types is typed as that class
#   and its subclasses, their metaclasses, or that union;
# * `self` is typed as the declaring class and its subclasses when the method
#   is an instance method of a non-generic class. For an instance method of a
#   non-generic module, `self` is the topmost class of the receiver's ancestry
#   that includes the module, and its subclasses. In a struct, a generic type
#   or a class method, `self` stays the caller's receiver (one copy per
#   receiver; parameters are still typed once).
#
# The body is therefore checked against the declared types: it may only use
# what every subclass offers, and instance variables the declaring class
# itself has.
module Crystal
  class Call
    # Returns *match* with the receiver and argument types replaced by the
    # types the def declares, when the def is `@[TypeOnce]` and this call
    # reaches it without dispatch. Returns *match* itself otherwise, which
    # types the usual copy for this call's own types.
    private def type_once_match(match : Match, self_type : Type?, single_match : Bool) : Match
      a_def = match.def
      return match unless a_def.type_once? && single_match
      # `super` and `previous_def` name their function after the caller.
      return match if self_type || super? || previous_def? || with_scope

      context = match.context
      # A union, module or other dispatching receiver picks its target by the
      # typed def's owner and parameter types at run time, so such a call
      # keeps the copy typed for its own types.
      receiver = context.instantiated_type
      receiver = receiver.base_type if receiver.is_a?(VirtualType)
      if call_obj = obj
        call_receiver = call_obj.type?.try(&.remove_indirection)
        return match unless call_receiver
        return match unless call_receiver.same?(context.instantiated_type) || call_receiver.same?(receiver)
      end

      # A method of a generic class with a bounded type parameter is typed once
      # for every instance (see `generic_type_once.cr`).
      if generic_match = generic_type_once_match(match)
        return generic_match
      end

      instantiated_type = type_once_self_type(a_def, context.instantiated_type)
      lookup_self_type = instantiated_type.instance_type
      defining_type = context.defining_type

      changed = !instantiated_type.same?(context.instantiated_type)
      arg_types = match.arg_types.map_with_index do |arg_type, index|
        declared = type_once_declared_type(a_def.args[index]?, defining_type, lookup_self_type, arg_type)
        changed ||= !declared.same?(arg_type)
        declared
      end
      named_arg_types = match.named_arg_types.try &.map do |named_arg|
        arg = a_def.args.find { |def_arg| def_arg.external_name == named_arg.name }
        declared = type_once_declared_type(arg, defining_type, lookup_self_type, named_arg.type)
        changed ||= !declared.same?(named_arg.type)
        NamedArgumentType.new(named_arg.name, declared, named_arg.loc)
      end
      return match unless changed

      new_context = MatchContext.new(instantiated_type, defining_type, context.bound_free_vars, context.def_free_vars)
      Match.new(a_def, arg_types, new_context, named_arg_types)
    end

    # The receiver type a `@[TypeOnce]` def is typed with: the declaring class
    # (or, for a module's method, the topmost class that includes the module)
    # and its subclasses for an instance method reached through a non-generic
    # class, the caller's receiver otherwise.
    private def type_once_self_type(a_def : Def, instantiated_type : Type) : Type
      def_owner = a_def.owner
      receiver = instantiated_type
      receiver = receiver.base_type if receiver.is_a?(VirtualType)
      return instantiated_type unless receiver.is_a?(NonGenericClassType) && !receiver.struct?
      if def_owner.is_a?(NonGenericClassType)
        return instantiated_type unless receiver.implements?(def_owner)
        def_owner.virtual_type
      elsif def_owner.is_a?(NonGenericModuleType)
        # The topmost class of the receiver's ancestry that includes the module.
        return instantiated_type unless receiver.implements?(def_owner)
        including_class = receiver
        while (superclass = including_class.superclass) && superclass.is_a?(NonGenericClassType) && superclass.implements?(def_owner)
          including_class = superclass
        end
        including_class.virtual_type
      else
        instantiated_type
      end
    end

    # The type a `@[TypeOnce]` parameter is typed with: the declared class and
    # its subclasses, or the declared union. *arg_type* (the caller's) is kept
    # for every other kind of restriction.
    private def type_once_declared_type(arg : Arg?, defining_type : Type, lookup_self_type : Type, arg_type : Type) : Type
      restriction = arg.try(&.restriction) || return arg_type
      declared = begin
        defining_type.lookup_type?(restriction, self_type: lookup_self_type, allow_typeof: false)
      rescue Crystal::CodeError
        nil
      end
      return arg_type unless declared
      declared = declared.remove_alias
      case declared
      when NonGenericClassType, GenericClassInstanceType
        return arg_type if declared.struct?
        declared = declared.virtual_type
      when VirtualType
        return arg_type if declared.struct?
      when MetaclassType
        # `Record.class`: the class itself is the value. Typed as the
        # metaclass of the declared class and its subclasses.
        instance = declared.instance_type
        return arg_type unless instance.is_a?(NonGenericClassType) && !instance.struct?
        declared = instance.virtual_type.metaclass
        passed = arg_type.instance_type
        passed = passed.base_type if passed.is_a?(VirtualType)
        return arg_type unless arg_type.metaclass? && passed.is_a?(NonGenericClassType) && passed.implements?(instance)
        return declared
      when VirtualMetaclassType
        instance = declared.instance_type.base_type
        passed = arg_type.instance_type
        passed = passed.base_type if passed.is_a?(VirtualType)
        return arg_type unless arg_type.metaclass? && passed.is_a?(NonGenericClassType) && !passed.struct? && passed.implements?(instance)
        return declared
      when UnionType
        return arg_type unless declared.union_types.all? { |member| type_once_union_member?(member) }
      else
        return arg_type
      end
      return arg_type if declared == arg_type
      type_once_widens?(arg_type, declared) ? declared : arg_type
    end

    private def type_once_union_member?(type : Type) : Bool
      case type
      when NilType, PrimitiveType, VirtualType
        !type.is_a?(VirtualType) || !type.struct?
      when NonGenericClassType, GenericClassInstanceType
        # Every value of the class is of that exact class.
        type.virtual_type.same?(type)
      else
        false
      end
    end

    private def type_once_widens?(arg_type : Type, declared : Type) : Bool
      arg_type = arg_type.remove_alias
      if arg_type.is_a?(UnionType)
        arg_type.union_types.all? { |member| type_once_widens?(member, declared) }
      elsif declared.is_a?(UnionType)
        declared.union_types.any? { |member| member == arg_type || (member.is_a?(VirtualType) && type_once_widens?(arg_type, member)) }
      elsif declared.is_a?(VirtualType)
        arg_type = arg_type.base_type if arg_type.is_a?(VirtualType)
        arg_type.is_a?(NonGenericClassType | GenericClassInstanceType) && !arg_type.struct? && arg_type.implements?(declared.base_type)
      else
        false
      end
    end
  end
end
