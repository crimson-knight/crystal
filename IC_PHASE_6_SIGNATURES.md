# Phase 6: Top-Level Signature Tracking

## Objective
When only method bodies change (not type or method signatures), skip re-running some semantic work for dependent files. This is the most common case during development: editing a method body without changing its interface.

## Prerequisites
Phase 2 complete (cache infrastructure for storing and comparing signatures).

## Implementation Steps

### Step 6.1: Define FileTopLevelSignature
**Add to:** `src/compiler/crystal/incremental_cache.cr`

Extract a structural signature per file that captures everything TopLevelVisitor produces:

```crystal
record TypeDeclarationSig,
  name : String,
  kind : String,  # "class", "struct", "module", "enum", "lib", "alias", "annotation"
  parent : String?,
  generic_params : Array(String) do
  include JSON::Serializable
end

record MethodSig,
  name : String,
  arg_names : Array(String),
  arg_restrictions : Array(String?),
  return_restriction : String?,
  is_abstract : Bool do
  include JSON::Serializable
end

record FileTopLevelSignature,
  type_declarations : Array(TypeDeclarationSig),
  method_signatures : Array(MethodSig),
  mixins : Array(String),  # include/extend statements
  constants : Array(String),
  has_top_level_macro_calls : Bool do
  include JSON::Serializable
end
```

### Step 6.2: Extract Signatures via AST Visitor
**File:** `src/compiler/crystal/incremental_cache.cr`

A `SignatureExtractor` visitor walks the parsed AST of each required file and collects:
- **Type declarations**: ClassDef, ModuleDef, EnumDef, LibDef, Alias, AnnotationDef
- **Method signatures**: Def (name, arg names, restrictions, return type, abstract flag), Macro, FunDef
- **Mixins**: Include and Extend statements
- **Constants**: Top-level constant assignments (Assign with Path target)
- **Macro calls**: Call nodes at top level, MacroExpression, MacroIf, MacroFor

The extractor operates on the original parsed AST (before semantic mutation), keeping extraction independent from the semantic pass. Each file is parsed individually and its signature extracted.

### Step 6.3: Compare Signatures for Changed Files
**File:** `src/compiler/crystal/incremental_cache.cr`

When a file has changed content but its `FileTopLevelSignature` is identical to the cached version, mark it as "body-only change." This means:
- The file itself needs re-processing (method bodies changed)
- But dependent files do NOT need re-processing (interface unchanged)

The `IncrementalCache.classify_changes` method takes the set of changed files, old signatures (from cache), and new signatures (freshly extracted), returning two sets: body-only files and structural files.

### Step 6.4: Integration and Reporting
**File:** `src/compiler/crystal/compiler.cr`

After semantic analysis completes (and before cache save):
1. Extract signatures for all required files via `extract_file_signatures`
2. Load cached signatures from disk
3. Compute changed files (stat-based)
4. Classify changes via `classify_changes`
5. Save new signatures to the incremental cache
6. Report via `--stats`: body-only and structural change counts

**Note:** This phase tracks and reports signature information only. The actual semantic optimization (skipping dependent file reprocessing for body-only changes) is deferred to a future iteration. Tracking alone validates correctness and provides data about change patterns.

**Critical caveat:** Files with `has_top_level_macro_calls == true` always count as structural changes. Macros can generate arbitrary types and methods.

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/incremental_cache.cr` | Add signature records, SignatureExtractor visitor, comparison logic |
| `src/compiler/crystal/compiler.cr` | Integrate signature extraction, comparison, cache persistence, stats reporting |

## Success Criteria
- [x] Signature extraction captures all structurally-significant information
- [x] Body-only changes (modifying a method body without changing args/return type) produce identical signatures
- [x] Type/method signature changes (adding an arg, changing return type) produce different signatures
- [x] Files with top-level macro calls always marked as "must re-process"
- [ ] ~10-20% speedup for body-only changes in watch mode (deferred: requires semantic skip logic)
- [x] No incorrect compilation results (conservative: if uncertain, full re-process)

## Implementation Notes

### Design Decisions
- **AST visitor approach over type graph iteration**: The SignatureExtractor walks the parsed AST rather than the program's type graph. This keeps signature extraction independent from semantic analysis and operates on the original, unmutated AST.
- **Per-file parsing for extraction**: Each required file is parsed independently for signature extraction. This runs after the main compilation succeeds, so parse errors are silently skipped (best-effort).
- **Conservative macro handling**: Any file with a top-level Call, MacroExpression, MacroIf, or MacroFor is marked as having top-level macro calls and always classified as a structural change.
- **Tracking only, no semantic skip**: Phase 6 tracks and reports body-only vs structural changes but does not yet skip semantic work. This validates correctness before adding optimization.
- **Backwards-compatible cache format**: The `file_signatures` field uses `@[JSON::Field(emit_null: false)]` so old caches without signatures are still valid.

### Signature Components
| Component | AST Nodes | What's Captured |
|-----------|-----------|-----------------|
| Type declarations | ClassDef, ModuleDef, EnumDef, LibDef, Alias, AnnotationDef | Name, kind, parent/superclass, generic params |
| Method signatures | Def, Macro, FunDef | Name, arg names, arg restrictions, return type, abstract flag |
| Mixins | Include, Extend | "include Foo" / "extend Bar" as strings |
| Constants | Assign (Path target) | Fully-qualified constant name |
| Macro calls | Call, MacroExpression, MacroIf, MacroFor | Boolean flag per file |

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Missing structurally-significant information in signature | Conservative: include more info than needed; false positive (unnecessary recompile) is safe |
| Macro calls can generate anything | Files with macros always fully re-processed |
| Cross-file type dependencies missed | Track reverse dependency graph from Phase 2 |
| High implementation complexity | Start with conservative invalidation, tighten incrementally |
| Signature extraction adds overhead | Runs after compilation; best-effort; skips failures |
