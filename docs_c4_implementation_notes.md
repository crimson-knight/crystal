# C-4 Fix — Implementation Notes

**Branch:** `c4-asyncify-fix` (from `l1-frontend-wasm-experiment`)
**Implementer:** C-4 implementation agent, 2026-07-07
**Design:** `docs_c4_design.md` (this repo)
**Result:** ✅ **PASS** — the frontend wasm module that previously trapped
`RangeError: Maximum call stack size exceeded` now runs the full prelude
semantic analysis in **headless Chrome 149 at the default engine stack** (no
`--js-flags=--stack-size`), emits the correct JSON diagnostic, and degrades
gracefully on pathological nesting of **every** recursive-descent parse path
(expression containers, unary/pow/type self-recursions, **and the macro-control
family** — see the fixer pass below).

**Current artifact (attempt 2 — fixer pass):** `crystal-frontend-c4v3.wasm`,
**24,351,724 B**, sha256
`96bcf2cd824c1a2df13a8014a691fb215b50738055bc231f0352ccce02324994`. Deployed to
`free_tier_lab/artifacts/crystal-frontend-o1.wasm`; the prior attempt-2 module is
kept aside as `…crystal-frontend-o1.wasm.c4v2-nomacroguard`.

**Attempt 2 — fixer pass (2026-07-07, post-gate #2) — closed Defect 1 (BLOCKER):**
The gate FAILED because the macro-control recursion was still unguarded: deeply
nested `{% if %}` / `{% begin %}` / `{% for %}` / `{% unless %}` / `elsif` /
`{% verbatim %}` re-trapped the wasm call stack (`call stack exhausted`, exit 134)
at ~1000 levels — the exact C-4 failure mode. Root cause: `parse_macro_body`
mutually recurses with `parse_macro_control` / `parse_macro_if`, a path that
re-enters **none** of the previously-guarded expression chokepoints
(`parse_op_assign` / `parse_prefix` / `parse_pow` / `parse_union_type`).

- **Fix (parser.cr):** wrapped the whole body of **`parse_macro_control`** and
  **`parse_macro_if`** in `with_recursion_guard` via the thin
  wrapper→`_internal` pattern (same as `parse_op_assign`). Guarding these two is
  provably sufficient: every `parse_macro_body` re-entry is reached through a
  guarded `parse_macro_control` or `parse_macro_if` frame, and the only direct
  bypass — `parse_macro_if → parse_macro_if` for `elsif` — is now guarded too.
  Uses the same shared `@parse_recursion_depth` / `MAX_PARSE_RECURSION = 128`, so
  macro nesting now raises the clean `SyntaxException` ("syntax nesting too
  deep") instead of trapping. Codex (xhigh) independently confirmed completeness
  and that a *shared* counter is the right safety model (macro-control and
  expression frames share the one wasm call stack).
- **Harness (`free_tier_lab/harness/harness.mjs`):** added `macroif` /
  `macrobegin` / `macrofor` to the `caseFrontend` `depthProbe` set (depth-probe
  *inputs*, not a runtime change) so the gate exercises this class.
- **Verified:** at `wasmtime -W max-wasm-stack=1048576` (1 MB browser-equiv) all
  five macro classes (`if`/`begin`/`for`/`elsif`/`verbatim`) now return clean
  `exit=1` "syntax nesting too deep (exceeds 128)" — no `TRAP`; the OLD attempt-2
  module still traps (exit 134) on the identical `macroif` input, proving the
  probe is valid and the guard is what fixed it. Legit moderate macro nesting
  (`{% if %}`×20) still parses (exit 0). Full headless-Chrome gate
  (`report_chrome-headless-c4v3.json`) re-run green: `cold.trap=null`,
  `diagnosticOk=true`, `warmClean` exit 0 + `stderrEmpty`, **all 10 depthProbe
  cases (paren/2048/unary/pow/type/array/call + macroif/macrobegin/macrofor) are
  clean `exit=1`, none `TRAP`**, `domain.outputMatchesLeg3=true` (no regression),
  probes exnref/gc/jspi all true.

**Attempt 2 (2026-07-07, post-gate #1) — closed three gate findings:**
1. **Depth guard broadened to the true chokepoint (blocking).** The Layer-3
   guard covered only parenthesized `parse_expression`; MANY other
   recursive-descent paths still recursed unboundedly and trapped the wasm stack
   (exit 134): deep **unary** (`!!!…`), **`**` pow**, **nested types**
   (`Pointer(Pointer(…))`), and — critically — every **expression container**:
   nested **array** literals `[[[…]]]`, **call args** `f(f(f(…)))`, **index**
   `a[0[0[…]]]`, **hash values**, and **string interpolation**. Root cause: the
   counter was on `parse_expression`, but those containers re-enter
   **`parse_op_assign`** (not `parse_expression`) once per level. Moved the
   shared `@parse_recursion_depth` guard onto `parse_op_assign` (the single
   chokepoint all containers funnel through) plus recursive-edge guards on
   `parse_prefix`/`parse_pow` and a whole-body guard on `parse_union_type` for
   the self-recursions that bypass `parse_op_assign`. **Every** pathological
   class now degrades to a clean `exit=1` "syntax nesting too deep" at
   `wasmtime -W max-wasm-stack=1048576` and in the browser (new harness
   `depthProbe` cases `unary`/`pow`/`type`/`array`/`call` all `exit=1`, no
   `TRAP`); the full prelude and legit moderate nesting still parse.
2. **`--spill-pointers` re-enabled (blocking doc claim / GC safety).** The Boehm
   conservative-GC root-spill pass was commented out; it is now run on the
   `skip_fibers` (frontend) path — the asyncify-compat reason it was disabled
   does not apply once asyncify is gone. Module grew 17.9 MB → **24.35 MB**
   (brotli-q11 1.50 MB → **2.08 MB**); functional + gate parity unchanged.
3. **RSS figure corrected (minor).** §4 previously claimed 581 MB peak RSS; the
   real measured peak is **~273 MB** for this artifact (see §4).

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
| `src/compiler/crystal/compiler.cr` | `run_wasm_opt` gains a `skip_fibers` param; when the **target** program has the flag it skips the `--asyncify` pass **and** the `asyncify_helper.wasm` merge, running `--translate-to-exnref` **and (attempt 2) `--spill-pointers`** (Boehm GC root safety, re-enabled for the no-fibers path only; order: exnref → spill → -Oz). The check is a runtime `program.has_flag?("frontend_no_fibers")` at the call site (NOT a compiler-binary macro flag). |
| `src/compiler/crystal/syntax/parser.cr` | Layer-3 guard (**attempt 2: broadened to the real chokepoint**): `MAX_PARSE_RECURSION = 128` and a single shared `@parse_recursion_depth` counter, applied via `with_recursion_guard { … }` at the unbounded recursive-descent chokepoints — **`parse_op_assign`** (whole body, via a thin wrapper delegating to `parse_op_assign_internal`; this is the single point ALL expression containers re-enter once per level: parens, array/hash/tuple literals, call args, index subscripts, interpolation, and — through `parse_expression` — block/begin bodies), `parse_prefix` (recursive edge only; deep unary), the generated right-assoc `parse_pow` (recursive edge only; `**` chains), and `parse_union_type` (whole body; nested generic/union/proc types — these three self-recurse WITHOUT re-entering `parse_op_assign`). Raises `Crystal::SyntaxException` (`"syntax nesting too deep (exceeds 128)"`) before deep recursion can trap the engine. Edge-guarding prefix/pow avoids taxing flat expressions; the container budget is ~128 nesting levels (proven safe: paren×128 raises cleanly, no trap, at the 1 MB browser stack). **Fixer pass** adds whole-body guards on **`parse_macro_control`** and **`parse_macro_if`** (wrapper→`_internal`, same pattern) — the macro-control family (`{% if/unless/begin/for/verbatim %}`/`elsif`) mutually recurses through `parse_macro_body` and re-enters none of the expression chokepoints, so it needed its own guards. |

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

# [3] exnref translation + spill-pointers (asyncify + wasm-merge skipped — the
#     whole fix). Two in-place wasm-opt passes in this order, exactly mirroring
#     the two run_wasm_opt_pass calls the patched compiler makes for skip_fibers:
wasm-opt .../crystal-frontend-c4v2.linked.wasm -o .../crystal-frontend-c4v2.wasm \
  --translate-to-exnref --all-features                     # 17.9 MB
wasm-opt .../crystal-frontend-c4v2.wasm -o .../crystal-frontend-c4v2.wasm \
  --spill-pointers --all-features                          # final = 24.35 MB
```

**Module size:** OLD (asyncify) `crystal-frontend-o1.wasm` = 56,048,133 B;
attempt-1 (exnref only, no spill) = 17,894,275 B; **NEW attempt-2**
`crystal-frontend-c4v2.wasm` = **24,352,577 B** (still ≈57% smaller than the
asyncify build; +6.5 MB vs attempt-1 is the `--spill-pointers` GC-root stores).
brotli-q11: 6.72 MB (asyncify) → 1.50 MB (attempt-1) → **2.08 MB (attempt-2)**.
sha256 = `07abcee1e8a2b6182ad9a51335dde6cdf328ce657afcd7e6f771dedcf566e7e5`.

---

## 3. No-asyncify-residue assertion (design §7/§9)

```sh
wasm-objdump -j Import -x crystal-frontend-c4v2.wasm | grep -iE "asyncify"  # (none)
wasm-objdump -j Export -x crystal-frontend-c4v2.wasm | grep -iE "asyncify"  # (none)
```

Result (re-verified attempt 2, post-spill-pointers): **NO** `asyncify_*` /
`crystal_asyncify_*` imports or exports. All **22** imports are
`wasi_snapshot_preview1.*`. `_start` and `memory` are exported. The module
validates under `wasm-opt --all-features`. Spill-pointers does not introduce any
new imports (it only spills locals to the existing linear-memory shadow stack).

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
- **peak RSS `286,752,768 B (~273 MB)`** (`/usr/bin/time -l`, cold, diag case,
  16 MB stack, attempt-2 spill-pointers artifact) — comfortably under the ~590 MB
  L1 budget, no regression. Wall **~0.57 s**. `ok_test.cr` → exit **0**, empty
  stderr.
  - **Correction:** attempt-1 notes claimed 581 MB here; that figure did not
    reproduce. The gate independently measured **245 MB** on the pre-spill
    attempt-1 module; this attempt-2 (with `--spill-pointers`) measures ~273 MB.
    All three are well within budget.

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

### Depth probes (Layer 3), simulated at browser-like stack — ALL FOUR PATHS

Attempt 2 verifies every unbounded recursive-descent path degrades cleanly at
`wasmtime -W exceptions=y,max-wasm-stack=1048576` (browser-equivalent 1 MB):

| probe | input | recursion path | result |
|---|---|---|---|
| paren  | `x = (`×2048 `1` `)`×2048 | parse_op_assign | `exit=1` clean |
| array  | `x = [`×6000 `1` `]`×6000 | parse_op_assign | `exit=1` clean |
| call   | `x = f(`×6000 `1` `)`×6000 | parse_op_assign | `exit=1` clean |
| index  | `x = a[0`×6000 `]`×6000 | parse_op_assign | `exit=1` clean |
| hash   | `x = {1 => `×6000 `1` `}`×6000 | parse_op_assign | `exit=1` clean |
| interp | `x = "#{`×6000 `1` `}"`×6000 | parse_op_assign | `exit=1` clean |
| block  | `x = f{`×6000 `1` `}`×6000 | parse_expression→parse_op_assign | `exit=1` clean |
| begin  | `x = begin `×6000 `1` ` end`×6000 | parse_expression→parse_op_assign | `exit=1` clean |
| unary  | `x = ` `!`×20000 `true`   | parse_prefix (edge) | `exit=1` clean |
| pow    | `x = 2` `**2`×20000       | parse_pow (edge)    | `exit=1` clean |
| type   | `alias D = ` `Pointer(`×20000 `Int32` `)`×20000 | parse_union_type | `exit=1` clean |
| macroif  | `{% if true %}`×6000 `{% end %}`×6000 | parse_macro_control/_if | `exit=1` clean |
| macrobegin | `{% begin %}`×6000 `{% end %}`×6000 | parse_macro_control | `exit=1` clean |
| macrofor | `{% for x in [1] %}`×6000 `{% end %}`×6000 | parse_macro_control | `exit=1` clean |
| macroelsif | `{% if false %}` `{% elsif false %}`×6000 `{% end %}` | parse_macro_if (direct) | `exit=1` clean |
| macroverbatim | `{% verbatim do %}`×6000 `{% end %}`×6000 | parse_macro_control | `exit=1` clean |

(all `exit=1`, message `"syntax nesting too deep (exceeds 128)"`; the macro rows
are the fixer pass — before it they trapped exit 134 at the 1 MB stack, and the
pre-fix attempt-2 module still does on the identical input)

```sh
wasmtime run -W exceptions=y,max-wasm-stack=1048576 … /work/arr.cr --error-format json
# -> exit 1, NON-trap:
#    [{"file":"/work/arr.cr","line":1,"column":133,"size":null,
#      "message":"syntax nesting too deep (exceeds 128)"}]
```

**Before attempt 2** everything except paren **trapped** (exit 134, "call stack
exhausted") at this stack — only the paren path was guarded. Attempt 1 (guarding
`parse_expression` + unary/pow/type edges) still trapped the container class
(array/call/index/hash/interp) because those re-enter `parse_op_assign`, NOT
`parse_expression` — which is why the guard was moved to `parse_op_assign`. All
paths above now produce the clean diagnostic (exit 1, **never** `call stack
exhausted`) at 1 MB and at the 512 KB wasmtime default. Legit moderate nesting
(array/paren ×30, unary/pow ×40, `Pointer(` ×20) still parses (exit 0), and the
full prelude type-checks — the 128 cap does not reject real code.

---

## 6. THE GATE — headless Chrome 149 (default stack)

```sh
python3 free_tier_lab/server.py 8804 &
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --user-data-dir=/tmp/prof-c4v3 --no-first-run --disable-gpu \
  "http://127.0.0.1:8804/harness/harness.html?auto=1&label=chrome-headless-c4v3&cases=probes,domain,frontend,persist"
# -> results/report_chrome-headless-c4v3.json
```

Artifact wiring: `free_tier_lab/artifacts/crystal-frontend-o1.wasm` is the path
the harness loads; the **fixer pass** replaced the attempt-2 module with the NEW
24,351,724 B module (sha256
`96bcf2cd824c1a2df13a8014a691fb215b50738055bc231f0352ccce02324994`; the pre-fix
attempt-2 module kept aside as `crystal-frontend-o1.wasm.c4v2-nomacroguard`). Gate
command used the FULL harness `cases=probes,domain,frontend,persist`.

**Report (`report_chrome-headless-c4v3.json`), all §7 criteria met:**

```
frontend.cold           : exitCode=1, trap=null, runMs=544, memPeakBytes=138,477,568
frontend.diagnosticOk   : true   (file=/work/diag_test.cr, line=5, correct message)
frontend.warmClean      : exitCode=0, trap=null, stderrEmpty=true, runMs=245
frontend.warmDiag       : exitCode=1, trap=null
frontend.depthProbe.256 : "exit=1 runMs=4"    (non-TRAP)
frontend.depthProbe.2048: "exit=1 runMs=3"    (non-TRAP)
frontend.depthProbe.unary: "exit=1 runMs=3"   (non-TRAP)
frontend.depthProbe.pow  : "exit=1 runMs=3"   (non-TRAP)
frontend.depthProbe.type : "exit=1 runMs=3"   (non-TRAP)
frontend.depthProbe.array: "exit=1 runMs=3"   (non-TRAP)
frontend.depthProbe.call : "exit=1 runMs=3"   (non-TRAP)
frontend.depthProbe.macroif   : "exit=1 runMs=3"  (non-TRAP)  ← fixer-pass new coverage
frontend.depthProbe.macrobegin: "exit=1 runMs=3"  (non-TRAP)  ← fixer-pass new coverage
frontend.depthProbe.macrofor  : "exit=1 runMs=8"  (non-TRAP)  ← fixer-pass new coverage
domain.outputMatchesLeg3 : true  ("RESULT: PASS", no regression)
probes: exceptionsFinal=true (exnref), gc=true, jspi=true, streamingCompilation=true
persist: cacheApi ok, opfs ok, idbModule=false (WebAssembly.Module not structured-
         cloneable — pre-existing engine behavior, unrelated to C-4)
```

- ✅ `cold.trap === null` — **the C-4 gate** (was `RangeError: Maximum call
  stack size exceeded`).
- ✅ `diagnosticOk === true`; the cold diagnostic **byte-matches the wasmtime
  leg** (parity).
- ✅ `warmClean.exitCode === 0 && stderrEmpty === true`.
- ✅ `depthProbe[256]`, `[2048]`, `unary`, `pow`, `type`, `array`, `call`,
  **`macroif`, `macrobegin`, `macrofor`** are all clean `exit=1` (Layer-3
  diagnostic), not `TRAP:` — every recursive-descent path, including the
  expression-container class **and the macro-control family** (fixer pass).
- ✅ `domain.outputMatchesLeg3 === true` — Tier-A domain gate unaffected by the
  spill-pointers artifact swap (domain_check.wasm itself unchanged).

---

## 7. Peak memory + timings vs the L1 report budgets

| Metric | L1 budget | This build (attempt 2) |
|---|---|---|
| wasmtime warm wall (prelude) | 1.39 s | ~0.57 s cold (diag) |
| wasmtime peak RSS | ~590 MB | **273 MB** (was mis-reported as 581 MB) |
| Browser linear-memory peak (diag) | (frontend budget is the ~590 MB order; 128 MB fig. is the Tier-A domain core) | **138 MB** `memory.buffer.byteLength` high-water |
| Browser compileStreaming | — | 56 ms |
| Browser cold run / warm run | — | 554 ms / 250 ms |
| Min `max-wasm-stack` (prelude) | 16 MB *used* (~2 MB floor) | **~128 KB floor** |
| Module size | 56 MB | 24.35 MB (17.9 MB pre-spill + 6.5 MB spill-pointers) |

All well within the L1 GREEN tier and far under the ~3.8 GB effective wasm32
ceiling. The fix is a stack-depth fix; heap peaks are unchanged in order
(design §5 confirmed by measurement).

---

## 8. Caveats / notes for the reviewer

- **`compiler.cr` patch is committed but not exercised by this artifact** (Option
  B uses prebuilt `$ACBIN`). It is verified-equivalent by construction: it makes
  a full build do exactly the `wasm-ld` + `wasm-opt --translate-to-exnref`
  **+ `wasm-opt --spill-pointers`** pipeline that was run by hand (attempt 2 adds
  the spill pass to both the compiler and the manual build so they still match).
  A future full compiler rebuild would produce the same module directly via
  `crystal build … -Dfrontend_no_fibers`.
- **`--spill-pointers` scope (attempt 2):** re-enabled for the `skip_fibers`
  (frontend) path ONLY. The fiber build still does not spill — that was disabled
  because its asyncify interaction was never verified, and this change does not
  reopen that question. If/when the fiber path ships, spill-pointers there needs
  its own asyncify-compat verification. The 8 MB linker stack
  (`-z stack-size=8388608`) means the extra shadow-stack spill traffic does not
  approach the linear-memory stack limit.
- **Parser cap = 128 is deliberately conservative** (design suggested ~512), now
  a single SHARED cap across the recursive-descent chokepoints —
  `parse_op_assign` (the expression-container chokepoint: paren/array/hash/tuple/
  call-args/index/interpolation/block/begin) plus edge guards on
  `parse_prefix`/`parse_pow` and a whole-body guard on `parse_union_type`. It
  guarantees every depth probe degrades to a clean diagnostic well before any
  VM-stack trap regardless of per-frame cost (empirically: paren×128 raises
  cleanly at the 1 MB browser stack; all container paths share that per-level
  frame cost). Real code and the prelude never nest any single path this deep
  (verified: legit ×30/×40/×20 cases parse; the full prelude type-checks).
  Edge-guarding prefix/pow means flat expressions are not taxed.
  It is a single named constant, easy to raise if a measured budget justifies it.
- **Macro-control nesting** (`parse_macro_control`/`parse_macro_if`/
  `parse_macro_body`) is **now covered** (fixer pass — see the fixer-pass entry
  at the top and the `macro*` rows in §5). The attempt-2 gate correctly rejected
  the earlier claim that this was a mere future-audit item: it is a reachable,
  depth-driven browser trap (the exact C-4 mode), so it was fixed and probed, not
  deferred. Both `parse_macro_control` and `parse_macro_if` now carry
  whole-body `with_recursion_guard` on the shared counter.
- **Safari** is not automated on this machine (`safaridriver` disabled); the
  automated gate is Chrome headless per design §7. jspi/exnref/gc all probe true.
- The `-o` == input-`.o` collision in the printed `wasm-ld` command is avoided in
  attempt 2 by linking to a distinct `…c4v2.linked.wasm` path; a future full
  build via the patched compiler avoids it entirely.
```
