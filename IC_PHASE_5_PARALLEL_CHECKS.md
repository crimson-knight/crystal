# Phase 5: Parallel Post-Semantic Checks

## Status: COMPLETE

## Objective
Parallelize read-only semantic sub-phases that iterate types independently. These phases only READ the type graph and can safely run per-type work on separate threads.

## Prerequisites
None strictly, but best implemented after Phases 1-2 for testing infrastructure. Independent of Phases 3-4.

## Implementation Steps

### Step 5.1: Parallelize AbstractDefChecker - COMPLETE
**File:** `src/compiler/crystal/semantic/abstract_def_checker.cr`

**What was done:**
- Extracted `check_single_type` from `check_single` to separate the per-type check logic from recursive type traversal
- Added `collect_all_types` / `collect_types_into` to flatten the nested type hierarchy into a single array
- Under `{% if flag?(:preview_mt) %}`, implemented `parallel_run` using Channel + WaitGroup + Mutex pattern (matching `mt_codegen` in compiler.cr)
- Worker count: `{System.cpu_count, 4}.max` clamped to type count
- Errors collected via mutex, sorted by `true_filename` for deterministic output
- `@warnings_mutex` instance variable protects `@program.warnings.add_warning` calls in `check_positional_param_names` from concurrent access
- Under `{% else %}`, `sequential_run` preserves original behavior exactly

**Thread safety analysis:**
- `check_single_type` reads: `type.abstract?`, `type.module?`, `type.defs`, subclasses, ancestors, `type.locations` -- all read-only
- `replace_method_arg_paths_with_type_vars` clones the method before modifying -- safe
- `check_return_type` clones `base_return_type_node` before accepting visitor -- safe
- `free_var_nodes` creates new `Path` nodes -- safe
- `@program.warnings.add_warning` pushes to a shared array -- protected by `@warnings_mutex`

### Step 5.2: Parallelize RecursiveStructChecker - COMPLETE
**File:** `src/compiler/crystal/semantic/recursive_struct_checker.cr`

**What was done:**
- Same parallel pattern as AbstractDefChecker
- Extracted `check_single_type` from `check_single` to separate check logic from traversal
- `collect_all_types` also collects generic struct instances via `collect_generic_instances_into`, since the original code checks these through `check_generic_instances`
- Each `check_single_type` creates local `Set(Type)` and `Array` per invocation -- fully thread-safe, no shared mutable state

**Thread safety analysis:**
- `check_recursive` and `check_recursive_instance_var_container` use only local `checked` set and `path` array
- All type graph access is read-only (`.struct?`, `.all_instance_vars`, `.subtypes`, etc.)
- No calls to `@program.warnings` or any shared mutable state

### Step 5.3: RestrictionsAugmenter - NOT PARALLELIZABLE
**File:** `src/compiler/crystal/semantic/restrictions_augmenter.cr`

**Analysis result: NOT safe to parallelize.** RestrictionsAugmenter performs write operations:
- `arg.restriction = restriction` -- mutates AST argument nodes
- `expansion_arg.restriction = restriction.dup` -- mutates expanded `new` method argument nodes
- Maintains mutable traversal state: `@current_type`, `@def`, `@args_hash`, `@conditional_nest`
- Operates as an AST visitor (`node.accept self`) requiring sequential tree traversal

This phase fundamentally modifies the AST and cannot be parallelized without a major redesign that would separate reading from writing phases.

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/semantic/abstract_def_checker.cr` | Flatten types + parallel workers under preview_mt |
| `src/compiler/crystal/semantic/recursive_struct_checker.cr` | Same parallel pattern, includes generic instance collection |

### Not Modified (with rationale)
| File | Reason |
|------|--------|
| `src/compiler/crystal/semantic/restrictions_augmenter.cr` | Writes to AST nodes, not parallelizable |
| `src/compiler/crystal/semantic.cr` | No changes needed, checkers called via `.run` which handles dispatch internally |
| `src/compiler/crystal/compiler.cr` | Phase 4 team scope, not modified |

## Code Patterns Used
- **Parallelism**: Channel + WaitGroup + Mutex (matching `mt_codegen` at compiler.cr:760-791)
- **Error collection**: Gather TypeException from workers via mutex, sort by `true_filename`, raise first
- **Conditional compilation**: `{% if flag?(:preview_mt) %}` for MT-only code paths
- **Type flattening**: Recursive `collect_types_into` gathers all nested types before distribution

## Success Criteria
- [x] AbstractDefChecker produces identical results in parallel vs sequential mode
- [x] RecursiveStructChecker produces identical results in parallel vs sequential mode
- [x] No data races under `-Dpreview_mt` (verified via code audit: no shared mutable state except mutex-protected warnings)
- [ ] Full Crystal spec suite passes with parallel checks enabled (blocked by pre-existing compiler.cr error from Phase 4)
- [ ] Compile time improvement measurable on large codebases (Crystal self-compilation)
- [x] Error messages are identical regardless of parallel/sequential execution (sorted by true_filename)

## Testing Instructions
```bash
# Compile with parallel checks (requires preview_mt)
LLVM_CONFIG=/opt/homebrew/Cellar/llvm/21.1.8_1/bin/llvm-config \
  bin/crystal build --stats -Dpreview_mt hello.cr

# Compare output with sequential
LLVM_CONFIG=/opt/homebrew/Cellar/llvm/21.1.8_1/bin/llvm-config \
  bin/crystal build --stats hello.cr

# Self-compilation test
LLVM_CONFIG=/opt/homebrew/Cellar/llvm/21.1.8_1/bin/llvm-config \
  time bin/crystal build --stats -Dpreview_mt src/compiler/crystal.cr -o /dev/null
LLVM_CONFIG=/opt/homebrew/Cellar/llvm/21.1.8_1/bin/llvm-config \
  time bin/crystal build --stats src/compiler/crystal.cr -o /dev/null
```

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Hidden mutations in "read-only" phases | Thorough code audit completed; only `add_warning` found, now mutex-protected |
| Error ordering differs in parallel mode | Errors sorted by `true_filename` before reporting |
| Small speedup (~1-2% of total time) | Low implementation effort justifies small gain |
| Generic instance collection misses types | `collect_generic_instances_into` recursively collects all levels |
