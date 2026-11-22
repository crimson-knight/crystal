require "./type_once"
require "./main_visitor"

# Typed once for every instance of a generic class.
#
# A method of a generic class `Builder(Model)` is typed once per instance:
# `Builder(Post)#where!` and `Builder(User)#where!` are two typed copies even
# when nothing in the method depends on which model it is. When the generic
# class declares a bound for a type parameter,
#
# ```
# @[TypeBound(Model, Grant::Base)]
# class Grant::Query::Builder(Model)
#   @[TypeOnce]
#   def limit!(count : Int32) : Nil
#     @relation_state.limit = count
#   end
# end
# ```
#
# a typed-once method (`@[TypeOnce]`, or a fully typed method of a strict
# file) is typed once against the *erased instance*: the instance whose
# bounded parameters are the bound and its subclasses (`Builder(Grant::Base+)`).
# Every instance whose argument is a class within the bound calls that one
# copy. Parameters without a bound keep the caller's argument, so
# `Pair(Post, Int32)` and `Pair(User, Int32)` share a copy and
# `Pair(Post, Int64)` has another.
#
# The copy is right for every instance because the method may use a bounded
# parameter only as a value: `Model.table_name`, `Model.new`, `foo(Model)`.
# Its value is read at run time from the receiver's class, and its type is
# the bound's virtual metaclass, so calls on it dispatch over the bound's
# subclasses. The methods the copy reaches on `self`, and the instance
# variables they read, follow the same rules (`Scan`):
#
# * no bounded parameter in a type position (`Array(Model)`, `as(Model)`,
#   `is_a?(Model)`, a parameter or return type, `[] of Model`);
# * `self` only as the receiver of a call, never passed on or returned;
# * no `typeof`, `Self`, class variables, `super`, `previous_def`, macro
#   expressions that read `@type`, primitives on `self` (`self.class`), or
#   macros called on `self`;
# * each instance variable it reads or writes has the same type in the
#   instance as in the erased instance, and every instance variable of the
#   instance has the same representation (the layouts are equal).
#
# A subclass of an instance (a named-scope relation, say) shares the copy when
# it overrides none of the methods the copy calls on `self`.
#
# A class method shares a copy only when nothing it reaches reads a bounded
# parameter: a class method gets no receiver at run time to read it from.
#
# A method that cannot be shared keeps one copy per instance, as before, and a
# strict file or `@[TypeOnce]` gets a warning naming what to change.
module Crystal
  class Program
    # The erased instances made so far, by object id, with the names of the
    # type parameters whose value each defining instance in their superclass
    # chain reads at run time.
    getter erased_type_vars_by_instance = Hash(UInt64, Set(String)).new

    # Erased instances the program used directly before they were needed.
    getter refused_erased_instances = Set(UInt64).new

    # Bounds of each generic class that declares `@[TypeBound]`, by object id.
    @generic_bounds = Hash(UInt64, Hash(String, Type)?).new

    # Scans of methods against an erased instance, by def and instance.
    @generic_type_once_scans = Hash({UInt64, UInt64}, GenericTypeOnce::Scan).new

    # Defs already warned about.
    @generic_type_once_warned = Set(UInt64).new

    # Counters for the census.
    property generic_type_once_kept = 0

    # The bounds `@[TypeBound(Name, Type)]` declares on *generic*, or `nil`.
    def generic_bounds(generic : GenericClassType) : Hash(String, Type)?
      @generic_bounds.put_if_absent(generic.object_id) do
        GenericTypeOnce.read_bounds(self, generic)
      end
    end

    def generic_type_once_scan(a_def : Def, erased : Type, & : -> GenericTypeOnce::Scan) : GenericTypeOnce::Scan
      key = {a_def.object_id, erased.object_id}
      @generic_type_once_scans[key]? || (@generic_type_once_scans[key] = yield)
    end

    # Warns once that *a_def* keeps a copy per instance, when the def asked to
    # be typed once (in a strict file or with `@[TypeOnce]`).
    def warn_generic_type_once(a_def : Def, owner : Type, reason : String) : Nil
      return unless @generic_type_once_warned.add?(a_def.object_id)
      self.generic_type_once_kept += 1
      owner_name = owner.is_a?(GenericInstanceType) ? owner.generic_type.to_s : owner.to_s
      separator = a_def.receiver ? "." : "#"
      message = "#{a_def.type_once? && strict_file?(a_def.location) ? "strict file: " : ""}method '#{owner_name}#{separator}#{a_def.name}' is typed for each instance of #{owner_name}, as before. To have it typed once for every instance, #{reason}"
      warnings.add_warning(a_def, message)
    end
  end

# A bounded type parameter read at run time in a method typed once for
# every instance of a generic class: the replacement of the path that
# names it (see `MainVisitor#erased_type_var_owner`).
class ErasedTypeVar < ASTNode
  # The defining instance whose type parameter is read.
  getter owner : Type
  getter name : String

  def initialize(@owner : Type, @name : String, @type : Type? = nil)
  end

  def clone_without_location
    ErasedTypeVar.new(@owner, @name, @type)
  end

  def_equals_and_hash owner, name
end

  module GenericTypeOnce
    # What a scan of a def against an erased instance found.
    class Scan
      # Why the def cannot be shared, in the words of the warning, or `nil`.
      property reason : String?
      # Instance variables the def and the methods it reaches on `self` use.
      getter instance_vars = Set(String).new
      # Methods called on `self` (for the subclass check).
      getter self_calls = Set(String).new
      # Whether a bounded type parameter is read at run time.
      property? reads_type_var = false

      def ok? : Bool
        @reason.nil?
      end
    end

    def self.read_bounds(program : Program, generic : GenericClassType) : Hash(String, Type)?
      annotations = generic.annotations(program.type_bound_annotation) || return nil
      bounds = Hash(String, Type).new
      annotations.each do |ann|
        parameter = ann.args[0]?
        value = ann.args[1]?
        unless ann.args.size == 2 && ann.named_args.nil? && parameter.is_a?(Path) && parameter.names.size == 1 && value.is_a?(Path)
          ann.raise "@[TypeBound] takes the type parameter and its bound (@[TypeBound(#{generic.type_vars.first? || "T"}, SomeClass)])"
        end
        name = parameter.names.first
        unless generic.type_vars.includes?(name)
          parameter.raise "#{generic} has no type parameter #{name}"
        end
        if generic.splat_index == generic.type_vars.index(name)
          parameter.raise "a splat type parameter can't have a bound"
        end
        bound = generic.lookup_type?(value).try(&.remove_alias)
        unless bound.is_a?(NonGenericClassType) && !bound.struct?
          value.raise "the bound of #{name} must be a class (a struct, module or generic type has no layout in common with its subtypes)"
        end
        bounds[name] = bound
      end
      bounds.empty? ? nil : bounds
    end
    
    # The receiver instance of a call: the generic class instance it is, or
    # whose subclass or metaclass it is. `nil` for every other receiver.
    def self.receiver_instance(type : Type) : GenericClassInstanceType?
      type = type.instance_type if type.metaclass?
      type = type.base_type if type.is_a?(VirtualType)
      return nil unless type.is_a?(GenericClassInstanceType) && !type.struct?
      type
    end

    # The erased instance of *instance*: its bounded type arguments replaced
    # by their bounds. `nil` when the generic class declares no bound, or when
    # an argument is not a class within its bound.
    def self.erased_instance(program : Program, instance : GenericClassInstanceType) : GenericClassInstanceType?
      generic = instance.generic_type
      return nil unless generic.is_a?(GenericClassType)
      return nil if generic.splat_index
      bounds = program.generic_bounds(generic) || return nil

      type_vars = Array(TypeVar).new(generic.type_vars.size)
      generic.type_vars.each do |name|
        arg = instance.type_vars[name]?.try(&.type?) || return nil
        if bound = bounds[name]?
          return nil unless within_bound?(arg, bound)
          type_vars << bound.virtual_type
        else
          type_vars << arg
        end
      end
      erased = generic.instantiate(type_vars)
      return nil unless erased.is_a?(GenericClassInstanceType)
      return nil unless record_erased_type_vars(program, erased, bounds)
      erased
    end

    private def self.within_bound?(arg : Type, bound : Type) : Bool
      arg = arg.remove_alias
      arg = arg.base_type if arg.is_a?(VirtualType)
      return false unless arg.is_a?(NonGenericClassType) && !arg.struct?
      arg.implements?(bound)
    end

    # Notes, for the erased instance and each generic class instance in its
    # superclass chain, the type parameters that hold a bound: those the
    # instance's methods read at run time.
    private def self.record_erased_type_vars(program : Program, erased : GenericClassInstanceType, bounds : Hash(String, Type)) : Bool
      return true if program.erased_type_vars_by_instance.has_key?(erased.object_id)
      return false if program.refused_erased_instances.includes?(erased.object_id)

      # Methods typed on the erased instance before it was one read its bounded
      # parameters as constants. The copies typed from now on must agree with
      # them, so an instance the program already used directly is not erased.
      type = erased
      while type
        if type.is_a?(GenericClassInstanceType) && !program.erased_type_vars_by_instance.has_key?(type.object_id) && (!type.def_instances.empty? || !type.metaclass.as(DefInstanceContainer).def_instances.empty?)
          program.refused_erased_instances << erased.object_id
          return false
        end
        type = type.superclass
      end

      bound_types = bounds.values.map(&.virtual_type)
      type = erased
      while type
        if type.is_a?(GenericClassInstanceType)
          names = Set(String).new
          type.type_vars.each do |name, var|
            names << name if (var_type = var.type?) && bound_types.any?(&.same?(var_type))
          end
          program.erased_type_vars_by_instance[type.object_id] ||= names
        end
        type = type.superclass
      end
      true
    end

    # The type parameters of *defining*, the instance that defines a method
    # in the erased instance's chain, that hold a bound (read at run time) and
    # those whose value only mentions one (never usable in the shared copy).
    def self.type_var_sets(program : Program, defining : Type) : {Set(String), Set(String)}
      read_at_run_time = Set(String).new
      tainted = Set(String).new
      return {read_at_run_time, tainted} unless defining.is_a?(GenericInstanceType)
      erased_names = defining.is_a?(GenericClassInstanceType) ? program.erased_type_vars_by_instance[defining.object_id]? : nil
      defining.type_vars.each do |name, var|
        var_type = var.type? || next
        if erased_names && erased_names.includes?(name)
          read_at_run_time << name
        elsif mentions_bound?(program, var_type)
          tainted << name
        end
      end
      {read_at_run_time, tainted}
    end

    # Whether *type* mentions the bound of an erased instance.
    private def self.mentions_bound?(program : Program, type : Type, depth = 0) : Bool
      return false if depth > 8
      case type
      when VirtualType
        program.erased_bound?(type)
      when UnionType
        type.union_types.any? { |member| mentions_bound?(program, member, depth + 1) }
      when GenericInstanceType
        type.type_vars.each_value.any? { |var| (var_type = var.type?) && mentions_bound?(program, var_type, depth + 1) }
      when MetaclassType, GenericClassInstanceMetaclassType, VirtualMetaclassType
        mentions_bound?(program, type.instance_type, depth + 1)
      else
        false
      end
    end

    # Instance-variable representations that are the same in two instances.
    def self.same_layout?(instance_type : Type, erased_type : Type) : Bool
      return true if instance_type.same?(erased_type)
      reference_like?(instance_type) && reference_like?(erased_type)
    end

    private def self.reference_like?(type : Type) : Bool
      case type
      when NilableType, ReferenceUnionType, NilableReferenceUnionType
        true
      when VirtualType
        !type.struct?
      when NonGenericClassType, GenericClassInstanceType
        !type.struct?
      else
        false
      end
    end

    # Why *receiver* (the caller's, maybe virtual) cannot use the copy of a
    # method scanned as *scan* in *erased*, or `nil` when it can.
    def self.receiver_mismatch(receiver : Type, instance : GenericClassInstanceType, erased : GenericClassInstanceType, scan : Scan, a_def : Def) : String?
      metaclass = receiver.metaclass?
      unless metaclass
        instance_vars = instance.all_instance_vars
        erased_vars = erased.all_instance_vars
        if instance_vars.size != erased_vars.size || instance_vars.keys != erased_vars.keys
          return "keep the instance variables of #{instance} the same as those of #{erased}"
        end
        instance_vars.each do |name, var|
          erased_var = erased_vars[name]
          var_type = var.type? || return "declare the type of #{name}"
          erased_type = erased_var.type? || return "declare the type of #{name}"
          if scan.instance_vars.includes?(name) && !var_type.same?(erased_type)
            return "read #{name} through a method typed for each instance: its type depends on the type argument (#{var_type} in #{instance})"
          end
          unless same_layout?(var_type, erased_type)
            return "give #{name} a type with the same layout in every instance (it is #{var_type} in #{instance} and #{erased_type} in #{erased})"
          end
        end
      end

      # A subclass of the instance shares the copy only when it overrides none
      # of the methods the copy calls on `self`.
      if receiver.is_a?(VirtualType) || (receiver.is_a?(VirtualMetaclassType))
        lookup_base = metaclass ? instance.metaclass : instance
        names = scan.self_calls.dup
        names << a_def.name
        instance.all_subclasses.each do |subclass|
          lookup_sub = metaclass ? subclass.metaclass : subclass
          names.each do |name|
            next if lookup_sub.lookup_defs(name).map(&.object_id).sort! == lookup_base.lookup_defs(name).map(&.object_id).sort!
            return "leave '#{name}' as it is in #{subclass}, or call a method that #{subclass} does not override"
          end
        end
      end
      nil
    end

    # Scans *a_def* (owned by a type in the erased instance's chain) and the
    # methods it reaches on `self`.
    class Scanner < Visitor
      getter scan : Scan

      def initialize(@program : Program, @erased : GenericClassInstanceType, @metaclass : Bool, @scan : Scan, @visiting : Set(UInt64))
        @read_at_run_time = Set(String).new
        @tainted = Set(String).new
        @entry = true
      end

      def scan_def(a_def : Def, entry : Bool) : Nil
        return unless @scan.ok?
        return unless @visiting.add?(a_def.object_id)

        defining = defining_instance(a_def.owner)
        @read_at_run_time, @tainted = GenericTypeOnce.type_var_sets(@program, defining)
        @entry = entry

        if a_def.macro_def?
          return fail("write '#{a_def.name}' without macro expressions that read `@type`")
        end
        if a_def.body.is_a?(Primitive)
          return fail("call something other than '#{a_def.name}' on `self`: it reads the receiver's class")
        end
        a_def.args.each do |arg|
          if restriction = arg.restriction
            check_type_position(restriction, "the type of parameter '#{arg.name}' of '#{a_def.name}'")
          end
          arg.default_value.try &.accept(self)
        end
        a_def.block_arg.try(&.restriction).try { |restriction| check_type_position(restriction, "the block type of '#{a_def.name}'") }
        a_def.return_type.try { |return_type| check_type_position(return_type, "the return type of '#{a_def.name}'") }
        return unless @scan.ok?
        a_def.body.accept self
      end

      # The instance of *owner* in the erased instance's chain: the type that
      # resolves the def's paths.
      private def defining_instance(owner : Type) : Type
        owner = owner.instance_type if owner.metaclass?
        @erased.ancestors.each do |ancestor|
          if ancestor.is_a?(GenericInstanceType) && ancestor.generic_type.same?(owner)
            return ancestor
          end
        end
        owner.same?(@erased.generic_type) ? @erased : owner
      end

      private def fail(reason : String) : Bool
        @scan.reason ||= reason
        false
      end

      private def mentions(node : ASTNode) : String?
        found = nil
        node.accept(NameFinder.new { |name| found ||= name if @read_at_run_time.includes?(name) || @tainted.includes?(name) })
        found
      end

      private def check_type_position(node : ASTNode, what : String) : Nil
        if name = mentions(node)
          fail("write #{what} without #{name}: a type parameter with a bound can only be used as a value (#{name}.some_class_method)")
        end
        node.accept(TypeOfFinder.new { fail("leave typeof out of #{what}") })
      end

      def visit(node : ASTNode) : Bool
        @scan.ok?
      end

      def visit(node : Var) : Bool
        if node.name == "self"
          fail("use `self` only as the receiver of calls: passing it on gives the callee the erased instance's type")
        end
        false
      end

      def visit(node : Path) : Bool
        if node.names.size == 1 && !node.global?
          name = node.names.first
          if @tainted.includes?(name)
            return fail("leave #{name} out: its value mentions a bounded type parameter")
          end
          if @read_at_run_time.includes?(name)
            if @metaclass
              return fail("read #{name} in an instance method, or pass the class as a parameter: a class method has no receiver to read it from at run time")
            end
            @scan.reads_type_var = true
          end
        end
        false
      end

      def visit(node : Generic | Union | Metaclass | ProcNotation) : Bool
        check_type_position(node, "the type #{node}")
        false
      end

      def visit(node : Cast | NilableCast) : Bool
        node.obj.accept self
        check_type_position(node.to, "the cast to #{node.to}")
        false
      end

      def visit(node : IsA) : Bool
        node.obj.accept self
        check_type_position(node.const, "the check is_a?(#{node.const})")
        false
      end

      def visit(node : ArrayLiteral) : Bool
        node.of.try { |of| check_type_position(of, "the element type #{of}") }
        node.name.try { |name| check_type_position(name, "the type #{name}") }
        node.elements.each &.accept(self)
        false
      end

      def visit(node : HashLiteral) : Bool
        if of = node.of
          check_type_position(of.key, "the key type #{of.key}")
          check_type_position(of.value, "the value type #{of.value}")
        end
        node.name.try { |name| check_type_position(name, "the type #{name}") }
        node.entries.each do |entry|
          entry.key.accept self
          entry.value.accept self
        end
        false
      end

      def visit(node : TypeDeclaration) : Bool
        check_type_position(node.declared_type, "the declared type #{node.declared_type}")
        node.var.accept self unless node.var.is_a?(Var)
        node.value.try &.accept(self)
        false
      end

      def visit(node : UninitializedVar) : Bool
        check_type_position(node.declared_type, "the declared type #{node.declared_type}")
        false
      end

      def visit(node : SizeOf | InstanceSizeOf | AlignOf | InstanceAlignOf | OffsetOf) : Bool
        check_type_position(node, "#{node}")
        false
      end

      def visit(node : TypeOf) : Bool
        fail("leave typeof out")
      end

      def visit(node : Self) : Bool
        fail("leave `self` out of type positions")
      end

      def visit(node : ClassVar) : Bool
        fail("leave #{node.name} out: each instance has its own class variables")
      end

      def visit(node : InstanceVar) : Bool
        @scan.instance_vars << node.name
        false
      end

      def visit(node : ReadInstanceVar) : Bool
        obj = node.obj
        if obj.is_a?(Var) && obj.name == "self"
          @scan.instance_vars << node.name
          false
        else
          true
        end
      end

      def visit(node : ProcPointer) : Bool
        obj = node.obj
        if obj.nil? || (obj.is_a?(Var) && obj.name == "self")
          return fail("take a proc of something other than a method of `self`")
        end
        obj.accept self
        node.args.each { |arg| check_type_position(arg, "the proc type") }
        false
      end

      def visit(node : ProcLiteral) : Bool
        node.def.args.each do |arg|
          arg.restriction.try { |restriction| check_type_position(restriction, "the type of parameter '#{arg.name}'") }
        end
        node.def.return_type.try { |return_type| check_type_position(return_type, "the proc's return type") }
        node.def.body.accept self
        false
      end

      def visit(node : MacroExpression | MacroIf | MacroFor | MacroVerbatim) : Bool
        fail("leave macro expressions out")
      end

      def visit(node : Call) : Bool
        return false unless @scan.ok?
        obj = node.obj
        self_call = obj.nil? || (obj.is_a?(Var) && obj.name == "self")
        obj.accept self if obj && !self_call
        node.args.each &.accept(self)
        node.named_args.try &.each &.value.accept(self)
        node.block.try &.accept(self)
        node.block_arg.try &.accept(self)
        return false unless @scan.ok?

        if node.name.in?("super", "previous_def")
          return fail("leave '#{node.name}' out: it names the method of one owner")
        end
        return false unless self_call

        lookup_type = @metaclass ? @erased.metaclass : @erased
        if obj.nil?
          macros = lookup_type.lookup_macros(node.name)
          macros = @program.lookup_macros(node.name) unless macros.is_a?(Array)
          if macros.is_a?(Array)
            return fail("leave the macro call '#{node.name}' out: a macro can read the receiver through @type")
          end
        end
        defs = lookup_type.lookup_defs(node.name)
        return false if defs.empty? && obj.nil? # a top-level method
        @scan.self_calls << node.name

        saved = {@read_at_run_time, @tainted, @entry}
        defs.each do |callee|
          scan_def(callee, entry: false)
          break unless @scan.ok?
        end
        @read_at_run_time, @tainted, @entry = saved
        false
      end
    end

    # Calls the block with each single-name path in a type expression.
    class NameFinder < Visitor
      def initialize(&@block : String ->)
      end

      def visit(node : ASTNode) : Bool
        true
      end

      def visit(node : Path) : Bool
        @block.call(node.names.first) if node.names.size == 1 && !node.global?
        false
      end
    end

    class TypeOfFinder < Visitor
      def initialize(&@block : ->)
      end

      def visit(node : ASTNode) : Bool
        true
      end

      def visit(node : TypeOf | Self) : Bool
        @block.call
        false
      end
    end
  end

  class Program
    # Whether *type* is the bound of an erased instance (`Grant::Base+`).
    def erased_bound?(type : VirtualType) : Bool
      @generic_bounds.each_value.any? { |bounds| bounds && bounds.each_value.any? { |bound| bound.virtual_type.same?(type) } }
    end
  end

  class Call
    # The match of a typed-once method of a generic class, typed against the
    # erased instance (see `generic_type_once.cr`), or `nil` when the method
    # keeps a copy per instance.
    private def generic_type_once_match(match : Match) : Match?
      a_def = match.def
      context = match.context
      receiver = context.instantiated_type
      instance = GenericTypeOnce.receiver_instance(receiver) || return nil
      erased = GenericTypeOnce.erased_instance(program, instance)
      return nil unless erased
      metaclass = receiver.metaclass?

      scan = program.generic_type_once_scan(a_def, erased) do
        result = GenericTypeOnce::Scan.new
        GenericTypeOnce::Scanner.new(program, erased, metaclass, result, Set(UInt64).new).scan_def(a_def, entry: true)
        result
      end
      reason = scan.reason || GenericTypeOnce.receiver_mismatch(receiver, instance, erased, scan, a_def)
      if reason
        program.warn_generic_type_once(a_def, instance, reason)
        return nil
      end

      erased_receiver = metaclass ? erased.metaclass : erased
      defining_type = context.defining_type
      defining_instance = defining_type.is_a?(GenericInstanceType) ? defining_type : nil
      if defining_instance
        generic = defining_instance.generic_type
        found = erased.generic_type.same?(generic) ? erased : erased.ancestors.find { |ancestor| ancestor.is_a?(GenericInstanceType) && ancestor.generic_type.same?(generic) }
        return nil unless found
        defining_type = found
      elsif defining_type.same?(instance) || defining_type.same?(receiver)
        defining_type = erased
      end
      defining_type = defining_type.metaclass if metaclass && !defining_type.metaclass?

      lookup_self_type = erased
      arg_types = match.arg_types.map_with_index do |arg_type, index|
        type_once_declared_type(a_def.args[index]?, defining_type, lookup_self_type, arg_type)
      end
      named_arg_types = match.named_arg_types.try &.map do |named_arg|
        arg = a_def.args.find { |def_arg| def_arg.external_name == named_arg.name }
        NamedArgumentType.new(named_arg.name, type_once_declared_type(arg, defining_type, lookup_self_type, named_arg.type), named_arg.loc)
      end
      new_context = MatchContext.new(erased_receiver, defining_type, context.bound_free_vars, context.def_free_vars)
      Match.new(a_def, arg_types, new_context, named_arg_types)
    end
  end
end

module Crystal
  class MainVisitor < SemanticVisitor
    # The erased instance whose bounded type parameter *path* names, when
    # *lookup_scope* (the defining type of the method being typed) is one.
    private def erased_type_var_owner(lookup_scope : Type, path : Path) : Type?
      return nil unless path.names.size == 1 && !path.global?
      return nil unless lookup_scope.is_a?(GenericClassInstanceType)
      names = @program.erased_type_vars_by_instance[lookup_scope.object_id]? || return nil
      names.includes?(path.names.first) ? lookup_scope : nil
    end
  end
end

module Crystal
  class ToSVisitor
    def visit(node : ErasedTypeVar)
      @str << node.name
      false
    end
  end
end

module Crystal::GenericTypeOnce
  # `CRYSTAL_GENERIC_TYPE_ONCE_PROBE=<file>`: for every method typed for an
  # instance of a generic class that declares `@[TypeBound]`, whether it
  # could be typed once for every instance and, when not, why. Writes one
  # line per method, most copies first. A diagnostic for choosing what to
  # mark; it changes no typing.
  module Probe
    class_getter? enabled : Bool = !ENV["CRYSTAL_GENERIC_TYPE_ONCE_PROBE"]?.nil?

    record Entry, a_def : Def, reason : String?, copies : Int32

    @@entries = Hash(UInt64, Entry).new

    def self.note(program : Program, match : Match, typed_def : Def) : Nil
      a_def = match.def
      receiver = match.context.instantiated_type
      instance = GenericTypeOnce.receiver_instance(receiver) || return
      generic = instance.generic_type
      return unless generic.is_a?(GenericClassType) && program.generic_bounds(generic)
      erased = GenericTypeOnce.erased_instance(program, instance)
      reason = if erased.nil?
                 "an argument is outside the bound, or the erased instance is used directly"
               else
                 scan = program.generic_type_once_scan(a_def, erased) do
                   result = Scan.new
                   Scanner.new(program, erased, receiver.metaclass?, result, Set(UInt64).new).scan_def(a_def, entry: true)
                   result
                 end
                 scan.reason || GenericTypeOnce.receiver_mismatch(receiver, instance, erased, scan, a_def)
               end
      key = a_def.object_id
      entry = @@entries[key]?
      @@entries[key] = Entry.new(a_def, entry.try(&.reason) || reason, (entry.try(&.copies) || 0) + 1)
    end

    def self.report(program : Program) : Nil
      path = ENV["CRYSTAL_GENERIC_TYPE_ONCE_PROBE"]? || return
      File.open(path, "w") do |file|
        @@entries.values.sort_by! { |entry| -entry.copies }.each do |entry|
          a_def = entry.a_def
          location = a_def.location
          file.puts "#{entry.copies}\t#{a_def.owner}#{a_def.receiver ? "." : "#"}#{a_def.name}\t#{location.try(&.original_filename)}:#{location.try(&.line_number)}\t#{a_def.type_once? ? "marked" : "unmarked"}\t#{entry.reason || "OK"}"
        end
      end
    end
  end
end
