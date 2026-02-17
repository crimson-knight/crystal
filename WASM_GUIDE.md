# Crystal WebAssembly (WASM) Target

Crystal can compile to the `wasm32-wasi` target, producing WebAssembly modules
that run in WASI-compatible runtimes (wasmtime, wasmer) or in web browsers with
a WASI shim.

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Crystal | 1.19+ | Host compiler |
| LLVM | 18+ | Must include `wasm-ld` (the WASM linker) |
| Binaryen | 126+ | `wasm-opt` and `wasm-merge` for post-link processing |
| wasmtime | 29+ | WASI runtime to execute `.wasm` binaries |
| WASI SDK | 21+ | WASI sysroot (libc headers and libraries) |
| wasm-libs | 0.0.3+ | Pre-compiled WASM libraries (libgc, libpcre2) |

### Environment Variables

```bash
# Path to WASI SDK installation (contains share/wasi-sysroot/)
export WASI_SDK_PATH=/path/to/wasi-sdk

# Path to pre-compiled WASM libraries (libgc.a, libpcre2-8.a, etc.)
export CRYSTAL_WASM_LIBS=/path/to/wasm32-wasi-libs
```

### Compile and Run

```bash
# Compile to WASM
crystal build hello.cr -o hello.wasm \
  --target wasm32-wasi \
  -Dwithout_iconv -Dwithout_openssl

# Run with wasmtime
wasmtime run -W exceptions=y hello.wasm

# Grant file system access (for programs that read/write files)
wasmtime run -W exceptions=y --dir /path/to/data hello.wasm
```

The `-Dwithout_iconv` and `-Dwithout_openssl` flags are required because these
C libraries are not available as WASM builds. See [What's Not Available](#whats-not-available)
for details.

### Hello World

```crystal
# hello.cr
puts "Hello from Crystal WASM!"
puts "Crystal #{Crystal::VERSION}"

begin
  raise "it works!"
rescue ex
  puts "Exceptions work: #{ex.message}"
end

arr = [1, 2, 3, 4, 5]
puts "Array: #{arr.map { |x| x * 2 }}"
```

## What Works

### Core Language

All core Crystal language features work on WASM:

- **Types**: Int8/16/32/64, UInt8/16/32/64, Float32/64, Bool, Char, String, Symbol, Nil
- **Collections**: Array, Hash, Set, Deque, Slice, Tuple, NamedTuple, StaticArray, BitArray
- **Control flow**: if/else, case/when, while, until, begin/rescue/ensure
- **OOP**: Classes, structs, modules, inheritance, generics, abstract types
- **Blocks and closures**: Procs, blocks, yield
- **Macros**: Full macro system
- **Union types, type restrictions, overloading**

### Standard Library

| Module | Status | Notes |
|--------|--------|-------|
| **String** | Works | Full UTF-8 support. No encoding conversion (no iconv). |
| **Regex** | Works | PCRE2 is pre-compiled for WASM. |
| **JSON** | Works | Parsing, building, serialization. |
| **Math** | Works | All math operations, Complex numbers. |
| **Random** | Works | Uses WASI `random_get` syscall. |
| **Time::Span** | Works | Duration arithmetic and formatting. |
| **IO** | Partial | Read/write to stdout/stderr/files. No pipes. |
| **File** | Partial | Open, read, write within preopened directories. See [File I/O](#file-io). |
| **Dir** | Partial | List, create, delete within preopened directories. |
| **Crypto** | Partial | BCrypt, Blowfish, Subtle (no OpenSSL). |
| **Spec** | Works | Test framework runs. `expect_raises` is a no-op. |
| **Base64** | Works | |
| **CSV** | Works | |
| **URI** | Works | |
| **UUID** | Works | Uses Crystal digest fallback (no OpenSSL). |
| **OptionParser** | Works | |
| **SemanticVersion** | Works | |
| **Comparable, Indexable, Iterator** | Works | |

### Exception Handling

Crystal's exception handling compiles to native WebAssembly exception instructions
(`try_table`/`throw`/`exnref`). This is zero-cost on the happy path -- no overhead
when exceptions aren't thrown.

- `raise` / `rescue` / `ensure`
- Type-based exception dispatch (`rescue ex : MyError`)
- Nested exceptions
- Custom exception classes
- Re-raise with `raise ex`

**Limitation**: Bare `raise` (re-raise without an argument) is not yet supported.

### Garbage Collection

Boehm GC is compiled for WASM and runs automatically. `GC.collect` and `GC.stats`
work. The stack is placed first in linear memory (`--stack-first`) with 8MB to
prevent silent heap corruption.

**How GC scanning works on WASM**: Boehm GC performs conservative stack scanning
over the linear memory stack. On native platforms, GC must also scan CPU registers
for live pointers. On WASM, there are no directly accessible CPU registers --
instead, values live in WASM locals (a virtual register file). However, LLVM
naturally spills most values to the linear memory stack during compilation, so the
conservative stack scan catches the majority of live pointers without special
handling.

**Why `--spill-pointers` is disabled**: Binaryen provides a `--spill-pointers`
pass that forces all pointer-typed WASM locals onto the linear memory stack,
ensuring GC can find every root. Crystal has this pass disabled because:

1. It has known bugs (incorrect stack frame sizing, breaks at `-O1`)
2. It is incompatible with Asyncify -- running both passes together produces
   incorrect output (confirmed by the Binaryen maintainer in
   emscripten/emscripten#18251)
3. Crystal uses Asyncify for fiber switching, so the two cannot coexist

**Recommended long-term fix**: Emscripten's approach uses `emscripten_scan_registers`,
which triggers an Asyncify unwind to capture all live WASM locals into linear
memory, then scans them. This is compatible with Asyncify because it uses the
same mechanism rather than fighting it. Implementing an equivalent in Crystal's
GC integration would guarantee all roots are visible to the collector.

**When you might see GC issues**: In practice, GC works reliably because LLVM
spills aggressively. A theoretical risk exists when a pointer is held only in a
WASM local (never spilled to the linear memory stack) during a GC collection.
This is rare -- it would require heavy allocation pressure where the sole
reference to a live object exists only in a WASM local at the exact moment GC
runs.

### Fibers and Channels

Cooperative multitasking works via Binaryen's Asyncify transformation:

```crystal
spawn { puts "from a fiber!" }
Fiber.yield

ch = Channel(Int32).new
spawn { ch.send(42) }
puts ch.receive  # => 42
```

**Known limitations**:

- Unbuffered channels with multiple sequential sends can deadlock
- `GC.collect` during fiber yield + channel operations can corrupt memory
- All fibers run on a single thread (no parallelism)
- Asyncify instruments every function, adding ~50% code size overhead

### File I/O

WASI uses a **capability-based** file system. Programs can only access directories
that the runtime explicitly grants via `--dir` flags:

```bash
# Grant access to current directory and /tmp
wasmtime run -W exceptions=y --dir . --dir /tmp hello.wasm
```

```crystal
# Reading files (directory must be preopened)
content = File.read("data.txt")

# Writing files
File.write("output.txt", "Hello WASM!")

# Directory listing
Dir.entries(".").each { |e| puts e }
```

**Not available**: `File.chmod`, `File.chown`, `File.delete`, `File.realpath`,
file locking, blocking mode changes.

## What's Not Available

### Networking (No Sockets)

WASI Preview 1 has **no socket API**. All networking operations raise
`NotImplementedError`:

- `TCPSocket`, `UDPSocket`, `UNIXSocket`
- `HTTP::Client`, `HTTP::Server`
- DNS resolution (`Socket::Addrinfo`)
- WebSocket

WASI Preview 2 adds socket support, but Crystal does not yet target it.

### Process Management

WASM runs in a sandboxed environment with no process control:

- `Process.fork`, `Process.run`, `Process.exec` -- not available
- `System.hostname` -- not available
- Signal handling -- entirely excluded
- `Process.pid` returns `1` (hardcoded)

### Threading

WebAssembly is **single-threaded**. Crystal's `-Dpreview_mt` flag is not
supported. Mutexes and condition variables are no-ops. Use fibers for
concurrency.

### Missing C Libraries

These Crystal features require C libraries that aren't compiled for WASM:

| Feature | Requires | Flag to Disable |
|---------|----------|----------------|
| String encoding conversion | libiconv | `-Dwithout_iconv` |
| TLS/SSL, HTTPS | OpenSSL | `-Dwithout_openssl` |
| `BigInt`, `BigFloat` | libgmp | N/A (link error) |
| `Compress::Gzip`, `Compress::Zlib` | zlib | N/A (link error) |
| `YAML` | libyaml | N/A (link error) |
| `XML` | libxml2 | N/A (link error) |

### Other Limitations

- **Call stack backtraces**: Exception backtraces return an empty array (WASM
  limitation -- the call stack is opaque)
- **TTY operations**: No terminal echo/raw mode
- **User/group info**: `System::User` and `System::Group` not available
- **Log backend**: Defaults to synchronous dispatch (no async)

## Running in a Browser

Crystal compiles to `wasm32-wasi`, which requires a WASI implementation to run.
Browsers don't provide WASI natively, so you need a JavaScript shim.

### Required WebAssembly Proposals

Your browser must support these WebAssembly proposals:

| Proposal | Chrome | Firefox | Safari |
|----------|--------|---------|--------|
| Exception Handling (exnref) | 126+ | 131+ | 18.2+ |
| Bulk Memory | 75+ | 79+ | 15+ |
| Multi-value | 85+ | 78+ | 15+ |
| Reference Types | 96+ | 79+ | 15+ |
| Mutable Globals | 74+ | 61+ | 13.1+ |
| Sign Extension | 74+ | 62+ | 14.1+ |

**The bottleneck is Exception Handling with exnref** -- you need a recent browser.

### Minimal WASI Shim

A Crystal WASM binary imports 14 functions from `wasi_snapshot_preview1`. For a
basic program that only writes to stdout, you need to implement:

| Import | Purpose |
|--------|---------|
| `fd_write` | Write to stdout/stderr |
| `proc_exit` | Clean exit |
| `args_get` / `args_sizes_get` | Command line arguments |
| `environ_get` / `environ_sizes_get` | Environment variables |
| `clock_time_get` | Current time |
| `random_get` | Random bytes (for GC, hashing) |
| `fd_close` / `fd_seek` / `fd_pread` | File descriptor operations |
| `fd_fdstat_get` / `fd_fdstat_set_flags` | File descriptor metadata |
| `poll_oneoff` | Event polling (for sleep/event loop) |

See `samples/wasm/index.html` for a complete working example with an inline
WASI shim.

### Browser Example

```html
<script>
// Fetch and run the WASM module
const response = await fetch('hello.wasm');
const wasmBytes = await response.arrayBuffer();

const importObject = {
  wasi_snapshot_preview1: createWasiShim(text => {
    document.getElementById('output').textContent += text;
  })
};

const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
instance.exports._start();
</script>
```

### Serving WASM Files

WASM files must be served with the correct MIME type. Use any HTTP server:

```bash
python3 -m http.server 8080
```

Your server must return `Content-Type: application/wasm` for `.wasm` files.
Most modern HTTP servers do this automatically.

## Build Pipeline

Understanding the compilation pipeline helps with debugging:

```
Crystal Source (.cr)
    │
    ▼  crystal build --target wasm32-wasi
LLVM IR → WASM Object (.o)
    │
    ▼  wasm-ld (links wasi-libc, libgc, libpcre2, etc.)
Linked WASM Module (.wasm) — uses legacy exception handling format
    │
    ▼  wasm-opt --asyncify (Binaryen)
Asyncify-instrumented WASM — fiber switching enabled
    │
    ▼  wasm-merge (Binaryen)
Merged WASM — asyncify_helper.wasm combined with main module
    │
    ▼  wasm-opt --translate-to-exnref (Binaryen)
Final WASM — uses modern try_table/exnref exception format
```

**Why legacy EH then translate?** Binaryen's Asyncify pass doesn't yet support
the new `try_table`/`exnref` instructions. The workaround is: compile with
legacy EH format → run Asyncify → convert to new EH format. This produces
correct output that all modern runtimes support.

### Build Flags

| Flag | Purpose |
|------|---------|
| `--target wasm32-wasi` | Select WASM target |
| `-Dwithout_iconv` | Disable iconv (required, not available for WASM) |
| `-Dwithout_openssl` | Disable OpenSSL (required, not available for WASM) |
| `--release` | Enable optimizations (recommended, significantly reduces binary size) |
| `--error-trace` | Show full error traces in compiler errors |

### Binary Size

A hello-world program compiles to roughly **1-6 MB** depending on optimization:

- **Debug mode** (~6 MB): All functions asyncify-instrumented, no optimization
- **Release mode** (~1-2 MB): `-Oz` applied by Binaryen, dead code eliminated

The main contributors to binary size are:

- Boehm GC library
- PCRE2 library (loaded via prelude for Regex)
- Asyncify instrumentation overhead (~50% increase)
- wasi-libc

## Troubleshooting

### "exceptions feature required"

Your WASI runtime needs exception handling enabled:

```bash
wasmtime run -W exceptions=y program.wasm
```

### "wasm trap: call stack exhausted"

The default WASM stack (8MB) was exceeded. This can happen with:

- Very deep recursion
- Fibers spawned inside standalone programs (a known issue with the asyncify
  unwind loop -- use the spec framework or simpler fiber patterns)

### Link errors about missing libraries

Ensure `WASI_SDK_PATH` and `CRYSTAL_WASM_LIBS` are set correctly and contain
the required `.a` files (libgc.a, libpcre2-8.a at minimum).

### "command not found: wasm-ld"

LLVM's WASM linker must be in your PATH. It's typically installed as
`wasm-ld-18` and needs a symlink:

```bash
sudo ln -s $(which wasm-ld-18) /usr/bin/wasm-ld
```

### Browser: "CompileError" or "WebAssembly.Exception"

Your browser may not support the required WebAssembly proposals. Update to the
latest version of Chrome (126+) or Firefox (131+).
