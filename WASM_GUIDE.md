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
over the linear memory stack (the shadow stack, which `__stack_pointer` points
into). On native platforms, GC must also scan CPU registers for live pointers.
On WASM, there are no directly accessible CPU registers: values live in WASM
locals (a virtual register file) that no code can scan. In an optimized build
LLVM keeps most pointers in locals, so an object whose only reference is a
local would be invisible to the collector and freed while still in use.

**`--spill-pointers` runs in every build with a collector**: the post-link step
runs Binaryen's `--spill-pointers`, which stores every pointer-sized local that
is live across a call on the shadow stack before the call, so the scan sees it.
It runs with or without fibers, and is skipped only with `-Dgc_none`, where
there is nothing to scan. In a build with fibers it runs first, in the same
`wasm-opt` run as `--asyncify` and before it: to asyncify the frame it reserves
is ordinary code, like the frame LLVM reserves, so an unwind leaves the frame in
place for the suspended fiber and a rewind restores the local that points at
it. (Run after asyncify, it would also instrument asyncify's own unwind and
rewind paths, the combination emscripten/emscripten#18251 warns about.) The two
passes share one run because `wasm-opt` drops the name section when it writes a
module, and asyncify finds `_start`, the boundary it must leave alone, by name.

**The heap is never unmapped**: bdwgc returns heap blocks that stay free for
a few collections to the system with `munmap`. WASI's emulated `munmap` can
only release a whole region its own `mmap` returned, so unmapping part of the
heap fails and the module aborts with an `unreachable` trap (after about
20,000 rounds of the load-and-dump fixture). Linear memory never shrinks
anyway, so `GC.init` sets `GC_unmap_threshold` to 0 on wasm32 and the
collector reuses every free block. Programs need no `GC.disable`,
`GC.collect` or unmap setting of their own;
`spec/compiler-cli/fixtures/wasm32-gc-load-dump.cr` runs 60,000 rounds with
automatic collections in a 4 MiB heap.

**Each fiber has its own shadow stack**: a spawned fiber's stack region holds a
16-byte header, its asyncify buffer in the lower quarter, and its shadow stack,
which grows down from the top through the rest. `swapcontext` records
`__stack_pointer` as the fiber's `stack_top` before it unwinds, and `_start`
sets `__stack_pointer` to the next fiber's `stack_top` before it starts or
rewinds that fiber. Another fiber therefore never writes over the frames of a
suspended one, and the collector scans the running fiber's shadow stack (the
scheduler sets the collector's stack bottom to it) and each suspended fiber's
from `stack_top` to the stack's bottom.

**Cost**: on Deck Designer's wasm core (`--release --no-debug`, fibers on), the
module grows from 1,448,587 to 2,130,236 bytes (542,999 to 677,035 gzipped),
and its 300-call replay takes about 760 ms, against about 345 ms for the same
core built with `-Dfrontend_no_fibers` (1,239,074 bytes, 298,022 gzipped). A
program that never switches fibers should still build with
`-Dfrontend_no_fibers`, which skips asyncify.

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
    ▼  wasm-opt --spill-pointers --asyncify (Binaryen; one run, spill first;
    │  --spill-pointers only with a collector)
Asyncify-instrumented WASM — fiber switching enabled, pointers visible to the GC
    │
    ▼  wasm-merge (Binaryen)
Merged WASM — asyncify_helper.wasm combined with main module
    │
    ▼  wasm-opt --translate-to-exnref (Binaryen)
WASM using the modern try_table/exnref exception format
    │
    ▼  wasm-opt -O1/-O2/-O3/-Os/-Oz (the compiler's optimization level; none at -O0)
Final WASM
```

Without fibers (`-Dfrontend_no_fibers`) the asyncify and wasm-merge steps are
skipped, and the first run is `--spill-pointers` alone. The last pass uses
the same level as the compiler (`--release` is `-O3`), so a release module
gets a final `wasm-opt -O3`.

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
| `--no-debug` | Leave out debug information; with it the module carries no absolute source paths |
| `-Dfrontend_no_fibers` | No fibers: no asyncify pass, so every function runs faster and the module is about half the size |
| `-Dgc_none` | No collector: memory is allocated with `malloc` and never freed |
| `-Dwithout_main` | Build a WASI reactor (`_initialize` and exports) instead of a command (`_start`) |
| `-Dlean_unreachable` | A left-out dispatch branch traps instead of printing an error |
| `--error-trace` | Show full error traces in compiler errors |

See [Lean release builds](#lean-release-builds) for when to use the last five.

### Binary Size

A hello-world program compiles to roughly **1-6 MB** depending on optimization:

- **Debug mode** (~6 MB): All functions asyncify-instrumented, no optimization
- **Release mode** (~0.5-2 MB): `wasm-opt -O3` applied by Binaryen, dead code eliminated
- **Lean release** (a few hundred KB): see [Lean release builds](#lean-release-builds)

The main contributors to binary size are:

- Boehm GC library
- PCRE2 library (loaded via prelude for Regex)
- Asyncify instrumentation overhead (~50% increase)
- wasi-libc

## Lean release builds

A module that a page or another host calls, and that never switches fibers,
can leave out the fiber layer, the collector and the debug information. That
is how the Box3D physics port came in smaller and faster than box3d-wasm, the
C engine compiled with Emscripten.

### The recipe

```bash
crystal build app.cr -o app.wasm \
  --target wasm32-wasi \
  -Dwithout_mt -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib \
  -Dfrontend_no_fibers -Dgc_none \
  --release --no-debug
```

| Part | What it does |
|------|--------------|
| `-Dfrontend_no_fibers` | Leaves out the fiber layer and the asyncify pass, which instruments every function. On the Box3D port this alone took a replay from 61.2 ms to 36.9 ms. |
| `-Dgc_none` | No collector: allocation goes to `malloc`, nothing is ever freed, and libgc is not linked. Use it when the module allocates a bounded amount (a fixed world, buffers it reuses); a module that keeps allocating will run out of memory. |
| `--release` | `-O3` and a single LLVM module, then a final `wasm-opt -O3` in the post-link step. |
| `--no-debug` | No DWARF, and with it no absolute source paths in the module. |

For the module in `spec/compiler-cli/fixtures/wasm32-lean-release.cr` the
recipe gives 71 KB gzipped against 183 KB for a plain `--release` build. The
spec in `spec/compiler-cli/crystal-build-wasm32_spec.cr` holds it under a
recorded ceiling and checks it carries no path under `$HOME`.

The recipe keeps exception handling: `raise` and `rescue` work, and an
exception that is not rescued reaches the host as a WebAssembly exception.

### Optional: `-Dwithout_main` for a WASI reactor

A module whose host calls its exports, rather than running it once, is a WASI
reactor. With `-Dwithout_main` on wasm32-wasi:

- the module has no `_start`; the standard library defines `_initialize`,
  which sets up the runtime and runs the program's top-level code;
- the host calls `_initialize` once, then any exported `fun`;
- the command exit path is left out: no `at_exit` handlers, no printing of an
  unhandled exception and its backtrace, no flushing of `STDOUT` (call
  `STDOUT.flush` in an export that prints);
- it needs `-Dfrontend_no_fibers`, because only `_start` can switch fibers; a
  reactor build without it stops with a compile error.

```crystal
module Counter
  class_property total = 0
end

Counter.total = 100 # runs in _initialize

fun counter_add(amount : Int32) : Int32
  Counter.total += amount
end
```

```js
const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi });
instance.exports._initialize();
instance.exports.counter_add(5); // => 105
```

On the Box3D port the reactor entry took the data section from 164 KB to 7 KB:
the exit path pulled in backtrace printing and the table of type names.

### Optional: `-Dlean_unreachable`

The compiler leaves out the dispatch branches for types a program never
creates. If such a type arrives after all (a compiler bug), the program
normally prints an "Unreachable type" error with the type, the call and its
source location. With `-Dlean_unreachable` the program traps there instead,
and carries neither the message, the type names nor the locations. It only
changes what that bug looks like; `-Dno_prune_dispatch` turns pruning off.

### Pinning the tools

The compiler runs `wasm-ld`, `wasm-opt` and, with fibers, `wasm-merge` from
the `PATH`. Set the SHA-256 each must have, and the build stops before it
links when one differs:

```bash
export CRYSTAL_WASM_LD_SHA256=$(shasum -a 256 "$(realpath "$(which wasm-ld)")" | cut -d' ' -f1)
export CRYSTAL_WASM_OPT_SHA256=$(shasum -a 256 "$(realpath "$(which wasm-opt)")" | cut -d' ' -f1)
export CRYSTAL_WASM_MERGE_SHA256=$(shasum -a 256 "$(realpath "$(which wasm-merge)")" | cut -d' ' -f1)
```

Record the values once, from the exact releases you install (for example
Binaryen 126 and LLD 23.1.2 from Homebrew), and set them in CI from that
record rather than computing them on each run. The hash covers the
executable itself (after resolving symlinks), not the shared libraries it
loads.

### Source paths in the module

A wasm32 module never decodes a backtrace, so with `--no-debug` it carries no
absolute source paths:

- the standard library does not register its files in the backtrace skip list
  on wasm32;
- the source locations the compiler writes into runtime messages (a failed
  cast, an unreachable type) are relative to the `CRYSTAL_PATH` entry or the
  working directory, for example `crystal/at_exit_handlers.cr:24:43`;
- `Crystal::PATH`, `Crystal::CACHE_DIR` and the other predefined constants are
  only emitted when the program reads them.

`__FILE__` and `__DIR__` in your own code still expand to absolute paths.
Check a build with `strings app.wasm | grep -c "$HOME"`, which should print 0.

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
