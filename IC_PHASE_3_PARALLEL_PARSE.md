# Phase 3: Parallel File Parsing

## Status: COMPLETE

## Objective
Parse multiple source files concurrently using OS threads to reduce the parse phase time. When combined with the parse cache (Phase 2), files that have changed are parsed in parallel across worker threads.

## Prerequisites
Phase 2 complete (parse cache provides storage for pre-parsed results and the ParseCache integration in `require_file`).

## Implementation Steps

### Step 3.1: Create RequireGraphDiscoverer
**New file:** `src/compiler/crystal/tools/require_graph_discoverer.cr`

A lightweight scanner that discovers all `require`d files WITHOUT doing semantic analysis:

1. Scan parsed AST for `Require` nodes
2. Resolve filenames via `CrystalPath.find` (at `src/compiler/crystal/crystal_path.cr`)
3. Handle `flag?` conditionals (program flags are static, known at compile start)
4. Recursively scan discovered files for their requires
5. Return topological ordering (dependencies before dependents)

**Implementation notes:**
- The discoverer walks the AST using pattern matching on node types (Require, Expressions, MacroIf)
- For `MacroIf` nodes, it evaluates `flag?` conditions statically using `program.has_flag?`
- Supports `!flag?`, `flag? && flag?`, and `flag? || flag?` compound conditions
- Files are parsed with independent `StringPool` instances to avoid thread safety issues
- Uses a `Set(String)` to track discovered files and avoid cycles
- Returns files in topological (dependency-first) order
- Errors during discovery are silently caught; the semantic phase handles them

**Key limitation:** Files discovered during macro expansion (which requires full semantic) will be missed by this scanner. They fall through to sequential parse in `require_file` -- this is expected and handled.

### Step 3.2: Implement parallel_parse_files
**File:** `src/compiler/crystal/compiler.cr`

Follows the `mt_codegen` pattern (Channel + WaitGroup + Mutex under `{% if flag?(:preview_mt) %}`):
- Under `preview_mt`: spawns `n_threads` workers via `WaitGroup.spawn`, each with a dedicated `StringPool`
- Workers receive filenames via `Channel(String)`, parse files, store results under `Mutex`
- Without `preview_mt`: sequential fallback using `program.new_parser`
- Parse errors are silently caught (semantic phase will re-report)

### Step 3.3: Modify parse() to Use Pre-Parsed Files
**File:** `src/compiler/crystal/compiler.cr`

After parsing initial sources and before normalization:
1. Check `parallel_parse?` (respects `CRYSTAL_PARALLEL_PARSE` env var)
2. Create `RequireGraphDiscoverer` and discover files from the initial AST + prelude
3. Parse discovered files via `parallel_parse_files`
4. Store results on `program.pre_parsed_files`
5. Entire block wrapped in begin/rescue for graceful fallback

### Step 3.4: Add pre_parsed_files Property to Program
**File:** `src/compiler/crystal/program.cr`

Added: `property pre_parsed_files : Hash(String, ASTNode)? = nil`

Maps absolute filename to parsed (but not normalized) AST. Consumed by `require_file` during semantic analysis.

### Step 3.5: Use Pre-Parsed Files in require_file
**File:** `src/compiler/crystal/semantic/semantic_visitor.cr`

At the top of `require_file`, before the incremental parse cache check:
- Checks `@program.pre_parsed_files.try(&.[filename]?)`
- If found, clones the AST (MUST clone -- semantic mutates AST in place)
- Normalizes and accepts the cloned nodes
- Wrapped in begin/rescue matching existing error handling patterns

### Step 3.6: Add CRYSTAL_PARALLEL_PARSE Environment Variable
**File:** `src/compiler/crystal/compiler.cr`

Opt-out: `ENV["CRYSTAL_PARALLEL_PARSE"]? == "0"` disables parallel parsing. Default: enabled.

## Files Summary

### New Files
| File | Purpose |
|------|---------|
| `src/compiler/crystal/tools/require_graph_discoverer.cr` | Lightweight require graph scanner |

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/compiler.cr` | Add require, parallel_parse_files, parallel_parse?, modify parse() |
| `src/compiler/crystal/program.cr` | Add pre_parsed_files property |
| `src/compiler/crystal/semantic/semantic_visitor.cr` | Check pre_parsed_files in require_file |

## Code Patterns to Follow
- **Parallelism**: `mt_codegen` at `compiler.cr:654-685` (Channel + WaitGroup + Mutex)
- **Per-thread resources**: Each codegen worker gets isolated LLVM context; parsing workers need isolated StringPool
- **Require resolution**: `CrystalPath#find` in `crystal_path.cr`

## Success Criteria
- [x] `RequireGraphDiscoverer` correctly discovers all require'd files in Crystal's stdlib
- [x] Parallel parse produces identical ASTs to sequential parse (diff test)
- [x] `--stats` shows pre-parse hit rate (discovered vs macro-discovered)
- [x] Benchmark: `CRYSTAL_WORKERS=1` vs `CRYSTAL_WORKERS=8` shows parse phase improvement
- [x] Files discovered during macro expansion fall through to sequential gracefully
- [x] No segfaults or data races under `-Dpreview_mt`
- [x] `CRYSTAL_PARALLEL_PARSE=0` disables parallel parsing
- [x] WASM target builds still work correctly

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Macro-conditional requires missed by discoverer | Sequential fallback in require_file handles them |
| StringPool thread safety | Per-thread instances (small memory overhead from duplicates) |
| Parse phase is only ~5% of total time | Combined with Phase 2 cache, the effective speedup is on changed files only |
| Flag-conditional requires | Discoverer checks program.flags (static at compile start) |
