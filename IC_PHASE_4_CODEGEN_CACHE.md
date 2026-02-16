# Phase 4: Enhanced Codegen Module Caching

## Objective
Skip LLVM IR generation entirely for modules whose contributing source files haven't changed. The current caching only skips the optimization + object compilation step (by comparing bitcode byte-for-byte), but still generates LLVM IR every time. This phase avoids IR generation altogether for unchanged modules.

## Prerequisites
Phase 2 complete (file fingerprinting provides the change detection mechanism).

## Implementation Steps

### Step 4.1: Track File-to-Module Mapping During Codegen
**File:** `src/compiler/crystal/codegen/codegen.cr`

In `type_module(type)` (in `codegen/fun.cr`), record which source files contribute to each LLVM module.

Add `@module_source_files : Hash(String, Set(String))` to `CodeGenVisitor` mapping module name -> set of source filenames.

When visiting a `Def` node, record `def.location.try(&.filename)` into the appropriate module's source file set.

### Step 4.2: Save Module-File Mapping to Cache
**File:** `src/compiler/crystal/incremental_cache.cr`

Extend `IncrementalCacheData` with:
```crystal
property module_file_mapping : Hash(String, Array(String))? = nil
```

After codegen completes, save the mapping from `CodeGenVisitor#module_source_files`.

### Step 4.3: Skip Unchanged Modules in Codegen
**File:** `src/compiler/crystal/compiler.cr` (in `codegen` method, around `CompilationUnit` creation)

Before generating IR for a compilation unit:
1. Look up the module's contributing source files from cached mapping
2. Check if ALL those files are unchanged (from Phase 2 fingerprints)
3. Check if the cached `.o` file exists
4. If all conditions met: skip IR gen + bitcode + compilation, use cached `.o` directly

### Step 4.4: Handle Class Reopening
A Crystal type can be defined across multiple files (class reopening). The file-to-module mapping must track ALL files that contribute methods to a type, not just the first definition file.

### Step 4.5: Disable for Single-Module Mode
Single-module mode (`--release` or `wasm32` target) puts all types in one module. This optimization cannot help there -- skip gracefully with a check:
```crystal
return if @single_module
```

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/codegen/codegen.cr` | Track file-to-module mapping |
| `src/compiler/crystal/compiler.cr` | Skip unchanged modules, pass cached info |
| `src/compiler/crystal/incremental_cache.cr` | Add ModuleFileMapping to cache data |

## Code Patterns to Follow
- **Compilation unit**: `CompilationUnit` class at `compiler.cr:1069-1228`
- **must_compile?**: `compiler.cr:1140-1158` (current bitcode comparison logic)
- **Module splitting**: `type_module(type)` in `codegen/fun.cr` creates per-type modules
- **Single module check**: `@single_module` property on Compiler

## Success Criteria
- [ ] After full compilation, `module_file_mapping` saved in cache
- [ ] On recompile with 1 file changed, only affected modules regenerate IR
- [ ] `--stats` shows "Modules skipped: N of M (cached)"
- [ ] Output binary is byte-identical to full rebuild
- [ ] Class reopening across files correctly invalidates affected modules
- [ ] Single-module mode (`--release`, `wasm32`) gracefully skips optimization
- [ ] Measurable speedup: ~5-15% reduction in codegen time for small changes

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Missing contributor file (class reopening, macro-generated types) | Conservative: if uncertain, regenerate the module |
| Stale .o file from different compiler version | Cache header check (Phase 2) invalidates on version change |
| Single-module mode can't benefit | Explicit skip with comment explaining why |
