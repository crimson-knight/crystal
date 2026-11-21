# Tracks parallelism capabilities for each semantic sub-phase.
#
# The Crystal semantic pipeline consists of 9 sequential sub-phases (see semantic.cr):
#
#   1. TopLevel         - Declare classes, modules, macros, defs (sequential)
#   2. New              - Create `new` methods for `initialize` (sequential)
#   3. TypeDeclarations - Process type declarations like `@x : Int32` (sequential)
#   4. AbstractDefCheck - Check abstract defs are implemented (PARALLEL - Phase 5)
#   5. RestrictionsAugmenter - Augment type restrictions (sequential)
#   6. IVarsInit        - Process instance var initializers `@x = 1` (sequential)
#   7. CVarsInit        - Process class var initializers `@@x = 1` (sequential)
#   8. Main             - Type inference, call resolution, method instantiation (sequential)
#   9. Cleanup          - Dead code removal, AST simplification (sequential)
#  10. RecursiveStructCheck - Check no recursive structs (PARALLEL - Phase 5)
#
# Currently, only sub-phases 4 and 10 are parallelized (Phase 5 of the incremental
# compilation project). This coordinator documents the parallelism status of each
# sub-phase and provides infrastructure for future parallelism work.
#
# ## Why Most Sub-Phases Cannot Be Parallelized Today
#
# ### TopLevel (sub-phase 1)
# - Mutates `Program.types` (the global type hierarchy)
# - Expands macros, which can define new types and methods
# - Processes `include`/`extend` which modify type ancestors
# - File processing order matters for require semantics
# - **Barrier**: Shared mutable Program state, macro expansion side effects
#
# ### New (sub-phase 2)
# - Creates `new` methods based on `initialize` methods found in TopLevel
# - Mutates type method tables
# - **Barrier**: Shared mutable type method tables
#
# ### TypeDeclarations (sub-phase 3)
# - Resolves type annotations and declares instance/class variables
# - Mutates type instance variable tables
# - Runs type guessing which reads the entire program's type graph
# - **Barrier**: Shared mutable instance variable declarations, cross-type dependencies
#
# ### RestrictionsAugmenter (sub-phase 5)
# - Augments method restrictions based on type hierarchy knowledge
# - Mutates Def argument restrictions
# - **Barrier**: Modifies shared Def objects
#
# ### IVarsInit / CVarsInit (sub-phases 6-7)
# - Visit initializer expressions using SemanticVisitor
# - Can trigger macro expansion
# - **Barrier**: Shared Program state, macro side effects
#
# ### Main (sub-phase 8) - THE BOTTLENECK (~40-50% of compile time)
# - Demand-driven type inference with cascading type changes
# - `DefInstanceContainer.@def_instances` is a global method instantiation cache
# - `ASTNode.@observers` / `.dependencies` form a shared binding graph
# - `Program.unions` caches union types by opaque ID
# - Method resolution looks up ALL overloads across the entire program
# - Changing one method's return type cascades through the binding graph
# - No module boundaries - everything is one interconnected type graph
# - **Barrier**: Deep shared mutable state everywhere. See MainVisitor header comments
#   for detailed analysis. Parallelizing this requires fundamental redesign
#   (message-passing, query-based/Salsa architecture, or coarse-grained partitioning).
#
# ### Cleanup (sub-phase 9)
# - Transforms AST nodes in-place (dead code removal, constant folding)
# - Uses `@transformed` set to avoid re-processing Defs reached via Calls
# - Call transformation recursively transforms target_def.body (shared Def mutation)
# - `cleanup_types` transforms instance var initializers per-type, but initializer
#   values can reference shared Defs via Calls, creating cross-type mutation
# - **Barrier**: In-place AST mutation, shared @transformed deduplication set,
#   cross-type Def body mutation via Call.target_defs traversal
#
# ## Parallelism Opportunities for Future Work
#
# 1. **Cleanup: Instance var initializer values** - If initializer values are simple
#    (literals, constructor calls without shared Def traversal), they could use
#    independent CleanupTransformer instances. Would need a "complexity check" to
#    determine if an initializer can be safely transformed independently.
#
# 2. **TopLevel: File-level pre-processing** - Before dependency ordering matters,
#    files could be pre-parsed and their top-level declarations (class names, method
#    signatures) extracted in parallel. This is partially done by Phase 3 (parallel
#    parsing) and Phase 6 (signature extraction).
#
# 3. **Main: Method instantiation work distribution** - The most impactful target.
#    Requires thread-safe DefInstanceContainer, thread-safe type propagation graph,
#    and a coordinator to deduplicate method instantiation requests. See Option A
#    (message-passing) in IC_PHASE_7_SEMANTIC.md.
#
# 4. **Main: Query-based architecture** - Rewrite the compiler around demand-driven
#    evaluation with declared inputs per query. This is the approach used by
#    rust-analyzer (Salsa framework) and would enable both parallelism and
#    incrementality. See Option B in IC_PHASE_7_SEMANTIC.md.
#
module Crystal
  class SemanticPhaseCoordinator
    # Parallelism status for a semantic sub-phase.
    enum ParallelismStatus
      # This sub-phase runs sequentially and cannot be parallelized
      # without fundamental changes.
      Sequential

      # This sub-phase is already parallelized under `preview_mt`.
      Parallel

      # This sub-phase could potentially be parallelized with careful
      # work, but is not yet implemented.
      PotentiallyParallelizable

      # This sub-phase is the main bottleneck and requires research-grade
      # effort to parallelize (3-6 months).
      ResearchRequired
    end

    # Information about a single semantic sub-phase.
    record PhaseInfo,
      name : String,
      description : String,
      status : ParallelismStatus,
      barriers : Array(String),
      notes : String? = nil

    # All semantic sub-phases and their parallelism information.
    #
    # This serves as the authoritative reference for which phases can run
    # in parallel, which are blocked, and what the barriers are.
    PHASES = [
      PhaseInfo.new(
        name: "top_level",
        description: "Declare classes, modules, macros, defs",
        status: ParallelismStatus::Sequential,
        barriers: ["Program.types mutation", "Macro expansion side effects", "Require ordering"],
      ),
      PhaseInfo.new(
        name: "new",
        description: "Create `new` methods for `initialize`",
        status: ParallelismStatus::Sequential,
        barriers: ["Type method table mutation"],
      ),
      PhaseInfo.new(
        name: "type_declarations",
        description: "Process type declarations (@x : Int32)",
        status: ParallelismStatus::Sequential,
        barriers: ["Instance variable table mutation", "Cross-type dependency in type guessing"],
      ),
      PhaseInfo.new(
        name: "abstract_def_check",
        description: "Check abstract defs are implemented",
        status: ParallelismStatus::Parallel,
        barriers: [] of String,
        notes: "Parallelized in Phase 5. Read-only traversal of type hierarchy.",
      ),
      PhaseInfo.new(
        name: "restrictions_augmenter",
        description: "Augment method type restrictions",
        status: ParallelismStatus::Sequential,
        barriers: ["Def argument restriction mutation"],
      ),
      PhaseInfo.new(
        name: "ivars_initializers",
        description: "Process instance var initializers (@x = 1)",
        status: ParallelismStatus::Sequential,
        barriers: ["Shared Program state", "Macro side effects"],
      ),
      PhaseInfo.new(
        name: "cvars_initializers",
        description: "Process class var initializers (@@x = 1)",
        status: ParallelismStatus::Sequential,
        barriers: ["Shared Program state", "Macro side effects"],
      ),
      PhaseInfo.new(
        name: "main",
        description: "Type inference, call resolution, method instantiation",
        status: ParallelismStatus::ResearchRequired,
        barriers: [
          "DefInstanceContainer.@def_instances (global instantiation cache)",
          "ASTNode.@observers / .dependencies (binding graph)",
          "Program.unions (union type cache)",
          "Program.types (global type hierarchy)",
          "Call.@target_defs (method resolution cache)",
          "Cascading type changes through binding graph",
          "No module boundaries (whole-program type graph)",
        ],
        notes: "~40-50% of compile time. Requires message-passing, query-based, " \
               "or coarse-grained partitioning architecture. See IC_PHASE_7_SEMANTIC.md.",
      ),
      PhaseInfo.new(
        name: "cleanup",
        description: "Dead code removal, AST simplification",
        status: ParallelismStatus::PotentiallyParallelizable,
        barriers: [
          "CleanupTransformer.@transformed (shared Def deduplication)",
          "In-place AST mutation via target_def.body transforms",
          "Cross-type Def body mutation via Call.target_defs",
        ],
        notes: "Per-type instance var initializer cleanup could be parallelized " \
               "if initializer complexity is bounded (no Call traversal into shared Defs).",
      ),
      PhaseInfo.new(
        name: "recursive_struct_check",
        description: "Check no recursive structs",
        status: ParallelismStatus::Parallel,
        barriers: [] of String,
        notes: "Parallelized in Phase 5. Read-only traversal of type hierarchy.",
      ),
    ]

    @program : Program

    def initialize(@program)
    end

    # Returns the parallelism status of a named sub-phase.
    def phase_status(name : String) : ParallelismStatus?
      PHASES.find { |p| p.name == name }.try(&.status)
    end

    # Returns true if the named sub-phase is currently parallelized.
    def parallel?(name : String) : Bool
      phase_status(name) == ParallelismStatus::Parallel
    end

    # Returns all phases that are currently parallelized.
    def parallel_phases : Array(PhaseInfo)
      PHASES.select { |p| p.status.parallel? }
    end

    # Returns all phases that are sequential but could potentially be parallelized.
    def potentially_parallelizable_phases : Array(PhaseInfo)
      PHASES.select { |p| p.status.potentially_parallelizable? }
    end

    # Returns all phases that require research-grade effort to parallelize.
    def research_required_phases : Array(PhaseInfo)
      PHASES.select { |p| p.status.research_required? }
    end

    # Returns the shared mutable state barriers for a named sub-phase.
    # These are the specific data structures or patterns that prevent
    # parallelization.
    def barriers_for(name : String) : Array(String)
      PHASES.find { |p| p.name == name }.try(&.barriers) || [] of String
    end

    # ## Thread-Safe Infrastructure Design Notes
    #
    # The following designs are documented here as extension points for future
    # parallelism work. They are NOT implemented because they require changes
    # to core data structures that would affect the entire compiler.
    #
    # ### Thread-Safe DefInstanceContainer
    #
    # `DefInstanceContainer.@def_instances` (in types.cr) is a Hash that caches
    # method instantiations (defs with concrete type arguments). Currently:
    #
    # ```crystal
    # module DefInstanceContainer
    #   getter(def_instances) { {} of DefInstanceKey => Def }
    #   def add_def_instance(key, typed_def)
    #     def_instances[key] = typed_def
    #   end
    #   def lookup_def_instance(key)
    #     def_instances[key]?
    #   end
    # end
    # ```
    #
    # A thread-safe version would need:
    # 1. A ReadWriteLock (multiple readers, single writer) around the hash
    # 2. A "claim" mechanism: when a worker starts instantiating a method,
    #    it registers a pending entry so other workers wait instead of
    #    duplicating work
    # 3. Atomicity: lookup + insert must be atomic to prevent races
    #
    # Conceptual design:
    # ```crystal
    # class ThreadSafeDefInstanceContainer
    #   @lock = ReadWriteLock.new
    #   @instances = {} of DefInstanceKey => Def
    #   @pending = Set(DefInstanceKey).new  # Being instantiated by some worker
    #
    #   def lookup_or_claim(key) : Def | :claimed | Nil
    #     @lock.read { @instances[key]? } || begin
    #       @lock.write do
    #         @instances[key]? || begin
    #           @pending.add(key)
    #           nil  # Caller should instantiate and then call #publish
    #         end
    #       end
    #     end
    #   end
    #
    #   def publish(key, typed_def)
    #     @lock.write do
    #       @instances[key] = typed_def
    #       @pending.delete(key)
    #     end
    #   end
    # end
    # ```
    #
    # ### Thread-Safe Type Registration
    #
    # `Program.types` and nested type hierarchies use plain Hashes.
    # For TopLevel parallelism, type registration would need:
    # 1. Concurrent hash map for `types` containers
    # 2. Ordered registration (preserve source order for determinism)
    # 3. Conflict detection (two files defining same type)
    #
    # The challenge is that Crystal's type system is built on Hash lookups
    # throughout the codebase (~hundreds of call sites). Replacing with a
    # concurrent container would require auditing every access pattern.
    #
    # ### Thread-Safe Union Type Cache
    #
    # `Program.unions` maps sorted opaque ID arrays to UnionType instances.
    # A thread-safe version would need a concurrent hash map. Since union
    # creation is frequent during type inference, lock contention here
    # could negate parallelism gains. A sharded lock approach (hash the
    # key to determine which shard/lock to use) could help.
  end
end
