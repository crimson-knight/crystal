# Symbols wasm-ld defines for every WASI module, which both entry points
# (`_start` in `main.cr`, `_initialize` in `reactor.cr`) and the runtime use.
lib LibC
  # Runs the static constructors of the C libraries linked in.
  fun __wasm_call_ctors

  # Bounds of the shadow stack. With `--stack-first` the stack sits below the
  # data segments and grows down from `__stack_high` toward `__stack_low`.
  $__stack_low : UInt8
  $__stack_high : UInt8
end
