# Phase 5: Parallel Post-Semantic Checks

## Objective
Parallelize read-only semantic sub-phases that iterate types independently. These phases only READ the type graph and can safely run per-type work on separate threads.

## Prerequisites
None strictly, but best implemented after Phases 1-2 for testing infrastructure. Independent of Phases 3-4.

## Implementation Steps

### Step 5.1: Parallelize AbstractDefChecker
**File:** `src/compiler/crystal/semantic/abstract_def_checker.cr`

The current `run` method iterates all types sequentially, calling `check_single(type)` for each. Each check only READS the type graph (verifies that abstract methods declared in parent types are implemented by concrete subtypes).

Partition top-level types across worker threads:

```crystal
def run
  types = collect_types_to_check  # Gather all types first

  {% if flag?(:preview_mt) %}
    wg = WaitGroup.new
    mutex = Mutex.new
    errors = [] of CodeError
    channel = Channel(Type).new(n_workers * 2)

    n_workers.times do
      wg.spawn do
        while type = channel.receive?
          begin
            check_single(type)
          rescue ex : CodeError
            mutex.synchronize { errors << ex }
          end
        end
      end
    end

    types.each { |t| channel.send(t) }
    channel.close
    wg.wait

    raise errors.first unless errors.empty?
  {% else %}
    types.each { |t| check_single(t) }
  {% end %}
end
```

**Thread safety**: `check_single` only reads type hierarchies, method definitions, and restriction information. No mutations occur.

### Step 5.2: Parallelize RecursiveStructChecker
**File:** `src/compiler/crystal/semantic/recursive_struct_checker.cr`

Same pattern as Step 5.1. Each `check_single(type)` is independent and read-only -- it checks whether a struct contains itself (directly or transitively), which would be impossible to represent in memory.

### Step 5.3: Consider RestrictionsAugmenter (Research)
**File:** `src/compiler/crystal/semantic/restrictions_augmenter.cr`

Evaluate whether this phase can also be parallelized. It visits method definitions and augments type restrictions. If it only reads the type graph and writes to per-method local state, it may be safe to parallelize. Requires careful analysis.

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/semantic/abstract_def_checker.cr` | Partition types across worker threads |
| `src/compiler/crystal/semantic/recursive_struct_checker.cr` | Same parallel pattern |

## Code Patterns to Follow
- **Parallelism**: `mt_codegen` at `compiler.cr:654-685` (Channel + WaitGroup + Mutex)
- **Error collection**: Gather errors from workers, raise first one after all complete
- **Conditional compilation**: `{% if flag?(:preview_mt) %}` for MT-only code paths

## Success Criteria
- [ ] AbstractDefChecker produces identical results in parallel vs sequential mode
- [ ] RecursiveStructChecker produces identical results in parallel vs sequential mode
- [ ] No data races under `-Dpreview_mt` (verified with TSAN or manual code review)
- [ ] Full Crystal spec suite passes with parallel checks enabled
- [ ] Compile time improvement measurable on large codebases (Crystal self-compilation)
- [ ] Error messages are identical regardless of parallel/sequential execution

## Testing Instructions
```bash
# Compile with parallel checks (requires preview_mt)
bin/crystal build --stats -Dpreview_mt hello.cr

# Compare output with sequential
bin/crystal build --stats hello.cr

# Self-compilation test
time bin/crystal build --stats -Dpreview_mt src/compiler/crystal.cr -o /dev/null
time bin/crystal build --stats src/compiler/crystal.cr -o /dev/null
```

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Hidden mutations in "read-only" phases | Careful code audit before parallelizing |
| Error ordering differs in parallel mode | Sort errors by location before reporting |
| Small speedup (~1-2% of total time) | Low implementation effort justifies small gain |
