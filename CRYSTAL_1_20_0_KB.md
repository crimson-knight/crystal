# Crystal 1.20.0 Fork Upgrade KB

This note tracks what matters from the official Crystal 1.20.0 release for the
Agent Crystal / Fort compiler fork, plus the validation work needed whenever we
sync to this release line.

## Official references

- Release post: <https://crystal-lang.org/2026/04/16/1.20.0-released/>
- Stable tag: `1.20.0`
- Full changelog: upstream `doc/changelogs/v1.20.md`

## Fork-relevant release changes

### Concurrency and scheduling

- Execution contexts remain a preview behind `-Dpreview_mt -Dexecution_context`.
- `Fiber::ExecutionContext::ThreadPool` was added.
- Execution-context schedulers can now detach from a running thread during
  blocking syscalls such as `getaddrinfo`.
- `ExecutionContext::Parallel` now adapts thread count to actual workload.

Why it matters here:

- Our fork has parallel parse/check/codegen work and benchmark scripts that are
  sensitive to scheduler behavior and thread scaling.
- Any assumptions in Fort-specific tests about fixed scheduler size or blocking
  behavior need to be revalidated on 1.20.0.

### Event loop

- Linux adds an experimental `io_uring` event loop via `-Devloop=io_uring`.
- With `io_uring`, I/O that can yield now always yields.

Why it matters here:

- Even though this workstation is macOS-first, Linux CI behavior can shift for
  concurrency-sensitive code and benchmark baselines.

### Compiler and toolchain

- The compiler now prefers `mold` or `lld` when available.
- LLVM 22.1 and 23.0 are supported.
- `@[TargetFeature]` enables per-function CPU feature or CPU model tuning.

Why it matters here:

- Our fork adds new compile targets and cross-target demos. Linker selection can
  affect cross-compile and release behavior.
- LLVM compatibility matters directly because the fork already depends on newer
  LLVM APIs for Wasm and incremental codegen work.

### Standard library and runtime

- `HTTP::Server` rejects requests that contain both `Content-Length` and
  `Transfer-Encoding`.
- Kernel TLS support is enabled by default on Linux and FreeBSD when available.
- `Mutex` is soft-deprecated in favor of `Sync::Mutex`.
- The new Process API preview adds array-first spawning and capture helpers.

Why it matters here:

- Fort tooling and test helpers should move toward `Sync::Mutex`.
- Any downstream runtime or network behavior checks should not assume old HTTP
  parsing behavior.

## Overlap between 1.20.0 and the fork

The merge base between the fork line and `1.20.0` is `8fa7f90c0`.

Files touched by both upstream 1.20.0 and the fork:

- `.ameba.yml`
- `_typos.toml`
- `spec/spec_helper.cr`
- `src/compiler/crystal/codegen/fun.cr`
- `src/compiler/crystal/compiler.cr`
- `src/compiler/crystal/program.cr`
- `src/compiler/crystal/semantic/cleanup_transformer.cr`
- `src/compiler/crystal/semantic/main_visitor.cr`
- `src/compiler/crystal/semantic/top_level_visitor.cr`
- `src/crystal/system/wasi/socket.cr`
- `src/fiber.cr`
- `src/llvm/enums.cr`
- `src/socket/address.cr`

Interpretation:

- The riskiest overlap is not the large fork-only surface; it is the small set
  of shared compiler, fiber, and WASI files where upstream runtime changes and
  fork features meet.

## Validation checklist for this sync

1. Build the merged fork compiler with local LLVM.
2. Run `scripts/compatibility_release_gate.sh 1.19.1 1.20.0 fork`.
3. Run targeted concurrency specs:
   - `spec/std/fiber/execution_context/parallel_spec.cr`
   - `spec/std/thread_spec.cr`
   - `spec/std/concurrent_spec.cr`
4. Run targeted compiler specs around targets and codegen:
   - `spec/compiler/codegen/target_spec.cr`
   - `spec/compiler/codegen/target_annotation_spec.cr`
5. Run Wasm-specific fork coverage:
   - `spec/wasm32/exception_handling_spec.cr`
   - `spec/wasm32/fiber_spec.cr`
   - `spec/wasm32/gc_spec.cr`
   - `spec/wasm32/io_spec.cr`
   - `spec/wasm32/linking_spec.cr`
6. Build cross-platform sample targets:
   - macOS native
   - iOS simulator
   - iOS device
   - Android object output
   - `wasm32-wasi`
7. Run at least one benchmark smoke pass for parallelism or incremental build
   behavior to catch large regressions after the scheduler changes.

## Expected challenges

- Adaptive `ExecutionContext::Parallel` scaling may move benchmark numbers even
  if correctness stays intact.
- Blocking syscall detachment can expose hidden race assumptions in tests that
  used to run more serially.
- Linker preference changes may surface target-specific issues on iOS, Android,
  Wasm, or Linux cross-compiles.
- WASI networking is still unavailable on Preview 1; keep the fork's explicit
  diagnostics when merging upstream socket changes.
