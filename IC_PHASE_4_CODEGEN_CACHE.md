# Phase 4: Enhanced Codegen Module Caching

## Objective
Skip LLVM IR generation entirely for modules whose contributing source files haven't changed. The current caching only skips the optimization + object compilation step (by comparing bitcode byte-for-byte), but still generates LLVM IR every time. This phase avoids IR generation altogether for unchanged modules.

## Prerequisites
Phase 2 complete (file fingerprinting provides the change detection mechanism).

## Implementation Steps

### Step 4.1: Track File-to-Module Mapping During Codegen
**File:** `src/compiler/crystal/codegen/codegen.cr` and `src/compiler/crystal/codegen/fun.cr`

Added `@module_source_files : Hash(String, Set(String))` getter to `CodeGenVisitor` mapping module name to set of source filenames.

In `codegen_fun` (in `codegen/fun.cr`), when generating code for a function definition, record `target_def.location.filename` into the appropriate module's source file set. The module name is derived from `self_type` using the same logic as `type_module(type)`: Nil/Program/LibType map to `""`, all others use `type.instance_type.to_s`.

Tracking is skipped in single-module mode since module-level caching doesn't apply there.

### Step 4.2: Save Module-File Mapping to Cache
**File:** `src/compiler/crystal/incremental_cache.cr`

Changed `IncrementalCacheData` from a `record` to a `class` with `JSON::Serializable` to support an optional field:
```crystal
getter module_file_mapping : Hash(String, Array(String))? = nil
```

The optional `module_file_mapping` field is nil-safe for backwards compatibility with older cache files. Uses `@[JSON::Field(emit_null: false)]` to omit the field from JSON when nil.

After codegen completes, the compiler converts `CodeGenVisitor#module_source_files` (which uses `Set(String)`) to sorted `Array(String)` for deterministic JSON serialization, then saves it via `IncrementalCache.save`.

### Step 4.3: Skip Unchanged Modules in Codegen
**File:** `src/compiler/crystal/compiler.cr` (in `codegen` method)

Before creating CompilationUnit instances:
1. Load cached `IncrementalCacheData` (only in multi-module + incremental mode)
2. Extract `module_file_mapping` from cached data
3. Compute changed files using `IncrementalCache.changed_files` from Phase 2

For each module/CompilationUnit:
1. Look up the module's contributing source files from cached mapping
2. Check if ALL those files are unchanged (not in the changed_files set)
3. Check if the cached `.o` file exists and is non-empty
4. Check that bc flags haven't changed
5. If all conditions met: mark the unit as `skipped_via_module_cache`

`CompilationUnit#compile` checks `@skipped_via_module_cache` first and returns early (setting `reused_previous_compilation = true`), completely bypassing IR generation, bitcode creation, and object compilation.

`CompilationUnit#generate_bitcode` also returns `nil` early for skipped modules, preventing any LLVM operations on the module.

### Step 4.4: Handle Class Reopening
The file-to-module mapping naturally handles class reopening because it tracks at the `codegen_fun` level: every time a method is codegen'd for a type, the method's source file location is added to that type's module source file set. If `class Foo` is defined in `a.cr` with method `bar` and reopened in `b.cr` with method `baz`, the module for `Foo` will have both `a.cr` and `b.cr` in its source file set. Changing either file will invalidate the module.

### Step 4.5: Disable for Single-Module Mode
Single-module mode (`--release`, `wasm32` target, `--cross-compile`, or `--emit`) puts all types in one module. The optimization is disabled in two places:

1. **Tracking**: `codegen_fun` skips recording to `@module_source_files` when `@single_module` is true
2. **Skip logic**: The module skip check in `compiler.cr` is gated on `!is_single_module`
3. **Cache saving**: `@last_module_source_files` is only set in multi-module mode

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/codegen/codegen.cr` | Added `module_source_files` getter; `program.codegen` returns tuple with mapping |
| `src/compiler/crystal/codegen/fun.cr` | Track source file per module in `codegen_fun` |
| `src/compiler/crystal/compiler.cr` | Skip unchanged modules, stats output, save mapping to cache |
| `src/compiler/crystal/incremental_cache.cr` | Add `module_file_mapping` to `IncrementalCacheData` |

## Code Patterns to Follow
- **Compilation unit**: `CompilationUnit` class at `compiler.cr:~1286+`
- **must_compile?**: `compiler.cr:~1391+` (current bitcode comparison logic)
- **Module splitting**: `type_module(type)` in `codegen/fun.cr` creates per-type modules
- **Single module check**: `@single_module` property on Compiler

## Success Criteria
- [x] After full compilation, `module_file_mapping` saved in cache
- [x] On recompile with 1 file changed, only affected modules regenerate IR
- [x] `--stats` shows "Modules skipped: N of M (cached)"
- [x] Output binary is byte-identical to full rebuild
- [x] Class reopening across files correctly invalidates affected modules
- [x] Single-module mode (`--release`, `wasm32`) gracefully skips optimization
- [ ] Measurable speedup: ~5-15% reduction in codegen time for small changes (needs benchmarking)

## Implementation Notes

### Conservative approach
If any of these conditions are true, the module is NOT skipped:
- No cached data exists (first compilation, or cache invalidated by version/target/flags change)
- The module has no entry in the cached `module_file_mapping` (new type added)
- Any contributing source file is in the changed set (new, modified, or removed)
- The cached `.o` file doesn't exist or is empty
- Build flags (bc_flags) changed since last compilation
- Single-module mode is active

### Compatibility
The `IncrementalCacheData` was changed from a `record` to a `class` to support the optional `module_file_mapping` field. Old cache files without this field will deserialize with `module_file_mapping = nil`, which disables the module skip optimization gracefully (no skip, full rebuild, then the new mapping is saved).

### Stats output
When `--stats` is passed and modules were skipped, the output includes:
```
Codegen (bc+obj):
 - N/M .o files were reused
 - Modules skipped: K of M (cached)
```

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Missing contributor file (class reopening, macro-generated types) | Conservative: if uncertain (no mapping entry), regenerate the module |
| Stale .o file from different compiler version | Cache header check (Phase 2) invalidates on version change |
| Single-module mode can't benefit | Explicit skip with comment explaining why |
| Old cache format without module_file_mapping | Nil-safe: gracefully degrades to full rebuild |
