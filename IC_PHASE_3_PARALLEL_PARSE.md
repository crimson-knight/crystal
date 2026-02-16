# Phase 3: Parallel File Parsing

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

```crystal
class Crystal::RequireGraphDiscoverer
  @program : Program
  @discovered = Set(String).new
  @ordered = [] of String

  def discover(initial_nodes : Array(ASTNode)) : Array(String)
    # Scan for Require nodes, resolve paths, recurse
    @ordered
  end
end
```

**Key limitation:** Files discovered during macro expansion (which requires full semantic) will be missed by this scanner. They fall through to sequential parse in `require_file` -- this is expected and handled.

### Step 3.2: Implement parallel_parse_files
**File:** `src/compiler/crystal/compiler.cr`

Follow the `mt_codegen` pattern (line 654-685):

```crystal
private def parallel_parse_files(program, filenames : Array(String)) : Hash(String, ASTNode)
  result = {} of String => ASTNode
  mutex = Mutex.new
  n = {n_threads, filenames.size}.min

  {% if flag?(:preview_mt) %}
    channel = Channel(String).new(n * 2)
    wg = WaitGroup.new
    n.times do
      wg.spawn do
        local_pool = StringPool.new  # NOT thread-safe, needs per-thread
        while filename = channel.receive?
          content = File.read(filename)
          parser = Parser.new(content, local_pool)
          parser.filename = filename
          parser.wants_doc = program.wants_doc?
          parsed = parser.parse
          mutex.synchronize { result[filename] = parsed }
        end
      end
    end
    filenames.each { |f| channel.send(f) }
    channel.close
    wg.wait
  {% else %}
    # Sequential fallback without preview_mt
    filenames.each do |filename|
      content = File.read(filename)
      parser = program.new_parser(content)
      parser.filename = filename
      parser.wants_doc = program.wants_doc?
      result[filename] = parser.parse
    end
  {% end %}

  result
end
```

**Thread safety notes:**
- Each worker gets its own `StringPool` (StringPool is NOT thread-safe)
- `Mutex` protects the shared result hash
- `CrystalPath.find` is read-only filesystem ops, safe from threads
- `WarningCollection` needs per-thread instances, merge after

### Step 3.3: Modify parse() to Use Pre-Parsed Files
**File:** `src/compiler/crystal/compiler.cr` (lines 296-313)

After parsing initial sources and before normalization, discover the require graph and parse files in parallel. Store results on Program.

### Step 3.4: Add pre_parsed_files Property to Program
**File:** `src/compiler/crystal/program.cr`

Add: `property pre_parsed_files : Hash(String, ASTNode)? = nil`

### Step 3.5: Use Pre-Parsed Files in require_file
**File:** `src/compiler/crystal/semantic/semantic_visitor.cr` (line 87)

At the top of `require_file`, before parse cache check:
```crystal
if pre_parsed = @program.pre_parsed_files.try(&.[filename]?)
  parsed_nodes = pre_parsed.clone
  parsed_nodes = @program.normalize(parsed_nodes, inside_exp: inside_exp?)
  parsed_nodes.accept self
  return FileNode.new(parsed_nodes, filename)
end
```

### Step 3.6: Add CRYSTAL_PARALLEL_PARSE Environment Variable
Opt-out: `ENV["CRYSTAL_PARALLEL_PARSE"]? == "0"` disables parallel parsing. Default: enabled when `parallel_codegen?` is true and `n_threads > 1`.

## Files Summary

### New Files
| File | Purpose |
|------|---------|
| `src/compiler/crystal/tools/require_graph_discoverer.cr` | Lightweight require graph scanner |

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/compiler.cr` | Add parallel_parse_files, modify parse() |
| `src/compiler/crystal/program.cr` | Add pre_parsed_files property |
| `src/compiler/crystal/semantic/semantic_visitor.cr` | Check pre_parsed_files in require_file |

## Code Patterns to Follow
- **Parallelism**: `mt_codegen` at `compiler.cr:654-685` (Channel + WaitGroup + Mutex)
- **Per-thread resources**: Each codegen worker gets isolated LLVM context; parsing workers need isolated StringPool
- **Require resolution**: `CrystalPath#find` in `crystal_path.cr`

## Success Criteria
- [ ] `RequireGraphDiscoverer` correctly discovers all require'd files in Crystal's stdlib
- [ ] Parallel parse produces identical ASTs to sequential parse (diff test)
- [ ] `--stats` shows pre-parse hit rate (discovered vs macro-discovered)
- [ ] Benchmark: `CRYSTAL_WORKERS=1` vs `CRYSTAL_WORKERS=8` shows parse phase improvement
- [ ] Files discovered during macro expansion fall through to sequential gracefully
- [ ] No segfaults or data races under `-Dpreview_mt`
- [ ] `CRYSTAL_PARALLEL_PARSE=0` disables parallel parsing
- [ ] WASM target builds still work correctly

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Macro-conditional requires missed by discoverer | Sequential fallback in require_file handles them |
| StringPool thread safety | Per-thread instances (small memory overhead from duplicates) |
| Parse phase is only ~5% of total time | Combined with Phase 2 cache, the effective speedup is on changed files only |
| Flag-conditional requires | Discoverer checks program.flags (static at compile start) |
