require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Crystal
  # Leaves out of a dispatch the branches for types the program never
  # creates.
  #
  # A call on a general type (`IO`, a module, a union) dispatches over every
  # type that could answer it, and each branch makes code generation emit
  # that type's method and everything the method calls. A type that no code
  # of the program ever creates can never be the receiver, so its branch is
  # dead, and so is every function reached only through it: a plain HTTP
  # server links `SSL_*` and `BIO_*` because `IO` has an OpenSSL socket
  # subclass.
  #
  # `Analysis` finds the types the program can create with a rapid type
  # analysis over the typed program: starting from the main program and
  # every `fun` with a body, it walks the bodies of the defs that code
  # generation can reach. A dispatch branch is followed only once each of
  # its positions (receiver, and each argument the dispatch tests) can hold
  # a created type; when a type is created later in the walk, the branches
  # waiting on it are followed then, until nothing changes.
  #
  # Only class instances (reference types other than `String`) are ever
  # left out. Every other type (structs, primitives, pointers, procs,
  # tuples, metaclasses, lib types) counts as created, so a dispatch on
  # `Class` values (`klass.new` on a union or virtual metaclass) keeps all
  # its branches, and with them every `allocate` they reach.
  #
  # A reference type counts as created when the walk reaches:
  # - its `allocate` (`new` calls it, also through macros) or
  #   `pre_initialize`;
  # - a value typed exactly as it that is made out of memory: a cast from a
  #   pointer to it (`ptr.as(T)`) or to a pointer to it (`x.as(T*)`, which
  #   `unsafe_as` uses), `Pointer(T).new(address)`, `va_arg`, `uninitialized`,
  #   zeroed memory from `Pointer(T).malloc`, or a zeroed instance variable
  #   of an allocated object (see `#conjure` for why exact types are enough).
  #
  # Code generation then asks `#prunes?` for each branch of a dispatch, with
  # the same rule over the final set. The analysis is an
  # over-approximation of what runs: the defs it walks include every def
  # code generation emits, since it follows every single-target call and
  # every dispatch branch code generation keeps.
  #
  # When the walk reaches a body it cannot read (a typed body released
  # after its function was generated), the analysis gives up and every type
  # counts as created.
  module DispatchPrune
    # How pruning applies to this program: `Off`, `On` (leave the branches
    # out), or `Check` (keep them, and make each one stop the program with
    # an "unreachable type" error, so running the specs proves that no left
    # out branch is ever taken).
    enum Mode
      Off
      On
      Check
    end

    # The mode from the program's flags: `-Dprune_dispatch` turns pruning
    # on, `-Dprune_dispatch_check` turns on check mode, and
    # `-Dno_prune_dispatch` turns it off.
    def self.mode_for(program : Program) : Mode
      return Mode::Off if program.has_flag?("no_prune_dispatch")
      return Mode::Check if program.has_flag?("prune_dispatch_check")
      return Mode::On if program.has_flag?("prune_dispatch")

      Mode::Off
    end

    # `CRYSTAL_PRUNE_DISPATCH_STATS=1` prints what the analysis found, and
    # what code generation left out, to standard error.
    class_getter?(print_stats : Bool) { ENV["CRYSTAL_PRUNE_DISPATCH_STATS"]?.presence == "1" }

    # What the analysis found, for the stats and the measurements.
    class Stats
      property seconds = 0.0
      property reached_defs = 0
      property dispatch_calls = 0
      property dispatch_targets = 0
      property pruned_targets = 0
      property dead_calls = 0
      property prunable_types = 0
      property created_types = 0
      property rounds = 0
      property gave_up_cause : String? = nil
    end

    class Analysis < Visitor
      getter stats = Stats.new
      getter mode : Mode

      # Types that count as created (keyed by object id).
      @created = Set(UInt64).new
      # Types whose liveness was settled as created, for `#live?` (positive
      # answers only: a type never stops being created).
      @live_cache = Set(UInt64).new
      @reached_defs = Set(UInt64).new
      @walked_consts = Set(UInt64).new
      @walked_class_var_initializers = Set(UInt64).new
      @conjured = Set(UInt64).new
      # Types whose instance variable initializers were walked.
      @allocated_types = Set(UInt64).new
      @concrete_types_by_type_id = {} of UInt64 => Array(Type)
      @list_of_pending_defs = [] of Def
      # Dispatch branches not followed yet: the call and its target def.
      @list_of_waiting_branches = [] of {Call, Def}
      @current_def : Def? = nil
      @gave_up = false

      def initialize(@program : Program, @mode : Mode)
      end

      # Runs the analysis over *node*, the typed main program.
      def run(node : ASTNode) : self
        started_at = Time.instant
        mark_created(@program.string)
        # Code generation itself types and runs `raise "..."` (a closure
        # passed to C) and, with an old prelude, `raise TypeCastError.new`.
        mark_created(@program.exception)
        @program.types["TypeCastError"]?.try { |type| mark_created(type) }
        node.accept self
        # Code generation runs the `macro finished` expansions after the
        # main program.
        @program.process_finished_hooks(self)
        loop do
          @stats.rounds += 1
          drain_pending_defs
          break if @gave_up

          list_of_waiting = @list_of_waiting_branches
          @list_of_waiting_branches = [] of {Call, Def}
          followed_any = false
          list_of_waiting.each do |(call, a_def)|
            if waiting_live?(call, a_def)
              reach(a_def)
              followed_any = true
            else
              @list_of_waiting_branches << {call, a_def}
            end
          end
          break unless followed_any
        end
        unless @gave_up
          @list_of_waiting_branches.each do |(call, _a_def)|
            count = 0
            call.each_target_def { count += 1 }
            if count > 1
              @stats.pruned_targets += 1
            else
              @stats.dead_calls += 1
            end
          end
        end
        @stats.reached_defs = @reached_defs.size
        @stats.created_types = @created.size
        @stats.seconds = (Time.instant - started_at).total_seconds
        @list_of_waiting_branches = [] of {Call, Def}
        @list_of_pending_defs = [] of Def
        self
      end

      # Whether code generation leaves the branch of *call* that goes to
      # *a_def* out: no value of a created type can select it.
      # Whether code generation replaces *call*, a call with a single target
      # def, by an "unreachable type" stop: its receiver is a class nothing
      # creates, so no execution gets to it.
      def prunes_call?(call : Call) : Bool
        return false if @gave_up || @mode.off?

        !single_target_live?(call, call.target_def)
      end

      # A call with a single target def runs only with a receiver of the
      # def's owner. A value whose static type is an exact class has that
      # class at run time, and one whose static type is virtual has one of
      # its subclasses, so a call on a class nothing creates never runs:
      # `if io.is_a?(OpenSSL::SSL::Socket::Server)` guards such calls in a
      # plain HTTP server. Other owners (the program, modules, metaclasses,
      # structs) and `super` always count as live.
      private def single_target_live?(call : Call, a_def : Def) : Bool
        return true if call.super?
        owner = a_def.owner?
        return true unless owner
        return true unless owner.is_a?(VirtualType) || prunable?(owner)

        live?(owner)
      end

      private def waiting_live?(call : Call, a_def : Def) : Bool
        count = 0
        call.each_target_def { count += 1 }
        count > 1 ? branch_live?(call, a_def) : single_target_live?(call, a_def)
      end

      def prunes?(call : Call, a_def : Def) : Bool
        return false if @gave_up || @mode.off?

        !branch_live?(call, a_def)
      end

      # Whether the analysis gave up (see `Stats#gave_up_cause`).
      def gave_up? : Bool
        @gave_up
      end

      # The created class types, by name, sorted: two builds that create the
      # same types prune the same branches (see `IrSkip`).
      def signature : String
        return "all" if @gave_up

        list_of_names = [] of String
        each_class_type(@program) do |type|
          list_of_names << type.to_s if prunable?(type) && live?(type)
        end
        list_of_names.sort!
        IrSkip::Hasher.digest_of(list_of_names.join('\n')).to_s
      end

      def print_stats : Nil
        stats = @stats
        STDERR.printf("prune dispatch (%s): %d defs reached, %d dispatch calls with %d targets, %d targets left out, %d calls on classes never created, %d of %d class types created, %d rounds, %.2f s%s\n",
          @mode.to_s.downcase, stats.reached_defs, stats.dispatch_calls, stats.dispatch_targets, stats.pruned_targets, stats.dead_calls,
          stats.created_types, stats.prunable_types, stats.rounds, stats.seconds,
          (cause = stats.gave_up_cause) ? ", gave up: #{cause}" : "")
      end

      # Counts the types that could be left out, for the stats.
      def count_prunable_types : Nil
        count = 0
        each_class_type(@program) { |type| count += 1 if prunable?(type) }
        @stats.prunable_types = count
      end

      private def each_class_type(type : Type, &block : Type ->) : Nil
        type.types?.try &.each_value do |nested|
          yield nested
          if nested.is_a?(GenericType)
            nested.each_instantiated_type { |instance| yield instance }
          end
          each_class_type(nested, &block)
        end
      end

      # A branch is live when every position it tests (the receiver, unless
      # the call is a `super`, and each argument that is not autocast) can
      # hold a created type.
      private def branch_live?(call : Call, a_def : Def) : Bool
        unless call.super?
          return false unless live?(a_def.owner)
        end
        call.args.each_with_index do |arg, index|
          next if arg.supports_autocast?(!@program.has_flag?("no_number_autocast"))
          def_arg = a_def.args[index]?
          next unless def_arg
          arg_type = def_arg.type?
          next unless arg_type
          return false unless live?(arg_type)
        end
        true
      end

      # Whether some concrete type of *type* is created (or is a type that
      # is never left out).
      def live?(type : Type) : Bool
        return true if @live_cache.includes?(type.object_id)

        list_of_concrete_types = concrete_types_of(type)
        # A type with no concrete types (the program, a module nothing
        # includes) is not something this analysis reasons about.
        result = list_of_concrete_types.empty? || list_of_concrete_types.any? do |concrete|
          !prunable?(concrete) || @created.includes?(concrete.object_id)
        end
        @live_cache << type.object_id if result
        result
      end

      # Only instances of reference classes are ever left out.
      def prunable?(type : Type) : Bool
        return false unless type.is_a?(NonGenericClassType) || type.is_a?(GenericClassInstanceType)
        return false if type.is_a?(PrimitiveType)
        return false if type.struct? || type.abstract?
        return false if type == @program.string

        true
      end

      # The types a value of *type* can have at run time, computed once per
      # type.
      private def concrete_types_of(type : Type) : Array(Type)
        @concrete_types_by_type_id[type.object_id] ||= begin
          list_of_types = [] of Type
          collect_concrete_types(type, list_of_types, 0)
          list_of_types
        end
      end

      private def collect_concrete_types(type : Type, list_of_types : Array(Type), depth : Int32) : Nil
        if depth > 16
          # A type nested this deep is not split: it stands for itself.
          list_of_types << type
          return
        end

        case type
        when UnionType
          type.union_types.each { |union_type| collect_concrete_types(union_type, list_of_types, depth + 1) }
        when VirtualType
          type.each_concrete_type { |concrete| list_of_types << concrete }
        when NonGenericModuleType, GenericModuleInstanceType
          if including = type.including_types
            collect_concrete_types(including, list_of_types, depth + 1)
          end
        when TypeDefType, AliasType
          collect_concrete_types(type.remove_indirection, list_of_types, depth + 1)
        else
          list_of_types << type
        end
      end

      private def mark_created(type : Type) : Nil
        type = type.base_type if type.is_a?(VirtualType)
        return unless prunable?(type)
        return if @created.includes?(type.object_id)
        return if forgotten?(type)

        @created << type.object_id
        explain_creation(type)
      end

      # `CRYSTAL_PRUNE_DISPATCH_FORGET=Name` makes the analysis miss that the
      # class *Name* is created, so the specs can prove that the
      # "unreachable type" fallback and check mode stop the program. Never
      # use it for a real build.
      @forgotten_type_name : String? = ENV["CRYSTAL_PRUNE_DISPATCH_FORGET"]?.presence

      # `CRYSTAL_PRUNE_DISPATCH_EXPLAIN=Name` prints where the analysis found
      # that the class *Name* is created, for finding out why a type stays.
      @explained_type_name : String? = ENV["CRYSTAL_PRUNE_DISPATCH_EXPLAIN"]?.presence
      # The node the walk is at when it marks a type as created.
      @origin : ASTNode? = nil
      # The def that first reached each def, kept only while explaining.
      @reached_from = {} of UInt64 => Def?

      private def explain_creation(type : Type) : Nil
        name = @explained_type_name
        return unless name && type.to_s == name

        origin = @origin
        current_def = @current_def
        STDERR.puts "prune dispatch: #{name} is created by #{origin.class.name.split("::").last} #{origin.try(&.to_s.lines.first?)} at #{origin.try(&.location)}"
        depth = 0
        while current_def && depth < 12
          STDERR.puts "  in #{current_def.owner?}##{current_def.name} (#{current_def.location})"
          current_def = @reached_from[current_def.object_id]?
          depth += 1
        end
      end

      private def forgotten?(type : Type) : Bool
        name = @forgotten_type_name
        name ? type.to_s == name : false
      end

      # Marks the classes a value made out of memory can have as its exact
      # static type, for a value of *type* that a cast, `Pointer.new`,
      # `va_arg` or `uninitialized` produced (*relabeled*), or that memory
      # set to zero holds (`Pointer.malloc`, the instance variables of an
      # object before `initialize`).
      #
      # A dispatch reads the type id of its receiver from the object itself
      # when the receiver's static type is virtual or a module, and only
      # `allocate` and `pre_initialize` write that id. It reads it from a
      # union's type id slot otherwise, which an upcast fills with the exact
      # static type of the value. So the only types besides the allocated
      # ones that a dispatch can see are the exact classes values are typed
      # as: those found here, through unions, pointers, struct fields,
      # tuples and type arguments.
      private def conjure(type : Type, relabeled : Bool = true) : Nil
        key = relabeled ? type.object_id : ~type.object_id
        return if @conjured.includes?(key)
        @conjured << key

        case type
        when UnionType
          # Zeroed or garbage memory of a union has type id 0 (nil) or no
          # meaning at all: only a relabeled union names its members.
          type.union_types.each { |union_type| conjure(union_type, relabeled) } if relabeled
        when VirtualType, VirtualMetaclassType, NonGenericModuleType, GenericModuleInstanceType
          # The type id comes from the object.
        when PointerInstanceType
          conjure(type.element_type, relabeled) if relabeled
        when TupleInstanceType
          type.tuple_types.each { |tuple_type| conjure(tuple_type, relabeled) }
        when NamedTupleInstanceType
          type.entries.each { |entry| conjure(entry.type, relabeled) }
        when StaticArrayInstanceType
          conjure(type.element_type, relabeled)
        when TypeDefType, AliasType
          conjure(type.remove_indirection, relabeled)
        else
          if prunable?(type)
            unless forgotten?(type) || @created.includes?(type.object_id)
              @created << type.object_id
              explain_creation(type)
            end
          elsif type.struct? && type.is_a?(InstanceVarContainer)
            type.all_instance_vars.each_value do |ivar|
              ivar.type?.try { |ivar_type| conjure(ivar_type, relabeled) }
            end
          end
          if relabeled && type.is_a?(GenericInstanceType)
            type.type_vars.each_value do |type_var|
              if type_var.is_a?(Var) && (type_var_type = type_var.type?)
                conjure(type_var_type, relabeled)
              end
            end
          end
        end
      end

      # The instance variables of a new object are zero until `initialize`
      # sets them, and code can read them before that (`allocate` alone).
      private def conjure_zeroed_instance_vars(type : Type) : Nil
        return unless type.is_a?(InstanceVarContainer)

        type.all_instance_vars.each_value do |ivar|
          ivar.type?.try { |ivar_type| conjure(ivar_type, relabeled: false) }
        end
      end

      private def give_up(cause : String) : Nil
        @gave_up = true
        @stats.gave_up_cause ||= cause
      end

      private def reach(a_def : Def) : Nil
        return if @reached_defs.includes?(a_def.object_id)

        @reached_defs << a_def.object_id
        @reached_from[a_def.object_id] = @current_def if @explained_type_name
        @list_of_pending_defs << a_def
      end

      private def drain_pending_defs : Nil
        while a_def = @list_of_pending_defs.pop?
          return if @gave_up

          walk_def(a_def)
        end
      end

      private def walk_def(a_def : Def) : Nil
        old_def = @current_def
        @current_def = a_def
        a_def.body.accept self
        @current_def = old_def
      end

      private def walk_const(const : Const) : Nil
        return if @walked_consts.includes?(const.object_id)

        @walked_consts << const.object_id
        const.value.accept self
      end

      private def walk_class_var(class_var : MetaTypeVar) : Nil
        owner = class_var.owner?
        case owner
        when VirtualType
          walk_class_var_initializer(owner.base_type.lookup_class_var?(class_var.name))
          owner.base_type.all_subclasses.each do |subclass|
            walk_class_var_initializer(subclass.lookup_class_var?(class_var.name)) if subclass.is_a?(ClassVarContainer)
          end
        when VirtualMetaclassType
          base_type = owner.base_type.instance_type
          walk_class_var_initializer(base_type.metaclass.lookup_class_var?(class_var.name))
          base_type.all_subclasses.each do |subclass|
            walk_class_var_initializer(subclass.metaclass.lookup_class_var?(class_var.name))
          end
        else
          walk_class_var_initializer(class_var)
        end
      end

      private def walk_class_var_initializer(class_var : MetaTypeVar?) : Nil
        return unless class_var
        initializer = class_var.initializer
        return unless initializer
        return if @walked_class_var_initializers.includes?(initializer.object_id)

        @walked_class_var_initializers << initializer.object_id
        initializer.node.accept self
      end

      # Runs what `allocate` runs: the instance variable initializers of the
      # type and of its superclasses.
      private def walk_instance_var_initializers(type : Type) : Nil
        current = type
        while current.is_a?(ClassType) || current.is_a?(GenericClassInstanceType)
          current.instance_vars_initializers.try &.each do |initializer|
            initializer.value.accept self
          end
          current = current.superclass
        end
      end

      private def created_by_allocation(type : Type) : Nil
        base_type = type.is_a?(VirtualType) ? type.base_type : type
        mark_created(base_type)
        return if @allocated_types.includes?(base_type.object_id)

        @allocated_types << base_type.object_id
        walk_instance_var_initializers(base_type)
        conjure_zeroed_instance_vars(base_type)
      end

      def visit(node : Call)
        if expanded = node.expanded
          expanded.accept self
          return false
        end

        node.obj.try &.accept self
        node.args.each &.accept self
        node.named_args.try &.each &.value.accept self
        if block = node.block
          block.body.accept self
          if fun_literal = block.fun_literal
            fun_literal.accept self
          end
        end

        count = 0
        node.each_target_def { count += 1 }
        if count > 1
          @stats.dispatch_calls += 1
          @stats.dispatch_targets += count
          node.each_target_def do |a_def|
            if @mode.off? || branch_live?(node, a_def)
              reach(a_def)
            else
              @list_of_waiting_branches << {node, a_def}
            end
          end
        else
          node.each_target_def do |a_def|
            if @mode.off? || single_target_live?(node, a_def)
              reach(a_def)
            else
              @list_of_waiting_branches << {node, a_def}
            end
          end
        end

        false
      end

      def visit(node : Primitive)
        @origin = node
        case node.name
        when "allocate"
          created_by_allocation(node.type)
        when "pre_initialize"
          if (current_def = @current_def) && (owner = current_def.owner?)
            instance_type = owner.instance_type
            concrete_types_of(instance_type).each { |concrete| created_by_allocation(concrete) }
          end
        when "pointer_new"
          if (type = node.type?).is_a?(PointerInstanceType)
            conjure(type.element_type)
          end
        when "pointer_malloc", "pointer_realloc"
          if (type = node.type?).is_a?(PointerInstanceType)
            conjure(type.element_type, relabeled: false)
          end
        when "va_arg"
          node.type?.try { |type| conjure(type) }
        end
        false
      end

      def visit(node : Cast | NilableCast)
        node.obj.accept self
        @origin = node

        obj_type = node.obj.type?
        to_type = node.to.type?
        return false unless obj_type && to_type

        to_type = to_type.virtual_type
        if to_type.is_a?(PointerInstanceType)
          conjure(to_type.element_type) unless obj_type.pointer? && obj_type == to_type
        elsif obj_type.pointer?
          conjure(to_type)
        end
        false
      end

      def visit(node : UninitializedVar)
        @origin = node
        node.type?.try { |type| conjure(type) }
        false
      end

      def visit(node : ProcLiteral)
        walk_def(node.def)
        false
      end

      def visit(node : ProcPointer)
        node.obj.try &.accept self
        node.call?.try &.each_target_def { |a_def| reach(a_def) }
        node.expanded.try &.accept self
        false
      end

      def visit(node : Path)
        if const = node.target_const
          walk_const(const)
        elsif replacement = node.syntax_replacement
          replacement.accept self
        end
        false
      end

      def visit(node : Assign)
        target = node.target
        if target.is_a?(Path)
          if (const = target.target_const) && const.used?
            walk_const(const)
          end
          return false
        end
        true
      end

      def visit(node : TypeDeclaration)
        var = node.var
        if var.is_a?(ClassVar)
          var.var?.try { |class_var| walk_class_var(class_var) }
          return false
        end
        node.value.try &.accept self
        false
      end

      def visit(node : ClassVar)
        node.var?.try { |class_var| walk_class_var(class_var) }
        false
      end

      def visit(node : FunDef)
        if node.body && (external = node.external?)
          walk_def(external)
        end
        false
      end

      def visit(node : Def)
        node.hook_expansions.try &.each &.accept self
        false
      end

      def visit(node : ClassDef)
        node.hook_expansions.try &.each &.accept self
        node.body.accept self
        false
      end

      def visit(node : Include | Extend)
        node.hook_expansions.try &.each &.accept self
        false
      end

      def visit(node : LibDef | Macro | TypeOf | SizeOf | InstanceSizeOf | AlignOf | InstanceAlignOf |
                       CStructOrUnionDef | ExternalVar | TypeDef | Alias | Annotation)
        false
      end

      def visit(node : ReleasedBody)
        give_up("a def whose body was released")
        false
      end

      def visit(node : ASTNode)
        !@gave_up
      end
    end
  end

  class Program
    # The dispatch pruning the next code generation uses (see
    # `DispatchPrune`). The compiler sets it before it computes the salt of
    # an incremental build and clears it after code generation; code
    # generation runs the analysis itself when it is not set.
    property dispatch_prune : DispatchPrune::Analysis?

    # Runs the analysis over *node* when the program's flags turn pruning
    # on; `nil` otherwise.
    def analyze_dispatch_prune(node : ASTNode) : DispatchPrune::Analysis?
      mode = DispatchPrune.mode_for(self)
      return nil if mode.off?

      analysis = DispatchPrune::Analysis.new(self, mode).run(node)
      if DispatchPrune.print_stats?
        analysis.count_prunable_types
        analysis.print_stats
        # The same walk following every branch: the defs reached only
        # through types the program never creates are the difference.
        DispatchPrune::Analysis.new(self, DispatchPrune::Mode::Off).run(node).tap(&.count_prunable_types).print_stats
      end
      analysis
    end
  end
end
