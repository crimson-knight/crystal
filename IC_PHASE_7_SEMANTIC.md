# Phase 7: Semantic Parallelism (Research/Future)

## Objective
Parallelize the MainVisitor (type inference) -- the true bottleneck at ~40-50% of total compile time. This is a research-grade effort requiring fundamental changes to the compiler's architecture.

## Prerequisites
Deep understanding of the type propagation system from implementing Phases 1-6. This phase is explicitly marked as research/future work.

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

## Key Data Structures Requiring Thread Safety

| Structure | Location | Challenge |
|-----------|----------|-----------|
| `DefInstanceContainer.@def_instances` | `types.cr` | Global method instantiation cache |
| `ASTNode.@observers` / `.dependencies` | `ast.cr` | Type binding graph |
| `Program.unions` | `program.cr` | Union type cache |
| `Program.types` | `program.cr` | Global type hierarchy |
| `Call.@target_defs` | `ast.cr` | Method resolution cache |

## Success Criteria
- [ ] Prototype compiles a non-trivial Crystal program correctly
- [ ] No data races or incorrect types
- [ ] ~40-50% reduction in semantic phase time
- [ ] Self-compilation (Crystal compiling Crystal) produces identical compiler output
- [ ] Memory usage remains reasonable (< 2x sequential)

## Estimated Effort
3-6 months of focused work, likely requiring deep collaboration with Crystal core team.

## References
- Rust-analyzer incremental architecture: query-based with Salsa framework
- TypeScript compiler: project references for coarse partitioning
- Binaryen issue #4470: related WASM tooling limitations
- Crystal language design: whole-program type inference makes this uniquely challenging
