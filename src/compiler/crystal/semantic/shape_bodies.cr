require "../syntax/ast"
require "../codegen/owner_shape_sharing"

module Crystal
  # One typed body per shape, during type inference.
  #
  # A large program types many methods once for each of many owners: an Amber
  # app of 300 resources has 300 typed copies of `save`, `__update`,
  # `table_name` and hundreds of other per-model methods, about 1.4 GB of
  # typed bodies when type inference ends. Code generation already gives
  # copies that differ only in *interchangeable classes* one function
  # (`OwnerShapeSharing`), but only after every copy was typed and kept to the
  # end of type inference, which is when the compiler's memory peaks.
  #
  # Here the same rule is applied as each copy is typed. When a newly typed
  # copy has the shape of an earlier one (same `OwnerShapeSharing::ShapeWalker`
  # hash, walked with macro expansions, and callees that share a function),
  # the copy keeps its def (its signature, return type and callers) and lets
  # its body go: code generation calls the earlier copy's function for it,
  # with the copy's own owner as `self`, which is the substitution the walk
  # allows. Only shapes that are not pinned qualify: code that reads the
  # identity of an interchangeable class (a type id, a metaclass value, a
  # class variable, a dispatch) is never shared.
  #
  # A body that was let go no longer follows type inference, so everything it
  # read from outside is remembered with the type it had (the *inputs*: the
  # instance variables, the callees' return types, constants and globals),
  # and everything outside that read from the body now reads a node that
  # holds the type the body gave it. When `Semantic (main)` has finished
  # (`#settle`), a copy whose inputs changed, whose callees stopped sharing
  # their function, whose classes changed their layout, or whose
  # representative's shape changed is typed again from its source def, as it
  # would have been, and that repeats until nothing changes.
  #
  # `CRYSTAL_SHAPE_BODIES=0` turns this off; `1` turns it on also for
  # `--no-codegen` builds (tools that read typed bodies keep them otherwise);
  # `verify` decides every share but keeps every body, and when type
  # inference ends compares each shared copy's own final shape with its
  # representative's, reporting any difference the checks above did not
  # catch. Off for incremental builds, the build server and documentation.
  class ShapeBodies
    enum Mode
      On
      Verify
    end

    # What `#unshare` needs to type a copy again, as `Call#instantiate` did.
    record Recipe, untyped_def : Def, match_owner : Type, lookup_self_type : Type,
      arg_types : Array(Type), named_args_types : Array(NamedArgumentType)?, match_context : MatchContext

    # A typed copy whose body was let go for its representative's.
    class SharedCopy
      getter typed_def : Def
      getter representative : Def
      getter key : {UInt64, UInt64, UInt64}
      getter list_of_callees : Array(Def)
      getter list_of_inputs : Array({ASTNode, Type?})
      getter list_of_layouts : Array({Type, UInt64})
      getter recipe : Recipe
      property? typed_again = false

      def initialize(@typed_def, @representative, @key, @list_of_callees, @list_of_inputs, @list_of_layouts, @recipe)
      end
    end

    # Holds the type a let-go body node had, for the nodes outside the body
    # that depended on it.
    class TypeHolder < ASTNode
      def initialize(type : Type?)
        @type = type
      end

      def clone_without_location
        TypeHolder.new(@type)
      end
    end

    class Stats
      property considered = 0
      property not_shareable = 0
      property pinned = 0
      property callee_in_progress = 0
      property unsuitable_body = 0
      property representatives = 0
      property shared = 0
      property shared_nodes = 0_i64
      property inputs = 0_i64
      property sweeps = 0
      property typed_again = 0
      property settle_rounds = 0
      property compared = 0
      property differ = 0
      property differ_unflagged = 0
      property flagged = 0
      property seconds = 0.0
    end

    getter mode : Mode
    getter stats = Stats.new

    # The first copy of every shape, by key.
    @representative_by_key = Hash({UInt64, UInt64, UInt64}, Def).new
    @shared_copy_by_def_id = Hash(UInt64, SharedCopy).new
    @list_of_shared_copies = [] of SharedCopy

    # The defs whose bodies are being typed right now (innermost last).
    @list_of_typing_defs = [] of Def

    # Typed defs a `super` call reached (codegen names their functions after
    # the caller's class).
    @super_target_ids = Set(UInt64).new

    # Nodes outside let-go bodies that still list let-go nodes as observers,
    # and those let-go nodes (see `#sweep`).
    @list_of_pending_observed = [] of ASTNode
    @pending_observed_ids = Set(UInt64).new
    @detached_node_ids = Set(UInt64).new

    SWEEP_THRESHOLD = 200_000

    getter? settled = false
    @settling = false

    def initialize(@program : Program, @mode : Mode)
    end

    def verify? : Bool
      @mode.verify?
    end

    def self.mode_setting : String
      ENV["CRYSTAL_SHAPE_BODIES"]? || ""
    end

    # The shared copy *typed_def* is, if it is one.
    def shared_copy?(typed_def : Def) : SharedCopy?
      return nil if verify?
      @shared_copy_by_def_id[typed_def.object_id]?
    end

    def each_shared_copy(& : SharedCopy ->) : Nil
      return if verify?
      @list_of_shared_copies.each do |shared_copy|
        yield shared_copy unless shared_copy.typed_again?
      end
    end

    def note_super_target(typed_def : Def) : Nil
      @super_target_ids << typed_def.object_id
    end

    # *typed_def*'s body is being typed from now until `#leave_typing`.
    def enter_typing(typed_def : Def) : Nil
      @list_of_typing_defs << typed_def
    end

    def leave_typing(typed_def : Def) : Nil
      index = @list_of_typing_defs.rindex(&.same?(typed_def))
      @list_of_typing_defs.delete_at(index) if index
    end

    private def being_typed?(typed_def : Def) : Bool
      @list_of_typing_defs.any?(&.same?(typed_def))
    end

    # Called by `Call#instantiate` once *typed_def*, a copy cached by its
    # owner, has been typed for the first time.
    def consider(typed_def : Def, recipe : Recipe) : Nil
      return if @settled || @settling
      return unless candidate?(typed_def)

      started = Time.instant
      begin
        consider_candidate(typed_def, recipe)
      ensure
        @stats.seconds += (Time.instant - started).total_seconds
      end
    end

    private def candidate?(typed_def : Def) : Bool
      return false if typed_def.is_a?(External)
      return false unless typed_def.owner?
      return false if typed_def.special_vars || typed_def.block_arg || typed_def.block_arity
      return false if typed_def.uses_block_arg? || typed_def.closure? || typed_def.self_closured? || typed_def.captured_block?
      return false if @super_target_ids.includes?(typed_def.object_id)
      body = typed_def.body
      return false if body.is_a?(Primitive) || body.is_a?(SharedShapeBody)
      # Code generation writes these bodies in place of every call.
      !CodeGenVisitor.inlines_body_at_call?(typed_def, body)
    end

    private def consider_candidate(typed_def : Def, recipe : Recipe) : Nil
      @stats.considered += 1
      types = OwnerShapeSharing::TypeFacts.new
      shape = OwnerShapeSharing::Shape.new(typed_def)
      walker = OwnerShapeSharing::ShapeWalker.new(@program, types, Set(UInt64).new)
      walker.walks_expansions = true
      walker.walk(shape)

      unless shape.shareable?
        @stats.not_shareable += 1
        return
      end
      if shape.pinned?
        @stats.pinned += 1
        return
      end
      if shape.callees.any? { |callee| being_typed?(callee) }
        @stats.callee_in_progress += 1
        return
      end

      key = {shape.base_first, shape.base_second, callee_hash(shape.callees)}
      representative = @representative_by_key[key]?
      unless representative
        @representative_by_key[key] = typed_def
        @stats.representatives += 1
        return
      end
      return if representative.same?(typed_def)

      body_nodes = BodyNodes.collect(typed_def)
      unless body_nodes
        @stats.unsuitable_body += 1
        return
      end

      list_of_inputs = inputs_of(body_nodes)
      return unless list_of_inputs

      list_of_layouts = [] of {Type, UInt64}
      walker.each_numbered_type { |type| list_of_layouts << {type, types.layout(type)} }

      shared_copy = SharedCopy.new(typed_def, representative, key, shape.callees.dup, list_of_inputs, list_of_layouts, recipe)
      @shared_copy_by_def_id[typed_def.object_id] = shared_copy
      @list_of_shared_copies << shared_copy
      @stats.shared += 1
      @stats.shared_nodes += body_nodes.list_of_nodes.size
      @stats.inputs += list_of_inputs.size

      detach(typed_def, body_nodes) unless verify?
    end

    # The hash of the functions *list_of_callees* call: each callee stands
    # for the copy whose function it shares.
    private def callee_hash(list_of_callees : Array(Def)) : UInt64
      hash = 0x6a09e667f3bcc908_u64
      list_of_callees.each do |callee|
        hash = OwnerShapeSharing.mix_first(hash, function_def(callee).object_id)
      end
      hash
    end

    # The def whose function *typed_def* calls with: its representative when
    # it is a shared copy.
    def function_def(typed_def : Def) : Def
      shared_copy = @shared_copy_by_def_id[typed_def.object_id]?
      shared_copy && !shared_copy.typed_again? ? shared_copy.representative : typed_def
    end

    # The nodes of a typed body: the tree with its expansions, and the def's
    # arguments and variables.
    class BodyNodes
      getter list_of_nodes = [] of ASTNode
      getter node_ids = Set(UInt64).new

      # Returns `nil` for a body that is not let go: one with a block, a proc
      # or a nested def, whose nodes other typed defs may hold.
      def self.collect(typed_def : Def) : BodyNodes?
        nodes = new
        nodes.add(typed_def.body)
        typed_def.args.each { |arg| nodes.add(arg) }
        typed_def.vars.try &.each_value { |meta_var| nodes.add(meta_var) }
        nodes.walk ? nodes : nil
      end

      @stack = [] of ASTNode

      def add(node : ASTNode) : Nil
        return unless @node_ids.add?(node.object_id)
        @list_of_nodes << node
        @stack << node
      end

      def includes?(node : ASTNode) : Bool
        @node_ids.includes?(node.object_id)
      end

      protected def walk : Bool
        collector = CensusChildCollector.new
        while node = @stack.pop?
          case node
          when Block, ProcLiteral, ProcPointer, Def
            return false
          when Call
            return false if node.block || node.block_arg
            node.expanded.try { |expanded| add(expanded) }
          when ExpandableNode
            node.expanded.try { |expanded| add(expanded) }
          end
          collector.children.clear
          node.accept_children(collector)
          collector.children.each { |child| add(child) }
        end
        true
      end
    end

    # What the body read from outside it, with the types it read; `nil` when
    # a node outside is notifying its observers right now (taking one out
    # would make it skip another).
    private def inputs_of(body_nodes : BodyNodes) : Array({ASTNode, Type?})?
      seen = Set(UInt64).new
      list_of_inputs = [] of {ASTNode, Type?}
      body_nodes.list_of_nodes.each do |node|
        return nil if node.notifying_observers?
        node.dependencies.each do |dependency|
          next if body_nodes.includes?(dependency)
          return nil if dependency.notifying_observers?
          list_of_inputs << {dependency, dependency.type?} if seen.add?(dependency.object_id)
        end
      end
      list_of_inputs
    end

    # Lets the body of *typed_def* go: nothing outside it reaches it any
    # more, through its type-inference edges or the def.
    private def detach(typed_def : Def, body_nodes : BodyNodes) : Nil
      body = typed_def.body
      body_nodes.list_of_nodes.each do |node|
        holder = nil
        node.each_observer do |observer|
          next if body_nodes.includes?(observer)
          holder ||= TypeHolder.new(node.type?)
          while observer.shape_bodies_replace_dependency(node, holder)
          end
        end
        node.shape_bodies_reject_observers { |observer| !body_nodes.includes?(observer) }

        node.dependencies.each do |dependency|
          next if body_nodes.includes?(dependency)
          @detached_node_ids << node.object_id
          @list_of_pending_observed << dependency if @pending_observed_ids.add?(dependency.object_id)
        end
      end

      typed_def.body = SharedShapeBody.new(body.type?)
      typed_def.vars = nil
      sweep if @detached_node_ids.size >= SWEEP_THRESHOLD
    end

    # Takes the let-go nodes out of the observer lists of the nodes they
    # read. Done in batches: a node like the program's nil var has hundreds
    # of thousands of observers. Waits while one of them is notifying.
    private def sweep : Nil
      return if @detached_node_ids.empty?
      return if @list_of_pending_observed.any?(&.notifying_observers?)

      detached = @detached_node_ids
      @list_of_pending_observed.each do |observed|
        observed.shape_bodies_reject_observers { |observer| detached.includes?(observer.object_id) }
      end
      @list_of_pending_observed.clear
      @pending_observed_ids.clear
      @detached_node_ids = Set(UInt64).new
      @stats.sweeps += 1
    end

    # Called when the main code and every finished hook have been typed:
    # types again every shared copy whose sharing no longer holds, until
    # none is left.
    def settle : Nil
      return if @settled
      started = Time.instant
      @settling = true
      begin
        sweep
        loop do
          @stats.settle_rounds += 1
          shape_by_def_id = Hash(UInt64, {UInt64, UInt64, UInt64}?).new
          list_of_flagged = @list_of_shared_copies.select do |shared_copy|
            !shared_copy.typed_again? && stale?(shared_copy, shape_by_def_id)
          end
          @stats.flagged += list_of_flagged.size

          if verify?
            compare_shapes(list_of_flagged, shape_by_def_id)
            break
          end
          break if list_of_flagged.empty?

          list_of_flagged.each { |shared_copy| type_again(shared_copy) }
        end
        sweep
      ensure
        @settling = false
        @settled = true
        @stats.seconds += (Time.instant - started).total_seconds
      end
      report
    end

    # Whether *shared_copy* can no longer use its representative's function.
    private def stale?(shared_copy : SharedCopy, shape_by_def_id) : Bool
      return true if @super_target_ids.includes?(shared_copy.typed_def.object_id)
      return true if shared_copy.list_of_inputs.any? { |(node, type)| !node.type?.same?(type) }

      types = OwnerShapeSharing::TypeFacts.new
      return true if shared_copy.list_of_layouts.any? { |(type, layout)| types.layout(type) != layout }
      return true if callee_hash(shared_copy.list_of_callees) != shared_copy.key[2]

      shape_of(shared_copy.representative, shape_by_def_id) != shared_copy.key
    end

    # The key of *typed_def*'s shape now (`nil` when it is not shareable).
    private def shape_of(typed_def : Def, shape_by_def_id) : {UInt64, UInt64, UInt64}?
      if shape_by_def_id.has_key?(typed_def.object_id)
        return shape_by_def_id[typed_def.object_id]
      end

      types = OwnerShapeSharing::TypeFacts.new
      shape = OwnerShapeSharing::Shape.new(typed_def)
      walker = OwnerShapeSharing::ShapeWalker.new(@program, types, Set(UInt64).new)
      walker.walks_expansions = true
      walker.walk(shape)
      key = shape.shareable? && !shape.pinned? ? {shape.base_first, shape.base_second, callee_hash(shape.callees)} : nil
      shape_by_def_id[typed_def.object_id] = key
    end

    # Verify mode: every body is still there, so each shared copy's own shape
    # is compared with its representative's.
    private def compare_shapes(list_of_flagged : Array(SharedCopy), shape_by_def_id) : Nil
      flagged_ids = list_of_flagged.map(&.typed_def.object_id).to_set
      @list_of_shared_copies.each do |shared_copy|
        @stats.compared += 1
        own = shape_of(shared_copy.typed_def, shape_by_def_id)
        representative = shape_of(shared_copy.representative, shape_by_def_id)
        next if own && own == representative

        @stats.differ += 1
        next if flagged_ids.includes?(shared_copy.typed_def.object_id)

        @stats.differ_unflagged += 1
        if @stats.differ_unflagged <= 20
          STDERR.puts "shape bodies: #{shared_copy.typed_def.owner}##{shared_copy.typed_def.name} differs from #{shared_copy.representative.owner}##{shared_copy.representative.name} and no check caught it"
        end
      end
    end

    # Types *shared_copy* again from its source def, into the same def, so
    # its callers keep it.
    def type_again(shared_copy : SharedCopy) : Nil
      typed_def = shared_copy.typed_def
      recipe = shared_copy.recipe
      call = Call.new(typed_def.name)
      call.scope = recipe.lookup_self_type
      fresh_def, args = call.prepare_typed_def_with_args(recipe.untyped_def, recipe.match_owner,
        recipe.lookup_self_type, recipe.arg_types, nil, recipe.named_args_types)

      body = fresh_def.body
      typed_def.shape_bodies_clear_dependencies
      typed_def.body = body
      typed_def.bind_to(body)

      visitor = MainVisitor.new(@program, args, typed_def)
      visitor.match_context = recipe.match_context
      visitor.untyped_def = recipe.untyped_def
      visitor.scope = recipe.lookup_self_type
      visitor.path_lookup = recipe.match_context.defining_type
      enter_typing(typed_def)
      begin
        body.accept visitor
      ensure
        leave_typing(typed_def)
      end
      visitor.release_inference_state if @program.release_inference_state?

      shared_copy.typed_again = true
      @shared_copy_by_def_id.delete(typed_def.object_id)
      @stats.typed_again += 1
    end

    private def report : Nil
      return unless verify? || ENV["CRYSTAL_SHAPE_BODIES_STATS"]? == "1"
      stats = @stats
      STDERR.puts "shape bodies: #{stats.considered} considered, #{stats.representatives} representatives, #{stats.shared} shared (#{stats.shared_nodes} nodes, #{stats.inputs} inputs), " \
                  "not shareable #{stats.not_shareable}, pinned #{stats.pinned}, callee in progress #{stats.callee_in_progress}, unsuitable body #{stats.unsuitable_body}; " \
                  "#{stats.settle_rounds} settle rounds, #{stats.flagged} flagged, #{stats.typed_again} typed again, #{stats.sweeps} sweeps, #{stats.seconds.round(2)} s"
      if verify?
        STDERR.puts "shape bodies verify: #{stats.compared} compared, #{stats.differ} differ, #{stats.differ_unflagged} differ without a check catching it"
      end
    end
  end

  # The body of a typed copy that shares its representative's function (see
  # `ShapeBodies`). It keeps the body's type.
  class SharedShapeBody < ASTNode
    def initialize(type : Type?)
      @type = type
    end

    def clone_without_location
      SharedShapeBody.new(@type)
    end
  end

  class ASTNode
    # Puts *new_node* in the place of *old_node* among this node's
    # dependencies, without touching either's observers (`ShapeBodies`).
    def shape_bodies_replace_dependency(old_node : ASTNode, new_node : ASTNode) : Bool
      @dependencies.replace_first(old_node, new_node)
    end

    # Takes out the observers for which the block is true (`ShapeBodies`).
    def shape_bodies_reject_observers(& : ASTNode -> Bool) : Nil
      @observers.reject! { |observer| yield observer }
    end

    # Forgets every dependency, leaving the dependencies' observer lists as
    # they are (`ShapeBodies`: they only hold a `TypeHolder`).
    def shape_bodies_clear_dependencies : Nil
      @dependencies = SmallNodeList.new
    end
  end

  class Program
    # See `ShapeBodies`. Set when type inference starts.
    getter shape_bodies : ShapeBodies?

    # `true` or `false` overrides `CRYSTAL_SHAPE_BODIES` for this program.
    property shape_bodies_setting : Bool?

    # Sets up `#shape_bodies` for a compiler build that generates code (or
    # any program with `CRYSTAL_SHAPE_BODIES=1` or `verify`).
    def start_shape_bodies : Nil
      @shape_bodies = nil
      mode = shape_bodies_mode
      @shape_bodies = ShapeBodies.new(self, mode) if mode
    end

    private def shape_bodies_mode : ShapeBodies::Mode?
      setting = ShapeBodies.mode_setting
      return ShapeBodies::Mode::Verify if setting == "verify"
      return nil if setting == "0" || @shape_bodies_setting == false
      return nil unless share_owner_shapes?
      return nil if wants_doc? || infer_reuse_record || Program.lazy_def_bodies_blocked_by_type_reuse?

      compiler = self.compiler
      return nil if compiler && compiler.incremental?
      return ShapeBodies::Mode::On if setting == "1" || @shape_bodies_setting == true
      return nil unless compiler

      compiler.no_codegen? ? nil : ShapeBodies::Mode::On
    end
  end
end
