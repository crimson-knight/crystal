# L1 Experiment: Crystal frontend (parse + semantic + diagnostics) on wasm32-wasi

Status: **SUCCESS — Stages A, B and C all completed.**

A frontend-only Crystal compiler (`src/compiler/frontend_main.cr`, built with
`-Dwithout_llvm`) runs the full prelude semantic analysis of real programs
**inside wasmtime** and emits text/JSON diagnostics. sizeof/alignof/
instance_sizeof/offsetof folding is bit-identical to the LLVM-backed compiler
(21/21 native aarch64 cases, 12/12 wasm32 cases) via a new pure-Crystal ABI
layout engine (`src/compiler/crystal/frontend/type_layout.cr`).

## Numbers

| Metric | Value |
|---|---|
| Native macOS binary | 27 MB, links only pcre2/gc/iconv/libSystem (no LLVM) |
| wasm32-wasi binary (-O0) | 84 MB — rejected by wasmtime ("too many locals", `NumberLiteral#interpret`) |
| wasm32-wasi binary (-O1) | 53 MB — runs |
| wasmtime cold run (cranelift compile) | ~35 s wall (218 s user, cached afterwards) |
| wasmtime warm run, full prelude semantic | **1.39 s wall** (native: ~1.3 s) |
| wasmtime max RSS (warm) | ~590 MB |

## Break-point catalog

### Stage A (native, LLVM severed) — sever points implemented
| # | Site | Classification | Fix |
|---|---|---|---|
| A-sever-1 | `Program#size_of/align_of/instance_*/offset_of` (codegen/codegen.cr) folding via LLVMTyper + LLVMABISizeOfType | llvm-leak (semantic) | New pure-Crystal `Crystal::TypeLayout` mirroring `LLVMTyper#create_llvm_type` incl. MixedUnionType/extern-union/packed rules; `Program` reopened under `-Dwithout_llvm` |
| A-sever-2 | `Program#target_machine` property (program.cr:390), `Program#compiler : Compiler?` (program.cr:168) | llvm-leak | Gated `{% unless flag?(:without_llvm) %}`; `compiler` returns nil |
| A-sever-3 | `Config.host_target` fallback `LLVM.default_target_triple` (config.cr), `LLVM.version` in DESCRIPTION + `Crystal::LLVM_VERSION` constant (program.cr:362) | llvm-leak | `CRYSTAL_CONFIG_TARGET` must be baked; new `Config.llvm_version` baked from `CRYSTAL_CONFIG_LLVM_VERSION` |
| A-sever-4 | `Codegen::Target#initialize` calls `LLVM.normalize_triple` on EVERY target construction (target.cr:17) — missed by recon | llvm-leak | Pure fallback `Target.normalize_triple_without_llvm` (inserts "unknown" vendor) |
| A-sever-5 | `target_machine.cpu` for AVR flags (semantic/flags.cr:107) | llvm-leak | Gated |
| A-sever-6 | `macro run` compiles a program via `Compiler` (macros/macros.cr) | process-dependency | `macro_run` raises under `-Dwithout_llvm` |

### Stage A — breaks hit while building
| # | Break | Classification | Fix |
|---|---|---|---|
| A-1 | **Require-order-dependent overload registration** (host-compiler behavior, both acrystal @6636853e8 AND stock Crystal 1.20.0): requiring `macros/*` before `semantic` mis-orders `MacroInterpreter#visit(Nop \| ... \| TypeNode \| Def)` (interpreter.cr:746) vs the `visit(ASTNode)` catch-all because TypeNode/MacroId live in semantic/ast.cr. Symptom at compile time: "expected argument #1 ... not Crystal::ASTNode" (with the expected list covering every subclass); symptom at RUNTIME: every `flag?(...)` dies with "can't execute SymbolLiteral in a macro". | compiler-dispatch/require-order | Require `semantic` BEFORE `macros/*` (frontend_main.cr). Three residual sites could not be fixed by ordering and carry runtime-unreachable fallbacks in `frontend/patches.cr`: `ASTNode#clone_without_location`, `Transformer#transform(ASTNode)`, `ToSVisitor#visit(ASTNode)` |
| A-2 | `LinkAnnotation`, `CacheDir`, `ExperimentalAnnotation`, `Type#has_inner_pointers?`, `Call#no_returns?`, `Crystal::Formatter` undefined | subset-gap | Require the LLVM-free codegen files: codegen/link, codegen/cache_dir, codegen/experimental, codegen/types, codegen/ast + formatter |
| A-3 | `TypeLayout#offset_of` arg typed `Int32` rejected union of numeric literal types from macro interpreter | own-bug | Untyped param + `.to_i` |
| A-4 | Closured option vars don't flow-narrow (`String \| Nil` into `Target.new`; `Bool \| Nil` when read from method-level rescue) | own-bug | Local copies / inner `analyze` method with begin/rescue |
| A-5 | acrystal wrapper script hard-sets CRYSTAL_PATH | toolchain | Invoke `/opt/homebrew/Cellar/agent-crystal/HEAD-6636853/libexec/agent-crystal-bin` directly |

### Stage B (cross-compile wasm32-wasi)
| # | Break | Classification | Fix |
|---|---|---|---|
| B-1 | `interpret_system` (macro backticks) interpolates `$?` → `Process::Status#to_s` → `#exit_signal? : Signal?` → **undefined constant Signal** on wasm32 | process-dependency | Gate under `flag?(:wasm32)`: raise "macro `system` is not supported on WASI" (macros/methods.cr) — the ONLY source break between native and linking .wasm |
| B-2 | wasm-ld warning: "large number of locals" in `NumberLiteral#interpret` (twice) at -O0 | linker/codegen | Became fatal at run time (C-1); fixed by building `-O1` |

Toolchain used: wasm-ld (LLD 22.1.3, Homebrew), lbguilherme wasm-libs 0.0.3
(sha256 cd36f319..., provides wasi-libc + libgc.a + libpcre2-8.a; downloaded to
`.build/wasm32-wasi-libs`), binaryen 126 (`wasm-opt`/`wasm-merge` — invoked
AUTOMATICALLY by this fork's compiler: asyncify → wasm-merge asyncify_helper →
translate-to-exnref), wasmtime 41.0.3. NO wasi-sdk needed (wasm-libs contains
the sysroot libs; `CRYSTAL_LIBRARY_PATH` is enough).

### Stage C (run under wasmtime)
| # | Break | Classification | Fix |
|---|---|---|---|
| C-1 | `wasmtime: too many locals: locals exceed maximum` compiling function 14219 (`NumberLiteral#interpret`, -O0 build, asyncify multiplies locals) | wasm-limit | Build with `-O1` (LLVM regalloc); binary 84→53 MB and loads |
| C-2 | `wasm-opt -O2 --all-features` post-pass output crashes wasmtime 41 cranelift: "declared type of variable var6 doesn't match type of value" (frontend.rs:509) | toolchain-bug (binaryen×exnref×cranelift) | Avoid post -O2; use -O1 at build instead |
| C-3 | "Please specify a writable cache directory" — `CACHE_DIR` predefined constant computed eagerly in `Program#initialize` | stdlib-gap/env | `--dir cache::/cache --env CRYSTAL_CACHE_DIR=/cache` |
| C-4 | `wasm trap: call stack exhausted` immediately (recursive-descent parser + asyncify overhead vs wasmtime's 512 KB default) | wasm-limit | `-W max-wasm-stack=16777216` |
| C-5 | src/regex/engine.cr probes `pkg-config` via macro backticks when `use_pcre2` undefined → hits B-1's raise | stdlib-gap | Added `-D/--define` to frontend; run with `-Duse_pcre2` |

## Reproduce

```sh
cd crystal-l1-wasm-worktree
ACBIN=/opt/homebrew/Cellar/agent-crystal/HEAD-6636853/libexec/agent-crystal-bin

# Native (no LLVM linked; stock crystal 1.20.0 works too)
CRYSTAL_PATH=$PWD/src CRYSTAL_CONFIG_TARGET=arm64-apple-darwin25.5.0 \
CRYSTAL_CONFIG_PATH=$PWD/src CRYSTAL_CONFIG_LLVM_VERSION=21.1.8 \
LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config LLVM_LDFLAGS=' ' \
crystal build src/compiler/frontend_main.cr -o .build/crystal-frontend -Dwithout_llvm
otool -L .build/crystal-frontend   # pcre2, gc, iconv, libSystem only

# wasm32-wasi (acrystal drives wasm-ld + asyncify pipeline itself)
CRYSTAL_PATH=$PWD/src CRYSTAL_CONFIG_TARGET=wasm32-wasi CRYSTAL_CONFIG_PATH=/src \
CRYSTAL_CONFIG_LLVM_VERSION=21.1.8 CRYSTAL_LIBRARY_PATH=$PWD/.build/wasm32-wasi-libs \
LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config LLVM_VERSION=21.1.8 \
LLVM_TARGETS=WebAssembly LLVM_LDFLAGS=' ' \
$ACBIN build src/compiler/frontend_main.cr -o .build/crystal-frontend-o1.wasm \
  --target wasm32-wasi -O1 -Dwithout_llvm -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib

# Run
wasmtime run -W exceptions=y,max-wasm-stack=16777216 \
  --dir $PWD/src::/src --dir $PWD::/work --dir /tmp::/cache \
  --env CRYSTAL_PATH=/src --env CRYSTAL_CACHE_DIR=/cache \
  .build/crystal-frontend-o1.wasm -Duse_pcre2 [--error-format json] /work/your.cr
```

## Open questions / next steps

- The require-order overload bug (A-1) reproduces on stock Crystal 1.20.0 —
  likely an upstream bug worth a minimal repro + issue.
- wasm-opt -O2 → cranelift panic (C-2) worth reporting to binaryen/wasmtime.
- `patches.cr` fallbacks are runtime-unreachable but mask genuine
  missing-overload errors; re-audit if the subset grows.
- Fibers/`spawn` in analyzed programs are fine (analysis only), but the
  frontend itself must NOT be built with -Dpreview_mt/-Dexecution_context.
- Memory: ~590 MB RSS for prelude-sized analysis; browser targets would want
  a trimmed prelude or lazy require analysis.
