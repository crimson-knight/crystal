require "./type_once"
require "./generic_type_once"

# Errors that keep `@[TypeOnce]` (and the methods a strict file types once)
# and `@[TypeBound]` from changing what a program does.
#
# A typed-once method is typed once, against its declared types, and every
# caller shares that copy. Where the shared copy would behave differently
# from the copies typed per caller, or fail to compile far from its cause,
# the compiler stops with an error at the annotation (at the `def` in a strict
# file) that names the method and the reason:
#
# * a macro called without a receiver in the body of a method whose `self` is
#   typed once for a class and its subclasses (or for every instance of a
#   generic class with a bound). The macro would expand once, for the declaring
#   type, where each receiver would expand it for itself; and a call that
#   finds a macro on the declaring type may find a method of the same name on
#   a subclass (Grant's `before_validation if responds_to?(:before_validation)`
#   skipped every model's callbacks);
# * a body that does not compile for the declared types: a call that only
#   compiles for concrete subclasses (`save` on a model base class), or a union
#   parameter passed whole to a set of overloads, where a member no caller
#   passes reaches an overload whose parameter has no type restriction;
# * `@[TypeBound(Model, Base)]` on a generic class the program instantiates
#   with the bound itself (`Builder(Base)`, as `Builder(self)` does from a
#   `Base.class` value): that instance is the one the shared copies are typed
#   against, so its own methods would read `Model` at run time.
module Crystal
  # An error about a typed-once method or a type bound, raised at the
  # annotation. A typed-once method that calls one is not blamed again.
  class TypeOnceError < TypeException
  end

  class Program
    # Calls in typed-once copies that pass a union parameter whole to a set of
    # overloads, where a member reaches an overload whose parameter has no type
    # restriction. Read only when typing the copy fails, by typed copy.
    getter type_once_union_forwards = Hash(UInt64, Array(String)).new

    # How errors name *a_def*, a method typed once: `@[TypeOnce] method
    # 'Record#touch'`, or `method 'Record#touch', typed once in a strict file,`.
    def type_once_label(a_def : Def) : String
      name = type_once_method_name(a_def)
      if a_def.annotation(type_once_annotation) || !strict_file?(a_def.location)
        "@[TypeOnce] method '#{name}'"
      else
        "method '#{name}', typed once in a strict file,"
      end
    end

    # What a typed-once method's author does to have it typed per caller again.
    def type_once_opt_out(a_def : Def) : String
      if a_def.annotation(type_once_annotation) || !strict_file?(a_def.location)
        "remove @[TypeOnce]"
      else
        "leave one type out of its signature"
      end
    end

    def type_once_method_name(a_def : Def) : String
      owner = a_def.owner?
      if owner.nil? || owner.is_a?(Program) || owner.is_a?(FileModule)
        a_def.name
      elsif owner.metaclass?
        "#{owner.instance_type}.#{a_def.name}"
      else
        "#{owner}##{a_def.name}"
      end
    end

    # Raises *message* at the `@[TypeOnce]` annotation of *a_def*, or at the def
    # when it is typed once because its file is strict.
    def raise_type_once_error(a_def : Def, message : String) : NoReturn
      node = a_def.annotation(type_once_annotation) || a_def
      ::raise TypeOnceError.for_node(node, message)
    end

    # Whether a typed copy whose `self` is *type* is shared by receivers of
    # several types: a class and its subclasses, or every instance of a generic
    # class with a bound.
    def type_once_shared_self?(type : Type) : Bool
      case type
      when VirtualType, VirtualMetaclassType
        true
      else
        instance = GenericTypeOnce.receiver_instance(type)
        !instance.nil? && erased_type_vars_by_instance.has_key?(instance.object_id)
      end
    end

    # " at file:line" for *location*, or "".
    def self.type_once_place(location : Location?) : String
      location = location.try(&.expanded_location)
      return "" unless location
      filename = location.filename
      return "" unless filename.is_a?(String)
      " (#{Crystal.relative_filename(filename)}:#{location.line_number})"
    end
  end

  abstract class SemanticVisitor
    # A macro called without a receiver in the body of a typed-once method
    # whose `self` stands for several receivers expands once, for the
    # declaring type: refused, as a `{{ }}` written in the body is.
    private def check_type_once_macro_call(node : Call, the_macro : Macro) : Nil
      untyped_def = @untyped_def || return
      @program.strict_tool_recorder.try &.record_macro_call(untyped_def, node)
      typed_def = @typed_def || return
      self_type = @scope || return
      return unless @program.type_once_shared_self?(self_type)

      # A typed-once method that calls this one with the same shared `self`
      # makes it typed once too (see `Call#check_type_once_callee_macro`).
      typed_def.macro_for_shared_self ||= "the macro '#{node.name}'#{Program.type_once_place(node.location)}"
      return unless untyped_def.type_once?

      declaring = self_type
      declaring = declaring.instance_type if declaring.is_a?(VirtualMetaclassType)
      declaring = declaring.base_type if declaring.is_a?(VirtualType)
      message = String.build do |io|
        io << @program.type_once_label(untyped_def) << " can't call the macro '" << node.name << "'"
        io << Program.type_once_place(node.location)
        io << ": the method is typed once for " << declaring << " and every "
        io << (declaring.is_a?(GenericClassInstanceType) ? "instance of #{declaring.generic_type}" : "subclass")
        io << ", so the macro expands once, for " << declaring << ", instead of once for each receiver."
        if definer = subclass_defining(declaring, node.name)
          io << " " << definer << " defines a method '" << node.name << "', which this call runs when the method is typed for each receiver; typed once, it never runs."
        end
        io << " Call a method in place of the macro, or " << @program.type_once_opt_out(untyped_def) << " to type the method for each receiver."
      end
      @program.raise_type_once_error(untyped_def, message)
    end

    # The first subclass of *type* that defines a method named *name* itself.
    private def subclass_defining(type : Type, name : String) : Type?
      return nil unless type.is_a?(ClassType)
      type.all_subclasses.find do |subclass|
        subclass.is_a?(ModuleType) && subclass.defs.try(&.has_key?(name))
      end
    end
  end

  class Call
    # Notes, for the typed-once copy this call is typed in, a union parameter
    # passed whole to overloads one of which leaves that parameter's type out.
    # Each member of the union picks its own overload, members no caller
    # passes included; if the copy then fails to compile, the error names it.
    private def note_type_once_union_forward(matches : Matches) : Nil
      return unless matches.size > 1
      visitor = @parent_visitor || return
      caller_def = visitor.untyped_def? || return
      return unless caller_def.type_once?
      typed_caller = visitor.typed_def? || return

      args.each_with_index do |arg, index|
        next unless arg.is_a?(Var)
        arg_type = arg.type?
        next unless arg_type.is_a?(UnionType)
        next unless caller_def.args.any? { |def_arg| def_arg.name == arg.name }
        next unless matches.any? { |match| match.def.args[index]?.try(&.restriction) }
        matches.each do |match|
          target_arg = match.def.args[index]? || next
          next if target_arg.restriction || match.def.splat_index == index
          taken = matches.compact_map { |other| other.def.args[index]?.try(&.restriction) ? other.arg_types[index]? : nil }
          members = arg_type.union_types.reject { |member| taken.any? { |other| other.same?(member) || (other.is_a?(UnionType) && other.union_types.includes?(member)) } }
          member = members.empty? ? (match.arg_types[index]? || next) : program.type_merge(members.map(&.as(Type?))) || next
          member_text = member.to_s
          member_text = member_text[1...-1] if member_text.starts_with?('(') && member_text.ends_with?(')')
          union_text = arg_type.to_s
          union_text = union_text[1...-1] if union_text.starts_with?('(') && union_text.ends_with?(')')
          target = "#{program.type_once_method_name(match.def)}(#{match.def.args.map(&.name).join(", ")})"
          note = "it passes parameter '#{arg.name}' (#{union_text}) whole to '#{name}', so each member of the union picks its own overload, and #{member_text} reaches '#{target}'#{Program.type_once_place(match.def.location)}, whose parameter '#{target_arg.name}' has no type restriction"
          notes = program.type_once_union_forwards[typed_caller.object_id] ||= [] of String
          notes << note unless notes.includes?(note)
        end
      end
    end

    # A typed-once method whose `self` stands for several receivers calls
    # *typed_def*, typed with that shared `self`, whose body (or a method it
    # calls the same way) calls a macro without a receiver. Typed for each
    # receiver, the callee would be typed for each receiver too and the macro
    # would expand for each; typed once, the callee is typed once with it and
    # the macro expands once, for the declaring type: refused. A caller that
    # is not typed once itself passes the note on to its own callers.
    private def check_type_once_callee_macro(typed_def : Def, match : Match) : Nil
      reason = typed_def.macro_for_shared_self || return
      return unless program.type_once_shared_self?(match.context.instantiated_type)
      visitor = @parent_visitor || return
      caller_typed = visitor.typed_def? || return
      scope = visitor.scope? || return
      return unless program.type_once_shared_self?(scope)
      caller = visitor.untyped_def? || return

      callee = "#{program.type_once_method_name(match.def)}"
      unless caller.type_once?
        caller_typed.macro_for_shared_self ||= "'#{callee}', which calls #{reason}"
        return
      end

      declaring = scope
      declaring = declaring.instance_type if declaring.is_a?(VirtualMetaclassType)
      declaring = declaring.base_type if declaring.is_a?(VirtualType)
      message = String.build do |io|
        io << program.type_once_label(caller) << " can't call '" << callee << "'" << Program.type_once_place(location)
        io << ": the method is typed once for " << declaring << " and every "
        io << (declaring.is_a?(GenericClassInstanceType) ? "instance of #{declaring.generic_type}" : "subclass")
        io << ", so '" << callee << "' is typed once for them too, and it calls " << reason
        io << ", which expands once, for " << declaring << ", instead of once for each receiver."
        io << " Call a method in place of the macro, or " << program.type_once_opt_out(caller) << " to type the method for each receiver."
      end
      program.raise_type_once_error(caller, message)
    end

    # `: self` (or a type that holds `self`) as the declared return type of a
    # typed-once method whose `self` stands for several receivers: each
    # caller would get its own receiver's type back, and gets the shared one
    # (`Model+`) instead.
    private def check_type_once_self_return(a_def : Def, shared_self : Type) : Nil
      return_type = a_def.return_type || return
      return unless program.type_once_shared_self?(shared_self)
      finder = SelfRestrictionFinder.new
      return_type.accept(finder)
      return unless finder.found?

      declaring = shared_self
      declaring = declaring.instance_type if declaring.is_a?(VirtualMetaclassType)
      declaring = declaring.base_type if declaring.is_a?(VirtualType)
      message = String.build do |io|
        io << program.type_once_label(a_def) << " can't declare its return type as '" << return_type << "'"
        io << ": the method is typed once for " << declaring << " and every subclass, so 'self' in the return type is "
        io << shared_self << " for every caller, where each caller typed for its own receiver gets that receiver's type back."
        io << " Declare the return type without 'self', or " << program.type_once_opt_out(a_def) << " to type the method for each receiver."
      end
      program.raise_type_once_error(a_def, message)
    end

    private class SelfRestrictionFinder < Visitor
      getter? found = false

      def visit(node : Self) : Bool
        @found = true
        false
      end

      def visit(node : ASTNode) : Bool
        !@found
      end
    end

    # *error* was raised while typing *typed_def*, the copy of a typed-once def
    # typed for the types *match* declares where the call passed those of
    # *called_match*. Raises an error at the annotation that names the method,
    # the types, and the call in its body that failed.
    private def raise_type_once_failure(typed_def : Def, match : Match, called_match : Match, error : CodeError) : NoReturn
      ::raise error if type_once_error_in?(error) || error.is_a?(FrozenTypeException)

      a_def = match.def
      # The frames of the error, from the call in the body inward. The reason
      # is the innermost frame that says something; the failing call is the
      # outermost frame that instantiates one.
      frames = [] of CodeError
      current = error.as(CodeError?)
      while current
        frames << current
        current = current.is_a?(TypeException) ? current.inner : nil
      end
      reason_frame = frames.reverse.find { |frame| !first_line(frame.message).empty? } || error
      reason = first_line(reason_frame.message)
      call_frame = frames.find { |frame| !frame.same?(reason_frame) && first_line(frame.message).starts_with?("instantiating '") }
      reason += type_once_error_place(reason_frame) if call_frame || frames.size > 1

      message = String.build do |io|
        io << program.type_once_label(a_def) << " can't be typed once: "
        if notes = program.type_once_union_forwards.delete(typed_def.object_id)
          io << notes.first << ". That overload fails: " << reason
        else
          io << "typed for its declared types " << type_once_types(a_def, match) << ", "
          if call_frame && (quoted = first_line(call_frame.message).match(/\Ainstantiating '(.+)'\z/))
            io << "the call '" << quoted[1] << "'" << type_once_error_place(call_frame) << " fails: " << reason
          else
            io << "its body fails: " << reason
            io << type_once_error_place(reason_frame) unless call_frame || frames.size > 1
          end
          io << ". The method may only call what every type it is typed for accepts"
        end
        io << ". Callers here pass " << type_once_types(a_def, called_match)
        io << "; " << program.type_once_opt_out(a_def) << " to type the method for each caller."
      end
      program.raise_type_once_error(a_def, message)
    end

    private def type_once_error_in?(error : Exception?) : Bool
      while error
        return true if error.is_a?(TypeOnceError)
        error = error.is_a?(TypeException) ? error.inner : nil
      end
      false
    end

    private def type_once_error_place(error : CodeError) : String
      return "" unless error.is_a?(TypeException)
      filename = error.@filename
      line = error.line_number
      return "" unless line
      filename = filename.expanded_location.try(&.filename) if filename.is_a?(VirtualFile)
      return "" unless filename.is_a?(String)
      " (#{Crystal.relative_filename(filename)}:#{line})"
    end

    private def first_line(message : String?) : String
      (message || "").each_line.first?.try(&.strip) || ""
    end

    # `(self : Record+, record : Record+)`: the receiver, when it is an
    # instance, and each parameter, as *match* types them.
    private def type_once_types(a_def : Def, match : Match) : String
      parts = [] of String
      receiver = match.context.instantiated_type
      parts << "self : #{receiver}" unless a_def.receiver || receiver.is_a?(Program) || receiver.is_a?(FileModule) || receiver.metaclass?
      match.arg_types.each_with_index do |arg_type, index|
        name = a_def.args[index]?.try(&.name) || next
        parts << "#{name} : #{arg_type}"
      end
      match.named_arg_types.try &.each do |named_arg|
        parts << "#{named_arg.name} : #{named_arg.type}"
      end
      "(#{parts.join(", ")})"
    end

    # `@[TypeBound(Model, Base)]` on a generic class that the program
    # instantiates with the bound itself: that instance is the erased instance
    # the methods typed once for every instance are typed against, so its own
    # methods would read the bounded parameter at run time.
    private def check_type_bound_instance(match : Match) : Nil
      instance = GenericTypeOnce.receiver_instance(match.context.instantiated_type) || return
      generic = instance.generic_type
      return unless generic.is_a?(GenericClassType)
      bounds = program.generic_bounds(generic) || return
      return unless bounds.all? { |name, bound| (var_type = instance.type_vars[name]?.try(&.type?)) && var_type.same?(bound.virtual_type) }
      # A call made in code typed on an erased instance (this one or another):
      # the shared copies reaching methods on `self` and on its instance
      # variables.
      if (visitor = @parent_visitor) && (scope = visitor.scope?)
        return if program.type_once_shared_self?(scope) && !scope.is_a?(VirtualType | VirtualMetaclassType)
        caller_instance = GenericTypeOnce.receiver_instance(scope)
        return if caller_instance && caller_instance.ancestors.includes?(instance)
      end

      name, bound = bounds.first
      ann = generic.annotations(program.type_bound_annotation).try(&.find { |candidate| candidate.args.first?.to_s == name })
      message = String.build do |io|
        io << "@[TypeBound(" << name << ", " << bound << ")] on " << generic << " can't hold: the program uses "
        io << generic.name << "(" << bound << "), the bound itself" << Program.type_once_place(location)
        io << " (calling '" << self.name << "'), and that is the instance the methods typed once for every instance of "
        io << generic << " are typed against, reading " << name << " at run time. A " << bound << ".class value as "
        io << name << " (`" << generic.name << "(self)` from a class method called on a " << bound << ".class value) makes it."
        io << " Pass a subclass of " << bound << ", or bound " << name << " by a class the program never passes itself (an abstract class under " << bound << ")."
      end
      ::raise TypeOnceError.for_node(ann || self, message)
    end
  end
end
