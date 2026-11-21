require "../syntax/ast"

module Crystal
  class ASTNode
    def raise(message, inner = nil, exception_type = Crystal::TypeException)
      ::raise exception_type.for_node(self, message, inner)
    end

    def simple_literal?
      case self
      when Nop, NilLiteral, BoolLiteral, NumberLiteral, CharLiteral,
           StringLiteral, SymbolLiteral
        true
      else
        false
      end
    end

    # `number_autocast` defines if casting numeric expressions to larger ones is enabled
    def supports_autocast?(number_autocast : Bool = true)
      case self
      when NumberLiteral, SymbolLiteral
        true
      else
        if number_autocast
          case self_type = self.type?
          when IntegerType
            self_type.kind.bytesize <= 64
          when FloatType
            self_type.kind.f32?
          else
            false
          end
        else
          false
        end
      end
    end
  end

  class Var
    def initialize(@name : String, @type : Type)
    end
  end

  # Fictitious node to represent primitives
  class Primitive < ASTNode
    getter name : String
    property extra : ASTNode?

    def initialize(@name : String, @type : Type? = nil)
    end

    def clone_without_location
      Primitive.new(@name, @type)
    end

    def_equals_and_hash name
  end

  # Fictitious node to represent a tuple indexer
  class TupleIndexer < Primitive
    getter index : TupleInstanceType::Index

    def initialize(@index)
      super("tuple_indexer_known_index")
    end

    def clone_without_location
      TupleIndexer.new(index)
    end

    def_equals_and_hash index
  end

  # Fictitious node to represent a type
  class TypeNode < ASTNode
    def initialize(@type : Type)
    end

    def to_macro_id
      @type.not_nil!.devirtualize.to_s
    end

    def clone_without_location
      self
    end

    def_equals_and_hash type
  end

  # Fictitious node to represent an assignment with a type restriction,
  # created to match the assignment of a method argument's default value.
  class AssignWithRestriction < ASTNode
    property assign
    property restriction

    def initialize(@assign : Assign, @restriction : ASTNode)
    end

    def clone_without_location
      AssignWithRestriction.new @assign.clone, @restriction.clone
    end

    def_equals_and_hash assign, restriction
  end

  class Arg
    include Annotatable

    # Name of the original arg if its def has been expanded (default arguments)
    property? original_name : String?

    def initialize(@name : String, @default_value : ASTNode? = nil, @restriction : ASTNode? = nil, external_name : String? = nil, @type : Type? = nil)
      @external_name = external_name || @name
    end

    def original_name
      @original_name || @name
    end

    # See `Def#share_signature_nodes_with`.
    def share_signature_nodes_with(source : Arg) : Nil
      @restriction = source.restriction
      @default_value = source.default_value
    end

    def clone_without_location
      arg = previous_def

      # An arg's type can sometimes be used as a restriction,
      # and must be preserved when cloned
      arg.set_type @type

      arg.annotations = @annotations.dup
      arg.original_name = original_name

      arg
    end
  end

  class Def
    include Annotatable

    property! owner : Type
    property! original_owner : Type
    property vars : MetaVars?
    rare_property yield_vars : Array(Var)?
    rare_property previous : DefWithMetadata?
    rare_property next : Def?
    rare_property special_vars : Set(String)?
    property freeze_type : Type?
    property block_nest = 0
    property? raises = false
    property? closure = false
    property? self_closured = false
    property? captured_block = false

    # `true` if this def has the `@[NoInline]` annotation
    property? no_inline = false

    # `true` if this def has the `@[AlwaysInline]` annotation
    property? always_inline = false

    # `true` if this def has the `@[ReturnsTwice]` annotation
    property? returns_twice = false

    # Set to the value of the `@[TargetFeature("+sve,+sve2")]` annotation
    rare_property target_features : String?

    # Set to the value of the `@[TargetFeature(cpu: "apple-m4")]` annotation
    rare_property target_cpu : String?

    # `true` if this def has the `@[Naked]` annotation
    property? naked = false

    # Is this a `new` method that was expanded from an initialize?
    property? new = false

    # Name of the original def if this def has been expanded (default arguments)
    rare_property explicit_original_name : String?

    rare_property explicit_macro_owner : Type?

    # Used to override the meaning of `self` in restrictions
    rare_property self_restriction_type : Type?

    def original_name? : String?
      explicit_original_name
    end

    def original_name=(original_name : String?)
      self.explicit_original_name = original_name
    end

    def macro_owner=(macro_owner : Type?)
      self.explicit_macro_owner = macro_owner
    end

    def macro_owner
      explicit_macro_owner || @owner
    end

    def macro_owner?
      explicit_macro_owner
    end

    def original_name
      explicit_original_name || @name
    end

    def add_special_var(name)
      special_vars = (self.special_vars ||= Set(String).new)
      special_vars << name
    end

    # Returns the minimum and maximum number of positional arguments that must
    # be passed to this method, assuming positional parameters are not matched
    # by named arguments.
    def min_max_args_sizes
      max_size = args.size
      default_value_index = args.index(&.default_value)
      min_size = default_value_index || max_size
      splat_index = self.splat_index
      if splat_index
        min_size = {default_value_index || splat_index, splat_index}.min
        if args[splat_index].name.empty?
          max_size = splat_index
        else
          if splat_restriction = args[splat_index].restriction
            min_size += 1 unless splat_restriction.is_a?(Splat) || default_value_index.try(&.< splat_index)
          end
          max_size = Int32::MAX
        end
      end
      {min_size, max_size}
    end

    def clone_without_location
      a_def = previous_def
      a_def.previous = previous
      a_def.raises = raises?
      a_def.no_inline = no_inline?
      a_def.always_inline = always_inline?
      a_def.returns_twice = returns_twice?
      a_def.target_features = target_features
      a_def.target_cpu = target_cpu
      a_def.naked = naked?
      a_def.annotations = annotations
      a_def.new = new?
      a_def.original_name = original_name?
      a_def
    end

    # Yields `arg, arg_index, object, object_index` corresponding
    # to arguments matching the given objects, taking into account this
    # def's splat index.
    def match(objects, &block)
      Splat.match(self, objects) do |arg, arg_index, object, object_index|
        yield arg, arg_index, object, object_index
      end
    end

    # Makes this copy of *source* use *source*'s own argument restrictions,
    # argument default values and return type.
    #
    # Type inference types a def instance's body in place, so each instance
    # needs its own copy of the body. It only reads the restrictions, the
    # default values and the return type, so every instance can share the
    # ones of the def it was copied from.
    def share_signature_nodes_with(source : Def) : Nil
      args.each_with_index do |arg, index|
        arg.share_signature_nodes_with(source.args[index])
      end
      if (double_splat = self.double_splat) && (source_double_splat = source.double_splat)
        double_splat.share_signature_nodes_with(source_double_splat)
      end
      if (block_arg = self.block_arg) && (source_block_arg = source.block_arg)
        block_arg.share_signature_nodes_with(source_block_arg)
      end
      self.return_type = source.return_type
    end

    def free_var?(node : Path)
      free_vars = self.free_vars
      return false unless free_vars
      name = node.single_name?
      !name.nil? && free_vars.includes?(name)
    end

    def free_var?(any)
      false
    end
  end

  class Macro
    include Annotatable

    property! owner : Type

    # Yields `arg, arg_index, object, object_index` corresponding
    # to arguments matching the given objects, taking into account this
    # macro's splat index.
    def match(objects, &block)
      Splat.match(self, objects) do |arg, arg_index, object, object_index|
        yield arg, arg_index, object, object_index
      end
    end

    def matches?(call_args, named_args)
      call_args_size = call_args.size
      my_args_size = args.size
      min_args_size = args.index(&.default_value) || my_args_size
      max_args_size = my_args_size
      splat_index = self.splat_index

      if splat_index
        if args[splat_index].external_name.empty?
          min_args_size = max_args_size = splat_index
        else
          min_args_size -= 1
          max_args_size = Int32::MAX
        end
      end

      # If there are arguments past the splat index and no named args, there's no match,
      # unless all args past it have default values
      if splat_index && my_args_size > splat_index + 1 && !named_args
        unless (splat_index + 1...args.size).all? { |i| args[i].default_value }
          return false
        end
      end

      # If there are more positional arguments than those required, there's no match
      # (if there's less they might be matched with named arguments)
      if call_args_size > max_args_size
        return false
      end

      # If there are named args we must check that all mandatory args
      # are covered by positional arguments or named arguments.
      if named_args
        mandatory_args = BitArray.new(my_args_size)
      elsif call_args_size < min_args_size
        # Otherwise, they must be matched by positional arguments
        return false
      end

      self.match(call_args) do |my_arg, my_arg_index, call_arg, call_arg_index|
        mandatory_args[my_arg_index] = true if mandatory_args
      end

      # Check named args
      named_args.try &.each do |named_arg|
        found_index = args.index { |arg| arg.external_name == named_arg.name }
        if found_index
          # A named arg can't target the splat index
          if found_index == splat_index
            return false
          end

          # Check whether the named arg refers to an argument that was already specified
          if mandatory_args
            if mandatory_args[found_index]
              return false
            end

            mandatory_args[found_index] = true
          else
            if found_index < call_args_size
              return false
            end
          end
        else
          # A double splat matches all named args
          next if double_splat

          return false
        end
      end

      # Check that all mandatory args were specified
      # (either with positional arguments or with named arguments)
      if mandatory_args
        self.args.each_with_index do |arg, index|
          if index != splat_index && !arg.default_value && !mandatory_args[index]
            return false
          end
        end
      end

      true
    end
  end

  class Splat
    # Yields `arg, arg_index, object, object_index` corresponding
    # to def arguments matching the given objects, taking into account the
    # def's splat index.
    def self.match(a_def, objects, &block)
      Splat.before(a_def, objects) do |arg, arg_index, object, object_index|
        yield arg, arg_index, object, object_index
      end
      Splat.at(a_def, objects) do |arg, arg_index, object, object_index|
        yield arg, arg_index, object, object_index
      end
    end

    # Yields `arg, arg_index, object, object_index` corresponding
    # to arguments before a def's splat index, matching the given objects.
    # If there are more objects than arguments in the method, they are not yielded.
    # If splat index is `nil`, all args and objects (with their indices) are yielded.
    def self.before(a_def, objects, &block)
      splat = a_def.splat_index || a_def.args.size
      splat.times do |i|
        obj = objects[i]?
        break unless obj

        yield a_def.args[i], i, obj, i
        i += 1
      end
      nil
    end

    # Yields `arg, arg_index, object, object_index` corresponding
    # to arguments at a def's splat index, matching the given objects.
    # If there are more objects than arguments in the method, they are not yielded.
    # If splat index is `nil`, all args and objects (with their indices) are yielded.
    def self.at(a_def, objects, &block)
      splat_index = a_def.splat_index
      return unless splat_index

      splat_size = Splat.size(a_def, objects, splat_index)
      splat_size.times do |i|
        obj_index = splat_index + i
        obj = objects[obj_index]?
        break unless obj

        yield a_def.args[splat_index], splat_index, obj, obj_index
      end

      nil
    end

    # Returns the splat size of this def matching the given objects.
    def self.size(a_def, objects, splat_index = a_def.splat_index)
      if splat_index
        objects.size - splat_index
      else
        0
      end
    end
  end

  class FunDef
    property! external : External
  end

  class If
    # This is set to `true` for an `If` that was created from an `&&` expression.
    flag_property? and, 1

    # This is set to `true` for an `If` that was created from an `||` expression.
    flag_property? or, 2

    # This is set to `true` when the compiler is sure that the condition is truthy
    flag_property? truthy, 3

    # This is set to `true` when the compiler is sure that the condition is falsey
    flag_property? falsey, 4

    def clone_without_location
      a_if = previous_def
      a_if.and = and?
      a_if.or = or?
      a_if
    end
  end

  class MetaVar < ASTNode
    include SpecialVar

    property name : String

    # This is the context of the variable: who allocates it.
    # It can either be the Program (for top level variables),
    # a Def or a Block.
    property context : ASTNode | NonGenericModuleType | Nil

    property freeze_type : Type?

    # True if we need to mark this variable as nilable
    # if this variable is read.
    flag_property? nil_if_read, 0

    # A variable is closured if it's used in a ProcLiteral context
    # where it wasn't created.
    flag_property? closured, 1

    # Is this metavar assigned a value?
    flag_property? assigned_to, 2

    # Is this metavar closured in a mutable way?
    # This means it's closured and it got a value assigned to it more than once.
    # If that's the case, when it's closured then all local variable related to
    # it will also be bound to it.
    flag_property? mutably_closured, 3

    # Is this var in the local vars of its cumulative meta var? (See
    # `MainVisitor#check_mutably_closured`.)
    flag_property? listed_as_local_var, 4

    # A visitor that keeps its variables after it finishes holds this var:
    # it stays bound as it is.
    flag_property? kept_by_visitor, 5

    # Local variables associated with this meta variable.
    # Can be Var or MetaVar. Most meta variables have a single one, which is
    # stored directly; an array is created from the second one on.
    @local_vars : ASTNode | Array(ASTNode) | Nil

    def add_local_var(var : ASTNode) : Nil
      local_vars = @local_vars
      if local_vars.is_a?(Array(ASTNode))
        local_vars << var
      elsif local_vars
        @local_vars = [local_vars, var] of ASTNode
      else
        @local_vars = var
      end
    end

    def initialize(@name : String, @type : Type? = nil)
    end

    # Is this var a wrapper that only repeats one other var? It is bound to
    # that var alone, nothing reads it, and it says the same as the wrapped
    # var about being nil when read.
    def unchanged_wrapper? : Bool
      return false unless @dependencies.size == 1 && @observers.empty?
      return false if @freeze_type
      wrapped = @dependencies.first
      return false unless wrapped.is_a?(MetaVar)
      wrapped.nil_if_read? == nil_if_read? && wrapped.type?.same?(type?)
    end

    # Does this var only repeat its one dependency? Then every node that
    # reads it can read the dependency instead.
    def repeats_one_dependency? : Bool
      return false unless @dependencies.size == 1
      return false if @freeze_type || kept_by_visitor?
      dependency = @dependencies.first
      !dependency.same?(self) && dependency.type?.same?(type?)
    end

    # Puts the nodes that observe *var* in *var*'s place among the local
    # vars, and says whether *var* was there. Binding those nodes to this meta
    # var later gives them the types that binding *var* would have given them.
    def replace_local_var_with_its_observers(var : MetaVar) : Bool
      local_vars = @local_vars
      if local_vars.is_a?(Array(ASTNode))
        size = local_vars.size
        local_vars.reject! &.same?(var)
        return false if local_vars.size == size
        var.each_observer { |observer| local_vars << list_as_local_var(observer) }
        case local_vars.size
        when 0 then @local_vars = nil
        when 1 then @local_vars = local_vars.first
        end
        true
      elsif local_vars.same?(var)
        @local_vars = nil
        var.each_observer { |observer| add_local_var(list_as_local_var(observer)) }
        true
      else
        false
      end
    end

    # An observer that is itself a point var may be spliced out later: it
    # must know it is listed, to hand its place over in turn.
    private def list_as_local_var(node : ASTNode) : ASTNode
      node.listed_as_local_var = true if node.is_a?(MetaVar)
      node
    end

    # `splice_out_of_bindings`, for a var that *meta_var* lists as a local
    # var: the nodes that observe this var are listed in its place. Returns
    # false, changing nothing, when the var cannot be taken out now.
    def splice_out_of_bindings_leaving_observers_to(meta_var : MetaVar) : Bool
      return false if @observers.empty? && @dependencies.first.notifying_observers?
      return false unless meta_var.replace_local_var_with_its_observers(self)
      self.listed_as_local_var = false
      splice_out_of_bindings
    end

    # Marks this variable as closured.
    def mark_as_closured
      self.closured = true

      return unless mutably_closured?

      # If a meta var is not readonly and it became a closure we must
      # bind all previously related local vars to it so that
      # they get all types assigned to it.
      local_vars = @local_vars
      if local_vars.is_a?(Array(ASTNode))
        local_vars.each &.bind_to self
      elsif local_vars
        local_vars.bind_to self
      end
    end

    # True if this variable belongs to the given context
    # but must be allocated in a closure.
    def closure_in?(context)
      closured? && belongs_to?(context)
    end

    # True if this variable belongs to the given context.
    def belongs_to?(context)
      @context.same?(context)
    end

    # Is this metavar associated with any local vars?
    def local_vars? : Bool
      !@local_vars.nil?
    end

    def ==(other : self)
      name == other.name
    end

    def clone_without_location
      self
    end

    def inspect(io : IO) : Nil
      io << name
      if type = type?
        io << " : "
        type.to_s(io)
      end
      io << " (nil-if-read)" if nil_if_read?
      io << " (closured)" if closured?
      io << " (mutably-closured)" if mutably_closured?
      io << " (assigned-to)" if assigned_to?
      io << " (object id: #{object_id})"
    end

    def pretty_print(pp)
      pp.text inspect
    end
  end

  # The variables of a def, a block or a visitor by name, in insertion order.
  #
  # Every typed def instance and every call with a block holds several of
  # these, and most hold a handful of variables. This is a compact stand-in
  # for `Hash(String, MetaVar)`: up to `SMALL_LIMIT` entries live in one flat
  # buffer that is searched linearly, and a hash takes over beyond that.
  class MetaVars
    include Enumerable({String, MetaVar})

    private SMALL_LIMIT = 15

    @size : Int32 = 0
    @entries : Pointer({String, MetaVar}) = Pointer({String, MetaVar}).null
    @large : Hash(String, MetaVar)?

    def size : Int32
      large = @large
      large ? large.size : @size
    end

    def empty? : Bool
      size == 0
    end

    def []?(name : String) : MetaVar?
      if large = @large
        return large[name]?
      end
      index = small_index(name)
      index ? @entries[index][1] : nil
    end

    def [](name : String) : MetaVar
      self[name]? || raise KeyError.new("Missing variable: #{name}")
    end

    def has_key?(name : String) : Bool
      !self[name]?.nil?
    end

    def []=(name : String, var : MetaVar) : MetaVar
      if large = @large
        return large[name] = var
      end

      if index = small_index(name)
        @entries[index] = {name, var}
      elsif @size == SMALL_LIMIT
        large = Hash(String, MetaVar).new(initial_capacity: SMALL_LIMIT * 2)
        @size.times do |i|
          key, value = @entries[i]
          large[key] = value
        end
        large[name] = var
        release_entries
        @large = large
      else
        grow if @size == small_capacity(@size)
        @entries[@size] = {name, var}
        @size += 1
      end
      var
    end

    def delete(name : String) : MetaVar?
      if large = @large
        return large.delete(name)
      end

      index = small_index(name)
      return unless index

      var = @entries[index][1]
      (@entries + index).move_from(@entries + index + 1, @size - index - 1)
      @size -= 1
      (@entries + @size).clear
      var
    end

    def each(& : {String, MetaVar} ->) : Nil
      if large = @large
        large.each { |entry| yield entry }
      else
        # The block may add variables, which can replace the buffer.
        i = 0
        while i < @size
          yield @entries[i]
          i += 1
        end
      end
    end

    def each_key(& : String ->) : Nil
      each { |(name, _)| yield name }
    end

    def each_value(& : MetaVar ->) : Nil
      each { |(_, var)| yield var }
    end

    def keys : Array(String)
      map { |(name, _)| name }
    end

    # The name of the variable added last.
    def last_key : String
      if large = @large
        large.last_key
      elsif @size > 0
        @entries[@size - 1][0]
      else
        raise Enumerable::EmptyError.new
      end
    end

    def values : Array(MetaVar)
      map { |(_, var)| var }
    end

    def dup : MetaVars
      copy = MetaVars.new
      copy.initialize_copy(self)
      copy
    end

    def clone : MetaVars
      copy = MetaVars.new
      each { |(name, var)| copy[name] = var.clone }
      copy
    end

    protected def initialize_copy(other : MetaVars) : Nil
      if large = other.@large
        @large = large.dup
      elsif other.@size > 0
        @size = other.@size
        @entries = Pointer({String, MetaVar}).malloc(small_capacity(@size))
        @entries.copy_from(other.@entries, @size)
      end
    end

    # The buffer holds 1, 3, 7 or 15 entries: the sizes that fill the
    # collector's 32, 64, 128 and 256 byte cells.
    private def small_capacity(size : Int32) : Int32
      case size
      when 0    then 0
      when 1    then 1
      when 2..3 then 3
      when 4..7 then 7
      else           SMALL_LIMIT
      end
    end

    private def grow : Nil
      entries = Pointer({String, MetaVar}).malloc(small_capacity(@size + 1))
      entries.copy_from(@entries, @size)
      release_entries
      @entries = entries
    end

    private def release_entries : Nil
      GC.free(@entries.as(Void*)) unless @entries.null?
      @entries = Pointer({String, MetaVar}).null
    end

    # Variable names come from the parser's string pool, so the same name is
    # nearly always the same object: look for that first.
    private def small_index(name : String) : Int32?
      entries = @entries
      size = @size
      i = 0
      while i < size
        return i if entries[i][0].same?(name)
        i += 1
      end
      i = 0
      while i < size
        return i if entries[i][0] == name
        i += 1
      end
      nil
    end
  end

  # A variable belonging to a type: a global,
  # class or instance variable (globals belong to the program).
  class MetaTypeVar < Var
    include Annotatable

    property doc : String?

    property nil_reason : NilReason?

    # The owner of this variable, useful for showing good
    # error messages.
    property! owner : Type

    # The (optional) initial value of a class variable
    property initializer : ClassVarInitializer?

    property freeze_type : Type?

    # Flag used during codegen to indicate the initializer is simple
    # and doesn't require a call to a function
    property? simple_initializer = false

    # Is this variable thread local? Only applicable
    # to global and class variables.
    property? thread_local = false

    # Is this variable "unsafe" (no need to check if it was initialized)?
    property? uninitialized = false

    # Was this class_var already read during the codegen phase?
    # If not, and we are at the place that declares the class var, we can
    # directly initialize it now, without checking for an `init` flag.
    property? read = false

    # If true, there's no need to check whether the class var was initialized or
    # not when reading it.
    property? no_init_flag = false

    enum Kind
      Class
      Instance
      Global
    end

    def kind
      case name[0]
      when '@'
        if name[1] == '@'
          Kind::Class
        else
          Kind::Instance
        end
      else
        Kind::Global
      end
    end

    def global?
      kind.global?
    end
  end

  class ClassVar
    # The "real" variable associated with this node,
    # belonging to a type.
    property! var : MetaTypeVar
  end

  class Global
    property! var : MetaTypeVar
  end

  class Path
    property target_const : Const?
    property target_type : Type?
    property syntax_replacement : ASTNode?
  end

  class Call
    rare_property before_vars : MetaVars?

    def clone_without_location
      cloned = previous_def

      # This is needed because this call might have resolved
      # to a macro and has an expansion.
      cloned.expanded = expanded.clone

      cloned
    end
  end

  class Block
    property scope : Type?
    property vars : MetaVars?
    property after_vars : MetaVars?
    property context : Def | NonGenericModuleType | Nil
    property fun_literal : ASTNode?
    property freeze_type : Type?
    property? visited = false

    getter(:break) { Var.new("%break") }
  end

  class While
    property break_vars : Array(MetaVars)?

    def has_breaks?
      !!@break_vars
    end
  end

  class Break
    property! target : ASTNode
  end

  class Next
    property! target : ASTNode
  end

  class Return
    property! target : Def
  end

  class IsA
    property syntax_replacement : Call?
  end

  module ExpandableNode
    property expanded : ASTNode?
  end

  {% for name in %w(And Or
                   ArrayLiteral HashLiteral RegexLiteral RangeLiteral
                   Case StringInterpolation
                   MacroExpression MacroIf MacroFor MacroVerbatim MultiAssign
                   SizeOf InstanceSizeOf AlignOf InstanceAlignOf OffsetOf Global Require Select) %}
    class {{name.id}}
      include ExpandableNode
    end
  {% end %}

  class ClassDef
    property! resolved_type : ClassType
  end

  class ModuleDef
    property! resolved_type : ModuleType
  end

  class LibDef
    property! resolved_type : LibType
  end

  class CStructOrUnionDef
    property! resolved_type : NonGenericClassType
  end

  class Alias
    property! resolved_type : AliasType
  end

  class AnnotationDef
    include Annotatable

    property! resolved_type : AnnotationType
  end

  class External < Def
    property? external_var : Bool = false
    property real_name : String
    property! fun_def : FunDef
    property call_convention : LLVM::CallConvention?
    property wasm_import_module : String?

    property? dead = false
    property? used = false
    property? varargs = false

    # An External is also used to represent external variables
    # such as libc's `$errno`, which can be annotated with
    # `@[ThreadLocal]`. This property is `true` in that case.
    property? thread_local = false

    def initialize(name : String, args : Array(Arg), body, @real_name : String)
      super(name, args, body, nil, nil, nil)
    end

    def mangled_name(program, obj_type)
      real_name
    end

    def compatible_with?(other)
      return false if args.size != other.args.size
      return false if varargs? != other.varargs?

      args.each_with_index do |arg, i|
        return false if arg.type != other.args[i].type
      end

      type == other.type
    end

    def_hash @real_name, @varargs, @fun_def
  end

  class EnumDef
    property! resolved_type : EnumType
  end

  class Yield
    property expanded : Call?
  end

  class NilReason
    enum Reason
      UsedBeforeInitialized
      UsedSelfBeforeInitialized
      InitializedInRescue
    end

    getter name : String
    getter reason : Reason
    getter nodes : Array(ASTNode)?
    getter scope : Type?

    def initialize(@name, @reason : Reason, @nodes = nil, @scope = nil)
    end
  end

  class Asm
    property output_ptrofs : Array(PointerOf)?
  end

  # Fictitious node that means "all these nodes come from this file"
  class FileNode < ASTNode
    property node : ASTNode
    property filename : String

    def initialize(@node : ASTNode, @filename : String)
    end

    def accept_children(visitor)
      @node.accept visitor
    end

    def clone_without_location
      self
    end

    def_equals_and_hash node, filename
  end

  class Assign
    # Whether a class variable assignment needs to be skipped
    # because it was replaced with another initializer
    #
    # ```
    # class Foo
    #   @@x = 1 # This will never execute
    #   @@x = 2
    # end
    # ```
    property? discarded = false
  end

  class TypeDeclaration
    # Whether a class variable assignment needs to be skipped
    # because it was replaced with another initializer
    #
    # ```
    # class Foo
    #   @@x : Int32 = 1 # This will never execute
    #   @@x : Int32 = 2
    # end
    # ```
    property? discarded = false
  end

  # Fictitious node to represent an id inside a macro
  class MacroId < ASTNode
    property value : String

    def initialize(@value)
    end

    def to_macro_id
      @value
    end

    def clone_without_location
      self
    end

    def_equals_and_hash value
  end

  # Fictitious node representing a variable in macros
  class MetaMacroVar < ASTNode
    property name : String
    property default_value : ASTNode?

    # The instance variable associated with this meta macro var
    property! var : MetaTypeVar

    def initialize(@name, @type)
    end

    def self.class_desc
      "MetaVar"
    end

    def clone_without_location
      self
    end
  end

  # Fictitious node to mean a location in code shouldn't be reached.
  # This is used in the implicit `else` branch of a case.
  class Unreachable < ASTNode
    def clone_without_location
      Unreachable.new
    end
  end

  # Stands in for the body of a typed def whose LLVM function has already
  # been generated, when `CodeGenVisitor#release_typed_bodies?` is set.
  #
  # Codegen generates each function once and later call sites only declare
  # it, so the typed body is dead weight afterwards; dropping it lets the
  # memory of the analyzed program shrink while LLVM's grows. Call sites see
  # a body they cannot inline and emit a plain call. If codegen ever reaches
  # one, it raises instead of generating an empty function.
  class ReleasedBody < ASTNode
    def clone_without_location
      ReleasedBody.new
    end
  end

  class ProcLiteral
    # If this ProcLiteral was created from expanding a ProcPointer,
    # this holds the reference to it.
    property proc_pointer : ProcPointer?
  end

  class ProcPointer
    property expanded : ASTNode?
  end
end
