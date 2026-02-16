# Phase 7: Semantic Parallelism (Research Foundation)

## Objective
Parallelize the MainVisitor (type inference) -- the true bottleneck at ~40-50% of total compile time. This is a research-grade effort requiring fundamental changes to the compiler's architecture.

## Prerequisites
Deep understanding of the type propagation system from implementing Phases 1-6. This phase is explicitly marked as research/future work.

## Status: Research Foundation Complete

Phase 7 has been implemented as a **research foundation** that provides:
1. **SemanticPhaseCoordinator** - Authoritative reference for parallelism status of all 10 semantic sub-phases
2. **Shared mutable state documentation** - Detailed analysis of the 7 barriers preventing MainVisitor parallelization, documented directly in the source code
3. **Thread-safe infrastructure designs** - Conceptual designs for thread-safe DefInstanceContainer, type registration, and union cache documented as extension points
4. **CleanupTransformer analysis** - Detailed explanation of why the cleanup phase cannot be naively parallelized, with notes on potential future approaches

### What Was Implemented
- `src/compiler/crystal/semantic/semantic_phase_coordinator.cr`: New file containing the `SemanticPhaseCoordinator` class with `PhaseInfo` records for all 10 sub-phases, parallelism status enum, barrier analysis, and thread-safe infrastructure design notes
- `src/compiler/crystal/semantic/main_visitor.cr`: Added comprehensive documentation of the 7 shared mutable state barriers preventing parallelization
- `src/compiler/crystal/semantic/cleanup_transformer.cr`: Added parallelism analysis documenting why `@transformed`, in-place AST mutation, and cross-type Def body mutation prevent parallelization
- `src/compiler/crystal/semantic/top_level_visitor.cr`: Added parallelism analysis documenting why file-level parallelism is blocked
- `src/compiler/crystal/semantic.cr`: Updated pipeline documentation to reflect parallelism status of each sub-phase

### What Remains (Research-Grade, 3-6 Months)
The full vision of parallelizing MainVisitor requires one of three approaches:

## Why This Is Hard

The `MainVisitor` (at `src/compiler/crystal/semantic/main_visitor.cr`, ~4000 lines) performs whole-program type inference with these characteristics:

1. **Demand-driven method instantiation**: When a method call is encountered, all matching overloads across the entire program are looked up. The best match is instantiated with concrete type arguments, creating a new MainVisitor to type-check the method body.

2. **Shared mutable state**: `DefInstanceContainer.@def_instances` caches method instantiations globally. `ASTNode.@observers` / `.dependencies` form a binding graph for type propagation. `Program.unions` caches union types by opaque ID.

3. **Cascading type changes**: Changing one method's return type cascades through the binding graph. A variable's type is the union of ALL assignments to it -- assignments can come from anywhere in the program.

4. **No module boundaries**: Crystal has no concept of "module interfaces" or "compilation units" in the semantic sense. Everything is one big interconnected type graph.

## Research Approach

### Option A: Message-Passing Architecture
- Method instantiation requests go to a coordinator that deduplicates
- Coordinator assigns instantiation work to worker threads
- Each worker has a thread-local visitor; results propagate back via channel
- Requires: thread-safe `DefInstanceContainer`, thread-safe type propagation graph

### Option B: Query-Based / Salsa Architecture
- Each computation (parse file, resolve type, check method) becomes a "query" with declared inputs
- When inputs change, only affected queries re-execute
- This is the architecture used by rust-analyzer and TypeScript compiler
- Requires: fundamentally rewriting the compiler around demand-driven evaluation

### Option C: Coarse-Grained Partitioning
- Identify independent "clusters" of types that don't interact
- Process each cluster on a separate thread
- Challenge: Crystal's type inference means most types ARE connected

## Semantic Sub-Phase Parallelism Status

| Sub-Phase | Status | Barriers |
|-----------|--------|----------|
| TopLevel | Sequential | Program.types mutation, macro expansion, require ordering |
| New | Sequential | Type method table mutation |
| TypeDeclarations | Sequential | Instance var table mutation, cross-type dependencies |
| AbstractDefCheck | **PARALLEL** | None (read-only, Phase 5) |
| RestrictionsAugmenter | Sequential | Def argument restriction mutation |
| IVarsInit | Sequential | Shared Program state, macro side effects |
| CVarsInit | Sequential | Shared Program state, macro side effects |
| Main | Research Required | 7 shared mutable state barriers (see main_visitor.cr) |
| Cleanup | Potentially Parallelizable | @transformed set, in-place AST mutation, cross-type Defs |
| RecursiveStructCheck | **PARALLEL** | None (read-only, Phase 5) |

## Key Data Structures Requiring Thread Safety

| Structure | Location | Challenge |
|-----------|----------|-----------|
| `DefInstanceContainer.@def_instances` | `types.cr` | Global method instantiation cache |
| `ASTNode.@observers` / `.dependencies` | `ast.cr` | Type binding graph |
| `Program.unions` | `program.cr` | Union type cache |
| `Program.types` | `program.cr` | Global type hierarchy |
| `Call.@target_defs` | `ast.cr` | Method resolution cache |
| `CleanupTransformer.@transformed` | `cleanup_transformer.cr` | Shared Def deduplication set |

## Success Criteria
- [x] SemanticPhaseCoordinator documents all sub-phase parallelism status
- [x] Shared mutable state barriers documented in source code (main_visitor.cr, cleanup_transformer.cr, top_level_visitor.cr)
- [x] Thread-safe infrastructure designs documented as extension points
- [x] Compiler self-validates (builds with --no-codegen)
- [ ] Prototype compiles a non-trivial Crystal program correctly (future)
- [ ] No data races or incorrect types (future)
- [ ] ~40-50% reduction in semantic phase time (future)
- [ ] Self-compilation produces identical compiler output (future)
- [ ] Memory usage remains reasonable (< 2x sequential) (future)

## Estimated Effort
Research foundation: 1 day (complete).
Full MainVisitor parallelism: 3-6 months of focused work, likely requiring deep collaboration with Crystal core team.

## Key Source Files

| File | Role |
|------|------|
| `src/compiler/crystal/semantic/semantic_phase_coordinator.cr` | Parallelism status tracker and infrastructure designs |
| `src/compiler/crystal/semantic/main_visitor.cr` | Type inference bottleneck with shared state barrier docs |
| `src/compiler/crystal/semantic/cleanup_transformer.cr` | AST simplification with parallelism analysis |
| `src/compiler/crystal/semantic/top_level_visitor.cr` | Type declaration with parallelism analysis |
| `src/compiler/crystal/semantic/abstract_def_checker.cr` | Parallelized read-only checker (Phase 5) |
| `src/compiler/crystal/semantic/recursive_struct_checker.cr` | Parallelized read-only checker (Phase 5) |
| `src/compiler/crystal/semantic.cr` | Pipeline orchestration with parallelism documentation |

## References
- Rust-analyzer incremental architecture: query-based with Salsa framework
- TypeScript compiler: project references for coarse partitioning
- Crystal language design: whole-program type inference makes this uniquely challenging
