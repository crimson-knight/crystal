# Crystal WebAssembly Guide

This guide explains how to compile Crystal programs to WebAssembly (WASM) using the `wasm32-unknown-wasi` target. Crystal compiles to WASM via LLVM's WebAssembly backend and runs on WASI-compatible runtimes like Wasmtime.

**Status (February 2026)**: WASM compilation works for programs that do not use exception handling (raise/rescue) at runtime. Basic output, string interpolation, arrays, hashes, and other core data structures all work. Exception handling compiles but does not fully work at runtime yet (throw works, catch does not).

---

## Requirements

**Crystal Version**: 1.20.0-dev (this fork: `crimson-knight/crystal`, branch: `wasm-support`)
**Base Crystal**: Built on `crystal-lang/crystal` master (commit `8fa7f90c0`)

### Required Tools

| Tool | Minimum Version | Purpose | Install |
|------|----------------|---------|---------|
| Crystal | 1.19+ (for bootstrapping) | Compile the compiler itself | -- |
| wasi-sdk | 21+ | WASI sysroot with wasi-libc, clang, and wasm-ld | GitHub releases, install to `/opt/wasi-sdk` |
| lld | (from LLVM) | WebAssembly linker (`wasm-ld`) | `brew install lld` (macOS) |
| Binaryen | 116+ | Provides `wasm-opt` for Asyncify pass | `brew install binaryen` (macOS) |
| Wasmtime | 25+ | Primary WASI runtime for executing `.wasm` binaries | `curl https://wasmtime.dev/install.sh -sSf \| bash` |

You also need a compiled `wasm_eh_support.o` object file for C++ exception handling ABI support. See the Prerequisites section below.

---

## Setup

### macOS

```bash
# 1. Install lld (provides wasm-ld)
brew install lld

# 2. Install Binaryen (provides wasm-opt)
brew install binaryen

# 3. Install Wasmtime
curl https://wasmtime.dev/install.sh -sSf | bash
export PATH="$HOME/.wasmtime/bin:$PATH"

# 4. Install wasi-sdk
# Download the latest release for macOS from:
#   https://github.com/WebAssembly/wasi-sdk/releases
# Example for wasi-sdk 25 (use arm64 variant for Apple Silicon):
curl -LO https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sdk-25.0-arm64-macos.tar.gz
tar xzf wasi-sdk-25.0-arm64-macos.tar.gz
sudo mv wasi-sdk-25.0-arm64-macos /opt/wasi-sdk

# 5. Compile the wasm_eh_support.o helper object
# This provides the C++ exception handling ABI functions (cxa_allocate_exception, etc.)
# that Crystal's WASM exception handling requires.
cat > /tmp/wasm_eh_support.cpp << 'CPPEOF'
#include <cstdlib>
#include <cstring>

extern "C" {

struct ExceptionInfo {
    void* ptr;
    size_t size;
};

void* __cxa_allocate_exception(size_t size) {
    ExceptionInfo* info = (ExceptionInfo*)malloc(sizeof(ExceptionInfo) + size);
    if (!info) __builtin_trap();
    info->size = size;
    info->ptr = (void*)(info + 1);
    return info->ptr;
}

void __cxa_free_exception(void* ptr) {
    ExceptionInfo* info = ((ExceptionInfo*)ptr) - 1;
    free(info);
}

void __cxa_throw(void* thrown_exception, void* tinfo, void (*dest)(void*)) {
    __builtin_wasm_throw(0, thrown_exception);
}

}
CPPEOF

/opt/wasi-sdk/bin/clang++ -target wasm32-wasi \
  --sysroot=/opt/wasi-sdk/share/wasi-sysroot \
  -fwasm-exceptions \
  -c /tmp/wasm_eh_support.cpp \
  -o /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o

# 6. Set environment variables
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi
```

### Ubuntu / Debian

```bash
# 1. Install LLVM 18 (includes wasm-ld)
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 18
sudo apt install llvm-18-dev lld-18

# Symlink wasm-ld if needed
sudo ln -sf /usr/bin/wasm-ld-18 /usr/bin/wasm-ld

# 2. Install Binaryen (provides wasm-opt)
# Option A: From package manager (check version is 116+)
sudo apt install binaryen

# Option B: From releases (if package version is too old)
curl -LO https://github.com/WebAssembly/binaryen/releases/download/version_119/binaryen-version_119-x86_64-linux.tar.gz
tar xzf binaryen-version_119-x86_64-linux.tar.gz
sudo cp binaryen-version_119/bin/* /usr/local/bin/

# 3. Install Wasmtime
curl https://wasmtime.dev/install.sh -sSf | bash
export PATH="$HOME/.wasmtime/bin:$PATH"

# 4. Install wasi-sdk
curl -LO https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sdk-25.0-x86_64-linux.tar.gz
tar xzf wasi-sdk-25.0-x86_64-linux.tar.gz
sudo mv wasi-sdk-25.0-x86_64-linux /opt/wasi-sdk

# 5. Compile wasm_eh_support.o (see macOS section above for the C++ source)
# Use the same source file and compile with:
/opt/wasi-sdk/bin/clang++ -target wasm32-wasi \
  --sysroot=/opt/wasi-sdk/share/wasi-sysroot \
  -fwasm-exceptions \
  -c /tmp/wasm_eh_support.cpp \
  -o /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o

# 6. Set environment variables
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi
```

### Persist Environment Variables

Add these lines to your shell profile (`~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`):

```bash
export PATH="$HOME/.wasmtime/bin:$PATH"
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi
```

---

## Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `CRYSTAL_LIBRARY_PATH` | Crystal's library search path. Must point to the wasi-sysroot lib directory so the linker can find wasi-libc and wasm_eh_support.o. | `/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi` |
| `PATH` | Must include wasmtime's bin directory. | `$HOME/.wasmtime/bin:$PATH` |

---

## Your First WASM App

Create a file called `hello.cr`:

```crystal
# hello.cr
puts "Hello from Crystal on WebAssembly!"
puts "1 + 2 = #{1 + 2}"
puts "Array: #{[1, 2, 3]}"
puts "It works!"
```

Compile it using the locally built Crystal compiler (from the repo root):

```bash
export PATH="$HOME/.wasmtime/bin:$PATH"
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi

bin/crystal build hello.cr \
  --target wasm32-unknown-wasi \
  -Dwithout_iconv \
  -Dwithout_openssl \
  --link-flags="--allow-undefined /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o -lc++abi" \
  -o hello.wasm
```

Run it with Wasmtime (the `-W exceptions` flag is required for WASM exception handling support):

```bash
wasmtime run -W exceptions hello.wasm
```

Expected output:

```
Hello from Crystal on WebAssembly!
1 + 2 = 3
Array: [1, 2, 3]
It works!
```

**Important notes about the build command:**

- `-Dwithout_iconv` and `-Dwithout_openssl` are required because these C libraries are not available on WASM.
- `--link-flags` passes additional flags to `wasm-ld`:
  - `--allow-undefined` allows unresolved symbols (needed for some WASI imports).
  - `/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o` links the C++ exception handling support object.
  - `-lc++abi` links the C++ ABI library for exception handling runtime support.
- `wasmtime run -W exceptions` enables the WASM exception handling proposal in Wasmtime, which is required for Crystal's exception throw mechanism.

---

## What Works

The following Crystal features are supported on the WASM target:

### Language Features
- All Crystal language features: types, generics, macros, blocks, closures, procs
- Structs, classes, enums, modules, abstract types
- Method dispatch, method overloading, multiple return types
- Union types, nilable types, type restrictions
- String interpolation, symbol literals

### Runtime Features
- **Basic I/O** -- writing to STDOUT and STDERR via `puts`, `print`, `STDOUT.puts`, etc.
- **Exception throwing** -- `raise` compiles and the throw side works via WASM exception handling instructions

### Standard Library
- Data structures: `Array`, `Hash`, `Set`, `Deque`, `Slice`, `Tuple`, `NamedTuple`, `StaticArray`
- String processing: `String`, `StringBuilder`, `StringScanner`, `Symbol`
- Encoding: `Base64`, `CSV`, `HTML`, `URI`, `UUID`
- Math: `Complex`, float printing (IEEE, Grisu3)
- JSON: `JSON::Builder`, `JSON::Lexer`, `JSON::Parser`, `JSON.parse`, `to_json`
- Random number generation via WASI `random_get`
- Basic file operations via WASI preopens (directory listing, file reading with `--dir`)

---

## What Doesn't Work (Current Limitations)

| Feature | Status | Details |
|---------|--------|---------|
| **Exception catching (rescue)** | Throw works, catch does not | `raise` correctly throws a WASM exception, but `rescue`/`catch` does not catch it at runtime. Programs that raise will trap instead of being rescued. This is the primary limitation. |
| **Fibers / Concurrency** | Stubbed out | `spawn`, `Fiber.yield`, `Channel` are stub implementations. Fibers require Binaryen Asyncify integration which is not yet wired up. |
| **Garbage Collection** | None (leak allocator) | Uses `gc/none` -- all allocations leak. No garbage collection occurs. Long-running programs will run out of memory. |
| **OpenSSL / TLS** | Not available | Would require OpenSSL cross-compiled to WASM. Build with `-Dwithout_openssl`. |
| **iconv** | Not available | Character encoding conversion not available on WASM. Build with `-Dwithout_iconv`. |
| **Threads** | Not available | WASI has no thread creation API. Crystal runs single-threaded on WASM. |
| **Sockets / HTTP** | Not available | Requires WASI Preview 2 socket support, which is not yet integrated. |
| **Signal handling** | Not available | Not meaningful in the WASM sandbox. Signals are excluded via `flag?(:wasm32)`. |
| **Process spawning** | Not available | WASM sandboxed environment does not support spawning processes. |
| **Full file system** | Limited | Only directories explicitly granted by the runtime via WASI preopens are accessible. |
| **Call stack / backtraces** | Empty | The WASM operand stack is opaque; backtraces return empty. |

---

## Compilation Flags

### Target Flag (Required)

```bash
--target wasm32-unknown-wasi
```

This tells Crystal and LLVM to emit WebAssembly targeting the WASI interface.

### Required Flags

| Flag | Purpose |
|------|---------|
| `--target wasm32-unknown-wasi` | Target the WASM/WASI platform |
| `-Dwithout_iconv` | Skip iconv, which is not available on WASM |
| `-Dwithout_openssl` | Skip OpenSSL, which is not available on WASM |
| `--link-flags="..."` | Pass additional flags to wasm-ld (see below) |

### Required Link Flags

The `--link-flags` argument must include:

| Link Flag | Purpose |
|-----------|---------|
| `--allow-undefined` | Allow unresolved symbols (needed for WASI imports) |
| `/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o` | C++ exception handling ABI support object |
| `-lc++abi` | C++ ABI library for exception handling runtime |

### Optional Flags

| Flag | Purpose |
|------|---------|
| `--release` | Enable optimizations. Strongly recommended for WASM. Reduces code size significantly and avoids Cranelift compilation failures on very large functions. |

### Example: Full Build Command

```bash
# Set up environment
export PATH="$HOME/.wasmtime/bin:$PATH"
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi

# Debug build (from the Crystal repo root, using the locally built compiler)
bin/crystal build app.cr \
  --target wasm32-unknown-wasi \
  -Dwithout_iconv \
  -Dwithout_openssl \
  --link-flags="--allow-undefined /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o -lc++abi" \
  -o app.wasm

# Release build (recommended for smaller binaries and fewer Cranelift issues)
bin/crystal build app.cr \
  --target wasm32-unknown-wasi \
  -Dwithout_iconv \
  -Dwithout_openssl \
  --link-flags="--allow-undefined /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o -lc++abi" \
  --release \
  -o app.wasm
```

### What Happens During Compilation

The compiler performs these steps for WASM targets:

1. **Crystal codegen** -- Crystal source is compiled to LLVM IR with WASM-specific features enabled (exception handling, bulk memory, mutable globals, sign extension, non-trapping float-to-int). The compiler forces `single_module` mode for WASM.
2. **LLVM compilation** -- LLVM IR is compiled to a `.o` WebAssembly object file.
3. **Linking** -- `wasm-ld` links the object file with wasi-libc, the `wasm_eh_support.o` object, and the C++ ABI library. The linker uses `--stack-first -z stack-size=8388608` to place the stack before data (preventing silent stack overflow corruption) and set an 8MB stack.

---

## Running WASM Programs

### Wasmtime (Recommended)

**Important**: The `-W exceptions` flag is required for all Crystal WASM programs. Crystal uses WASM exception handling instructions, and Wasmtime requires this flag to enable them.

```bash
# Basic execution (the -W exceptions flag is REQUIRED)
wasmtime run -W exceptions app.wasm

# Grant file system access to the current directory
wasmtime run -W exceptions --dir=. app.wasm

# Grant access to a specific directory
wasmtime run -W exceptions --dir=/path/to/data app.wasm

# Pass command-line arguments
wasmtime run -W exceptions app.wasm -- arg1 arg2

# Set environment variables
wasmtime run -W exceptions --env MY_VAR=value app.wasm
```

The `--dir=.` flag grants the WASM program access to the current directory via WASI preopens. Without it, the program cannot read or write any files.

If you forget the `-W exceptions` flag, you will see an error like: `unknown import: __wasm_tag is not a function`.

### Wasmer

Wasmer may work for some programs but is less tested. Note that Wasmer's singlepass compiler may crash on ARM64. Use Wasmtime on Apple Silicon Macs.

```bash
wasmer run app.wasm
```

### Browser

Crystal WASM binaries target WASI and cannot run directly in the browser without a WASI polyfill. A thin JavaScript wrapper using a library like `@aspect-build/aspect-wasi` or `browser_wasi_shim` is needed to provide the WASI interface. Browser support is experimental and untested.

---

## Validating Your Setup

A validation script is included to verify that all required tools are installed and that WASM compilation works correctly:

```bash
# Full validation (checks tools + runs compilation tests)
./scripts/validate_wasm.sh

# Quick validation (checks tool versions only, no compilation)
./scripts/validate_wasm.sh --quick
```

The script checks:

1. **Tool presence**: Crystal (local `bin/crystal`), wasm-ld, wasm-opt, wasmtime
2. **Prerequisites**: `CRYSTAL_LIBRARY_PATH` set, wasi-sdk installed, `wasm_eh_support.o` exists
3. **Compilation tests** (full mode only):
   - Basic output (puts, string interpolation, arrays)
   - String operations and data structures
   - WASM-specific spec files in `spec/wasm32/`

Note: The validation script uses the same build command documented above, including the `--link-flags` and `wasmtime run -W exceptions` invocation.

---

## Architecture

### Linear Memory Model

Crystal compiles to WASM using **linear memory** (not WasmGC). This preserves Crystal's pointer model, C FFI, and the entire standard library. All objects, strings, arrays, and structs live in WASM's linear memory, just as they would in native memory on x86_64 or aarch64.

### Memory Layout

The linker is configured with `--stack-first -z stack-size=8388608`, which produces this layout:

```
+--------+-------------------+---------------+------------------
| Unused | Main stack (8MB)  | Static data   | Heap ...
+--------+-------------------+---------------+------------------
0      1024            __data_start      __heap_base
```

Placing the stack first prevents stack overflow from silently corrupting heap data (the default layout puts the stack between data and heap, where overflow corrupts `dlmalloc` structures).

### Exception Handling (Partial)

Crystal's exceptions use LLVM's exception handling model. LLVM's WASM backend translates this to WASM's native exception handling instructions (`try_table`/`throw`/`throw_ref`), which are enabled via the `+exception-handling` target feature. The throw side works: `raise` correctly creates and throws a WASM exception. However, the catch side (`rescue`/`ensure`) does not work at runtime yet -- thrown exceptions are not caught and instead cause the program to trap. This is the primary area of active development.

The `wasm_eh_support.o` object file provides the C++ exception handling ABI functions (`__cxa_allocate_exception`, `__cxa_throw`, etc.) that bridge Crystal's exception model to WASM's native exception handling instructions.

### Garbage Collection (Not Yet Implemented)

WASM currently uses `gc/none` -- a leak allocator with no garbage collection. All memory allocations persist for the lifetime of the program. This is adequate for short-running programs but will cause out-of-memory errors for long-running or allocation-heavy programs.

The planned approach is to use Boehm GC with Binaryen's Asyncify transformation for stack scanning (see WASM_ROADMAP.md for details).

### Fiber Switching (Not Yet Implemented)

Fiber context switching is stubbed out. The planned approach uses Binaryen's Asyncify transformation to enable cooperative concurrency (see WASM_ROADMAP.md for details).

### Event Loop

The WASI event loop (`Crystal::EventLoop::Wasi`) has limited functionality. Most methods raise `NotImplementedError`. Basic `poll_oneoff` support exists for sleep/timeout via clock subscriptions.

---

## Troubleshooting

### "unknown import: __wasm_tag is not a function"

You forgot the `-W exceptions` flag when running with Wasmtime. Crystal WASM binaries require exception handling support:

```bash
# Wrong:
wasmtime run app.wasm

# Correct:
wasmtime run -W exceptions app.wasm
```

### "wasm-ld: error: unable to find library -lc"

The linker cannot find wasi-libc. Ensure `CRYSTAL_LIBRARY_PATH` points to the wasi-sysroot lib directory:

```bash
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi
```

Verify the sysroot exists:

```bash
ls /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a
```

### "wasm-ld: error: unable to find library -lc++abi"

The C++ ABI library is not found. Ensure `CRYSTAL_LIBRARY_PATH` points to the correct wasi-sysroot directory, and that wasi-sdk is fully installed at `/opt/wasi-sdk`.

### "cannot open wasm_eh_support.o: No such file or directory"

You need to compile the `wasm_eh_support.o` file. See the Setup section above for the C++ source and compilation command.

### "wasm-opt: command not found"

Binaryen is not installed or not in `PATH`. Install it:

```bash
# macOS
brew install binaryen

# Ubuntu
sudo apt install binaryen

# Or download from https://github.com/WebAssembly/binaryen/releases
```

### "EXITING: __crystal_raise called"

You are running an older Crystal compiler that does not have WASM exception handling support. The `__crystal_raise` stub in older versions simply prints this message and calls `exit(1)`. Use this fork (`crimson-knight/crystal`, branch `wasm-support`) which has the WASM exception handling codegen.

### Program traps when an exception is raised

This is a known limitation. The throw side of exception handling works (WASM `throw` instruction fires), but the catch side (`rescue`/`ensure`) does not work at runtime yet. Programs that raise exceptions will trap. Avoid `raise`/`rescue` in your WASM programs for now. Be aware that some stdlib operations raise internally (e.g., out-of-bounds array access, nil assertions).

### "out of bounds memory access" (runtime trap)

This usually indicates a stack overflow. The default 8MB stack may be insufficient for deeply recursive programs or programs with many large stack frames. Possible causes:

- Deep recursion without `--release` (unoptimized code uses more stack)
- Very large functions generated without optimization

Workaround: Build with `--release` to reduce stack usage through optimization.

### Large binary size

WASM binaries can be large for several reasons:

1. **No release mode**: Debug builds include much more code. Always use `--release` for production.
2. **Standard library**: Crystal's stdlib is statically linked. Only used code is included, but the type system can pull in more than expected.

Mitigation:

```bash
# Always build with --release for smaller binaries
bin/crystal build app.cr \
  --target wasm32-unknown-wasi \
  -Dwithout_iconv -Dwithout_openssl \
  --link-flags="--allow-undefined /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/wasm_eh_support.o -lc++abi" \
  --release \
  -o app.wasm

# Check the binary size
ls -lh app.wasm
```

### "Compiling ... failed" with Cranelift errors in Wasmtime

Without `--release`, LLVM can produce extremely large functions (e.g., `String::Grapheme::codepoints` with over 34,000 local variables). Wasmtime's Cranelift compiler may refuse to compile such functions.

Solution: Always build with `--release`, which dramatically reduces the number of locals through optimization.

### Missing library errors during linking

If you see errors about missing `.a` files, ensure `CRYSTAL_LIBRARY_PATH` points to the wasi-sysroot lib directory:

```bash
export CRYSTAL_LIBRARY_PATH=/opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi
ls /opt/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a
```

---

## Known Limitations

- **Exception catching does not work**: `raise` throws correctly but `rescue`/`ensure` do not catch exceptions at runtime. This is the primary blocker for many Crystal programs. Programs that trigger exceptions (including implicit ones from nil assertions, bounds checks, etc.) will trap.
- **No garbage collection**: Uses the leak allocator (`gc/none`). All allocations persist. Long-running programs will exhaust memory.
- **No fiber/concurrency support**: `spawn`, `Fiber.yield`, and `Channel` are stubbed out and do not function.
- **Release mode strongly recommended**: Without `--release`, some functions are too large for Wasmtime's Cranelift compiler. Always use `--release` for WASM builds.
- **No parallelism**: WASM is single-threaded. Crystal's `-Dpreview_mt` multi-threading is not available.
- **No OpenSSL, iconv, or other C libraries**: These must be excluded with `-Dwithout_openssl` and `-Dwithout_iconv`.
- **Requires wasi-sdk at /opt/wasi-sdk**: The `wasm_eh_support.o` file and wasi-libc must be available from the wasi-sdk installation.
- **Requires wasmtime with -W exceptions**: The WASM exception handling proposal must be enabled in the runtime.
- **WASI API is evolving**: This target uses WASI Preview 1 (`snapshot-01`). WASI Preview 2 introduces the Component Model with different APIs, and Preview 3 will add native async I/O. Migration will be needed as runtimes deprecate Preview 1.
- **32-bit address space**: WASM32 has a 4GB address limit. Pointers are 32-bit (`sizeof(Pointer(Void)) == 4`).
- **No backtraces**: The WASM operand stack is opaque, so `Exception#backtrace` returns empty results.

---

## Examples

**Important**: All examples below avoid `raise`/`rescue` since exception catching does not work at runtime yet. Also avoid fibers/channels and any operations that trigger implicit exceptions (like out-of-bounds access).

### Basic Output and String Interpolation

```crystal
puts "Hello from Crystal on WebAssembly!"
puts "1 + 2 = #{1 + 2}"
puts "Array: #{[1, 2, 3]}"
puts "It works!"
```

### Working with Collections

```crystal
names = ["Alice", "Bob", "Charlie"]
lengths = names.map(&.size)
puts lengths.inspect # => [5, 3, 7]

scores = {"math" => 95, "science" => 88, "history" => 92}
average = scores.values.sum / scores.size
puts "Average: #{average}" # => Average: 91
```

### JSON Processing

```crystal
require "json"

data = JSON.parse(%({"name": "Crystal", "target": "wasm32"}))
puts data["name"]   # => Crystal
puts data["target"] # => wasm32
```

### Math and Computation

```crystal
# Fibonacci (iterative to avoid deep recursion)
def fib(n : Int32) : Int64
  a, b = 0i64, 1i64
  n.times { a, b = b, a + b }
  a
end

10.times do |i|
  puts "fib(#{i}) = #{fib(i)}"
end
```

### File Access (with WASI Preopens)

```crystal
# Compile normally, then run with: wasmtime run -W exceptions --dir=. app.wasm
File.write("output.txt", "Written from Crystal WASM!")
content = File.read("output.txt")
puts content # => Written from Crystal WASM!
```
