# Crystal Incremental Compilation & Parallelization

## Status Dashboard

| Phase | Status | Description |
|-------|--------|-------------|
| [Phase 0: Documentation](IC_PHASE_0_DOCS.md) | [ ] In Progress | Project docs, Obsidian canvas, phase articles |
| [Phase 1: Watch Command](IC_PHASE_1_WATCH.md) | [x] Complete | `crystal watch` with cross-platform file watching |
| [Phase 2: Cache Foundation](IC_PHASE_2_CACHE.md) | [x] Complete | File fingerprinting + in-memory parse cache |
| [Phase 3: Parallel Parsing](IC_PHASE_3_PARALLEL_PARSE.md) | [x] Complete | Multi-threaded file parsing |
| [Phase 4: Codegen Caching](IC_PHASE_4_CODEGEN_CACHE.md) | [ ] Not Started | Skip LLVM IR for unchanged modules |
| [Phase 5: Parallel Checks](IC_PHASE_5_PARALLEL_CHECKS.md) | [ ] Not Started | Parallelize read-only semantic sub-phases |
| [Phase 6: Signature Tracking](IC_PHASE_6_SIGNATURES.md) | [ ] Not Started | Skip semantic for body-only changes |
| [Phase 7: Semantic Parallelism](IC_PHASE_7_SEMANTIC.md) | [ ] Not Started | Parallelize MainVisitor type inference |

## Architecture Overview

### Current 14-Stage Pipeline (All Sequential Except Codegen BC+OBJ)

```
                          SEMANTIC (9 sub-phases, ~60-70% of time)
                    ┌──────────────────────────────────────────────┐
                    │                                              │
 ┌───────┐  ┌──────┴──┐  ┌─────┐  ┌──────────┐  ┌────────────┐  │  ┌──────────┐  ┌──────────┐  ┌─────────┐
 │ Parse  │→│ TopLevel │→│ New │→│ TypeDecls │→│ AbstractChk │──┤  │CodegenIR │→│CodegenBC │→│ Linking │
 │        │  │          │  │     │  │          │  │            │  │  │          │  │ (parallel)│  │         │
 └───────┘  └──────────┘  └─────┘  └──────────┘  └────────────┘  │  └──────────┘  └──────────┘  └─────────┘
                                                                   │
             ┌──────────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌───────┤
             │Restrict  │→│IVars │→│CVars │→│ Main  │→│Cleanup│
             │Augmenter │  │ Init │  │ Init │  │Visitor│  │       │
             └──────────┘  └──────┘  └──────┘  └──────┘  └───────┘
                                                  ▲
                                             BOTTLENECK
                                          (~40-50% alone)
```

### Target Pipeline (After All Phases)

```
 ┌────────────┐   ┌──────────────────┐   ┌──────────────────┐   ┌────────────┐
 │ Parse      │   │ Semantic         │   │ Codegen          │   │ Linking    │
 │ (parallel) │ → │ (cached sigs,    │ → │ (skip unchanged  │ → │            │
 │ (cached)   │   │  parallel checks)│   │  modules, cached)│   │            │
 └────────────┘   └──────────────────┘   └──────────────────┘   └────────────┘
       ▲                   ▲                      ▲
    Phase 3             Phase 5,6              Phase 4
    Phase 2             Phase 7                Phase 2
```

## Phase Dependencies

```
Phase 0 ──→ Phase 1 ──→ Phase 2 ──┬──→ Phase 3
                                   ├──→ Phase 4
                                   └──→ Phase 6

Phase 5 (independent, can start anytime)

Phase 7 (research, after all above understood)
```

## Expected Speedups

| Phase | Watch Mode (warm) | Cold Build | Effort |
|-------|-------------------|------------|--------|
| 1: Watch command | New feature | N/A | 2-3 weeks |
| 2: Parse cache | ~3-5% | ~0% (infra) | 1-2 weeks |
| 3: Parallel parsing | ~5-10% | ~5-10% | 2-3 weeks |
| 4: Codegen cache | ~5-15% | ~0% | 2-3 weeks |
| 5: Parallel checks | ~1-2% | ~1-2% | 1 week |
| 6: Signatures | ~10-20% | ~0% | 3-4 weeks |
| 7: Semantic | ~40-50% | ~40-50% | 3-6 months |

**Phases 1-5 combined**: ~15-30% faster recompilation in watch mode.
**With Phase 6**: ~25-45% faster for body-only changes.

## Key Files Reference

| File | Role |
|------|------|
| `src/compiler/crystal/compiler.cr` | Main compile pipeline, codegen parallelism (1230 lines) |
| `src/compiler/crystal/command.cr` | CLI dispatcher, command registration (~500 lines) |
| `src/compiler/crystal/program.cr` | Central type graph, requires tracking (~600 lines) |
| `src/compiler/crystal/semantic.cr` | Semantic phase orchestration (103 lines) |
| `src/compiler/crystal/semantic/semantic_visitor.cr` | Base visitor, `require_file` at line 87 |
| `src/compiler/crystal/semantic/main_visitor.cr` | Type inference bottleneck (~4000 lines) |
| `src/compiler/crystal/codegen/codegen.cr` | LLVM IR generation (~3000 lines) |
| `src/compiler/crystal/codegen/cache_dir.cr` | Cache directory management (135 lines) |
| `src/compiler/crystal/crystal_path.cr` | Require path resolution (~200 lines) |
| `src/compiler/crystal/macros/macros.cr` | RequireWithTimestamp pattern (line 80+) |
| `src/compiler/crystal/progress_tracker.cr` | Stage timing and progress (73 lines) |
| `src/compiler/crystal/syntax/ast.cr` | AST definitions, ASTNode#clone (~3000 lines) |
| `src/lib_c/aarch64-darwin/c/sys/event.cr` | kqueue constants (needs VNODE additions) |
| `src/crystal/system/unix/kqueue.cr` | Existing kqueue wrapper to reuse |

## Quick Reference

### Build Commands
```bash
# Build the compiler
make crystal

# Run compiler specs
make compiler_spec

# Build a WASM target
CRYSTAL_LIBRARY_PATH=/tmp/wasm32-wasi-libs bin/crystal build foo.cr \
  -o foo.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl

# Run WASM binary
~/.wasmtime/bin/wasmtime run --wasm exceptions foo.wasm

# Self-compilation benchmark
time bin/crystal build src/compiler/crystal.cr --stats -o /dev/null
```

### Environment Variables
| Variable | Purpose |
|----------|---------|
| `CRYSTAL_WORKERS` | Number of codegen threads (default: 8) |
| `CRYSTAL_CACHE_DIR` | Override cache directory location |
| `CRYSTAL_LIBRARY_PATH` | Library search path (needed for WASM) |
| `CRYSTAL_PARALLEL_PARSE` | Set to `0` to disable parallel parsing (Phase 3) |

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-16 | Start with watch command before caching | Provides the recompilation loop needed to test all subsequent phases |
| 2026-02-16 | Use polling as fallback, kqueue/inotify as native | Cross-platform support with best available performance per OS |
| 2026-02-16 | In-memory parse cache, not disk serialization | Parse is ~5% of time; serializing 100+ AST node types has poor ROI |
| 2026-02-16 | Program always created fresh (no reuse) | No reset mechanism exists; adding one is prohibitively complex |
| 2026-02-16 | JSON for cache metadata, not binary | Debuggable, matches existing RequireWithTimestamp/RecordedRequire patterns |
| 2026-02-16 | Phase 7 (semantic parallelism) is research-grade | MainVisitor has deep shared mutable state; requires fundamental redesign |

## Benchmarks

*Record measurements here as phases are implemented.*

| Measurement | Baseline | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 |
|-------------|----------|---------|---------|---------|---------|---------|
| Self-compile (cold) | TBD | - | TBD | TBD | TBD | TBD |
| Self-compile (warm) | TBD | - | TBD | TBD | TBD | TBD |
| Parse phase | TBD | - | TBD | TBD | - | - |
| Codegen phase | TBD | - | - | - | TBD | - |
| Memory usage | TBD | - | TBD | TBD | - | - |
