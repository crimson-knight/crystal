# C-4 Fix Design — Crystal frontend wasm32-wasi: surviving the browser call-stack limit

**Branch:** `c4-asyncify-fix` (from `l1-frontend-wasm-experiment`)
**Author:** C-4 designer agent, 2026-07-07
**Advisor:** Codex (xhigh) — consulted on the draft; incorporated/rebutted in §9.
**Scope:** design only. No compiler source is patched in this commit; this document
is the buildable plan the implementation agent executes next.

Companion docs (read for context):
`agentc_website/docs/product/COMPILER_IN_TAB_L1_REPORT.md` (§5 item 2, §1.2 break
C-4), `.../CRYSTAL_WASM_COMPILER_FEASIBILITY.md` (§3.5), the experiment log
`EXPERIMENT_L1_FRONTEND_WASM.md` (C-1..C-5), and `free_tier_lab/FREE_TIER_FUNNEL.md`
(§0 — the empirical both-browser confirmation).

---

## 1. The problem, stated precisely

The frontend-only compiler `crystal-frontend-o1.wasm` (parse + full semantic +
JSON diagnostics, `-Dwithout_llvm`, `-O1`, 56 MB raw / 6.72 MB brotli) runs the
full prelude semantic analysis of real programs **under wasmtime 41** at near
native speed (warm 1.39 s, ~590 MB RSS) — but **only** with
`-W max-wasm-stack=16777216`. In **Chrome 149 and Safari 26.5** the same module
traps `RangeError: Maximum call stack size exceeded` ~3–4 s into prelude semantic
analysis. wasmtime's default `max-wasm-stack` is 512 KB; the browser engines cap
the wasm execution stack at roughly ~1 MB (V8/JSC) and **expose no knob** — Chrome's
`--js-flags=--stack-size` crashes the renderer and is not shippable; Safari has
none. This is L1-report break **C-4**, the ranked-#1 open browser risk, now
empirically confirmed as the *only* blocker for the Tier-B diagnostics playground
(FREE_TIER_FUNNEL §0).

The experiment log names the cause exactly: *"recursive-descent parser + asyncify
overhead vs wasmtime's 512 KB default."* This design attacks both halves.

---

## 2. Root-cause diagnosis (correcting the framing)

The workstream framing is *"the fiber/asyncify layer keeps fiber stacks on the
wasm value stack; relocate fiber stacks into linear memory."* That names the right
suspect (asyncify) but the mechanism needs correction, and the correction changes
the fix:

**2.1 The binding limit is the VM execution/call stack, not the shadow stack.**
There are two "stacks" in a wasm32 module:

- The **linear-memory shadow stack** (`__stack_pointer` global) — holds spilled
  locals, address-taken variables, and by-value aggregates. In this build it is
  **already 8 MB** (`wasm-ld ... --stack-first -z stack-size=8388608`,
  `src/compiler/crystal/compiler.cr:784`). An overflow here would surface as a
  linear-memory *out-of-bounds* trap, not a `RangeError`.
- The **VM execution stack** — the engine's native call-frame/operand stack. This
  is what `max-wasm-stack` governs in wasmtime, and it is what throws
  `RangeError: Maximum call stack size exceeded` in browsers. It is **not backed
  by linear memory** and **cannot be relocated there** by any module-level trick.

The observed trap is `RangeError`, so the constraint is unambiguously the **VM
execution stack**. The 8 MB shadow stack is not the bottleneck; it can even be
*shrunk* by this fix (§5).

**2.2 Two multiplicative contributors to VM-stack depth × per-frame cost:**

- **(a) Genuine deep recursion.** The recursive-descent parser (nested
  expressions) and, more importantly for the *prelude* trap, the recursive
  semantic visitors — type inference walks the call graph via
  `Call#instantiate → typed_def.body.accept visitor`
  (`src/compiler/crystal/semantic/call.cr:430`) and generic AST-visitor recursion.
- **(b) Asyncify per-frame amplification.** The fork's wasm32 pipeline
  unconditionally runs `wasm-opt --asyncify` (`compiler.cr` `run_wasm_opt`,
  ~line 1544). Asyncify instruments functions to save/restore all live locals to
  a linear-memory buffer at unwind points; to do so it keeps locals live across
  calls and adds dispatch prologues, **inflating per-frame VM-stack cost**. This
  is exactly what produced break **C-1** ("too many locals" at `-O0`,
  `NumberLiteral#interpret`) — asyncify multiplies locals. Codex estimates a
  **2–5× frame amplifier** in affected functions.

**2.3 Why "relocate fiber stacks into linear memory" (as an asyncify trick) does
NOT fix this.** Asyncify's unwind copies the *current* call chain into a
linear-memory buffer and returns to `_start`; **rewind reconstructs the identical
VM call-frame depth** to resume. It preserves logical depth; it cannot flatten
native recursion. Binaryen's `onlylist`/`removelist`/`asyncify-imports`/
`ignore-indirect` knobs change *which* functions are instrumented, never the
recursion depth. Confirmed by Codex (Claim A) against the Binaryen Asyncify source
and Emscripten docs. The only ways to make a deep native recursion use less VM
stack are: **reduce the depth** (algorithm change / explicit heap work-stack),
**reduce per-frame cost** (remove asyncify), a runtime with a bigger native stack
(wasmtime — not available in-browser), or engine **stack-switching (JSPI)** —
which is Chromium-only with **no Safari** and is deliberately off the critical
path (feasibility §6.8).

**Corrected reading of the goal.** "Relocate the stack into linear memory" is
achievable in the two senses that actually help, and this design delivers both:
(1) **remove the asyncify layer** so the fiber/asyncify instrumentation stops
inflating the VM value stack (the amplifier the framing correctly blames), and
(2) where genuine recursion still overflows, **move the recursion *state* into a
heap-allocated (linear-memory) work-stack** via explicit iterative traversal.
What is *not* achievable is relocating the live VM call stack itself; the design
does not pretend otherwise, and §10 states the consequence honestly.

---

## 3. The chosen approach (three layers, staged)

Attack the cheap, high-leverage amplifier first; reduce genuine depth only where
measurement proves it is still needed; always ship the graceful guard.

### Layer 1 — De-asyncify the frontend (necessary, high-leverage)

The frontend needs **no fibers**: single-threaded (`--threads 1`), never `spawn`s,
uses no `Channel`/`sleep`/`Fiber.yield` on the analysis path; WASI file I/O is
synchronous; the 2022 crystal.wasm ran with `swapcontext` stubbed to a no-op. So
the entire asyncify apparatus is dead weight that only inflates the VM stack.

**Layer 1 is not a mere pipeline toggle** (Codex, Claim B — the key correction).
The current wasm32 `_start` (`src/crystal/system/wasi/main.cr:40`) *unconditionally*
calls `crystal_get_state`/`crystal_stop_unwind`, and `src/fiber/context/wasm32.cr:3`
`require`s `crystal/asyncify`. If we merely skipped `wasm-merge`, those
`crystal_*` imports would be unresolved. Layer 1 therefore has **three coordinated
parts**, all gated behind a new build flag `-Dfrontend_no_fibers` (implied by
`-Dwithout_llvm` for the frontend build, or set explicitly):

1. **A non-asyncify WASI entry path.** Provide an alternate `_start` (gated
   `{% if flag?(:frontend_no_fibers) %}`) that is the classic WASI boundary and
   references **no** `LibCrystalAsyncify` symbol:
   `__wasm_call_ctors → status = __main_void → __wasm_call_dtors →
   proc_exit(status)`. No unwind/rewind loop.
2. **Neutralize the fiber context.** Under the flag, the wasm32 fiber context does
   **not** `require "crystal/asyncify"`, does not allocate the asyncify header/
   buffer (`MAIN_FIBER_ASYNCIFY_SIZE`, `init_main_fiber_asyncify`), and defines
   `Fiber.swapcontext` as an **abort stub** (`LibC.abort` / `unreachable`). The
   abort is a *safety net*, not the mechanism (see part 3): if any unexpected path
   ever tries to switch fibers, we get a clean, loud abort instead of silent
   corruption.
3. **Skip the asyncify + wasm-merge passes.** Under the flag, `run_wasm_opt`
   emits only `--translate-to-exnref` (browsers need exnref EH), skipping
   `--asyncify` and `wasm-merge asyncify_helper.wasm`. **Do not rely on "the stub
   removes all reachability so asyncify instruments nothing"** — Binaryen treats
   indirect calls conservatively (Codex), so the robust guarantee comes from
   *skipping the pass outright*, with the entry-path + stub changes making that
   skip sound.

Net effect: amplifier (b) is eliminated; per-frame VM-stack cost drops by the
asyncify multiplier (est. 2–5× on affected frames); the module shrinks (no
instrumentation, no merged helper). This is the single biggest safe lever and may,
on its own, bring the prelude under the ~1 MB browser budget — **plausible but not
bankable** (Codex, A3); §9/§9-acceptance quantifies it by binary-searching the
minimum `max-wasm-stack` before vs after.

### Layer 2 — Move residual deep recursion into a linear-memory work-stack (only if measured)

If, after Layer 1, the prelude (or realistic user files) still overflows the
browser budget, convert the **specific** dominating recursions to explicit
iterative traversal with a heap-allocated `Array`/`Deque` worklist — the honest
"recursion state in linear memory" transform.

**Targets, in priority order (per Codex A4, citations verified):**

- **Semantic (the prelude driver):** `Call#instantiate → typed_def.body.accept
  visitor` (`call.cr:430`); generic `ASTNode` visitor recursion in `MainVisitor`
  (`semantic/main_visitor.cr:89`); secondary self-call walks such as
  `InstanceVarsCollector` (`main_visitor.cr:1774`, used at `:1865`).
- **Parser (only the genuinely recursive productions):** nested parentheses,
  unary chains, right-associative operators, and pathological nested
  array/hash/tuple literals. **Do not** start with parser trampolining for the
  prelude — left-associative binary and method chains are already largely
  iterative (Codex).

**Honesty about the hard case.** The prelude's depth is dominated by
`Call#instantiate → body.accept` *mutual* recursion — the core of Crystal's type
inference, threaded through the call graph. This is not a self-recursive tree walk
that trampolines cleanly; converting it to an explicit continuation stack
approaches a compiler rewrite and is high-risk. If Layer 1 does not get the
*prelude* under budget and the residual depth lives here, the pragmatic levers are
(in order): **(i) a trimmed / lazy-`require` "browser prelude"** for the
diagnostics tier (the experiment log's own next-step: *"browser targets would want
a trimmed prelude or lazy require analysis"*) — reduces both depth and the ~590 MB
heap; **(ii) Chromium-first Tier B via JSPI** as a stack-switch escape hatch
(no Safari); **(iii)** accept that user *files* (shallow) type-check fine while
the deepest cold-prelude pass is served by the trimmed prelude. See §10.

### Layer 3 — Graceful depth guard (always ships)

Independent of Layers 1–2, add a **recursion-depth guard** so pathological input
never reaches the engine trap:

- Parser: a `nesting_depth` counter (incremented at the recursive expression
  productions), with a configurable cap (default e.g. 512), raising a normal
  `Crystal::SyntaxException` → rendered as a clean diagnostic *"expression nesting
  too deep (max N)"*. This is standard (clang/rustc/gcc all cap nesting).
- Semantic: a bounded instantiation/inference depth counter that raises a
  `Crystal::TypeException` (*"type inference nesting too deep"*) before the engine
  budget is hit.

The cap is set **below** the empirically measured browser budget (from the
binary-search in §9) with margin, so the frontend degrades to a diagnostic — the
memory-governance *graceful-wall* philosophy (L1 report §3.4): the user always
gets a real error, never an uncatchable trap. This is what makes the harness'
`depthProbe[2048]` case pass as a clean `exit=1`, not a `TRAP:`.

---

## 4. How asyncify unwind/rewind data and stack pointers move

The task asks specifically how unwind/rewind data and stack pointers relocate.
For the **frontend module (Tier B)** the answer is: **they are eliminated, not
relocated** — because the frontend never switches fibers.

| Element | Today (asyncify build) | After Layer 1 (frontend) |
|---|---|---|
| `__stack_pointer` global | Governs 8 MB linear-memory shadow stack | Unchanged mechanism; reserve can shrink (§5) |
| Asyncify `Data` header (`current_location`, `end_location`) per fiber | Written to the 16-byte header at each fiber's `stack_low`; buffer grows upward, shadow stack downward (`fiber/context/wasm32.cr:83`) | **Removed** — no `asyncify_data`, no header, no per-fiber buffer |
| `MAIN_FIBER_ASYNCIFY_SIZE` (8 KB+16) main-fiber buffer | `malloc`'d in `init_main_fiber_asyncify` | **Not allocated** |
| `asyncify_start/stop_unwind`, `_rewind` (Binaryen-generated) + `crystal_asyncify_*` (helper) | Present; imported/exported across `wasm-merge` | **Absent** from the module (assert: no `asyncify_*`/`crystal_asyncify_*` imports or exports — §9) |
| Unwind/rewind control loop in `_start` | Drives fiber scheduling after each unwind | **Replaced** by the classic linear WASI entry path |

For the **general runtime** (L4/L5 user programs that *do* `spawn`), the durable
"fiber stacks in linear memory" story is a *separate* effort and is **out of scope
for the Tier-B unblock**: per §2.3, asyncify already keeps fiber save-buffers in
linear memory, and truly relocating a running fiber's *execution* stack needs
stack-switching (JSPI) or a CPS rewrite. This design deliberately does not couple
Tier B to that; it removes fibers from the frontend instead.

---

## 5. Memory budget

The fix is a **stack-depth** fix, not a heap fix; it does not move the memory
peaks (Codex Claim C — directionally right, verify by measurement):

- **Layer 1** *reduces* footprint: removing asyncify instrumentation shrinks the
  module (fewer locals, no merged helper), and the 8 MB shadow-stack reserve can
  be lowered (e.g. `-z stack-size=2097152`) once recursion no longer leans on it —
  freeing several MB of upfront linear memory. Keep 8 MB until §9 measurement
  confirms the new shadow-stack high-water.
- **Layer 2** replaces VM frames with heap worklist entries. These are **not**
  a flat 8 bytes each (Codex): a semantic worklist entry may carry visitor state,
  var scope, and call context. Still expected to be **KB-scale total**, negligible
  against the ~590 MB semantic heap — but must be measured, not assumed.
- **Peak linear memory** stays the same order: ~590 MB RSS at hello-scale in
  wasmtime; the browser's `WebAssembly.Memory.buffer.byteLength` high-water is the
  free RSS-equivalent (L1 report §3.2). This sits far under the ~3.8 GB effective
  wasm32 ceiling and the GREEN tier.
- The task's "128 MB current full-gate peak" refers to the **Tier-A domain core**
  (`domain_check.wasm`, FREE_TIER_FUNNEL appendix), a different, smaller module;
  the frontend's budget is the ~590 MB figure above. This fix leaves both peaks
  effectively unchanged.

---

## 6. Exact build-flag / source-patch plan

New flag: **`-Dfrontend_no_fibers`** (the frontend build passes it alongside
`-Dwithout_llvm`). All changes gated so non-frontend wasm builds are untouched.

**Source patches (all in the fork, branch `c4-asyncify-fix`):**

1. `src/crystal/system/wasi/main.cr` — add `{% if flag?(:frontend_no_fibers) %}`
   branch defining a fiber-free `_start` (`__wasm_call_ctors` → `__main_void` →
   `__wasm_call_dtors` → `proc_exit`); keep the existing asyncify `_start` under
   `{% else %}`.
2. `src/fiber/context/wasm32.cr` — under the flag: drop `require "crystal/asyncify"`;
   omit `init_main_fiber_asyncify`, the asyncify header/`Data` plumbing, and
   `MAIN_FIBER_ASYNCIFY_SIZE`; define `makecontext` minimally and
   `Fiber.swapcontext` as an abort stub (`LibC.abort`).
3. `src/crystal/asyncify.cr` — top-guard so the module compiles to nothing under
   the flag (`{% skip_file if flag?(:frontend_no_fibers) %}`), and ensure nothing
   references `LibCrystalAsyncify` when it is skipped.
4. `src/compiler/crystal/compiler.cr` — `run_wasm_opt`: under
   `flag?(:frontend_no_fibers)` (thread the program flags in), skip the
   `--asyncify` pass and `run_wasm_merge`; still run `--translate-to-exnref`.
   Optionally lower `-z stack-size` at line 784 under the same flag (defer until
   §9 measures the shadow-stack high-water; keep 8 MB by default).
5. `src/compiler/crystal/parser.cr` (or `lexer`/`parser` recursive productions) —
   Layer 3 nesting-depth guard.
6. `src/compiler/crystal/semantic/*` — Layer 3 inference-depth guard; Layer 2
   worklist conversions **only** for the profiled hot targets (§3), added
   incrementally and behind the same measurement gate.

**Build command (adapts the experiment log's reproduce recipe):**

```sh
ACBIN=/opt/homebrew/Cellar/agent-crystal/HEAD-6636853/libexec/agent-crystal-bin
CRYSTAL_PATH=$PWD/src CRYSTAL_CONFIG_TARGET=wasm32-wasi CRYSTAL_CONFIG_PATH=/src \
CRYSTAL_CONFIG_LLVM_VERSION=21.1.8 CRYSTAL_LIBRARY_PATH=$PWD/.build/wasm32-wasi-libs \
LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config LLVM_VERSION=21.1.8 \
LLVM_TARGETS=WebAssembly LLVM_LDFLAGS=' ' \
$ACBIN build src/compiler/frontend_main.cr -o .build/crystal-frontend-c4.wasm \
  --target wasm32-wasi -O1 -Dwithout_llvm -Dfrontend_no_fibers \
  -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib
```

Keep `-O1` (C-1: `-O0` is rejected for "too many locals"; that pressure drops once
asyncify is gone, but `-O1` regalloc is still the safe floor). Avoid post-`-O2`
(C-2 cranelift panic) until root-caused.

---

## 7. Acceptance test (the gate) — headless Chrome

The lab harness (`free_tier_lab/harness/harness.mjs`, `caseFrontend`) is the
runtime and the gate; **do not rewrite it** (LAW). Procedure:

1. Build `.build/crystal-frontend-c4.wasm` (§6); copy to
   `free_tier_lab/artifacts/crystal-frontend-o1.wasm` (the harness path).
2. Start the lab server (`free_tier_lab/server.py`), launch **headless Chrome** at
   `/harness/harness.html?auto=1&label=chrome-headless-c4&cases=probes,frontend`.
   The harness POSTs its JSON report to `/report` → `results/report_chrome-headless-c4.json`.
3. **PASS requires all of:**
   - `cases.frontend.cold.trap === null` (was: `RangeError: Maximum call stack size
     exceeded`) — the core C-4 gate.
   - `cases.frontend.diagnosticOk === true` — exit 1 + JSON diagnostic at
     `line 5`, message contains *"expected argument #2 to 'add' to be Int32, not
     String"*, `file === "/work/diag_test.cr"`.
   - `cases.frontend.warmClean.exitCode === 0 && warmClean.stderrEmpty === true`
     (clean file type-checks silently).
   - `cases.frontend.depthProbe["256"]` and `["2048"]` are clean `exit=…` (0/1 or
     the Layer-3 "nesting too deep" diagnostic), **not** `TRAP:`.
   - **Parity:** the emitted JSON diagnostic byte-matches the wasmtime leg
     (`free_tier_lab/results/wasmtime_frontend_diag.json`).

**Measurement gates baked in (per Codex):**

- **Binary-search the minimum `max-wasm-stack`** under wasmtime for the OLD and
  NEW artifacts (`wasmtime -W max-wasm-stack=N …`, bisect the smallest N that runs
  the full prelude). This quantifies the asyncify multiplier and predicts browser
  fit: NEW must sit comfortably under the ~1 MB browser budget with margin.
- **Assert no asyncify residue:** the NEW module must contain no `asyncify_*` or
  `crystal_asyncify_*` imports/exports (`wasm-objdump`/`wasm2wat | grep`).
- **GC stress:** run the diagnostic + clean cases **N× in one instance / repeated
  instances** and watch for corruption or divergent output — guards the Claim-D
  GC-scanning risk (§8).
- Firefox is expected-fine but must be verified before any "every browser" claim.

Acceptance is the headless-Chrome harness pass (criterion above). Safari
confirmation is manual on this machine (`safaridriver` not enabled;
`tools/run_safari.py`), and should follow, but the automated gate is Chrome
headless.

---

## 8. Risks (Claim-D GC correctness is first-class)

- **GC conservative scanning (highest correctness risk).** Boehm on wasm can only
  scan **linear memory**, never the opaque VM value stack. GC-visible pointers
  living only in wasm locals are invisible to the collector. Asyncify does **not**
  help here (it materializes local spills only *during an unwind*, not during
  arbitrary GC), which implies the current asyncify-on frontend already survives
  without VM-local scanning — so removing asyncify should not *regress* GC
  (Codex confirms the reasoning). **But this must be verified, not assumed** (GC
  stress, §7). `--spill-pointers` (currently disabled in `run_wasm_opt`, TODO
  "verify compatibility with asyncify") becomes *available* once asyncify is gone,
  but the repo's own notes flag it as buggy/breaking — treat it as a **risky
  correctness lever of last resort**, not a free cleanup; if enabled, test pass
  order (spill before exnref) and re-measure frame cost (it re-inflates shadow
  stack and can add locals, §9-6).
- **Hidden fiber-switch paths hitting the abort stub.** Guard: main-fiber init,
  WASI `EAGAIN` read/write suspend paths (the event loop *does* have
  `resume_read`/`resume_write` fiber machinery — `event_loop/wasi.cr:225`), STDOUT/
  STDERR flush, `at_exit` handlers. The frontend reads regular files and writes
  diagnostics (blocking I/O), so no yield is expected — but ensure FDs are blocking
  and treat any abort-stub hit in testing as a real bug to trace. The abort stub
  converts such a path into a loud failure rather than corruption (intentional).
- **Layer 1 insufficiency.** If the prelude still overflows after de-asyncify, the
  residual depth is likely the `Call#instantiate` inference core — hard to
  trampoline. Fallbacks: trimmed/lazy browser prelude, then Chromium-first JSPI
  (§3 Layer 2 honesty, §10).
- **Toolchain.** Avoid post-`-O2` (C-2). Keep `-O1`.

---

## 9. Codex (xhigh) consultation — incorporated and rebutted

Consulted with the L1 excerpt + this draft. Verdict: *"Diagnosis mostly right; the
infeasible part is Claim B as worded."* Disposition:

- **Claim A (asyncify can't reduce depth): confirmed.** Kept as the design's
  central correction (§2.3).
- **Claim B (stub ⇒ zero instrumentation, skip passes is a toggle): accepted as a
  correction.** Two fixes folded in: (i) Layer 1 now includes a **non-asyncify
  WASI entry path** and neutralizes the fiber context, because `_start` and
  `wasm32.cr` reference `LibCrystalAsyncify` unconditionally (§3.1, §6); (ii) the
  design **relies on skipping the asyncify pass outright**, not on reachability,
  because Binaryen is conservative about indirect calls — the stub is reframed as
  a *safety net*, not the mechanism.
- **Claim C (memory unchanged): accepted with a caveat.** Softened §5 — worklist
  entries are not flat 8 bytes; measure.
- **Claim D (GC risk): accepted and elevated.** Now the #1 risk (§8);
  `--spill-pointers` reclassified from "free cleanup" to "risky last resort."
- **A2 (hidden fiber paths): incorporated** as the abort-stub guard list (§8).
- **A3 (Layer 1 not bankable): incorporated** — binary-search min `max-wasm-stack`
  old vs new is now an acceptance gate (§7).
- **A4 (target semantic recursion, not the parser): incorporated** — Layer 2
  targets reordered to `Call#instantiate`/visitor/`InstanceVarsCollector` first;
  parser guarded only for nested parens/unary/right-assoc/literals (§3.2). Codex's
  citations verified against the source.
- **A5/A6 (pass order, spill re-inflation): incorporated** into §6/§8.

**Where I hold my ground (rebuttal):** Codex flags Layer 1 as "plausible but not
bankable." I keep Layer 1 as the *first shipped step* anyway, because it is safe,
strictly reduces VM-stack cost, and is the prerequisite for measuring whether
Layers 2/3 are even needed — staging is cheaper than pre-committing to a semantic
rewrite. I also keep Layer 3 (graceful guard) as *always-ship* even if Layer 1
suffices for the prelude, because pathological user input (`depthProbe[2048]`) is a
product-surface reality the guard must own regardless.

---

## 10. What would make this infeasible as designed (blocked)

Nothing blocks *starting* — Layer 1 + Layer 3 are unconditionally safe and
implementable. The design becomes only-partially-feasible **iff both**: (a) Layer 1
de-asyncify does **not** bring the *cold prelude* pass under the ~1 MB browser
budget (measured via §7 binary-search), **and** (b) the residual depth is
dominated by the `Call#instantiate → body.accept` type-inference mutual recursion
rather than the parser/localized visitors. In that case Layer 2 as a clean
trampoline is not tractable (it approaches a compiler rewrite), and the shippable
Tier-B paths degrade to, in order: **(1)** a trimmed/lazy-`require` *browser
prelude* (also cuts the ~590 MB heap) — most likely sufficient and recommended to
prototype in parallel; **(2)** Chromium-first Tier B via **JSPI** stack-switching,
explicitly **no Safari**; **(3)** ship diagnostics for user *files* (shallow depth,
fine) while the deepest cold-prelude analysis rides the trimmed prelude. A true
cross-browser "arbitrary-depth type inference in the tab on the full prelude"
without any prelude trimming would require engine stack-switching that Safari does
not provide — that specific maximalist form is the one genuinely blocked today, and
the trimmed-prelude path (1) is the designed way around it.

---

## 11. Sequencing for the implementation agent

1. Implement Layer 1 (§6 patches 1–4) behind `-Dfrontend_no_fibers`; build
   `crystal-frontend-c4.wasm` (`-O1`). **One heavy build at a time** (LAW).
2. Verify natively first (frontend_main runs, diagnostics identical to the
   asyncify build), then under wasmtime; **binary-search min `max-wasm-stack`**
   old vs new (§7 measurement gate) and assert no asyncify residue.
3. Drop into `free_tier_lab/artifacts/`; run the headless-Chrome harness (§7).
   If PASS → the C-4 gate is met; add Layer 3 guard, re-verify `depthProbe`.
4. If the prelude still traps → GC-stress to isolate, then apply Layer 2 to the
   profiled hot target(s), or pivot to the trimmed-prelude fallback (§10). Re-run
   the gate.
5. Only when the headless-Chrome gate passes: push branch `c4-asyncify-fix` to the
   fork remote (LAW — the gate pushes).
