require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Crystal
  # Finds typed defs that generate the same machine code and gives each group
  # one representative, so codegen emits one LLVM function for the group.
  #
  # Two typed defs are in one group when their bodies have the same shape,
  # every type in them is either the same type or a pair of *interchangeable
  # classes*, and every call in them goes to defs that are again in one group
  # (a bisimulation over the call graph, computed by partition refinement).
  #
  # An interchangeable class is a non-generic, non-abstract reference class
  # without subclasses. A value of such a class is a pointer, so code that
  # only moves the pointer around, reads instance variables at equal offsets
  # or calls methods that are themselves shared does not depend on which
  # class it is. Everything that reads the identity of the class (a type id
  # constant, a metaclass value, a struct or union that embeds it) *pins* the
  # def: a pinned def is only grouped with defs that name the very same
  # classes.
  #
  # The walk is a whitelist. A node class or type kind it does not know makes
  # the def unshareable, so a gap in the whitelist costs sharing, never
  # correctness.
  class OwnerShapeSharing
    # How the owner enters a def's body (reported by the census).
    @[Flags]
    enum OwnerUse
      SelfPassed
      InstanceVar
      ClassSide
      SelfClass
      TypeOf
      MacroExpansion
      InsideOtherTypes
    end

    # One typed def in the call graph.
    class Shape
      getter typed_def : Def
      property base_first = 0_u64
      property base_second = 0_u64
      property first = 0_u64
      property second = 0_u64
      getter callees = [] of Def
      property? shareable = true
      property? pinned = false
      property blocker : String?
      property owner_use = OwnerUse::None
      property node_count = 0

      def initialize(@typed_def : Def)
      end
    end

    # Counters for the build log and the census.
    class Stats
      property typed_defs = 0
      property unshareable = 0
      property pinned = 0
      property groups = 0
      property shared = 0
      property rounds = 0
      property released_bodies = 0
      property seconds = 0.0
    end

    getter stats = Stats.new
    getter shapes = [] of Shape

    @shape_by_def = Hash(UInt64, Shape).new
    @representatives = Hash(UInt64, Def).new
    @super_targets = Set(UInt64).new
    @types = TypeFacts.new

    def initialize(@program : Program)
    end

    def self.enabled? : Bool
      ENV["CRYSTAL_SHARE_OWNER_SHAPES"]? != "0"
    end

    # The def whose function stands for *typed_def*, or `nil` when
    # *typed_def* generates its own function.
    def representative?(typed_def : Def) : Def?
      @representatives[typed_def.object_id]?
    end

    def shape?(typed_def : Def) : Shape?
      @shape_by_def[typed_def.object_id]?
    end

    def each_shared_def(& : Def, Def ->) : Nil
      @shapes.each do |shape|
        if representative = @representatives[shape.typed_def.object_id]?
          yield shape.typed_def, representative
        end
      end
    end

    # Walks every typed def reachable from the program's types and from
    # *main_node*, then groups them.
    def analyze(main_node : ASTNode) : Nil
      started = Time.instant
      pending = [] of Def
      collect_cached_defs(@program, Set(UInt64).new, pending)
      collect_calls(main_node, pending)

      walker = ShapeWalker.new(@program, @types, @super_targets)
      index = 0
      while index < pending.size
        typed_def = pending[index]
        index += 1
        next if @shape_by_def.has_key?(typed_def.object_id)
        shape = Shape.new(typed_def)
        @shape_by_def[typed_def.object_id] = shape
        @shapes << shape
        walker.walk(shape)
        walker.discovered.each { |found| pending << found unless @shape_by_def.has_key?(found.object_id) }
      end

      refine
      @stats.seconds = (Time.instant - started).total_seconds
    end

    # Walks *first* and *second* again and describes the first place where
    # their own shapes differ (census diagnostics only).
    def describe_difference(first : Def, second : Def) : String
      walker = ShapeWalker.new(@program, @types, Set(UInt64).new)
      traces = {first, second}.map do |typed_def|
        trace = [] of {UInt64, String}
        walker.trace = trace
        walker.walk(Shape.new(typed_def))
        trace
      end
      traces[0].each_with_index do |(value, place), index|
        other = traces[1][index]?
        if other.nil? || other[0] != value
          before = traces[0][{index - 3, 0}.max...index].map(&.[1]).join(" > ")
          return "step #{index}: #{place} / #{other.try(&.[1])} after #{before}"
        end
      end
      "no difference in #{traces[0].size} steps (other has #{traces[1].size})"
    end

    private def collect_cached_defs(type : Type, seen : Set(UInt64), pending : Array(Def)) : Nil
      return unless seen.add?(type.object_id)
      if type.is_a?(DefInstanceContainer)
        type.@def_instances.try &.each_value { |typed_def| pending << typed_def }
      end
      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| collect_cached_defs(instance, seen, pending) }
      end
      type.types?.try &.each_value { |nested| collect_cached_defs(nested, seen, pending) }
      collect_cached_defs(type.metaclass, seen, pending) unless type.metaclass?
    end

    # Finds the defs called from code outside any typed def (the top level).
    private def collect_calls(root : ASTNode, pending : Array(Def)) : Nil
      stack = [root] of ASTNode
      collector = CensusChildCollector.new
      while current = stack.pop?
        collector.children.clear
        current.accept_children(collector)
        stack.concat(collector.children)
        case current
        when Call
          current.each_target_def do |target_def|
            pending << target_def
            @super_targets << target_def.object_id if current.super?
          end
          current.expanded.try { |expanded| stack << expanded }
        when ExpandableNode
          current.expanded.try { |expanded| stack << expanded }
        end
      end
    end

    private def refine : Nil
      @shapes.each do |shape|
        if shape.shareable? && @super_targets.includes?(shape.typed_def.object_id)
          shape.shareable = false
          shape.blocker = "target of a super call"
        end
        unless shape.shareable?
          shape.base_first = shape.typed_def.object_id
          shape.base_second = 0x5bd1e995_u64
          shape.callees.clear
        end
        shape.first = shape.base_first
        shape.second = shape.base_second
      end

      callee_shapes = @shapes.map do |shape|
        shape.callees.map { |callee| @shape_by_def[callee.object_id] }
      end

      groups = count_groups
      next_values = Array({UInt64, UInt64}).new(@shapes.size, {0_u64, 0_u64})
      loop do
        @stats.rounds += 1
        @shapes.each_with_index do |shape, index|
          first = shape.base_first
          second = shape.base_second
          callee_shapes[index].each do |callee|
            first = OwnerShapeSharing.mix_first(first, callee.first)
            second = OwnerShapeSharing.mix_second(second, callee.second)
          end
          next_values[index] = {first, second}
        end
        @shapes.each_with_index do |shape, index|
          shape.first, shape.second = next_values[index]
        end
        refined = count_groups
        break if refined == groups
        groups = refined
      end

      first_of_group = Hash({UInt64, UInt64}, Def).new
      @shapes.each do |shape|
        @stats.typed_defs += 1
        @stats.unshareable += 1 unless shape.shareable?
        @stats.pinned += 1 if shape.pinned?
        next unless shape.shareable?
        key = {shape.first, shape.second}
        if representative = first_of_group[key]?
          @representatives[shape.typed_def.object_id] = representative
          @stats.shared += 1
        else
          first_of_group[key] = shape.typed_def
        end
      end
      @stats.groups = groups
    end

    private def count_groups : Int32
      seen = Set({UInt64, UInt64}).new
      @shapes.each { |shape| seen << {shape.first, shape.second} }
      seen.size
    end

    def self.mix_first(hash : UInt64, value : UInt64) : UInt64
      hash = (hash ^ value) &* 0x9e3779b97f4a7c15_u64
      hash ^ (hash >> 32)
    end

    def self.mix_second(hash : UInt64, value : UInt64) : UInt64
      hash = (hash &+ value &+ 0x632be59bd9b4e019_u64) &* 0xd6e8feb86659fd93_u64
      hash ^ (hash >> 29)
    end

    # What the walk needs to know about a type, computed once per type.
    class TypeFacts
      MENTIONS   = 1_u8
      MIXED_SLOT = 2_u8

      @flags = Hash(UInt64, UInt8).new
      @interchangeable = Hash(UInt64, Bool).new
      @layouts = Hash(UInt64, UInt64).new
      @receives = Hash({UInt64, UInt64}, Bool).new

      # Measurement switch: treat casts at different source lines as equal,
      # so a shared function reports the line of its representative when a
      # cast fails.
      getter? ignore_cast_location : Bool = ENV["CRYSTAL_OWNER_SHAPES_IGNORE_CAST_LOCATION"]? == "1"

      # A class whose values are interchangeable pointers (see the class doc).
      def interchangeable?(type : Type) : Bool
        cached = @interchangeable[type.object_id]?
        return cached unless cached.nil?
        result = type.is_a?(NonGenericClassType) && type.class? && !type.struct? && !type.abstract? &&
                 !type.extern? && type.subclasses.empty? && !type.same?(type.program.string)
        @interchangeable[type.object_id] = result
      end

      # A generic reference class instance (`Array(T)`, not a pointer, tuple,
      # proc or struct).
      def generic_reference?(type : Type) : Bool
        type.class == GenericClassInstanceType && type.class? && !type.struct?
      end

      def flags(type : Type) : UInt8
        if cached = @flags[type.object_id]?
          return cached
        end
        # A type that reaches itself (a recursive alias) mentions nothing new.
        @flags[type.object_id] = 0_u8
        value = 0_u8
        value |= MENTIONS if compute_mentions(type)
        value |= MIXED_SLOT if type.remove_indirection.is_a?(MixedUnionType)
        @flags[type.object_id] = value
      end

      def mentions?(type : Type) : Bool
        flags(type) & MENTIONS != 0
      end

      private def compute_mentions(type : Type) : Bool
        case type
        when NonGenericClassType
          interchangeable?(type)
        when UnionType
          type.union_types.any? { |member| mentions?(member) }
        when TupleInstanceType
          type.tuple_types.any? { |member| mentions?(member) }
        when NamedTupleInstanceType
          type.entries.any? { |entry| mentions?(entry.type) }
        when ProcInstanceType
          type.arg_types.any? { |member| mentions?(member) } || mentions?(type.return_type)
        when GenericInstanceType
          type.type_vars.each_value.any? do |type_var|
            type_var.is_a?(Var) && (var_type = type_var.type?) ? mentions?(var_type) : false
          end
        when MetaclassType
          mentions?(type.instance_type)
        when GenericClassInstanceMetaclassType, GenericModuleInstanceMetaclassType, VirtualMetaclassType
          mentions?(type.instance_type)
        when VirtualType
          mentions?(type.base_type)
        when TypeDefType
          mentions?(type.typedef)
        when AliasType
          (aliased = type.aliased_type?) ? mentions?(aliased) : false
        else
          false
        end
      end

      # Hash of what codegen reads from the layout of a class: the name of
      # each instance variable, in order, and how its value is stored.
      def layout(type : Type) : UInt64
        if cached = @layouts[type.object_id]?
          return cached
        end
        hash = 0x243f6a8885a308d3_u64
        type.all_instance_vars.each do |name, ivar|
          hash = OwnerShapeSharing.mix_first(hash, name.hash)
          hash = OwnerShapeSharing.mix_first(hash, storage((ivar.type? || type.program.nil_type)))
        end
        @layouts[type.object_id] = hash
      end

      # How a value of *type* is stored inside an object: equal results mean
      # equal size, alignment and position of what follows it.
      private def storage(type : Type) : UInt64
        return type.object_id unless mentions?(type)
        case type
        when PointerInstanceType
          4_u64
        when ProcInstanceType, NilableProcType
          5_u64
        when TupleInstanceType
          type.tuple_types.reduce(6_u64) { |hash, member| OwnerShapeSharing.mix_first(hash, storage(member)) }
        when NamedTupleInstanceType
          type.entries.reduce(7_u64) { |hash, entry| OwnerShapeSharing.mix_first(hash, storage(entry.type)) }
        when MixedUnionType
          # A union is as large as its largest member.
          members = type.union_types.map { |member| storage(member) }.sort!
          members.reduce(9_u64) { |hash, member| OwnerShapeSharing.mix_first(hash, member) }
        when GenericClassInstanceType
          if type.struct?
            OwnerShapeSharing.mix_first(8_u64, layout(type))
          else
            1_u64
          end
        when MetaclassType, GenericClassInstanceMetaclassType, GenericModuleInstanceMetaclassType, VirtualMetaclassType
          # A metaclass value is a type id.
          10_u64
        else
          type.reference_like? ? 1_u64 : type.object_id
        end
      end

      # Whether a value of the class *source* can be stored in a slot of the
      # mixed union *slot*; storing it writes the type id of *source*.
      def receives?(slot : Type, source : Type) : Bool
        key = {slot.object_id, source.object_id}
        cached = @receives[key]?
        return cached unless cached.nil?
        target = slot.remove_indirection
        result =
          if target.is_a?(UnionType)
            target.union_types.any? { |member| source.implements?(member) || source.implements?(member.devirtualize) }
          else
            true
          end
        @receives[key] = result
      end
    end

    # Hashes one typed def and lists the defs it calls.
    class ShapeWalker < Visitor
      # Primitives whose code depends only on how their operands are stored.
      STORAGE_PRIMITIVES = Set{"pointer_malloc", "pointer_set", "pointer_get", "pointer_address", "pointer_new",
                               "pointer_realloc", "pointer_add", "pointer_diff", "object_id"}

      LEAVE         = 0x1f83d9abfb41bd6b_u64
      TOKEN_CLASS   = 0x452821e638d01377_u64
      TOKEN_NILABLE = 0xbe5466cf34e90c6c_u64
      TOKEN_POINTER = 0xc0ac29b7c97c50dd_u64
      TOKEN_GENERIC = 0x3f84d5b5b5470917_u64
      TOKEN_VIRTUAL = 0xa4093822299f31d0_u64
      TOKEN_NAME    = 0x082efa98ec4e6c89_u64
      TOKEN_META    = 0x9216d5d98979fb1b_u64
      TOKEN_EDGE    = 0xd1310ba698dfb5ac_u64
      TOKEN_CONST   = 0x2ffd72dbd01adfb7_u64

      getter discovered = [] of Def

      @first = 0_u64
      @second = 0_u64
      @numbered = [] of Type
      @mixed_slots = [] of Type
      @sources = [] of Type
      @made_up_names = [] of String
      @shape : Shape
      @owner : Type?
      @owner_instance : Type?
      @def_filename : String | VirtualFile | Nil
      @place = "signature"

      def initialize(@program : Program, @types : TypeFacts, @super_targets : Set(UInt64))
        @shape = Shape.new(Def.new("unused"))
      end

      def walk(shape : Shape) : Nil
        @shape = shape
        @first = 0xcbf29ce484222325_u64
        @second = 0x84222325cbf29ce4_u64
        @numbered.clear
        @mixed_slots.clear
        @sources.clear
        @made_up_names.clear
        @discovered.clear

        typed_def = shape.typed_def
        @owner = owner = typed_def.owner?
        @owner_instance = owner.try { |type| type.metaclass? ? type.instance_type : type }
        @def_filename = typed_def.location.try(&.filename)
        @place = "signature"

        if typed_def.is_a?(External) || typed_def.body.is_a?(Primitive) || typed_def.body.is_a?(ReleasedBody)
          block("external, primitive or released def")
        else
          mix_def(typed_def)
        end

        if shape.shareable? && !shape.pinned?
          @mixed_slots.each do |slot|
            if @sources.any? { |source| @types.receives?(slot, source) }
              pin("a mixed union slot can receive an interchangeable class")
              break
            end
          end
        end
        if shape.pinned?
          @numbered.each { |type| mix(type.object_id) }
        end
        shape.base_first = @first
        shape.base_second = @second
      end

      # When set, every mixed value is recorded with the place it came from
      # (census diagnostics only).
      property trace : Array({UInt64, String})?

      private def mix(value : UInt64) : Nil
        @trace.try &.<<({value, @place})
        @first = OwnerShapeSharing.mix_first(@first, value)
        @second = OwnerShapeSharing.mix_second(@second, value)
      end

      private def mix(value : Int) : Nil
        mix(value.to_u64!)
      end

      private def mix(value : Bool) : Nil
        mix(value ? 1_u64 : 2_u64)
      end

      private def mix(value : String) : Nil
        mix(value.hash)
      end

      # Mixes the name of a local variable. Names the compiler makes up
      # (`__temp_1`, `__arg0`) are counted in order of appearance: their
      # number comes from a program-wide counter and does not reach the code.
      private def mix_local_name(name : String?) : Nil
        if name && (name.starts_with?("__temp_") || name.starts_with?("__arg"))
          index = @made_up_names.index(name)
          unless index
            index = @made_up_names.size
            @made_up_names << name
          end
          mix(TOKEN_NAME)
          mix(index)
        else
          mix(name)
        end
      end

      private def mix(value : Nil) : Nil
        mix(3_u64)
      end

      # The def can not be shared at all.
      private def block(reason : String) : Nil
        return unless @shape.shareable?
        @shape.shareable = false
        @shape.blocker = reason
      end

      # The def is only shared with defs that name the same classes.
      private def pin(reason : String) : Nil
        return if @shape.pinned?
        @shape.pinned = true
        @shape.blocker ||= reason
      end

      private def pin_if_mentions(type : Type?, reason : String) : Nil
        pin(reason) if type && @types.mentions?(type)
      end

      # Mixes *type* as the type of a value. *metaclass_as_name* is set where
      # codegen names a non-generic metaclass without reading its value (the
      # receiver of a class method, the owner of a def).
      private def mix_type(type : Type?, metaclass_as_name = false) : Nil
        unless type
          mix(0_u64)
          return
        end
        @place = "#{@place.partition(" :: ")[0]} :: #{type}" if @trace
        flags = @types.flags(type)
        if flags & TypeFacts::MIXED_SLOT != 0 && !@mixed_slots.any?(&.same?(type))
          @mixed_slots << type
        end
        if flags & TypeFacts::MENTIONS == 0
          mix(type.object_id)
        else
          mix_mentioning(type, metaclass_as_name)
        end
      end

      private def mix_mentioning(type : Type, metaclass_as_name : Bool) : Nil
        note_owner_inside(type)
        if @types.interchangeable?(type)
          index = @numbered.index(&.same?(type))
          unless index
            index = @numbered.size
            @numbered << type
          end
          mix(TOKEN_CLASS)
          mix(index)
          mix(@types.layout(type))
          note_source(type)
        elsif type.is_a?(NilableType)
          mix(TOKEN_NILABLE)
          mix_component(type.not_nil_type)
        elsif type.is_a?(PointerInstanceType)
          mix(TOKEN_POINTER)
          mix_component(type.element_type)
        elsif @types.generic_reference?(type)
          instance = type.as(GenericClassInstanceType)
          mix(TOKEN_GENERIC)
          mix(instance.generic_type.object_id)
          instance.type_vars.each_value do |type_var|
            if type_var.is_a?(Var)
              mix_component(type_var.type?)
            else
              mix(type_var.to_s)
            end
          end
          mix(@types.layout(type))
          note_source(type)
        elsif type.is_a?(VirtualType) && @types.generic_reference?(type.base_type)
          # A pointer whose type id is read from the object.
          mix(TOKEN_VIRTUAL)
          mix_mentioning(type.base_type, false)
        elsif metaclass_as_name && type.is_a?(MetaclassType) && @types.interchangeable?(type.instance_type)
          mix(TOKEN_META)
          mix_mentioning(type.instance_type, false)
        else
          pin("a value of #{type_kind(type)} that names an interchangeable class (#{@place})")
          mix(type.object_id)
        end
      end

      private def mix_component(type : Type?) : Nil
        if type && @types.mentions?(type)
          mix_mentioning(type, false)
        else
          mix(type.try(&.object_id) || 0_u64)
        end
      end

      private def note_source(type : Type) : Nil
        @sources << type unless @sources.any?(&.same?(type))
      end

      private def note_owner_inside(type : Type) : Nil
        owner_instance = @owner_instance
        return unless owner_instance
        return if type.same?(owner_instance) || type.same?(@owner)
        @shape.owner_use |= OwnerUse::InsideOtherTypes
      end

      private def type_kind(type : Type) : String
        case type
        when MetaclassType, GenericClassInstanceMetaclassType, VirtualMetaclassType then "a metaclass"
        when MixedUnionType                                                         then "a mixed union"
        when UnionType                                                              then "a reference union"
        when TupleInstanceType, NamedTupleInstanceType                              then "a tuple"
        when ProcInstanceType                                                       then "a proc"
        when GenericInstanceType                                                    then "a generic struct or module"
        else                                                                             "another type"
        end
      end

      private def enter(node : ASTNode) : Nil
        @place = node.class.name.lchop("Crystal::")
        @shape.node_count += 1
        mix(node.crystal_type_id)
        mix(node.@flags)
        mix_type(node.type?)
        note_macro_expansion(node)
      end

      private def note_macro_expansion(node : ASTNode) : Nil
        return if @shape.owner_use.macro_expansion?
        filename = node.location.try(&.filename)
        if filename.is_a?(VirtualFile) && !filename.same?(@def_filename)
          @shape.owner_use |= OwnerUse::MacroExpansion
        end
      end

      def end_visit(node : ASTNode) : Nil
        mix(LEAVE)
      end

      private def mix_def(node : Def) : Nil
        @place = "signature"
        mix(node.name)
        mix_type(node.owner?, metaclass_as_name: true)
        mix(node.args.size)
        node.args.each do |arg|
          mix_local_name(arg.name)
          mix_type(arg.type?)
        end
        mix(node.splat_index || -1)
        if block_arg = node.block_arg
          mix_local_name(block_arg.name)
          mix_type(block_arg.type?)
        end
        mix(node.block_arity || -1)
        mix_type(node.type?)
        mix(node.@flags)
        mix(node.uses_block_arg?)
        mix(node.raises?)
        mix(node.closure?)
        mix(node.self_closured?)
        mix(node.captured_block?)
        mix(node.no_inline?)
        mix(node.always_inline?)
        mix(node.returns_twice?)
        mix(node.naked?)
        mix(node.target_features)
        mix(node.target_cpu)
        node.special_vars.try &.each { |name| mix(name) }
        mix_vars(node.vars, node)
        node.body.accept(self)
      end

      # *holder* is the def or block that lists the vars. Codegen allocates a
      # var where its context is, and resets it to nil when it is bound to the
      # program's nil var.
      private def mix_vars(vars : MetaVars?, holder : ASTNode) : Nil
        return unless vars
        @place = "local var"
        nil_var = @program.nil_var
        vars.each_value do |meta_var|
          mix_local_name(meta_var.name)
          mix(meta_var.@flags)
          # `self` is not a local: a class method never stores its metaclass,
          # unless a closure captures it.
          self_name = meta_var.name == "self" && holder.is_a?(Def) && !holder.self_closured?
          mix_type(meta_var.type?, metaclass_as_name: self_name)
          context = meta_var.context
          mix(context.same?(holder) ? 1_u64 : (context.is_a?(ASTNode) ? context.crystal_type_id.to_u64 : 2_u64))
          mix(meta_var.dependencies.any?(&.same?(nil_var)))
        end
      end

      def visit(node : Nop | NilLiteral | Unreachable | Expressions | If | While | Not | Return | Break | Next | Yield | TupleLiteral | ExceptionHandler | UninitializedVar | Underscore) : Bool
        enter(node)
        true
      end

      # Codegen skips an assignment or declaration marked as discarded.
      def visit(node : Assign | TypeDeclaration) : Bool
        enter(node)
        mix(node.discarded?)
        true
      end

      def visit(node : PointerOf) : Bool
        enter(node)
        # The pointer of a lib variable is found through the call's bindings.
        block("pointerof a lib variable") if node.exp.is_a?(Call)
        true
      end

      def visit(node : BoolLiteral) : Bool
        enter(node)
        mix(node.value)
        false
      end

      def visit(node : NumberLiteral) : Bool
        enter(node)
        mix(node.value)
        mix(node.kind.value)
        false
      end

      def visit(node : CharLiteral) : Bool
        enter(node)
        mix(node.value.ord)
        false
      end

      def visit(node : StringLiteral | SymbolLiteral) : Bool
        enter(node)
        mix(node.value)
        false
      end

      def visit(node : Var) : Bool
        enter(node)
        mix_local_name(node.name)
        @shape.owner_use |= OwnerUse::SelfPassed if node.name == "self"
        false
      end

      def visit(node : Global) : Bool
        enter(node)
        mix(node.name)
        false
      end

      def visit(node : InstanceVar) : Bool
        enter(node)
        mix(node.name)
        @shape.owner_use |= OwnerUse::InstanceVar
        false
      end

      def visit(node : ReadInstanceVar) : Bool
        enter(node)
        mix(node.name)
        true
      end

      def visit(node : ClassVar) : Bool
        enter(node)
        mix(node.name)
        mix(node.var.object_id)
        @shape.owner_use |= OwnerUse::ClassSide if node.var.owner.same?(@owner_instance) || node.var.owner.same?(@owner)
        false
      end

      def visit(node : NamedTupleLiteral) : Bool
        enter(node)
        node.entries.each { |entry| mix(entry.key) }
        true
      end

      def visit(node : Rescue) : Bool
        enter(node)
        mix_local_name(node.name)
        true
      end

      # A type named as a value is its type id.
      def visit(node : Path) : Bool
        enter(node)
        if target_const = node.target_const
          mix(target_const.object_id)
          @shape.owner_use |= OwnerUse::ClassSide if target_const.namespace.same?(@owner_instance)
        end
        false
      end

      def visit(node : Generic | Metaclass | ProcNotation | Union | Self) : Bool
        enter(node)
        false
      end

      # Nodes whose code reads the identity of the types involved.
      def visit(node : TypeOf | SizeOf | InstanceSizeOf | AlignOf | InstanceAlignOf | OffsetOf) : Bool
        enter(node)
        @shape.owner_use |= OwnerUse::TypeOf if node.is_a?(TypeOf) && node.type?.try { |type| @types.mentions?(type) }
        collector = CensusChildCollector.new
        node.accept_children(collector)
        collector.children.each { |child| mix_identity(child.type?, "sizeof, typeof or offsetof of an interchangeable class") }
        mix_identity(node.type?, "sizeof, typeof or offsetof of an interchangeable class")
        false
      end

      def visit(node : IsA) : Bool
        enter(node)
        mix(node.nil_check?)
        mix_identity(node.obj.type?, "is_a? on an interchangeable class")
        mix_identity(node.const.type?, "is_a? on an interchangeable class")
        node.obj.accept(self)
        false
      end

      def visit(node : RespondsTo) : Bool
        enter(node)
        mix(node.name)
        mix_identity(node.obj.type?, "responds_to? on an interchangeable class")
        node.obj.accept(self)
        false
      end

      def visit(node : Cast | NilableCast) : Bool
        enter(node)
        mix_identity(node.obj.type?, "a cast of an interchangeable class")
        mix_identity(node.to.type?, "a cast of an interchangeable class")
        mix_identity(node.type?, "a cast of an interchangeable class")
        if node.is_a?(Cast)
          mix(node.upcast?)
          # A cast that can fail raises with its own location in the message.
          mix_location(node.location) unless node.upcast? || @types.ignore_cast_location?
        end
        node.obj.accept(self)
        false
      end

      private def mix_identity(type : Type?, reason : String) : Nil
        mix(type.try(&.object_id) || 0_u64)
        pin_if_mentions(type, reason)
      end

      private def mix_location(location : Location?) : Nil
        if location
          mix(location.line_number)
          mix(location.expanded_location.to_s)
        else
          mix(0_u64)
        end
      end

      def visit(node : ProcLiteral) : Bool
        enter(node)
        mix(node.force_nil?)
        mix_def(node.def)
        false
      end

      def visit(node : Block) : Bool
        enter(node)
        mix(node.splat_index || -1)
        mix_type(node.break.type?)
        mix_vars(node.vars, node)
        if fun_literal = node.fun_literal
          fun_literal.accept(self)
        end
        true
      end

      def visit(node : Call) : Bool
        enter(node)
        mix(node.name)
        mix(node.global?)

        # Codegen raises on a call that still has an expansion, so a typed
        # def that codegen reaches never runs this one: it is dead code.
        return false if node.expanded
        if node.uses_with_scope?
          block("a call that uses with scope")
          return false
        end

        if obj = node.obj
          if constant_metaclass?(obj)
            mix(TOKEN_CONST)
            mix_type(obj.type?, metaclass_as_name: true)
            @shape.owner_use |= obj.is_a?(Call) ? OwnerUse::SelfClass : OwnerUse::ClassSide
          else
            obj.accept(self)
          end
        end
        mix(node.args.size)
        node.args.each &.accept(self)
        node.named_args.try &.each do |named_arg|
          mix(named_arg.name)
          named_arg.value.accept(self)
        end
        node.block_arg.try &.accept(self)
        node.block.try &.accept(self)

        target_defs = node.target_defs
        if target_defs.nil? || target_defs.empty?
          mix(0_u64)
        elsif target_defs.size == 1
          mix_single_target(node, target_defs.first)
        else
          mix_dispatch(node, target_defs)
        end
        false
      end

      # A receiver that is a non-generic metaclass known at compile time: a
      # type name, `self` inside a class method, or `self.class` on an exact
      # class. Codegen does not pass it to the method, so its value is unused.
      private def constant_metaclass?(obj : ASTNode) : Bool
        type = obj.type?
        return false unless type.is_a?(MetaclassType) && @types.interchangeable?(type.instance_type)
        case obj
        when Path
          obj.target_const.nil?
        when Var
          obj.name == "self"
        when Call
          return false unless obj.name == "class" && obj.args.empty? && !obj.block && !obj.named_args
          receiver = obj.obj
          return false unless receiver.nil? || (receiver.is_a?(Var) && receiver.name == "self")
          targets = obj.target_defs
          return false unless targets && targets.size == 1
          body = targets.first.body
          body.is_a?(Primitive) && body.name == "class" && targets.first.owner.same?(type.instance_type)
        else
          false
        end
      end

      private def mix_single_target(node : Call, target_def : Def) : Nil
        @discovered << target_def
        note_owner_call(node, target_def)
        if node.super?
          # Codegen names a super call's function after the caller's class.
          @super_targets << target_def.object_id
          mix(target_def.object_id)
          return
        end

        @place = "callee signature"
        mix_type(target_def.owner?, metaclass_as_name: true)
        target_def.args.each { |arg| mix_type(arg.type?) }
        mix_type(target_def.type?)
        if node.args.size < target_def.args.size
          # Magic constant arguments take their value from the call's location.
          mix_location(node.location)
          mix_location(node.end_location)
        end

        body = target_def.body
        if target_def.is_a?(External)
          mix(target_def.object_id)
        elsif body.is_a?(Primitive)
          if STORAGE_PRIMITIVES.includes?(body.name)
            mix(body.name)
          else
            mix(target_def.object_id)
            pin_if_mentions(target_def.owner?, "the primitive #{body.name} on an interchangeable class")
            target_def.args.each { |arg| pin_if_mentions(arg.type?, "the primitive #{body.name} on an interchangeable class") }
            pin_if_mentions(node.type?, "the primitive #{body.name} on an interchangeable class")
          end
        elsif (block = node.block) && mixed_block?(block)
          # The def is inlined and its yields convert to the block's types.
          mix(target_def.object_id)
        else
          mix(TOKEN_EDGE)
          @shape.callees << target_def
        end
      end

      private def mixed_block?(block : Block) : Bool
        return true if block.args.any? { |arg| slot_or_unknown?(arg.type?) }
        slot_or_unknown?(block.type?) || slot_or_unknown?(block.break.type?)
      end

      private def slot_or_unknown?(type : Type?) : Bool
        return false unless type
        @types.flags(type) & TypeFacts::MIXED_SLOT != 0
      end

      private def mix_dispatch(node : Call, target_defs : Array(Def)) : Nil
        reason = "a dispatch over interchangeable classes"
        if obj = node.obj
          pin_if_mentions(obj.type?, reason)
        else
          pin_if_mentions(@owner, reason)
        end
        node.args.each { |arg| pin_if_mentions(arg.type?, reason) }
        mix(target_defs.size)
        target_defs.each do |target_def|
          @discovered << target_def
          @super_targets << target_def.object_id if node.super?
          mix(target_def.object_id)
        end
      end

      private def note_owner_call(node : Call, target_def : Def) : Nil
        owner_instance = @owner_instance
        return unless owner_instance
        target_owner = target_def.owner?
        return unless target_owner
        if !node.obj && target_owner.same?(@owner)
          @shape.owner_use |= OwnerUse::SelfPassed
        elsif target_owner.metaclass? && target_owner.instance_type.same?(owner_instance) && !@owner.same?(target_owner)
          @shape.owner_use |= OwnerUse::ClassSide
        end
      end

      # Cleanup replaces every expandable node codegen can reach, and codegen
      # raises on one that is left. What remains sits in code that was never
      # typed, so only its place in the tree matters.
      def visit(node : ExpandableNode) : Bool
        mix(node.crystal_type_id)
        false
      end

      # Any node class the whitelist does not name.
      def visit(node : ASTNode) : Bool
        block("node #{node.class.name.lchop("Crystal::")}")
        false
      end
    end
  end

  class Program
    # Whether codegen emits one function for typed defs that differ only in
    # interchangeable classes (see `OwnerShapeSharing`).
    # `CRYSTAL_SHARE_OWNER_SHAPES=0` turns it off.
    property? share_owner_shapes : Bool = OwnerShapeSharing.enabled?
  end
end
