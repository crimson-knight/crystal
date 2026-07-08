# C-4 Fix — Implementation Notes

**Branch:** `c4-asyncify-fix` (from `l1-frontend-wasm-experiment`)
**Implementer:** C-4 implementation agent, 2026-07-07
**Design:** `docs_c4_design.md` (this repo)
**Result:** ✅ **PASS** — the frontend wasm module that previously trapped
`RangeError: Maximum call stack size exceeded` now runs the full prelude
semantic analysis in **headless Chrome 149 at the default engine stack** (no
`--js-flags=--stack-size`), emits the correct JSON diagnostic, and degrades
gracefully on pathological nesting.

---

## 1. What was implemented

**Layer 1 (de-asyncify the frontend)** and **Layer 3 (graceful parser depth
guard)** from the design. Layer 2 (semantic work-stack) was **not needed**: the
min-`max-wasm-stack` measurement (§5) shows Layer 1 alone brings the prelude to
~128 KB, ~8× under the ~1 MB browser budget.

All Layer-1 source changes are gated behind a new build flag
**`-Dfrontend_no_fibers`**, so non-frontend wasm builds are byte-for-byte
unaffected.

### Source patches (5 files, all on `c4-asyncify-fix`)

| File | Change |
|---|---|
| `src/crystal/system/wasi/main.cr` | Under `{% if flag?(:frontend_no_fibers) %}`: a fiber-free classic WASI `_start` (`__wasm_call_ctors → status = __main_void → __wasm_call_dtors → proc_exit(status) if status != 0`) that references **no** asyncify symbol. The existing asyncify `_start` moves to the `{% else %}` branch. |
| `src/fiber/context/wasm32.cr` | Under the flag: **no** `require "crystal/asyncify"`; `init_main_fiber_asyncify` becomes a no-op; `makecontext` a minimal stub (records `stack_top`, `resumable=1`); `Fiber.swapcontext` a loud abort stub (`LibC.write` to fd 2 + `LibC.exit(1)`). Zero `LibAsyncify`/`Crystal::Asyncify` references in this branch. |
| `src/crystal/asyncify.cr` | `{% skip_file if flag?(:frontend_no_fibers) %}` at top — compiles to nothing, so no `LibAsyncify`/`LibCrystalAsyncify` import/export survives. |
| `src/compiler/crystal/compiler.cr` | `run_wasm_opt` gains a `skip_fibers` param; when the **target** program has the flag it skips the `--asyncify` pass **and** the `asyncify_helper.wasm` merge, running only `--translate-to-exnref`. The check is a runtime `program.has_flag?("frontend_no_fibers")` at the call site (NOT a compiler-binary macro flag). |
| `src/compiler/crystal/syntax/parser.cr` | Layer-3 guard: `MAX_EXPRESSION_NESTING = 128`, an `@expression_nesting` counter incremented/decremented around `parse_expression` (the per-nesting-level chokepoint — each parenthesized sub-expression re-enters it once), raising a `Crystal::SyntaxException` (`"expression nesting too deep (exceeds 128)"`) before deep recursion can trap the engine. |

---

## 2. Build path (Option B — Codex-advised)

`$ACBIN` (`/opt/homebrew/Cellar/agent-crystal/HEAD-6636853/libexec/agent-crystal-bin`)
is a **prebuilt** compiler, so the `compiler.cr` patch (step d) cannot take
effect through it. Codex (xhigh) confirmed that Option A (rebuild the whole
compiler) and Option B (use `$ACBIN --cross-compile` to emit the `.o` + printed
`wasm-ld` command, then run `wasm-ld` and `wasm-opt --translate-to-exnref`
manually) produce an **equivalent artifact**, because the `compiler.cr` patch
only changes post-link orchestration — not codegen. Option B was chosen: one
codegen build, no LLVM-version-skew risk, and it still picks up the *source*
patches (main.cr/wasm32.cr/asyncify.cr/parser.cr) because `$ACBIN` recompiles
`src/` from `CRYSTAL_PATH`. The `compiler.cr` patch is committed for correctness
and future full builds (it reproduces exactly what Option B does by hand).

Codex advisory doc: consulted via
`codex exec -s read-only -c model_reasoning_effort=xhigh`. Key notes folded in:
use `-o …/frontend.o` (not `.wasm`) for `--cross-compile`; runtime
`program.has_flag?` check in `compiler.cr`; `--translate-to-exnref` directly on
the linked legacy-EH module is the correct order when asyncify is absent; verify
zero asyncify residue in the final module.

### Shared build env

```sh
export CRYST=/Users/crimsonknight/open_source_coding_projects/crystal
export ACBIN=/opt/homebrew/Cellar/agent-crystal/HEAD-6636853/libexec/agent-crystal-bin
cd "$CRYST"
export CRYSTAL_PATH="$CRYST/src" CRYSTAL_CONFIG_TARGET=wasm32-wasi CRYSTAL_CONFIG_PATH=/src
export CRYSTAL_CONFIG_LLVM_VERSION=21.1.8 CRYSTAL_LIBRARY_PATH="$CRYST/.build/wasm32-wasi-libs"
export LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config LLVM_VERSION=21.1.8
export LLVM_TARGETS=WebAssembly LLVM_LDFLAGS=' '
# wasm32-wasi-libs copied from the l1 worktree (.build is gitignored):
#   cp -R ../crystal-l1-wasm-worktree/.build/wasm32-wasi-libs .build/wasm32-wasi-libs
```

### Semantic pre-check (fast, catches source errors before the long build)

```sh
$ACBIN build --no-codegen $CRYST/src/compiler/frontend_main.cr \
  --target wasm32-wasi -O1 -Dwithout_llvm -Dfrontend_no_fibers \
  -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib
# -> exit 0, no errors (3.5s, incremental semantic cache)
```

### The build (codegen → link → exnref)

```sh
# [1] cross-compile: emit object + print the wasm-ld command (no wasm-opt)
$ACBIN build --cross-compile $CRYST/src/compiler/frontend_main.cr \
  --target wasm32-wasi -O1 -Dwithout_llvm -Dfrontend_no_fibers \
  -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib \
  -o $CRYST/.build/crystal-frontend-c4.o        # ~80s; object = 33 MB
# printed command:
#   wasm-ld .../crystal-frontend-c4.o -o .../crystal-frontend-c4.o \
#     --stack-first -z stack-size=8388608 --allow-undefined \
#     --allow-multiple-definition -lc -lwasi-emulated-mman \
#     -lwasi-emulated-process-clocks -L.../.build/wasm32-wasi-libs -lpcre2-8 -lgc

# [2] link (run the printed command verbatim). NOTE: the compiler's -o equals
#     the input .o path (object_extension != ".o"); wasm-ld reads the input
#     fully before writing, so this is safe. Linked module = 26 MB.
wasm-ld .../crystal-frontend-c4.o -o .../crystal-frontend-c4.o --stack-first \
  -z stack-size=8388608 --allow-undefined --allow-multiple-definition \
  -lc -lwasi-emulated-mman -lwasi-emulated-process-clocks \
  -L.../.build/wasm32-wasi-libs -lpcre2-8 -lgc

# [3] exnref translation ONLY (asyncify + wasm-merge skipped — the whole fix)
wasm-opt .../crystal-frontend-c4.o -o .../crystal-frontend-c4.wasm \
  --translate-to-exnref --all-features                     # final = 17.9 MB
```

**Module size:** OLD (asyncify) `crystal-frontend-o1.wasm` = 56,048,133 B;
**NEW** `crystal-frontend-c4.wasm` = **17,894,275 B** (≈68% smaller — removing
the asyncify instrumentation + merged helper).

---

## 3. No-asyncify-residue assertion (design §7/§9)

```sh
wasm-objdump -j Import -x crystal-frontend-c4.wasm | grep -iE "asyncify"  # (none)
wasm-objdump -j Export -x crystal-frontend-c4.wasm | grep -iE "asyncify"  # (none)
```

Result: **NO** `asyncify_*` / `crystal_asyncify_*` imports or exports. All
imports are `wasi_snapshot_preview1.*`. `_start` and `memory` are exported. The
module validates under `wasm-opt --all-features`.

---

## 4. Verification (a): wasmtime — no regression

```sh
SRC=$CRYST/src; WORK=<workdir with diag_test.cr/ok_test.cr>; CACHE=<tmp>
/usr/bin/time -l wasmtime run -W exceptions=y,max-wasm-stack=16777216 \
  --dir $SRC::/src --dir $WORK::/work --dir $CACHE::/cache \
  --env CRYSTAL_PATH=/src --env CRYSTAL_CACHE_DIR=/cache \
  crystal-frontend-c4.wasm -Duse_pcre2 --error-format json /work/diag_test.cr
```

- exit **1**; stderr diagnostic is **byte-identical** to the reference
  `free_tier_lab/results/wasmtime_frontend_diag.err`:
  `[{"file":"/work/diag_test.cr","line":5,"column":13,"size":0,"message":"expected argument #2 to 'add' to be Int32, not String\n\nOverloads are:\n - add(a : Int32, b : Int32)"}]`
- peak RSS **581,206,016 B (~581 MB)** — matches the L1 budget (~590 MB), no
  regression. Wall **1.46 s** (cold; cranelift compiles the smaller module in
  parallel). `ok_test.cr` → exit **0**, empty stderr.

---

## 5. Verification (b) core measurement: min `max-wasm-stack` (the C-4 lever)

Binary-searched the smallest `-W max-wasm-stack=N` that runs the full prelude
(emits the diagnostic, no `call stack exhausted`), for the diag case:

| Module | Traps at | Runs at | Floor |
|---|---|---|---|
| **NEW** `crystal-frontend-c4.wasm` | 96 KB | **128 KB** | **~128 KB** |
| **OLD** `crystal-frontend-o1.wasm` (asyncify) | 1024 KB | 2048 KB | **~2 MB** |

- **Asyncify multiplier ≈ 16×** (2 MB → 128 KB). Bigger than the design's
  2–5× estimate because per-frame amplification compounds over the deep
  `Call#instantiate → body.accept` prelude recursion.
- Browser VM stack ≈ **1 MB** (V8/JSC): **NEW fits with ~8× margin**; **OLD
  (~2 MB) exceeds it** — precisely why Chrome 149 / Safari 26.5 trapped.
- Layer 1 alone clears the budget; **Layer 2 was not required**.

### Depth probes (Layer 3), simulated at browser-like stack

```sh
# deep_256.cr / deep_2048.cr = `x = ((((…))))` + `puts x`
wasmtime run -W exceptions=y,max-wasm-stack=1048576 … /work/deep_2048.cr --error-format json
# -> exit 1, NON-trap:
#    [{"file":"/work/deep_2048.cr","line":1,"column":134,"size":null,
#      "message":"expression nesting too deep (exceeds 128)"}]
```

Both `deep_256` and `deep_2048` produce the clean nesting diagnostic (exit 1,
**never** `call stack exhausted`) at 1 MB and at the 512 KB wasmtime default.

---

## 6. THE GATE — headless Chrome 149 (default stack)

```sh
python3 free_tier_lab/server.py 8799 &
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --user-data-dir=/tmp/prof-c4 --no-first-run --disable-gpu \
  "http://127.0.0.1:8799/harness/harness.html?auto=1&label=chrome-headless-c4&cases=probes,frontend"
# -> results/report_chrome-headless-c4.json
```

Artifact wiring: `free_tier_lab/artifacts/crystal-frontend-o1.wasm` is the path
the harness loads; the OLD 56 MB module was moved aside to
`crystal-frontend-o1.wasm.bak` and replaced with the NEW 17.9 MB module
(sha256 `2794040113494df44d445d7ae96d6be60b8717eb4e07f49f677256fcd61827a6`).

**Report (`report_chrome-headless-c4.json`), all §7 criteria met:**

```
frontend.cold           : exitCode=1, trap=null, runMs=322, memPeakBytes=138,477,568
frontend.diagnosticOk   : true   (file=/work/diag_test.cr, line=5, correct message)
frontend.warmClean      : exitCode=0, trap=null, stderrEmpty=true, runMs=202
frontend.warmDiag       : exitCode=1, trap=null, runMs=192
frontend.depthProbe.256 : "exit=1 runMs=4"    (non-TRAP)
frontend.depthProbe.2048: "exit=1 runMs=3"    (non-TRAP)
frontend.compileStreamingMs: 60
probes: exceptionsFinal=true (exnref), gc=true, jspi=true, streamingCompilation=true
```

- ✅ `cold.trap === null` — **the C-4 gate** (was `RangeError: Maximum call
  stack size exceeded`).
- ✅ `diagnosticOk === true`; the cold diagnostic **byte-matches the wasmtime
  leg** (parity).
- ✅ `warmClean.exitCode === 0 && stderrEmpty === true`.
- ✅ `depthProbe[256]` and `[2048]` are clean `exit=1` (Layer-3 diagnostic), not
  `TRAP:`.

---

## 7. Peak memory + timings vs the L1 report budgets

| Metric | L1 budget | This build |
|---|---|---|
| wasmtime warm wall (prelude) | 1.39 s | 1.46 s cold / (cranelift now much faster for the 17.9 MB module) |
| wasmtime peak RSS | ~590 MB | 581 MB |
| Browser linear-memory peak (diag) | (frontend budget is the ~590 MB order; 128 MB fig. is the Tier-A domain core) | **138 MB** `memory.buffer.byteLength` high-water |
| Browser compileStreaming | — | 60 ms |
| Browser cold run / warm run | — | 322 ms / 202 ms |
| Min `max-wasm-stack` (prelude) | 16 MB *used* (~2 MB floor) | **~128 KB floor** |
| Module size | 56 MB | 17.9 MB |

All well within the L1 GREEN tier and far under the ~3.8 GB effective wasm32
ceiling. The fix is a stack-depth fix; heap peaks are unchanged in order
(design §5 confirmed by measurement).

---

## 8. Caveats / notes for the reviewer

- **`compiler.cr` patch is committed but not exercised by this artifact** (Option
  B uses prebuilt `$ACBIN`). It is verified-equivalent by construction: it makes
  a full build do exactly the `wasm-ld` + `wasm-opt --translate-to-exnref`
  pipeline that was run by hand. A future full compiler rebuild would produce the
  same module directly via `crystal build … -Dfrontend_no_fibers`.
- **Parser cap = 128 is deliberately conservative** (design suggested ~512). It
  guarantees the depth probes degrade to a clean diagnostic well before any
  VM-stack trap regardless of exact per-frame cost. Real code and the prelude
  never nest *expressions* this deep (unions/method-chains/array siblings parse
  iteratively, not through this recursion). It is a single named constant, easy
  to raise if a measured budget justifies it.
- **Safari** is not automated on this machine (`safaridriver` disabled); the
  automated gate is Chrome headless per design §7. jspi/exnref/gc all probe true.
- The `-o` == input-`.o` collision in the printed `wasm-ld` command is benign
  (wasm-ld reads before writing) but noted; a future full build via the patched
  compiler avoids it entirely.
```
