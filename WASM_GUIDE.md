# Crystal WebAssembly Guide

This guide explains how to compile Crystal programs to WebAssembly (WASM) using the `wasm32-unknown-wasi` target. Crystal compiles to WASM via LLVM's WebAssembly backend and runs on WASI-compatible runtimes like Wasmtime.

---

## Requirements

**Crystal Version**: 1.20.0-dev (this fork: `crimson-knight/crystal`, branch: `wasm-support`)
**Base Crystal**: Built on `crystal-lang/crystal` master (commit `8fa7f90c0`)

### Required Tools

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Crystal | 1.19+ (for bootstrapping) | Compile the compiler itself |
| LLVM | 17.0+ | WebAssembly backend with exception handling support |
| wasm-ld | (bundled with LLVM) | WebAssembly linker |
| wasi-sdk | 21+ | WASI sysroot with wasi-libc |
| Binaryen (wasm-opt) | 116+ | Asyncify pass for fibers and GC stack scanning |
| Wasmtime | 25+ | Primary WASI runtime for executing `.wasm` binaries |

---

## Setup

### macOS

```bash
# 1. Install LLVM 18 (includes wasm-ld)
brew install llvm@18

# Add LLVM to PATH (add to ~/.zshrc or ~/.bash_profile for persistence)
export PATH="$(brew --prefix llvm@18)/bin:$PATH"

# 2. Install Binaryen (provides wasm-opt)
brew install binaryen

# 3. Install Wasmtime
curl https://wasmtime.dev/install.sh -sSf | bash

# 4. Install wasi-sdk
# Download the latest release for macOS from:
#   https://github.com/WebAssembly/wasi-sdk/releases
# Example for wasi-sdk 25:
curl -LO https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sdk-25.0-x86_64-macos.tar.gz
tar xzf wasi-sdk-25.0-x86_64-macos.tar.gz
sudo mv wasi-sdk-25.0-x86_64-macos /opt/wasi-sdk

# Set environment variable
export WASI_SDK_PATH=/opt/wasi-sdk

# 5. Download pre-compiled WASM libraries
# These are pre-compiled .a archives of Crystal's C dependencies (libpcre2, bdwgc, etc.)
# built for wasm32-wasi.
git clone https://github.com/lbguilherme/wasm-libs.git ~/wasm-libs

# Set environment variables
export CRYSTAL_WASM_LIBS=~/wasm-libs
export CRYSTAL_LIBRARY_PATH=~/wasm-libs
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

# 4. Install wasi-sdk
curl -LO https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sdk-25.0-x86_64-linux.tar.gz
tar xzf wasi-sdk-25.0-x86_64-linux.tar.gz
sudo mv wasi-sdk-25.0-x86_64-linux /opt/wasi-sdk

# Set environment variable
export WASI_SDK_PATH=/opt/wasi-sdk

# 5. Download pre-compiled WASM libraries
git clone https://github.com/lbguilherme/wasm-libs.git ~/wasm-libs

# Set environment variables
export CRYSTAL_WASM_LIBS=~/wasm-libs
export CRYSTAL_LIBRARY_PATH=~/wasm-libs
```

### Persist Environment Variables

Add these lines to your shell profile (`~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`):

```bash
export WASI_SDK_PATH=/opt/wasi-sdk
export CRYSTAL_WASM_LIBS=~/wasm-libs
export CRYSTAL_LIBRARY_PATH=~/wasm-libs
```

---

## Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `WASI_SDK_PATH` | Path to the wasi-sdk installation. The compiler uses this to locate the WASI sysroot (`share/wasi-sysroot`) for system headers and libraries. | `/opt/wasi-sdk` |
| `CRYSTAL_WASM_LIBS` | Directory containing pre-compiled WASM `.a` archive files (bdwgc, libpcre2, etc.). | `~/wasm-libs` |
| `CRYSTAL_LIBRARY_PATH` | Crystal's library search path. Should include the WASM libs directory so the linker can find them. | `~/wasm-libs` |

The compiler automatically detects `WASI_SDK_PATH` and adds the sysroot library path (`$WASI_SDK_PATH/share/wasi-sysroot/lib/wasm32-wasi`) to the linker search paths.

---

## Your First WASM App

Create a file called `hello_wasm.cr`:

```crystal
# hello_wasm.cr
puts "Hello from Crystal on WebAssembly!"

# Exception handling works
begin
  raise "Testing exceptions"
rescue ex
  puts "Caught: #{ex.message}"
end

# Fiber concurrency works
ch = Channel(String).new
spawn do
  ch.send("Fibers work too!")
end
puts ch.receive
```

Compile it:

```bash
crystal build hello_wasm.cr --target wasm32-unknown-wasi -o hello.wasm
```

Run it with Wasmtime:

```bash
wasmtime run hello.wasm
```

Expected output:

```
Hello from Crystal on WebAssembly!
Caught: Testing exceptions
Fibers work too!
```

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
- **Exception handling** -- full `raise`/`rescue`/`ensure` support including type dispatch, nested exceptions, re-raise, and custom exception classes
- **Garbage collection** -- Boehm GC compiled to WASM with Asyncify-based stack scanning
- **Fiber concurrency** -- `spawn`, `Fiber.yield`, `Channel` send/receive via Binaryen Asyncify
- **Basic I/O** -- writing to STDOUT and STDERR
- **sleep** -- via WASI `poll_oneoff` clock subscriptions

### Standard Library
- Data structures: `Array`, `Hash`, `Set`, `Deque`, `Slice`, `Tuple`, `NamedTuple`, `StaticArray`
- String processing: `String`, `StringBuilder`, `StringScanner`, `Symbol`
- Encoding: `Base64`, `CSV`, `HTML`, `URI`, `UUID`
- Math: `Complex`, float printing (IEEE, Grisu3)
- JSON: `JSON::Builder`, `JSON::Lexer`, `JSON::Parser`, `JSON.parse`, `to_json`
- Random number generation via WASI `random_get`
- Basic file operations via WASI preopens (directory listing, file reading with `--dir`)

---

## What Doesn't Work

| Feature | Reason |
|---------|--------|
| Threads | WASI has no thread creation API. Crystal runs single-threaded on WASM. |
| Sockets / HTTP | Requires WASI Preview 2 socket support, which is not yet integrated. |
| Signal handling | Not meaningful in the WASM sandbox. Signals are excluded via `flag?(:wasm32)`. |
| Process spawning | WASM sandboxed environment does not support spawning processes. |
| OpenSSL / TLS | Would require OpenSSL cross-compiled to WASM. Not currently available. |
| Full file system | Limited to WASI preopens. Only directories explicitly granted by the runtime are accessible. |
| Call stack / backtraces | The WASM operand stack is opaque; backtraces return empty. |
| iconv | Not available on WASM. Use `-Dwithout_iconv`. |

---

## Compilation Flags

### Target Flag (Required)

```bash
--target wasm32-unknown-wasi
```

This tells Crystal and LLVM to emit WebAssembly targeting the WASI interface.

### Recommended Flags

| Flag | Purpose |
|------|---------|
| `--target wasm32-unknown-wasi` | Target the WASM/WASI platform |
| `-Dwithout_iconv` | Skip iconv, which is not available on WASM |
| `-Dwithout_openssl` | Skip OpenSSL, which is not available on WASM |
| `--release` | Enable optimizations. Strongly recommended for WASM. Reduces code size significantly and avoids Cranelift compilation failures on very large functions. |

### Example: Full Build Command

```bash
# Debug build
crystal build app.cr --target wasm32-unknown-wasi -Dwithout_iconv -Dwithout_openssl -o app.wasm

# Release build (recommended)
crystal build app.cr --target wasm32-unknown-wasi -Dwithout_iconv -Dwithout_openssl --release -o app.wasm
```

### What Happens During Compilation

The compiler performs these steps for WASM targets:

1. **Crystal codegen** -- Crystal source is compiled to LLVM IR with WASM-specific features enabled (exception handling, bulk memory, mutable globals, sign extension, non-trapping float-to-int). The compiler forces `single_module` mode for WASM.
2. **LLVM compilation** -- LLVM IR is compiled to a `.o` WebAssembly object file.
3. **Linking** -- `wasm-ld` links the object file with wasi-libc and any pre-compiled WASM libraries. The linker uses `--stack-first -z stack-size=8388608` to place the stack before data (preventing silent stack overflow corruption) and set an 8MB stack.
4. **Asyncify pass** -- `wasm-opt --asyncify --all-features` transforms the binary to support fiber switching and GC stack scanning via Binaryen's Asyncify instrumentation.
5. **Optimization** (release only) -- `wasm-opt -Oz --all-features` optimizes for code size.

---

## Running WASM Programs

### Wasmtime (Recommended)

```bash
# Basic execution
wasmtime run app.wasm

# Grant file system access to the current directory
wasmtime run --dir=. app.wasm

# Grant access to a specific directory
wasmtime run --dir=/path/to/data app.wasm

# Pass command-line arguments
wasmtime run app.wasm -- arg1 arg2

# Set environment variables
wasmtime run --env MY_VAR=value app.wasm
```

The `--dir=.` flag grants the WASM program access to the current directory via WASI preopens. Without it, the program cannot read or write any files.

### Wasmer

```bash
# Basic execution
wasmer run app.wasm

# With file system access
wasmer run --dir=. app.wasm
```

Note: Wasmer's singlepass compiler may crash on ARM64. Use Wasmtime on Apple Silicon Macs.

### Node.js

Node.js supports WASI through its built-in `node:wasi` module:

```javascript
// run_wasm.mjs
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const wasi = new WASI({
  version: "preview1",
  args: process.argv.slice(1),
  preopens: { "/": "." },
});

const wasm = await WebAssembly.compile(await readFile("./app.wasm"));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
wasi.start(instance);
```

Run with:

```bash
node --experimental-wasi-unstable-preview1 run_wasm.mjs
```

### Browser

Crystal WASM binaries target WASI and cannot run directly in the browser without a WASI polyfill. A thin JavaScript wrapper using a library like `@aspect-build/aspect-wasi` or `browser_wasi_shim` is needed to provide the WASI interface. Browser support is experimental.

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

1. **Tool presence**: Crystal, wasm-ld, wasm-opt, wasmtime, LLVM
2. **Environment variables**: `WASI_SDK_PATH`, `CRYSTAL_WASM_LIBS`, `CRYSTAL_LIBRARY_PATH`
3. **Compilation tests** (full mode only):
   - Exception handling (basic raise/rescue, type dispatch, ensure blocks)
   - Garbage collection (allocation, `GC.collect`)
   - Fiber concurrency (spawn/yield, channel send/receive)
   - Event loop (sleep via `poll_oneoff`)
   - WASM-specific spec files in `spec/wasm32/`

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

### Exception Handling

Crystal's exceptions use LLVM's funclet-based exception handling model (catchswitch/catchpad/catchret). LLVM's WASM backend translates this to WASM's native exception handling instructions (`try_table`/`throw`/`throw_ref`), which are enabled via the `+exception-handling` target feature. The WASM EH proposal is standardized and supported by all major runtimes.

### Fiber Switching via Asyncify

WASM's call stack and operand stack are opaque -- user code cannot inspect or modify them directly. Crystal uses Binaryen's **Asyncify** transformation to enable fiber switching:

1. `wasm-opt --asyncify` instruments every function with suspend/resume logic.
2. When a fiber yields, Asyncify **unwinds** the call stack by having each frame serialize its locals to a buffer in linear memory, then return.
3. When a fiber resumes, Asyncify **rewinds** by re-entering the function chain and restoring locals from the buffer.
4. The WASM `__stack_pointer` global (the shadow stack pointer) is saved and restored separately via inline WASM assembly.

Each fiber has its own stack region in linear memory. The region holds both the shadow stack (growing downward) and the Asyncify buffer (growing upward from a header):

```
+--------+---------------------------+------------------------+
| Header | Asyncify buffer =>        |               <= Stack |
+--------+---------------------------+------------------------+
^        ^                                                    ^
stack_low  (+ header)                                    stack_top
```

### Garbage Collection

Boehm GC (bdwgc) is cross-compiled to WASM. The core challenge is stack scanning: GC needs to find root pointers on the stack, but WASM locals are invisible. Asyncify solves this by spilling all locals to linear memory during an unwind, allowing the GC to scan the buffer for pointer-like values (conservative scanning).

### Event Loop

The WASI event loop (`Crystal::EventLoop::Wasi`) uses WASI's `poll_oneoff` syscall with clock subscriptions for sleep/timeout functionality. It supports cooperative fiber scheduling through the Asyncify mechanism. Socket-based I/O events are not yet supported (requires WASI Preview 2).

---

## Troubleshooting

### "wasm-ld: error: unable to find library -lc"

The linker cannot find wasi-libc. Set the `WASI_SDK_PATH` environment variable:

```bash
export WASI_SDK_PATH=/opt/wasi-sdk
```

Verify the sysroot exists:

```bash
ls $WASI_SDK_PATH/share/wasi-sysroot/lib/wasm32-wasi/libc.a
```

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

You are running an older Crystal compiler that does not have WASM exception handling support. The `__crystal_raise` stub in older versions simply prints this message and calls `exit(1)`. Use this fork (`crimson-knight/crystal`, branch `wasm-support`) which implements full WASM exception handling.

### "out of bounds memory access" (runtime trap)

This usually indicates a stack overflow. The default 8MB stack may be insufficient for deeply recursive programs or programs with many large stack frames. Possible causes:

- Deep recursion without `--release` (unoptimized code uses more stack)
- Very large functions generated without optimization (Asyncify overhead)

Workaround: Build with `--release` to reduce stack usage through optimization.

### Large binary size

WASM binaries can be large for several reasons:

1. **Asyncify overhead**: The Asyncify transformation adds 10-50% to code size because every function is instrumented with suspend/resume logic.
2. **No release mode**: Debug builds include much more code. Always use `--release` for production.
3. **Standard library**: Crystal's stdlib is statically linked. Only used code is included, but the type system can pull in more than expected.

Mitigation:

```bash
# Always build with --release for smaller binaries
crystal build app.cr --target wasm32-unknown-wasi --release -o app.wasm

# Check the binary size
ls -lh app.wasm
```

### "Compiling ... failed" with Cranelift errors in Wasmtime

Without `--release`, LLVM can produce extremely large functions (e.g., `String::Grapheme::codepoints` with over 34,000 local variables). The Asyncify pass makes these larger. Wasmtime's Cranelift compiler may refuse to compile such functions.

Solution: Always build with `--release`, which dramatically reduces the number of locals through optimization.

### Missing library errors during linking

If you see errors about missing `.a` files (e.g., `-lgc`, `-lpcre2-8`), the pre-compiled WASM libraries are not found. Ensure `CRYSTAL_LIBRARY_PATH` points to the directory containing the WASM `.a` files:

```bash
export CRYSTAL_LIBRARY_PATH=~/wasm-libs
ls ~/wasm-libs/*.a
```

---

## Known Limitations

- **Asyncify code size overhead**: Asyncify adds 10-50% code size because it instruments every function for suspend/resume. Future versions may use `--asyncify-only-list` to limit instrumentation to functions that actually need it.
- **Release mode strongly recommended**: Without `--release`, some functions are too large for Wasmtime's Cranelift compiler. Always use `--release` for WASM builds.
- **No parallelism**: WASM is single-threaded. Crystal's `-Dpreview_mt` multi-threading is not available. All fibers run cooperatively on one thread.
- **bdwgc cross-compilation**: The Boehm GC must be separately cross-compiled for WASM with threads and parallel marking disabled. The pre-compiled libraries from `lbguilherme/wasm-libs` include this.
- **WASI API is evolving**: This target uses WASI Preview 1 (`snapshot-01`). WASI Preview 2 introduces the Component Model with different APIs, and Preview 3 will add native async I/O. Migration will be needed as runtimes deprecate Preview 1.
- **32-bit address space**: WASM32 has a 4GB address limit. Pointers are 32-bit (`sizeof(Pointer(Void)) == 4`).
- **No backtraces**: The WASM operand stack is opaque, so `Exception#backtrace` returns empty results.

---

## Examples

### JSON Processing

```crystal
require "json"

data = JSON.parse(%({"name": "Crystal", "target": "wasm32"}))
puts data["name"]   # => Crystal
puts data["target"] # => wasm32

record Person, name : String, age : Int32 do
  include JSON::Serializable
end

person = Person.from_json(%({"name": "Alice", "age": 30}))
puts person.to_json # => {"name":"Alice","age":30}
```

### Concurrent Computation with Channels

```crystal
ch = Channel(Int32).new

10.times do |i|
  spawn do
    ch.send(i * i)
  end
end

sum = 0
10.times do
  sum += ch.receive
end
puts "Sum of squares: #{sum}" # => Sum of squares: 285
```

### File Access (with WASI Preopens)

```crystal
# Run with: wasmtime run --dir=. app.wasm
File.write("output.txt", "Written from Crystal WASM!")
content = File.read("output.txt")
puts content # => Written from Crystal WASM!
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
