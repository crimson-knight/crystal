# Phase 2: Incremental Compilation Cache Foundation

## Objective
Track file fingerprints across compilations and cache parsed ASTs in memory for the watch loop, so unchanged files aren't re-parsed. This provides the infrastructure that Phases 3, 4, and 6 all build upon.

## Prerequisites
Phase 1 complete (watch command provides the recompilation loop for testing).

## Implementation Steps

### Step 2.1: Create IncrementalCache Module
**New file:** `src/compiler/crystal/incremental_cache.cr`

Define JSON-serializable records following the `RequireWithTimestamp` pattern from `src/compiler/crystal/macros/macros.cr:80+`:

```crystal
module Crystal
  record FileFingerprint,
    filename : String,
    mtime_epoch : Int64,
    content_hash : String,
    byte_size : Int64 do
    include JSON::Serializable
  end

  record IncrementalCacheData,
    compiler_version : String,
    codegen_target : String,
    flags : Array(String),
    prelude : String,
    file_fingerprints : Hash(String, FileFingerprint) do
    include JSON::Serializable
  end
end
```

Add `IncrementalCache` class with:
- `def self.load(cache_dir : String) : IncrementalCacheData?` -- load from JSON, nil if missing/corrupt/version mismatch
- `def self.save(cache_dir : String, data : IncrementalCacheData)` -- write JSON
- `def self.fingerprint(filename : String) : FileFingerprint` -- compute using `File.info` + `Crystal::Digest::MD5`
- `def self.changed_files(old_data : IncrementalCacheData, current_files : Set(String)) : Set(String)` -- compare fingerprints
- Cache file location: `{cache_dir}/incremental_cache.json`

### Step 2.2: Create ParseCache Class
**Add to:** `src/compiler/crystal/incremental_cache.cr`

```crystal
module Crystal
  class ParseCache
    @cache = {} of String => {content_hash: String, ast: ASTNode}

    def get(filename : String, current_content_hash : String) : ASTNode?
      entry = @cache[filename]?
      return nil unless entry
      return nil unless entry[:content_hash] == current_content_hash
      entry[:ast].clone  # MUST clone - semantic mutates AST nodes in place
    end

    def store(filename : String, content_hash : String, ast : ASTNode) : Nil
      @cache[filename] = {content_hash: content_hash, ast: ast}
    end

    def clear : Nil
      @cache.clear
    end

    def size : Int32
      @cache.size
    end
  end
end
```

**Critical note:** AST nodes MUST be cloned before reuse because semantic analysis mutates them in place (sets types, expands macros, binds nodes). `ASTNode#clone` at `src/compiler/crystal/syntax/ast.cr:44-49` performs deep copy with location preservation.

### Step 2.3: Add ParseCache Property to Compiler
**File:** `src/compiler/crystal/compiler.cr` (around line 50, near other properties)

Add: `property parse_cache : ParseCache = ParseCache.new`

This lives on the `Compiler` instance so it survives between `compile` calls in watch mode. The Compiler is reused but Program is created fresh each time (line 277-294).

### Step 2.4: Integrate Parse Cache into require_file
**File:** `src/compiler/crystal/semantic/semantic_visitor.cr` (lines 87-104)

Modify the `require_file` method to check parse cache before reading/parsing:

```crystal
private def require_file(node : Require, filename : String)
  if parse_cache = @program.compiler.try(&.parse_cache)
    content = File.read(filename)
    content_hash = Crystal::Digest::MD5.hexdigest(content)

    if cached_ast = parse_cache.get(filename, content_hash)
      parsed_nodes = @program.normalize(cached_ast, inside_exp: inside_exp?)
      parsed_nodes.accept self
      return FileNode.new(parsed_nodes, filename)
    end

    # Cache miss - parse and store
    parser = @program.new_parser(content)
    parser.filename = filename
    parser.wants_doc = @program.wants_doc?
    parsed_nodes = parser.parse
    parse_cache.store(filename, content_hash, parsed_nodes.clone)
    parsed_nodes = @program.normalize(parsed_nodes, inside_exp: inside_exp?)
    parsed_nodes.accept self
  else
    # Original code path
    parser = @program.new_parser(File.read(filename))
    parser.filename = filename
    parser.wants_doc = @program.wants_doc?
    parsed_nodes = parser.parse
    parsed_nodes = @program.normalize(parsed_nodes, inside_exp: inside_exp?)
    parsed_nodes.accept self
  end
  FileNode.new(parsed_nodes, filename)
rescue ex : CodeError
  node.raise "while requiring \"#{node.string}\"", ex
rescue ex
  raise Error.new "while requiring \"#{node.string}\"", ex
end
```

### Step 2.5: Integrate Fingerprint Cache into Compile Pipeline
**File:** `src/compiler/crystal/compiler.cr` (around `compile_configure_program` at line 224)

After successful compilation (after line 242), save fingerprints:
```crystal
save_incremental_cache(program) unless @no_codegen
```

Add private method to compute and save cache data from `program.requires`.

### Step 2.6: Add --incremental Flag
- `src/compiler/crystal/compiler.cr` -- add `property? incremental = false`
- `src/compiler/crystal/command.cr` (in `setup_simple_compiler_options`) -- add `--incremental` option
- `src/compiler/crystal/tools/watch/watcher.cr` -- enable incremental by default in watch mode

### Step 2.7: Add Stats Output for Cache Hits
When `--stats` is enabled, print after compilation:
```
Parse cache:                      hits: 127, misses: 3 (97.7%)
Files changed:                    3 of 130
```

## Files Summary

### New Files
| File | Purpose |
|------|---------|
| `src/compiler/crystal/incremental_cache.cr` | IncrementalCache, FileFingerprint, ParseCache |

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/compiler.cr` | Add parse_cache property, save_incremental_cache, --incremental |
| `src/compiler/crystal/semantic/semantic_visitor.cr` | Check parse cache in require_file |
| `src/compiler/crystal/command.cr` | Add --incremental option |

## Code Patterns to Follow
- **JSON serialization**: `RequireWithTimestamp` in `macros.cr:80+` (proven file fingerprint pattern)
- **Cache directory**: `CacheDir` in `codegen/cache_dir.cr` (singleton, directory_for, LRU cleanup)
- **MD5 hashing**: `Crystal::Digest::MD5` already imported in `compiler.cr:4`
- **AST cloning**: `ASTNode#clone` at `syntax/ast.cr:44-49`

## Success Criteria
- [ ] After first compilation with `--incremental`, `incremental_cache.json` exists in cache directory
- [ ] Cache JSON contains correct compiler version, target, flags, and per-file fingerprints
- [ ] On second compilation with no changes, parse cache hits 100% (visible via `--stats`)
- [ ] Modifying one file shows 1 cache miss, all others hit (via `--stats`)
- [ ] Changing compiler flags invalidates entire cache (version/flags mismatch)
- [ ] In watch mode, second recompilation is measurably faster (parse phase shorter)
- [ ] `ASTNode#clone` correctly deep-copies nodes (semantic doesn't corrupt cache)
- [ ] Parse cache memory usage is reasonable (< 2x single compilation memory)

## Testing Instructions
```bash
# First compile - establishes cache
bin/crystal build --incremental --stats hello.cr

# Second compile - should show 100% cache hits
bin/crystal build --incremental --stats hello.cr

# Modify one file and recompile
echo '# changed' >> hello.cr
bin/crystal build --incremental --stats hello.cr
# Should show: Parse cache: hits: N-1, misses: 1

# Watch mode (incremental is automatic)
bin/crystal watch --stats hello.cr
# Edit file, observe faster recompile on parse phase
```

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| AST clone is not deep enough | Verify with test: modify cached node, check original unchanged |
| MD5 collision (different content, same hash) | Astronomically unlikely; also check mtime+size first |
| Cache grows unbounded in memory | ParseCache only keeps latest AST per file; GC handles old clones |
| Stale cache after compiler upgrade | Header includes compiler_version; mismatch triggers full invalidation |
