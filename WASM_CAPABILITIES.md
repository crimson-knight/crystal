# Crystal WebAssembly Capabilities Reference

**Version**: Alpha 0.1.0
**Target**: `wasm32-wasi` (WASI Preview 1)
**Crystal**: master HEAD (post-1.19.1)
**LLVM**: 18+
**Binaryen**: 117+
**Last Updated**: 2026-02-16

---

## Quick Start

### Build Commands

Compile Crystal source to a `.wasm` binary:

```sh
crystal build hello.cr -o hello.wasm \
  --target wasm32-wasi \
  -Dwithout_iconv \
  -Dwithout_openssl
```

Run with wasmtime (CLI):

```sh
wasmtime run -W exceptions=y hello.wasm
```

Serve in the browser (requires an HTTP server for `fetch()` to work):

```sh
python3 -m http.server 8080
# Then open http://localhost:8080/index.html
```

Or use the included Crystal static file server:

```sh
crystal run samples/wasm/server.cr
# Then open http://localhost:8080
```

### Minimal Example

```crystal
# hello.cr
puts "Hello from Crystal WASM!"
puts "Crystal version: #{Crystal::VERSION}"
puts "Math: 1 + 1 = #{1 + 1}"

arr = [10, 20, 30]
puts "Array sum: #{arr.sum}"

h = {"name" => "Crystal", "target" => "wasm32"}
puts "Hash: #{h}"
```

Compile and run:

```sh
crystal build hello.cr -o hello.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
wasmtime run -W exceptions=y hello.wasm
```

---

## Compilation

### Required Tools

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Crystal compiler | 1.19.1+ (or master HEAD) | Compiles `.cr` source to `.wasm` via LLVM |
| LLVM | 18+ | Backend code generation for `wasm32-wasi` target |
| Binaryen (`wasm-opt`, `wasm-merge`) | 117+ | Post-link pipeline: asyncify instrumentation, EH translation, optimization |
| wasmtime | 14+ | CLI WASM runtime for testing (must support `-W exceptions=y`) |
| wasm-objdump (optional, from wabt) | any | Used by `validate_wasm.sh` to inspect WASM imports |
| Pre-compiled WASM libraries | see below | `libgc.a`, `libpcre2-8.a`, `libc.a` (wasi-sysroot) |

### Compile Flags

| Flag | Required | Description |
|------|----------|-------------|
| `--target wasm32-wasi` | Yes | Sets compilation target to 32-bit WebAssembly with WASI syscalls |
| `-Dwithout_iconv` | Yes | Disables iconv (character encoding conversion). Not available cross-compiled for WASM. |
| `-Dwithout_openssl` | Yes | Disables OpenSSL bindings. Not available cross-compiled for WASM. |
| `-o output.wasm` | Recommended | Specifies output filename |

### Post-Link Pipeline

After the Crystal compiler produces a raw `.wasm` file, Binaryen performs critical transformations:

1. **Asyncify** (`wasm-opt --asyncify`): Instruments all functions to support stack unwinding and rewinding through linear memory buffers. This enables cooperative multitasking (fiber context switching) on WebAssembly, where the call stack is otherwise opaque. The `_start` function is excluded via `--asyncify-removelist` because it serves as the asyncify boundary.

2. **wasm-merge**: Combines the main WASM module with `asyncify_helper.wasm`, resolving bidirectional imports:
   - Main module's `crystal_*` imports resolve to helper's `crystal_*` exports
   - Helper's `asyncify_*` imports resolve to main module's `asyncify_*` exports (created by the asyncify pass)

3. **Exception Handling Translation** (`--translate-to-exnref`): Translates legacy WASM exception handling to the modern `exnref` proposal format for browser compatibility.

4. **Optimization** (`wasm-opt -O`): Standard WASM optimization pass for size and speed.

---

## Language Features

### Fully Supported

Every feature listed below has been tested and confirmed working on `wasm32-wasi`.

**Primitive Types**

All Crystal numeric types work. Note that on `wasm32`, pointer size is 32 bits.

```crystal
x : Int8 = 127_i8
y : Int16 = 32767_i16
z : Int32 = 2_147_483_647
w : Int64 = 9_223_372_036_854_775_807_i64
a : UInt8 = 255_u8
b : UInt16 = 65535_u16
c : UInt32 = 4_294_967_295_u32
d : UInt64 = 18_446_744_073_709_551_615_u64
f : Float32 = 3.14_f32
g : Float64 = 3.141592653589793
flag : Bool = true
ch : Char = 'A'
```

**Strings**

Full string support including interpolation, methods, and UTF-8.

```crystal
s = "Hello, #{name}!"
s.upcase           # => "HELLO, WORLD!"
s.downcase         # => "hello, world!"
s.split(" ")       # => ["Hello,", "World!"]
s.gsub("o", "0")   # => "Hell0, W0rld!"
s.size             # => 13
s.includes?("llo") # => true
```

**String::Builder and IO::Memory**

```crystal
io = IO::Memory.new
io << "Hello "
io << "World"
io.to_s  # => "Hello World"
```

**Symbols**

```crystal
sym = :hello
sym.to_s  # => "hello"
```

**Nil**

```crystal
val : String? = nil
val.nil?  # => true
```

**Arrays**

```crystal
arr = [1, 2, 3, 4, 5]
arr.map { |x| x * 2 }       # => [2, 4, 6, 8, 10]
arr.select { |x| x > 3 }    # => [4, 5]
arr.reduce(0) { |s, x| s + x } # => 15
arr.sort                     # => [1, 2, 3, 4, 5]
arr.reverse                  # => [5, 4, 3, 2, 1]
arr.size                     # => 5
arr.first                    # => 1
arr.last                     # => 5
arr.includes?(3)             # => true
arr.each_with_index { |v, i| puts "#{i}: #{v}" }
```

**Hashes**

```crystal
h = {"name" => "Crystal", "target" => "wasm32"}
h["name"]          # => "Crystal"
h["new_key"] = "value"
h.keys             # => ["name", "target", "new_key"]
h.values           # => ["Crystal", "wasm32", "value"]
h.each { |k, v| puts "#{k}: #{v}" }
h.has_key?("name") # => true
h.size             # => 3
```

**Tuples and Named Tuples**

```crystal
tup = {1, "hello", true}
tup[0]  # => 1
tup[1]  # => "hello"

named = {name: "Crystal", version: 1}
named[:name]    # => "Crystal"
named[:version] # => 1
```

**Ranges**

```crystal
(1..10).each { |i| puts i }
(1...10).to_a  # => [1, 2, 3, 4, 5, 6, 7, 8, 9]
(1..100).includes?(50)  # => true
```

**Enums**

```crystal
enum Direction
  North; South; East; West
end

dir = Direction::North
dir.to_s     # => "North"
dir.north?   # => true
Direction.values.map(&.to_s)  # => ["North", "South", "East", "West"]
```

**Structs**

```crystal
struct Position
  property x : Int32, y : Int32
  def initialize(@x, @y); end
end

pos = Position.new(10, 20)
pos.x  # => 10
```

**Classes and Inheritance**

```crystal
abstract class Character
  property name : String, hp : Int32
  abstract def attack_power : Int32
  def initialize(@name, @hp); end
end

class Hero < Character
  def attack_power : Int32
    10
  end
end

hero = Hero.new("Crystalia", 100)
hero.attack_power  # => 10
```

**Modules and Mixins**

```crystal
module Damageable
  abstract def hp : Int32
  abstract def hp=(value : Int32)

  def take_damage(amount : Int32)
    self.hp = hp - amount
  end

  def alive? : Bool
    hp > 0
  end
end

class Monster
  include Damageable
  property hp : Int32
  def initialize(@hp); end
end
```

**Generics**

```crystal
class Inventory(T)
  @items = Array(T).new

  def add(item : T)
    @items << item
  end

  def find(name : String) : T?
    @items.find { |i| i.name == name }
  end

  def size
    @items.size
  end
end

inv = Inventory(Item).new
inv.add(Item.new("Sword"))
```

**Procs and Closures**

```crystal
on_hit = ->(name : String, damage : Int32) {
  puts "#{name} takes #{damage} damage!"
}
on_hit.call("Goblin", 15)

multiply = ->(x : Int32, y : Int32) { x * y }
multiply.call(3, 4)  # => 12
```

**Blocks and Iterators**

```crystal
[1, 2, 3].each { |x| puts x }
[1, 2, 3].map(&.to_s)
[1, 2, 3].select(&.odd?)
["a", "b"].each_with_index { |v, i| puts "#{i}: #{v}" }
5.times { |i| puts i }
```

**Exception Handling**

Crystal uses native WASM exception handling instructions (`llvm.wasm.throw`). Exceptions are fully supported.

```crystal
begin
  raise "something went wrong"
rescue ex : RuntimeError
  puts "Caught: #{ex.message}"
ensure
  puts "Cleanup"
end

# Custom exceptions
class MyError < Exception; end

begin
  raise MyError.new("custom error")
rescue ex : MyError
  puts ex.message
end
```

**Regex (PCRE2)**

Full regex support via PCRE2 compiled for WASM.

```crystal
"hello world" =~ /(\w+)\s(\w+)/
puts $1  # => "hello"
puts $2  # => "world"

case "attack goblin"
when /^attack\s+(.+)$/
  puts "Target: #{$1}"
end

"foo bar baz".scan(/\w+/)  # => [Regex::MatchData("foo"), ...]
"hello".match?(/ell/)      # => true
```

**Math Module**

```crystal
Math.sqrt(144.0)    # => 12.0
Math::PI            # => 3.141592653589793
Math.min(5, 3)      # => 3
Math.max(5, 3)      # => 5
Math.log(10.0)      # => 2.302585...
Math.sin(Math::PI)  # => ~0.0
Math.abs(-5)        # => 5
```

**Random**

```crystal
Random.rand(1..6)     # => random Int32 in 1..6
Random.rand(1.0)      # => random Float64 in 0.0...1.0
Random.rand(100)      # => random Int32 in 0...100
```

Random number generation uses the WASI `random_get` syscall, which in browsers maps to `crypto.getRandomValues()`.

**Properties (Getters/Setters)**

```crystal
class Entity
  property name : String     # getter + setter
  getter id : Int32          # getter only
  setter score : Int32       # setter only
  property? active : Bool    # Bool getter with `?` suffix

  def initialize(@name, @id, @score, @active); end
end
```

**Control Flow**

All control flow constructs work: `if/elsif/else/end`, `unless`, `case/when`, `while`, `until`, `loop`, `break`, `next`, `return`.

```crystal
case value
when .is_a?(String) then puts "string"
when .responds_to?(:size) then puts "has size"
when 1..10 then puts "small number"
else puts "other"
end
```

**Type Unions and Nilable Types**

```crystal
val : Int32 | String = "hello"
val = 42

nullable : String? = nil
if str = nullable
  puts str.upcase
end
```

**Closures and Variable Capture**

```crystal
counter = 0
increment = -> { counter += 1; counter }
increment.call  # => 1
increment.call  # => 2
```

**Operator Overloading**

```crystal
struct Vec2
  property x : Float64, y : Float64
  def initialize(@x, @y); end

  def +(other : Vec2) : Vec2
    Vec2.new(x + other.x, y + other.y)
  end
end
```

**Constants**

```crystal
MAX_SIZE = 1024
PI = 3.14159
NAME = "Crystal WASM"
Crystal::VERSION  # => the Crystal version string
```

**Pointers (for WASM interop)**

```crystal
buffer = Pointer(UInt8).malloc(1024)
buffer[0] = 65_u8
buffer.copy_from(source.to_unsafe, count)
```

**Deque**

```crystal
d = Deque(Int32).new
d.push(1)
d.push(2)
d.shift  # => 1
```

**Set**

```crystal
s = Set{1, 2, 3}
s.includes?(2)  # => true
s.add(4)
s.size  # => 4
```

**Comparable and Sorting**

```crystal
[3, 1, 4, 1, 5].sort           # => [1, 1, 3, 4, 5]
[3, 1, 4].sort { |a, b| b <=> a }  # => [4, 3, 1]
```

**String Formatting**

Basic string formatting works. Note: on WASM, the Ryu printf algorithm is disabled for floating-point format specifiers due to memory constraints with its lookup tables. It falls back to `LibC.snprintf`, which still works correctly.

```crystal
"Value: %d" % 42        # => "Value: 42"
"Name: %s" % "Crystal"  # => "Name: Crystal"
"Float: %.2f" % 3.14    # => "Float: 3.14"  (via LibC.snprintf fallback)
```

**Unicode**

```crystal
"Hello".chars    # => ['H', 'e', 'l', 'l', 'o']
'A'.ord          # => 65
65.chr           # => 'A'
"cafe\u0301".unicode_normalize  # works
```

**Base64**

```crystal
require "base64"
Base64.encode("Hello")           # => "SGVsbG8="
Base64.decode_string("SGVsbG8=") # => "Hello"
```

### Partially Supported

**JSON Serialization** (require "json")

JSON parsing and generation works fully. Classes can use `JSON::Serializable`.

```crystal
require "json"

class GameState
  include JSON::Serializable
  property name : String
  property score : Int32
  def initialize(@name, @score); end
end

state = GameState.new("Player", 100)
json = state.to_json           # => "{\"name\":\"Player\",\"score\":100}"
restored = GameState.from_json(json)
```

**Caveat**: JSON works well but requires the `json` module to be explicitly required. It is not part of the prelude.

**Time::Span** (monotonic timing)

`Time::Span` and monotonic timing via `Time.measure` work. Clock resolution depends on the WASI runtime's `clock_time_get` implementation.

```crystal
elapsed = Time.measure do
  # work here
end
puts elapsed.total_milliseconds

span = Time::Span.new(seconds: 30)
puts span  # => "00:00:30"
```

**Caveat**: Wall-clock `Time` (dates, time zones) may have limited support depending on the WASI runtime. `Time.utc` works if `clock_time_get` with `CLOCK_REALTIME` is implemented. Time zones are not available (no filesystem access to timezone data in browser).

**Fibers** (via Asyncify)

Fiber spawning and cooperative yielding work via Binaryen's Asyncify transformation.

```crystal
results = [] of String

spawn do
  results << "from fiber"
  Fiber.yield
  results << "fiber resumed"
end

Fiber.yield  # let the spawned fiber run
Fiber.yield  # let it resume
puts results # => ["from fiber", "fiber resumed"]
```

**Caveats**:
- Fiber context switching relies on Asyncify (stack unwinding/rewinding through linear memory), which adds overhead compared to native fiber switching.
- The asyncify buffer default size is 8KB per fiber (configurable via `MAIN_FIBER_ASYNCIFY_SIZE`).
- All fibers run cooperatively in a single thread. There is no parallelism.

**File I/O** (WASI runtimes only, not browser)

File operations work when using a WASI runtime (like wasmtime) with preopened directories. They do NOT work in the browser where the WASI shim returns `ENOTCAPABLE` for `path_open`.

```sh
# Must preopened the directory:
wasmtime run --dir=. -W exceptions=y program.wasm
```

**Caveat**: In the browser, the WASI shim does not provide filesystem access. `path_open` returns errno 76 (`ENOTCAPABLE`).

**Sleep**

Sleep works via WASI `poll_oneoff` with a clock subscription.

```crystal
sleep(1.second)    # Works in wasmtime
sleep(0.5.seconds) # Works in wasmtime
```

**Caveat**: In the browser, the WASI shim implements `poll_oneoff` but the sleep is synchronous (blocks the main thread). For browser use, prefer exporting functions and using JS `setTimeout`/`requestAnimationFrame`.

**Log Module**

The `Log` module works but defaults to `DispatchMode::Sync` on WASM (channels are not reliable).

```crystal
require "log"
Log.info { "Hello from WASM" }
```

**GC (Garbage Collection)**

Boehm GC is compiled for WASM and works. Manual GC operations are available.

```crystal
GC.collect
stats = GC.stats
puts stats.heap_size
puts stats.free_bytes
puts stats.total_bytes
```

**Caveats**:
- Thread-related GC features are disabled (no `stop_world_external`, `start_world_external`, `pthread_create`, etc.).
- `GC_clear_stack` is a no-op on WASM (returns its argument directly). The WASM call stack limit (~6500 frames) is exhausted before stack clearing becomes relevant, and `--spill-pointers` ensures GC roots are visible in linear memory.
- `set_handle_fork` is not called (no fork on WASM).

### Not Supported

**Networking (HTTP, Socket, TCP, UDP)**

WASI Preview 1 does not include socket APIs. All socket operations raise `NotImplementedError`.

```crystal
# These will NOT work:
require "http/client"   # No socket support
require "http/server"   # No socket support
require "socket"        # No socket support
```

The error message states: "socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2."

**Process**

Process spawning, forking, and signal handling are not available.

```crystal
# These will NOT work:
Process.run("ls")        # No process spawning
Process.fork             # No fork
Signal::INT.trap { }     # Signal module excluded from prelude on wasm32
```

The `Signal` module is explicitly excluded from the prelude on `wasm32`.

**Threads and Parallelism**

WASM is single-threaded. There is no `Thread` class support, no `preview_mt`, and no parallel execution.

```crystal
# NOT available:
Thread.new { }           # No threads
spawn(same_thread: false) # All fibers run on same (only) thread
```

**Channels**

The `Channel` class compiles but does not work reliably on WASM. The `Log` module explicitly defaults to `DispatchMode::Sync` because channels are broken on WASM.

```crystal
# UNRELIABLE on WASM:
ch = Channel(Int32).new
spawn { ch.send(42) }
ch.receive  # May deadlock or behave incorrectly
```

**Workaround**: Use shared mutable state with `Fiber.yield` for fiber-to-fiber communication instead of channels.

**Pipes**

Pipe creation raises `NotImplementedError`:

```crystal
# NOT available:
IO.pipe  # Raises NotImplementedError
```

**iconv (Character Encoding Conversion)**

Disabled via `-Dwithout_iconv`. The iconv library is not cross-compiled for WASM.

**OpenSSL / TLS**

Disabled via `-Dwithout_openssl`. OpenSSL is not cross-compiled for WASM.

**BigInt / BigFloat / BigDecimal**

These require `libgmp` which is not cross-compiled for WASM.

```crystal
# NOT available without cross-compiling libgmp:
require "big"
BigInt.new("123456789012345678901234567890")
```

**YAML**

Requires `libyaml` which is not cross-compiled for WASM.

```crystal
# NOT available:
require "yaml"
```

**XML**

Requires `libxml2` which is not cross-compiled for WASM.

```crystal
# NOT available:
require "xml"
```

**Compress::Zlib / Compress::Gzip**

Requires `zlib` which is not cross-compiled for WASM.

```crystal
# NOT available:
require "compress/gzip"
```

**Crystal::Scheduler.init**

The scheduler initialization is skipped on `wasm32`. Fiber scheduling is handled by the asyncify-based `_start` loop instead.

---

## Standard Library

### Available Modules

These modules are confirmed working or expected to work on `wasm32-wasi`:

| Module | Status | Notes |
|--------|--------|-------|
| `Array` | Full | All operations including sort, map, select, reduce |
| `Hash` | Full | All operations |
| `Set` | Full | All operations |
| `Deque` | Full | All operations |
| `String` | Full | All methods, interpolation, UTF-8 |
| `Char` | Full | Unicode operations |
| `Int8/16/32/64` | Full | All arithmetic and bitwise operations |
| `UInt8/16/32/64` | Full | All arithmetic and bitwise operations |
| `Float32/Float64` | Full | Formatting uses LibC.snprintf fallback (no Ryu) |
| `Bool` | Full | |
| `Nil` | Full | |
| `Symbol` | Full | |
| `Tuple` | Full | |
| `NamedTuple` | Full | |
| `Range` | Full | |
| `Regex` | Full | PCRE2 compiled for WASM, full regex support |
| `Math` | Full | sqrt, sin, cos, PI, min, max, log, etc. |
| `Random` | Full | Uses WASI `random_get` / browser `crypto.getRandomValues` |
| `IO::Memory` | Full | In-memory I/O buffer |
| `String::Builder` | Full | Efficient string construction |
| `JSON` | Full | `require "json"` -- Serializable, parsing, generation |
| `Base64` | Full | Encode and decode |
| `Enum` | Full | Values, to_s, predicates |
| `Struct` | Full | Value types |
| `Class` | Full | Inheritance, abstract methods |
| `Module` | Full | Mixins, include |
| `Proc` | Full | Closures, lambdas |
| `Pointer` | Full | Malloc, indexing, copy -- essential for WASM interop |
| `Slice` | Full | Byte slices, copy_to |
| `StaticArray` | Full | Fixed-size arrays |
| `Comparable` | Full | Sorting, comparison operators |
| `Enumerable` | Full | each, map, select, reduce, etc. |
| `Iterator` | Full | Lazy iteration |
| `Iterable` | Full | |
| `Time::Span` | Full | Duration arithmetic, measurement |
| `Time.measure` | Full | Monotonic timing |
| `Time.monotonic` | Full | Via WASI `clock_time_get` |
| `GC` | Full | collect, stats (heap_size, free_bytes, total_bytes) |
| `Exception` | Full | raise, rescue, ensure, custom exceptions |
| `Fiber` | Partial | spawn + yield work; see Fibers section |
| `Log` | Partial | Works with Sync dispatch only |
| `File` | Partial | Works in wasmtime with `--dir=.`; not in browser |
| `Dir` | Partial | Works in wasmtime with preopened dirs; not in browser |
| `Path` | Full | Path manipulation (no filesystem access needed) |
| `Errno` | Full | Error codes |
| `WasiError` | Full | WASI-specific error codes |
| `Unicode` | Full | Normalization, categories |
| `Atomic` | Partial | Compiles but no true atomics (single-threaded) |
| `Mutex` | Partial | Compiles but no-op (single-threaded) |
| `Spec` | Partial | Basic test framework works; `expect_raises` is a no-op on wasm32 |

### Unavailable Modules

| Module | Reason |
|--------|--------|
| `HTTP::Client` | Requires sockets (WASI Preview 1 has no networking) |
| `HTTP::Server` | Requires sockets |
| `HTTP::WebSocket` | Requires sockets and OpenSSL |
| `Socket` | Not in WASI Preview 1 |
| `TCPSocket` / `UDPSocket` | Not in WASI Preview 1 |
| `OpenSSL` | Library not cross-compiled for WASM |
| `Signal` | Excluded from prelude on wasm32 (no OS signals) |
| `Process` | No process spawning in WASM sandbox |
| `Thread` | Single-threaded only |
| `Channel` | Compiles but unreliable at runtime |
| `BigInt` / `BigFloat` / `BigDecimal` | Requires libgmp (not cross-compiled) |
| `YAML` | Requires libyaml (not cross-compiled) |
| `XML` | Requires libxml2 (not cross-compiled) |
| `Compress::Zlib` / `Compress::Gzip` | Requires zlib (not cross-compiled) |
| `Digest::SHA256` (OpenSSL-backed) | Requires OpenSSL |
| `UUID` (v4 random) | Should work since Random works; requires testing |

---

## Browser Integration

### Architecture

Crystal WASM programs run in the browser via a **WASI shim** -- a JavaScript object that implements the `wasi_snapshot_preview1` import module. The browser creates a `WebAssembly.Instance` with this shim, giving the Crystal program access to stdout, stderr, clocks, and random number generation.

There are two integration patterns:

1. **CLI-style (stdout-based)**: The WASM module's `_start` function runs to completion, writing output via `fd_write` to stdout/stderr. The JS shim captures this output and displays it.

2. **Interactive (function exports)**: The WASM module exports `fun` functions that JavaScript can call. The Crystal program maintains state in global variables, and JS drives the interaction by calling exported functions and reading results from shared WASM memory.

### Exporting Functions

Use Crystal's `fun` keyword (top-level C-ABI functions) to create WASM exports callable from JavaScript.

```crystal
# Crystal side: define exported functions
fun game_init : Int32
  # Initialize state
  0
end

fun game_command(input_ptr : UInt8*, input_len : Int32) : Int32
  input = String.new(input_ptr, input_len)
  # Process command, return output length
  result.size
end

fun game_get_output : UInt8*
  OUTPUT_BUFFER
end
```

```javascript
// JavaScript side: call exported functions
const result = instance.exports.game_init();
const outputLen = instance.exports.game_command(ptr, len);
const outputPtr = instance.exports.game_get_output();
```

### Memory Management: The game_alloc Pattern

Since JavaScript cannot directly allocate WASM memory, export an allocation function:

```crystal
# Crystal side
fun game_alloc(size : Int32) : UInt8*
  Pointer(UInt8).malloc(size)
end
```

```javascript
// JavaScript side: write a string into WASM memory
function writeWasmString(instance, str) {
  const encoder = new TextEncoder();
  const encoded = encoder.encode(str);
  const ptr = instance.exports.game_alloc(encoded.length);
  const bytes = new Uint8Array(instance.exports.memory.buffer, ptr, encoded.length);
  bytes.set(encoded);
  return { ptr, len: encoded.length };
}
```

### Output Buffer Pattern

For returning strings from Crystal to JS, use a pre-allocated output buffer:

```crystal
OUTPUT_BUFFER_SIZE = 65536
OUTPUT_BUFFER     = Pointer(UInt8).malloc(OUTPUT_BUFFER_SIZE)
OUTPUT_LENGTH     = Pointer(Int32).malloc(1)

def write_output(text : String)
  bytes = text.to_slice
  len = Math.min(bytes.size, OUTPUT_BUFFER_SIZE - 1)
  bytes.copy_to(OUTPUT_BUFFER, len)
  OUTPUT_BUFFER[len] = 0_u8
  OUTPUT_LENGTH.value = len
end

fun get_output : UInt8*
  OUTPUT_BUFFER
end

fun get_output_length : Int32
  OUTPUT_LENGTH.value
end
```

```javascript
// JavaScript side: read the output string
function readOutput(instance) {
  const ptr = instance.exports.get_output();
  const len = instance.exports.get_output_length();
  return new TextDecoder().decode(
    new Uint8Array(instance.exports.memory.buffer, ptr, len)
  );
}
```

### WASI Shim

The browser must implement these WASI Preview 1 functions as a JavaScript import object under the `wasi_snapshot_preview1` namespace:

**Required (will crash without these)**:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `args_get` | `(argv, argv_buf) -> errno` | Provides program arguments |
| `args_sizes_get` | `(argc, argv_buf_size) -> errno` | Returns argument count and buffer size |
| `environ_get` | `(environ, environ_buf) -> errno` | Provides environment variables |
| `environ_sizes_get` | `(count, buf_size) -> errno` | Returns env var count and buffer size |
| `fd_write` | `(fd, iovs, iovs_len, nwritten) -> errno` | Writes to stdout (fd=1) and stderr (fd=2) |
| `fd_close` | `(fd) -> errno` | Closes a file descriptor |
| `fd_seek` | `(fd, offset, whence, newoffset) -> errno` | Seeks in a file descriptor |
| `fd_fdstat_get` | `(fd, stat) -> errno` | Gets file descriptor attributes |
| `proc_exit` | `(code) -> noreturn` | Program exit; throw a JS exception to handle |
| `clock_time_get` | `(id, precision, time) -> errno` | Returns monotonic/wall clock time in nanoseconds |
| `random_get` | `(buf, buf_len) -> errno` | Fills buffer with random bytes; use `crypto.getRandomValues()` |

**Recommended (needed by common programs)**:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `fd_read` | `(fd, iovs, iovs_len, nread) -> errno` | Reads from stdin (fd=0); return 0 bytes for EOF |
| `fd_fdstat_set_flags` | `(fd, flags) -> errno` | Sets FD flags; can be a no-op returning 0 |
| `fd_pread` | `(fd, iovs, iovs_len, offset, nread) -> errno` | Positional read; can return 0 bytes |
| `fd_prestat_get` | `(fd, buf) -> errno` | Returns preopened directory info; return errno 8 (EBADF) |
| `fd_prestat_dir_name` | `(fd, path, path_len) -> errno` | Returns preopened dir name; return errno 8 (EBADF) |
| `poll_oneoff` | `(in, out, nsubs, nevents) -> errno` | Polls for events; needed for `sleep` and fiber scheduling |
| `path_open` | `(fd, dirflags, path, path_len, oflags, ...) -> errno` | Opens a file; return errno 76 (ENOTCAPABLE) in browser |

### Required Browser Features

The WASM binary produced by Crystal requires these WebAssembly proposals:

| Proposal | Required | Browser Support |
|----------|----------|----------------|
| **Exception Handling** (Phase 4) | Yes | Chrome 95+, Firefox 100+, Safari 15.2+ |
| **Bulk Memory Operations** | Yes | Chrome 75+, Firefox 79+, Safari 15+ |
| **Mutable Globals** | Yes | Chrome 74+, Firefox 62+, Safari 13.1+ |
| **Sign Extension** | Yes | Widely supported |
| **BigInt for i64** | Yes (for JS interop of 64-bit values) | All modern browsers |

Minimum browser versions (conservative): **Chrome 95+, Firefox 100+, Safari 15.2+, Edge 95+**.

The wasmtime CLI requires the `-W exceptions=y` flag to enable exception handling support.

---

## Linked C Libraries

### Available (pre-compiled for wasm32-wasi)

| Library | Version | What It Enables |
|---------|---------|----------------|
| **libgc** (Boehm GC) | 8.2.2 | Garbage collection. All heap allocation goes through GC. |
| **libpcre2-8** | (bundled) | Regular expressions. Full PCRE2 regex engine. |
| **libc** (wasi-sysroot) | (wasi-sdk) | C standard library for WASI. Provides `malloc`, `printf`, `snprintf`, `memcpy`, etc. |

### Not Available (would need cross-compilation)

| Library | What It Would Enable | Workaround |
|---------|---------------------|------------|
| **zlib** | `Compress::Gzip`, `Compress::Zlib` | None; implement in JS if needed |
| **libgmp** | `BigInt`, `BigFloat`, `BigDecimal` | Use `Int64`/`Float64` or implement in JS |
| **libyaml** | `YAML` module | Use `JSON` instead |
| **libxml2** | `XML` module | Parse XML in JS, pass data via WASM exports |
| **openssl** / **libressl** | TLS, `HTTP::Client`, crypto digests | Handle crypto/networking in JS |
| **libiconv** | Character encoding conversion beyond UTF-8 | Stick to UTF-8 (which Crystal uses natively) |

---

## Concurrency

### Fibers

Fibers on WASM work via Binaryen's **Asyncify** transformation, which instruments all functions to support stack unwinding and rewinding through linear memory buffers.

**How it works**:

1. When a fiber yields or switches (`Fiber.yield`, `sleep`), the Asyncify runtime **unwinds** the call stack, saving each frame's local state to a linear memory buffer.
2. Control returns to the `_start` function, which acts as the asyncify boundary.
3. `_start` picks the next fiber to run. If the fiber was previously suspended, Asyncify **rewinds** by replaying the saved call stack frames until execution resumes at the suspension point. If the fiber is fresh, its entry function is called directly.

**Working patterns**:

```crystal
# Spawn and yield
spawn do
  puts "Step 1"
  Fiber.yield
  puts "Step 2"
end

Fiber.yield  # Let spawned fiber run Step 1
Fiber.yield  # Let spawned fiber run Step 2
```

```crystal
# Multiple fibers with shared state
results = [] of String

3.times do |i|
  spawn do
    results << "fiber #{i}"
    Fiber.yield
  end
end

10.times { Fiber.yield }  # Yield enough for all fibers to complete
puts results
```

**What does NOT work**:

- **Channels**: The `Channel` class compiles but does not function correctly. The `Log` module explicitly uses `DispatchMode::Sync` on WASM because channels are broken. Use shared mutable state + `Fiber.yield` instead.
- **Parallel execution**: All fibers run on a single thread. There is no `preview_mt` support.
- **Scheduler**: The normal `Crystal::Scheduler.init` is skipped on `wasm32`. The asyncify `_start` loop handles fiber scheduling.

### Event Loop

The WASI event loop (`Crystal::EventLoop::Wasi`) uses WASI's `poll_oneoff` syscall for:

- **Clock subscriptions**: Used by `sleep` to pause for a duration.
- **FD read/write subscriptions**: Used for waiting on file descriptor readiness (wasmtime only, not browser).
- **Timeout events**: Used by `Fiber#timeout` and select expressions.

The event loop is single-threaded and cooperative. The `interrupt` method is a no-op since there are no concurrent threads to interrupt.

---

## Memory & GC

### Boehm GC

Boehm GC version 8.2.2 is compiled for `wasm32-wasi` and provides automatic garbage collection.

**Available operations**:

```crystal
GC.collect                    # Force a collection
stats = GC.stats
stats.heap_size               # Total heap size in bytes
stats.free_bytes              # Free bytes in heap
stats.total_bytes             # Total allocated bytes
GC.enable                     # Enable GC
GC.disable                    # Disable GC
```

**WASM-specific behavior**:

- `GC_clear_stack` is a no-op (returns its argument). On WASM, `--spill-pointers` ensures GC roots are written to linear memory, making stack clearing irrelevant.
- Thread-related GC APIs are disabled: no `stop_world_external`, `start_world_external`, `pthread_create`, `pthread_join`, `pthread_detach`, `set_on_thread_event`, `get_on_thread_event`.
- `set_handle_fork` is not called (no `fork` on WASM).
- The GC cannot detect stack roots through the opaque WASM call stack; it relies on `--spill-pointers` to make all GC roots visible in linear memory.

### Stack Size

- Each fiber gets a memory region that contains a 16-byte header, an asyncify buffer (growing upward from the header), and a shadow stack (growing downward from the top).
- The main fiber's asyncify buffer is `MAIN_FIBER_ASYNCIFY_SIZE = 8192 + 16` bytes (approximately 8KB).
- The WASM linear memory can grow dynamically (up to the WASM runtime's limit, typically 4GB for wasm32).
- The WASM call stack depth limit is approximately 6500 frames (runtime-dependent), which is separate from linear memory.

---

## Known Limitations

1. **No networking**: WASI Preview 1 has no socket API. All HTTP, TCP, UDP, and WebSocket operations raise `NotImplementedError`.

2. **No process spawning**: Cannot run subprocesses, use `Process.run`, or call `fork`.

3. **No signals**: The `Signal` module is excluded from the WASM prelude entirely.

4. **No threads**: WASM is single-threaded. `Thread.new` is not available.

5. **Channels are broken**: `Channel` compiles but does not work reliably. Use shared state + `Fiber.yield`.

6. **No pipes**: `IO.pipe` raises `NotImplementedError`.

7. **No file I/O in browser**: The browser WASI shim does not implement filesystem access. `path_open` returns `ENOTCAPABLE`. File I/O only works in WASI runtimes like wasmtime with `--dir=.`.

8. **No iconv**: Character encoding conversion is disabled. Only UTF-8 is natively supported.

9. **No OpenSSL**: TLS, SSL, and OpenSSL-based crypto digests are not available.

10. **No BigInt/BigFloat**: `libgmp` is not cross-compiled for WASM.

11. **No YAML/XML**: `libyaml` and `libxml2` are not cross-compiled for WASM.

12. **No zlib compression**: `zlib` is not cross-compiled for WASM.

13. **Float formatting uses LibC fallback**: The Ryu printf algorithm is disabled on WASM due to memory constraints with its lookup tables. Floating-point format specifiers (`%f`, `%e`, `%g`) fall back to `LibC.snprintf`, which works but may have minor formatting differences.

14. **`expect_raises` is a no-op in spec**: The `expect_raises` helper in `Spec` is stubbed out on `wasm32`. You can still use `begin/rescue` directly in tests.

15. **Sleep blocks the browser main thread**: `sleep` in the browser uses a synchronous `poll_oneoff` shim, blocking the UI. For browser use, prefer JS-driven timing with exported functions.

16. **No reopening file descriptors**: `EventLoop#reopened` raises `NotImplementedError`.

17. **32-bit address space**: Pointers are 32 bits. Maximum addressable memory is 4GB. `Int32` is the natural integer size.

18. **Asyncify overhead**: Fiber context switching involves unwinding and rewinding the entire call stack through linear memory, which is slower than native fiber switching on x86_64 or aarch64.

19. **No tracing of thread/fiber info**: The Crystal tracing subsystem skips thread and fiber information on WASM since threads do not exist and fiber tracking objects may not be initialized.

---

## Validation

### Import Validation

Use `validate_wasm.sh` to verify that all WASI imports in a `.wasm` file are implemented by the browser shim before loading in the browser:

```sh
./samples/wasm/validate_wasm.sh my_program.wasm samples/wasm/index.html
```

Output on success:

```
OK: All 15 WASI imports are implemented in the browser shim.
Imports: args_get, args_sizes_get, clock_time_get, environ_get, ...
```

Output on failure:

```
FAIL: 2 of 17 WASI imports are MISSING from the browser shim!

Missing functions (add these to index.html):
  - fd_allocate
  - path_remove_directory
```

Requires `wasm-objdump` from the wabt toolkit.

### Testing

**CLI testing with wasmtime**:

```sh
crystal build test.cr -o test.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
wasmtime run -W exceptions=y test.wasm
```

**Browser testing**:

1. Build the `.wasm` file
2. Place it alongside `index.html` (or your custom HTML)
3. Serve with any HTTP server (the `fetch()` API requires HTTP, not `file://`)
4. Open the browser developer console for error output

---

## Examples

### CLI Program (stdout-based)

This pattern is for programs that run to completion and produce output via `puts`/`print`.

```crystal
# fibonacci.cr
def fib(n : Int32) : Int64
  return n.to_i64 if n <= 1
  a, b = 0_i64, 1_i64
  (n - 1).times { a, b = b, a + b }
  b
end

puts "Fibonacci sequence (Crystal WASM):"
20.times do |i|
  puts "  fib(#{i}) = #{fib(i)}"
end
```

Build and run:

```sh
crystal build fibonacci.cr -o fibonacci.wasm \
  --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
wasmtime run -W exceptions=y fibonacci.wasm
```

### Interactive Browser App (function exports)

This pattern is for programs that expose functions for JavaScript to call.

**Crystal side** (`app.cr`):

```crystal
OUTPUT_BUFFER_SIZE = 65536
OUTPUT_BUFFER     = Pointer(UInt8).malloc(OUTPUT_BUFFER_SIZE)
OUTPUT_LENGTH     = Pointer(Int32).malloc(1)

def write_output(text : String)
  bytes = text.to_slice
  len = Math.min(bytes.size, OUTPUT_BUFFER_SIZE - 1)
  bytes.copy_to(OUTPUT_BUFFER, len)
  OUTPUT_BUFFER[len] = 0_u8
  OUTPUT_LENGTH.value = len
end

# State
COUNTER = Pointer(Int32).malloc(1)

fun app_init : Int32
  COUNTER.value = 0
  write_output("Initialized! Counter = 0")
  0
end

fun app_increment : Int32
  COUNTER.value += 1
  write_output("Counter = #{COUNTER.value}")
  OUTPUT_LENGTH.value
end

fun app_get_counter : Int32
  COUNTER.value
end

fun app_get_output : UInt8*
  OUTPUT_BUFFER
end

fun app_alloc(size : Int32) : UInt8*
  Pointer(UInt8).malloc(size)
end
```

**Build**:

```sh
crystal build app.cr -o app.wasm \
  --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
```

**HTML/JavaScript side** (`app.html`):

```html
<!DOCTYPE html>
<html>
<head><title>Crystal WASM App</title></head>
<body>
  <h1>Crystal WASM Counter</h1>
  <p>Counter: <span id="counter">--</span></p>
  <button onclick="increment()">Increment</button>
  <p id="output"></p>

<script>
// Minimal WASI shim (see samples/wasm/index.html for the full version)
function createWasiShim() {
  let memory;
  return {
    wasi: {
      args_get(argv, argv_buf) {
        const view = new DataView(memory.buffer);
        view.setUint32(argv, argv_buf, true);
        new Uint8Array(memory.buffer)[argv_buf] = 0;
        return 0;
      },
      args_sizes_get(argc, buf_size) {
        const view = new DataView(memory.buffer);
        view.setUint32(argc, 1, true);
        view.setUint32(buf_size, 1, true);
        return 0;
      },
      environ_get() { return 0; },
      environ_sizes_get(c, s) {
        const v = new DataView(memory.buffer);
        v.setUint32(c, 0, true);
        v.setUint32(s, 0, true);
        return 0;
      },
      clock_time_get(id, prec, ptr) {
        new DataView(memory.buffer).setBigUint64(ptr,
          BigInt(Math.floor(performance.now() * 1e6)), true);
        return 0;
      },
      fd_write(fd, iovs, iovs_len, nwritten) {
        const view = new DataView(memory.buffer);
        let total = 0;
        for (let i = 0; i < iovs_len; i++) {
          total += view.getUint32(iovs + i * 8 + 4, true);
        }
        view.setUint32(nwritten, total, true);
        return 0;
      },
      fd_close() { return 0; },
      fd_seek(fd, off, wh, out) {
        new DataView(memory.buffer).setBigUint64(out, 0n, true);
        return 0;
      },
      fd_fdstat_get(fd, ptr) {
        const v = new DataView(memory.buffer);
        v.setUint8(ptr, 2);
        v.setUint16(ptr+2, 0, true);
        v.setBigUint64(ptr+8, 0xFFFFFFFFFFFFFFFFn, true);
        v.setBigUint64(ptr+16, 0xFFFFFFFFFFFFFFFFn, true);
        return 0;
      },
      fd_fdstat_set_flags() { return 0; },
      fd_pread(fd, iovs, len, off, nr) {
        new DataView(memory.buffer).setUint32(nr, 0, true);
        return 0;
      },
      fd_read(fd, iovs, len, nr) {
        new DataView(memory.buffer).setUint32(nr, 0, true);
        return 0;
      },
      fd_prestat_get() { return 8; },
      fd_prestat_dir_name() { return 8; },
      path_open() { return 76; },
      poll_oneoff(inp, out, n, ne) {
        const v = new DataView(memory.buffer);
        if (n > 0) {
          const ud = v.getBigUint64(inp, true);
          v.setBigUint64(out, ud, true);
          v.setUint16(out+8, 0, true);
          v.setUint8(out+10, 0);
          v.setUint32(ne, 1, true);
        } else {
          v.setUint32(ne, 0, true);
        }
        return 0;
      },
      proc_exit(code) { throw new Error(`exit: ${code}`); },
      random_get(buf, len) {
        crypto.getRandomValues(new Uint8Array(memory.buffer, buf, len));
        return 0;
      },
    },
    setMemory(mem) { memory = mem; },
  };
}

let instance;

async function init() {
  const shim = createWasiShim();
  const resp = await fetch('app.wasm');
  const bytes = await resp.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: shim.wasi,
  });
  instance = result.instance;
  shim.setMemory(instance.exports.memory);

  // Initialize WASI runtime
  try { instance.exports._start(); } catch(e) { /* proc_exit */ }

  // Initialize app
  instance.exports.app_init();
  updateUI();
}

function increment() {
  const len = instance.exports.app_increment();
  updateUI();

  // Read output string
  const ptr = instance.exports.app_get_output();
  const text = new TextDecoder().decode(
    new Uint8Array(instance.exports.memory.buffer, ptr, len)
  );
  document.getElementById('output').textContent = text;
}

function updateUI() {
  document.getElementById('counter').textContent =
    instance.exports.app_get_counter();
}

init();
</script>
</body>
</html>
```

---

## Changelog

### Alpha 0.1.0

- Initial capability reference based on Crystal master HEAD (post-1.19.1).
- Documented all working language features: primitive types, strings, arrays, hashes, tuples, named tuples, ranges, enums, structs, classes, inheritance, modules, generics, procs, blocks, closures, exception handling, regex (PCRE2), math, random, and more.
- Documented standard library module availability (JSON, Base64, Time::Span, GC, etc.) and unavailability (HTTP, Socket, Process, YAML, XML, BigInt, etc.).
- Documented the Asyncify-based fiber system and its limitations (no working channels).
- Documented the WASI event loop with poll_oneoff support for sleep and timeouts.
- Documented the browser integration architecture: WASI shim, function exports, memory management patterns, output buffer pattern.
- Listed all required WASI shim functions with signatures and purposes.
- Listed required WebAssembly proposals and minimum browser versions.
- Listed all linked C libraries (libgc, libpcre2, libc) and unavailable libraries.
- Documented 19 known limitations with explanations.
- Provided complete working examples for both CLI and interactive browser use cases.
- Documented the `validate_wasm.sh` import validation tool.
