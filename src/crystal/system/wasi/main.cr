require "./lib_wasi"

# This file serve as the entrypoint for WebAssembly applications compliant to the WASI spec.
# See https://github.com/WebAssembly/WASI/blob/snapshot-01/design/application-abi.md.

lib LibC
  fun __wasm_call_ctors
  fun __wasm_call_dtors
  fun __main_void : Int32
end

# IMPORTANT: _start is excluded from asyncify instrumentation via
# --pass-arg=asyncify-removelist@_start in the wasm-opt pass. This makes
# it the "asyncify boundary". When asyncified code unwinds during a fiber
# switch, all asyncified functions save their state and return, and
# control returns here. _start manages the unwind/rewind cycle.
#
# During asyncify rewind, the call path must match what was used during
# the original unwind. The main fiber unwinds through run_main, so it
# must be rewound through run_main. Spawned fibers unwind through
# run_fiber, so they must be rewound through run_fiber.
fun _start
  LibC.__wasm_call_ctors

  # Run the main program
  status = Crystal::Asyncify.run_main

  # Fiber switching loop: when an asyncified function triggers an unwind
  # (via crystal_asyncify_switch), run_main/run_fiber returns here.
  while Crystal::Asyncify.state.unwinding?
    next_fiber = Crystal::Asyncify.stop_and_get_next
    break unless next_fiber
    break unless next_fiber.resumable?

    if Crystal::Asyncify.fiber_fresh?(next_fiber)
      # Fresh fiber: start it for the first time
      Crystal::Asyncify.prepare_fresh(next_fiber)
      Crystal::Asyncify.run_fiber(next_fiber)
    else
      # Suspended fiber: rewind it through the same call path
      Crystal::Asyncify.prepare_rewind(next_fiber)
      if next_fiber.@context.main_fiber?
        # Main fiber was unwound through run_main → rewind through run_main
        status = Crystal::Asyncify.run_main
      else
        # Spawned fiber was unwound through run_fiber → rewind through run_fiber
        Crystal::Asyncify.run_fiber(next_fiber)
      end
    end
  end

  LibC.__wasm_call_dtors
  LibWasi.proc_exit(status) if status != 0
end

# `__main_argc_argv` is called by wasi-libc's `__main_void` with the
# program arguments.
fun __main_argc_argv(argc : Int32, argv : UInt8**) : Int32
  main(argc, argv)
end
