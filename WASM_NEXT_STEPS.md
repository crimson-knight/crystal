# Crystal WASM: Next Steps Plan

## Current State (Completed)

- Phase 1: Exception Handling (native WASM EH via try_table/exnref)
- Phase 2: Garbage Collection (Boehm GC)
- Phase 3: Fiber/Concurrency (Asyncify-based cooperative switching)
- Phase 4: Standard Library Linking (wasm-ld, WASI_SDK_PATH, CRYSTAL_WASM_LIBS)
- Phase 5: Event Loop (WASI poll_oneoff, timeout/FD events)
- Phase 6: CI/Toolchain (full CI pipeline, Binaryen integration)
- 74 passing tests across 4 spec suites
- Documentation and examples

## Phase A: Fix Fiber Stack Overflow in Standalone Programs (CRITICAL)

**Priority**: Must fix before any release.

**Problem**: `spawn { ... }; Fiber.yield` crashes with stack exhaustion in
standalone programs but works in the spec test harness.

**Root Cause Analysis** (from investigation):

1. `swapcontext` in `src/fiber/context/wasm32.cr` does NOT set
   `new_context.value.resumable = 0` on the target fiber. Every native
   platform implementation (x86_64, aarch64, arm, etc.) does this. Without it,
   dead fibers appear resumable, causing the `_start` loop to attempt rewind
   on a fiber that has already completed.

2. The `_start` loop in `src/crystal/system/wasi/main.cr` checks
   `next_fiber.resumable?` but NOT `next_fiber.dead?`. A dead fiber with
   stale `resumable = 1` causes infinite re-entry.

3. `Fiber#run`'s ensure block calls `Fiber.suspend` during asyncify unwind,
   which interacts with the legacy-EH-to-exnref translation in ways that may
   corrupt the asyncify state.

**Fixes Required**:

1. In `src/fiber/context/wasm32.cr`, `swapcontext`: add
   `new_context.value.resumable = 0` before triggering unwind (matching native
   platform behavior).

2. In `src/crystal/system/wasi/main.cr`, `_start` loop: add
   `break if next_fiber.dead?` safety check.

3. Add diagnostic `Crystal::Asyncify.debug_print` calls to trace the exact
   failure point (these use raw `LibC.write`, bypassing asyncify).

4. Test with the standalone program:
   ```crystal
   spawn { puts "fiber ran!" }
   Fiber.yield
   puts "main done"
   ```

**Verification**: The standalone fiber program should produce output and exit
cleanly (exit code 0).

---

## Phase B: Cross-Compile Missing C Libraries (HIGH)

**Priority**: Required for stdlib feature parity.

### B1: zlib (Easy, ~1-2 hours)

Enables: `Compress::Gzip`, `Compress::Zlib`

Pure C, no dependencies. Standard cross-compilation with wasi-sdk.

```bash
CC="${WASI_SDK_PATH}/bin/clang" \
CFLAGS="--sysroot=${WASI_SDK_PATH}/share/wasi-sysroot -Os" \
AR="${WASI_SDK_PATH}/bin/llvm-ar" \
RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib" \
CHOST=wasm32 ./configure --static --prefix=$OUTPUT_DIR
make && make install
```

### B2: libgmp (Moderate, ~2-3 hours)

Enables: `BigInt`, `BigFloat`

Must use `--host=none` to disable assembly. Use `ABI=longlong` for better
performance (WASM has native i64).

```bash
./configure --prefix=$OUTPUT_DIR --host=none --enable-static --disable-shared \
  CC="${WASI_SDK_PATH}/bin/clang" \
  CFLAGS="--sysroot=${WASI_SDK_PATH}/share/wasi-sysroot -Os" \
  ABI=longlong
```

### B3: libyaml (Easy, ~1-2 hours)

Enables: `YAML`

Pure C, standard autotools cross-compilation. Must copy wasi-sdk's
`config.sub` and `config.guess` for `--host=wasm32-wasi` recognition.

### B4: libiconv (Trivial -- code change only)

Enables: String encoding conversion (removes `-Dwithout_iconv`)

wasi-libc (musl) already includes `iconv_open`/`iconv`/`iconv_close` with
POSIX symbol names. Crystal's `lib_iconv.cr` uses GNU `libiconv` symbol
names. Fix: conditionally use POSIX names on wasm32/linux.

### B5: libxml2 (Moderate, ~3-4 hours)

Enables: `XML`

Depends on zlib (B1). Must disable: http, ftp, threads, modules, python.
Use VMware's webassembly-language-runtimes as reference.

### B6: OpenSSL (Hard, ~1-2 days, Optional)

Enables: TLS/crypto (removes `-Dwithout_openssl`)

Requires 3 patches (entropy, certs, WASI config). Security caveat: WASM
does not guarantee constant-time operations, making cryptographic code
potentially vulnerable to timing attacks. Consider keeping optional until
the wasi-tls proposal matures.

Reference: github.com/jedisct1/openssl-wasm

### Packaging

Extend the existing `lbguilherme/wasm-libs` repo (or create Crystal-org
fork) with build scripts for each library. Update CI to download the new
release.

---

## Phase C: Standards Alignment (MEDIUM)

### C1: Rename target to wasm32-wasip1

Rust removed `wasm32-wasi` in January 2025, replacing it with
`wasm32-wasip1` (explicit about WASI version). Crystal should follow:

- Add `wasm32-wasip1` as a target alias (keep `wasm32-wasi` for
  backward compatibility)
- Update documentation to prefer the new name

### C2: Track WASI Preview 2 for networking

WASI 0.2 adds TCP/UDP sockets via `wasi:sockets`. This requires the
Component Model, which is a significant architectural change. Plan:

1. Research Component Model binary format requirements
2. Evaluate wasi-sdk support for Preview 2
3. Prototype a minimal `wasm32-wasip2` target
4. Implement `wasi:sockets/tcp` bindings

This would unlock: `TCPSocket`, `HTTP::Client`, `HTTP::Server`, DNS

### C3: Monitor WASI 0.3 and Stack Switching

WASI 0.3 (expected ~early 2026) adds native async (`stream<T>`,
`future<T>`). This maps naturally to Crystal's fibers. The Stack Switching
proposal (Phase 3 in WebAssembly) would replace Asyncify entirely with
zero-overhead coroutines.

Timeline: Watch, don't act yet. These are not stable enough.

### C4: Consider additional Wasm features

Low priority but worth tracking:

- `tail-call` (finished in Wasm 3.0) -- useful for recursive patterns
- `simd` (finished in Wasm 2.0) -- useful for string ops, crypto
- `threads` (Phase 4) -- eventual multi-threading

---

## Phase D: Polish and Testing (MEDIUM)

### D1: Expand spec coverage

- Add standalone fiber test (not in spec harness) to CI
- Add file I/O tests (read/write with `--dir`)
- Add sleep/time tests
- Add comprehensive channel tests

### D2: Binary size optimization and GC root scanning

- Implement `--asyncify-only-list` to limit Asyncify instrumentation
  to functions that actually need it (reduces ~50% code size overhead)
- Implement Asyncify-based GC root scanning (modeled on Emscripten's
  `emscripten_scan_registers`): trigger an Asyncify unwind before GC
  collection to spill all live WASM locals into linear memory, then
  scan them. This guarantees all pointer roots are visible to Boehm GC.
  **Note**: `--spill-pointers` (Binaryen pass) cannot be used -- it has
  known bugs and is incompatible with Asyncify (see
  emscripten/emscripten#18251).
- Benchmark debug vs release mode sizes

### D3: Error messages

- Replace `NotImplementedError` with descriptive messages explaining
  the WASI limitation and suggesting alternatives
- Example: "Sockets are not available in WASI Preview 1. Crystal
  will support networking when targeting WASI Preview 2."

---

## Delegation Plan

| Phase | Agent Type | Parallelizable? | Depends On |
|-------|-----------|-----------------|------------|
| A (fiber fix) | Implementation | No (critical path) | Nothing |
| B1 (zlib) | Build/packaging | Yes | Nothing |
| B2 (libgmp) | Build/packaging | Yes | Nothing |
| B3 (libyaml) | Build/packaging | Yes | Nothing |
| B4 (libiconv) | Implementation | Yes | Nothing |
| B5 (libxml2) | Build/packaging | No | B1 (zlib) |
| B6 (OpenSSL) | Build/packaging | Yes | Nothing |
| C1 (target rename) | Implementation | Yes | Nothing |
| C2 (WASI p2) | Research | Yes | Nothing |
| D1 (tests) | Implementation | No | A (fiber fix) |
| D2 (size opt) | Implementation | Yes | Nothing |
| D3 (error msgs) | Implementation | Yes | Nothing |

### Recommended execution order:

1. **Immediately**: Phase A (fiber fix) -- blocks everything user-facing
2. **Parallel with A**: B1-B4 (easy C libs), D2 (size opt), D3 (error msgs)
3. **After A**: D1 (expanded tests)
4. **After B1**: B5 (libxml2)
5. **After initial release**: B6 (OpenSSL), C1 (target rename), C2 (WASI p2 research)
