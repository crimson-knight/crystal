require "./lib_wasi"
require "./linker_symbols"

# The entry point of a WASI reactor, which `-Dwithout_main` builds on
# wasm32-wasi. See https://github.com/WebAssembly/WASI/blob/snapshot-01/design/application-abi.md.
#
# A reactor has no `_start`: the host calls `_initialize` once, and then the
# module's exported `fun`s, as often as it likes. `_initialize` sets up the
# runtime and runs the program's top-level code. It leaves out the exit path
# of a command (`at_exit` handlers, printing an unhandled exception with its
# backtrace, flushing `STDOUT` and `STDERR`), which a reactor never reaches;
# an exception that escapes the top-level code reaches the host as a
# WebAssembly exception.
{% unless flag?(:frontend_no_fibers) %}
  {% raise "A WASI reactor (-Dwithout_main on wasm32-wasi) has no _start to switch fibers from: build it with -Dfrontend_no_fibers" %}
{% end %}

fun _initialize : Nil
  LibC.__wasm_call_ctors
  GC.init
  Crystal.init_runtime
  LibCrystalMain.__crystal_main(0, Pointer(Pointer(UInt8)).null)
end
