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
  kind : String,  # "class", "struct", "module", "enum", "lib"
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

### Step 6.2: Extract Signatures After TopLevelVisitor
**File:** `src/compiler/crystal/semantic/top_level_visitor.cr`

After `TopLevelVisitor` completes, extract `FileTopLevelSignature` for each file by walking the types and methods that were registered, tagged by their source location filename.

### Step 6.3: Compare Signatures for Changed Files
**File:** `src/compiler/crystal/incremental_cache.cr`

When a file has changed content but its `FileTopLevelSignature` is identical to the cached version, mark it as "body-only change." This means:
- The file itself needs re-processing (method bodies changed)
- But dependent files do NOT need re-processing (interface unchanged)

### Step 6.4: Use Signature Information in Semantic Phases
**File:** `src/compiler/crystal/semantic.cr`

For files marked as "body-only change," skip `TypeDeclarationProcessor` re-processing of unchanged types from those files.

**Critical caveat:** Files with `has_top_level_macro_calls == true` must ALWAYS be fully re-processed. Macros can generate arbitrary types and methods.

## Files Summary

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/crystal/incremental_cache.cr` | Add signature records and comparison |
| `src/compiler/crystal/semantic/top_level_visitor.cr` | Extract signatures |
| `src/compiler/crystal/semantic.cr` | Use signature info for selective re-processing |

## Success Criteria
- [ ] Signature extraction captures all structurally-significant information
- [ ] Body-only changes (modifying a method body without changing args/return type) produce identical signatures
- [ ] Type/method signature changes (adding an arg, changing return type) produce different signatures
- [ ] Files with top-level macro calls always marked as "must re-process"
- [ ] ~10-20% speedup for body-only changes in watch mode
- [ ] No incorrect compilation results (conservative: if uncertain, full re-process)

## Risks and Mitigations
| Risk | Mitigation |
|------|------------|
| Missing structurally-significant information in signature | Conservative: include more info than needed; false positive (unnecessary recompile) is safe |
| Macro calls can generate anything | Files with macros always fully re-processed |
| Cross-file type dependencies missed | Track reverse dependency graph from Phase 2 |
| High implementation complexity | Start with conservative invalidation, tighten incrementally |
