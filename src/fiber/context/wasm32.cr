{% skip_file unless flag?(:wasm32) %}

class Fiber
  # :nodoc:
  def makecontext(stack_ptr, fiber_main)
    # TODO: Fiber context switching is not yet implemented for wasm32.
    # This will require either Binaryen Asyncify (wasm-opt --asyncify
    # post-link step) or the WASM Stack Switching proposal to enable
    # cooperative multitasking in WebAssembly.
    #
    # Binaryen's Asyncify pass currently does not support the new WASM
    # exception handling format (try_table/exnref). See:
    # https://github.com/WebAssembly/binaryen/issues/4470
    #
    # When Binaryen adds TryTable support to the Flatten and Asyncify
    # passes, this can be implemented using the approach from Crystal
    # PR #13107 (Asyncify-based fiber context switching).
  end

  # :nodoc:
  @[NoInline]
  @[Naked]
  def self.swapcontext(current_context, new_context) : Nil
    # TODO: Fiber context switching is not yet implemented for wasm32.
    # See makecontext above for details.
  end
end
