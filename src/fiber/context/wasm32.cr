{% skip_file unless flag?(:wasm32) %}

class Fiber
  # :nodoc:
  def makecontext(stack_ptr, fiber_main)
    # TODO: Fiber context switching is not yet implemented for wasm32.
    # This will require either Binaryen Asyncify (wasm-opt --asyncify
    # post-link step) or JSPI (JavaScript Promise Integration) to
    # enable cooperative multitasking in WebAssembly.
  end

  # :nodoc:
  @[NoInline]
  @[Naked]
  def self.swapcontext(current_context, new_context) : Nil
    # TODO: Fiber context switching is not yet implemented for wasm32.
    # See makecontext above for details.
  end
end
