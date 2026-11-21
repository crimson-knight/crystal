require "../syntax/ast"
require "../types"

module Crystal
  # Sharing of typed defs between calls that pass a block to a yielding def.
  #
  # A def that yields is inlined at every call, together with that call's
  # block, so `Call#instantiate` used to type one private clone of the def per
  # call site (`def_instances` only caches defs called without a block or with
  # a captured block). In a large program most of those clones are identical in
  # everything codegen reads: the same def, owner, `self` type, argument types
  # and block type.
  #
  # With sharing, the first call for a given def and argument types types its
  # clone as before. That call's block is the clone's *first block*: the
  # clone's `yield`s are bound to it, exactly as without sharing. A later call
  # with the same def and argument types whose block has the same type reuses
  # the clone: its block's parameters are bound to the clone's `yield`
  # expressions and a `BlockInstanceWatcher` compares the two block types from
  # then on. The moment they differ, the watcher gives the later call a private
  # clone again, before the first block's new type reaches the clone's body.
  #
  # A clone is a function of the def, the argument types and the block's
  # type (the block's type also binds the free variables of `& : T -> U`), so
  # a block of the same type would get an identical private clone.
  #
  # A block that has no type before the def is typed gets its parameter types
  # from the clone's `yield` expressions. Such a block only tries clones whose
  # `yield` expressions cannot depend on the block's type
  # (`BlockInstance#yields_independent_of_block?`): those expressions have the
  # same types in every clone, so the block is typed as with a private one.
  class BlockInstance
    # Nodes visited before a clone is declared dependent on its block.
    DEPENDENCY_WALK_LIMIT = 600

    # Times a clone with a block that is still untyped is asked again.
    MAX_INCOMPLETE_CHECKS = 4

    getter first_call : Call
    getter first_block : Block
    getter yields = [] of Yield
    getter watchers = [] of BlockInstanceWatcher

    # Set once the clone's body was typed without an error.
    property? ready = false

    # Cleared when the clone can never be shared (see `#add_yield`).
    property? shareable = true

    # Why the last check failed (shown by the memory census).
    getter dependence_reason : String?

    @checked_yield_count = -1
    @incomplete_checks = 0
    @independent = false

    def initialize(@first_call : Call, @first_block : Block, @block_return_type_declared : Bool)
    end

    # Records a `yield` of *typed_def* that was bound to the first block.
    #
    # A `yield` typed after the clone's body (inside a call whose types
    # arrived late) ends sharing for this clone: the walk in
    # `#yields_independent_of_block?` ran without it.
    def add_yield(node : Yield, program : Program) : Nil
      @yields << node
      return unless ready?

      @shareable = false
      program.block_instance_stats.late_yields += 1
      live_watchers = @watchers.reject(&.detached?)
      @watchers.clear
      live_watchers.each &.diverge
    end

    # Whether another call's block may share *typed_def* at all.
    def accepts_sharing?(typed_def : Def) : Bool
      # `with scope yield` gives the first block a scope taken from the clone.
      shareable? && @yields.none?(&.scope)
    end

    # Whether the clone was typed without ever reading the block: it has no
    # `yield` and its block parameter declares no return type. Any block can
    # share such a clone, whatever its type.
    def ignores_block? : Bool
      ready? && shareable? && @yields.empty? && !@block_return_type_declared
    end

    def add_watcher(watcher : BlockInstanceWatcher) : Nil
      @watchers << watcher
    end

    # Returns `true` when no `yield` expression of *typed_def* can change type
    # because the block's type changes.
    #
    # The block's type enters the clone through its `yield` nodes (each is
    # bound to the block). This walks forward from them, along the edges type
    # inference propagates on, and fails when it reaches the first block's
    # parameters. (A block return type that binds a free variable requires a
    # typed block, which never needs this check.)
    def yields_independent_of_block?(typed_def : Def) : Bool
      return false unless shareable?
      return @independent if @checked_yield_count == @yields.size
      return false if @incomplete_checks > MAX_INCOMPLETE_CHECKS

      unless all_blocks_typed?(typed_def)
        # A block that is typed later can add edges the walk has not seen.
        # Ask again on the next call, a few times at most.
        @incomplete_checks += 1
        @dependence_reason = "a block in the def is not typed yet"
        return false
      end

      # The walk can come back to this clone through a nested one; it then
      # reads the conservative answer.
      @checked_yield_count = @yields.size
      @independent = false
      @independent = compute_yields_independent_of_block(typed_def)
    end

    # Whether every block in the body of *typed_def* was typed already.
    private def all_blocks_typed?(typed_def : Def) : Bool
      pending = [typed_def.body] of ASTNode
      children = BlockInstanceChildCollector.new
      while node = pending.pop?
        return false if node.is_a?(Block) && !node.visited? && !node.fun_literal

        if node.is_a?(Call) && (expanded = node.expanded)
          pending << expanded
          next
        end
        children.nodes.clear
        node.accept_children(children)
        pending.concat(children.nodes)
        if node.is_a?(ExpandableNode)
          if expanded = node.expanded
            pending << expanded
          end
        end
      end
      true
    end

    private def compute_yields_independent_of_block(typed_def : Def) : Bool
      # A def that never yields has no `yield` expressions to depend on.
      pending = [] of ASTNode
      pending.concat(@yields)
      seen = Set(UInt64).new
      while node = pending.pop?
        next unless seen.add?(node.object_id)
        if seen.size > DEPENDENCY_WALK_LIMIT
          @dependence_reason = "walk limit"
          return false
        end

        if node.same?(typed_def)
          # The clone's return type goes to its callers, never back into it:
          # a def that yields cannot call itself with the same block.
          next
        elsif node.is_a?(YieldBlockBinder)
          if node.block.same?(@first_block)
            @dependence_reason = "a yield expression follows the block's value"
            return false
          end
          pending.concat(node.block.args)
          next
        elsif node.is_a?(BlockInstanceWatcher)
          # A block in this clone's body shares a nested clone. The nested
          # clone is identical to a private one, so the block's type reaches
          # the nested call's type, and it reaches the block's parameters
          # only if the nested clone's `yield` expressions depend on its block.
          pending << node.call
          nested = node.typed_def.block_instance
          unless nested && nested.yields_independent_of_block?(node.typed_def)
            pending.concat(node.block.args)
          end
          next
        elsif node.is_a?(MetaTypeVar)
          # Instance, class and global vars are typed for the whole program,
          # whichever clone assigns them.
          next
        elsif node.is_a?(Def)
          if nested = node.block_instance
            # A nested clone was reached through its first block, which is in
            # this clone's body. Its other callers are unrelated call sites.
            pending << nested.first_call
            next
          end
        end

        node.each_observer { |observer| push_dependent(pending, observer) }
        if enclosing_call = node.enclosing_call
          push_dependent(pending, enclosing_call)
        end
      end
      true
    end

    # *node* reads a value that follows the block's type. A call that reads
    # it as its receiver, as an argument or as the type of its own block may
    # target another def, so the parameters of its block follow too. (A call
    # reached only because its result changed is pushed without them.)
    private def push_dependent(pending : Array(ASTNode), node : ASTNode) : Nil
      pending << node
      if node.is_a?(Call) && (block = node.block)
        pending.concat(block.args)
      end
    end
  end

  # Collects the direct children of a node without descending further.
  class BlockInstanceChildCollector < Visitor
    getter nodes = [] of ASTNode

    def visit(node : ASTNode) : Bool
      @nodes << node
      false
    end
  end

  # Observes the block of a call that shares a typed def and the def's first
  # block. When their types stop being equal the call gets a private clone.
  class BlockInstanceWatcher < ASTNode
    getter typed_def : Def
    getter first_block : Block
    getter block : Block
    getter call : Call
    getter? detached = false

    # *compares_types* is false for a clone that ignores its block: the
    # watcher then only serves to end sharing if the clone yields later.
    def initialize(@typed_def : Def, @first_block : Block, @block : Block, @call : Call, @compares_types : Bool)
    end

    def attach : Nil
      @first_block.add_observer(self)
      @block.add_observer(self)
    end

    # Stops watching. The observer entries stay behind; they are inert.
    def detach : Nil
      @detached = true
    end

    def update(from = nil)
      return if @detached || !@compares_types
      return if @first_block.type?.same?(@block.type?)

      diverge
    end

    def diverge : Nil
      return if @detached

      @detached = true
      @call.program.block_instance_stats.diverged += 1
      @call.unbind_block_from_yields(@block, @typed_def)
      @call.give_private_block_instance(@typed_def)
    end

    def clone_without_location
      self
    end

    def accept_children(visitor)
    end
  end

  # Counters for `CRYSTAL_MEMORY_CENSUS` and for specs.
  class BlockInstanceStats
    property typed = 0
    property shared = 0
    property reused_by_first_call = 0
    property diverged = 0
    property late_yields = 0
    property block_type_differs = 0
    property yields_depend_on_block = 0

    # Calls that typed a private clone although other clones existed, by def
    # name and reason. Filled only while the memory census is on.
    getter unshared_reasons = Hash(String, Int32).new(0)

    def note_unshared(def_name : String, reason : String) : Nil
      return unless MemoryCensus.enabled?

      @unshared_reasons["#{def_name}: #{reason}"] += 1
    end
  end

  class Def
    # Present on a typed def that was instantiated for a call with a block
    # it yields to, when such defs are shared (see `BlockInstance`).
    rare_property block_instance : BlockInstance?
  end

  class ASTNode
    def each_observer(& : ASTNode ->) : Nil
      @observers.each { |observer| yield observer }
    end
  end

  class YieldBlockBinder
    # Forgets *nodes*. Their expressions keep this binder as an observer; an
    # update from them recomputes the parameters from the remaining yields.
    def remove_yields(nodes : Array(Yield)) : Nil
      @yields.reject! { |entry| nodes.any?(&.same?(entry[0])) }
    end

    def add_yield_once(node : Yield, yield_vars : Array(Var)?) : Nil
      return if @yields.any? { |entry| entry[0].same?(node) }

      add_yield(node, yield_vars)
    end
  end

  module DefInstanceContainer
    # Typed defs instantiated for calls with a block the def yields to, by def
    # and argument types. Each entry was typed against a different block type.
    getter(block_def_instances) { {} of DefInstanceKey => Array(Def) }

    def add_block_def_instance(key : DefInstanceKey, typed_def : Def) : Nil
      list = block_def_instances[key] ||= [] of Def
      list << typed_def
    end

    def lookup_block_def_instances(key : DefInstanceKey) : Array(Def)?
      @block_def_instances.try &.[key]?
    end
  end

  class Program
    # Whether calls that pass a block to a yielding def share one typed def
    # per def, argument types and block type. `CRYSTAL_SHARE_BLOCK_INSTANCES=0`
    # types a private clone per call site, as before.
    property? share_block_instances : Bool = ENV["CRYSTAL_SHARE_BLOCK_INSTANCES"]? != "0"

    getter block_instance_stats = BlockInstanceStats.new
  end
end
