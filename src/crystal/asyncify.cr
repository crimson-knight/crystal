{% skip_file unless flag?(:wasm32) %}

# Crystal::Asyncify — Binaryen Asyncify runtime integration for fiber switching
#
# Binaryen's Asyncify pass instruments all functions to support stack
# unwinding and rewinding via linear memory buffers. This enables
# cooperative multitasking (fiber switching) on WebAssembly where the
# call stack is otherwise opaque and not directly accessible.
#
# Architecture:
#   _start (NOT asyncified, serves as boundary via --asyncify-removelist)
#     calls run_main → __main_void → __main_argc_argv → main
#     when unwind occurs, run_main returns to _start
#     _start calls crystal_stop_unwind, then either:
#       - crystal_start_rewind + run_main (for suspended fibers)
#       - run_fiber (for fresh fibers)
#
#   crystal_asyncify_switch (NOT asyncified, merged post-asyncify via wasm-merge)
#     Called from swapcontext to initiate unwind or terminate rewind.
#     During unwind: calls asyncify_start_unwind
#     During rewind: calls asyncify_stop_rewind (prevents state corruption)
#
# Build pipeline:
#   1. Crystal compiles to WASM with crystal_* functions as unresolved imports
#   2. wasm-opt --asyncify instruments functions, adds asyncify_* definitions
#   3. wasm-merge combines main module + asyncify_helper.wasm, resolving:
#      - main's crystal_* imports → helper's crystal_* exports
#      - helper's asyncify_* imports → main's asyncify_* exports

# Data structure used by asyncify to track buffer positions.
# Kept separate from the function wrappers since the struct is used
# directly by Crystal code for buffer management.
lib LibAsyncify
  struct Data
    current_location : Void*
    end_location : Void*
  end
end

# Wrapper functions provided by asyncify_helper.wasm (merged post-asyncify).
# These call the real asyncify runtime functions (asyncify_start_unwind, etc.)
# which are created by wasm-opt's asyncify pass.
lib LibCrystalAsyncify
  fun crystal_asyncify_switch(unwind_data : Void*)
  fun crystal_stop_unwind
  fun crystal_start_rewind(data : Void*)
  fun crystal_stop_rewind
  fun crystal_get_state : Int32
end

module Crystal::Asyncify
  enum State
    Normal
    Unwinding
    Rewinding
  end

  @@state = State::Normal

  def self.state : State
    @@state
  end

  # Read the WASM __stack_pointer global via inline assembly
  def self.stack_pointer : Void*
    ptr = Pointer(Void).null
    asm("global.get __stack_pointer" : "=r"(ptr))
    ptr
  end

  # Write the WASM __stack_pointer global via inline assembly
  def self.stack_pointer=(value : Void*)
    asm("local.get $0\0Aglobal.set __stack_pointer" :: "r"(value))
  end

  @@next_fiber : Fiber? = nil

  # Run the main program. Called from _start.
  # During rewind, asyncify replays through this call path.
  def self.run_main : Int32
    LibC.__main_void
  end

  # Run a fresh (never-suspended) fiber's entry function.
  # Called from _start for fibers that don't have saved asyncify state.
  def self.run_fiber(fiber : Fiber) : Nil
    ctx = fiber.@context
    fn_ptr, closure_data = ctx.fiber_main_pointers
    entry = Proc(Fiber, Nil).new(fn_ptr, closure_data)
    entry.call(fiber)
  end

  # Called from _start after an asyncified function returns due to unwind.
  # Stops the unwind and prepares the next action.
  # Returns: the next fiber to run, or nil if done.
  #
  # NOTE: This method is asyncified. It must only be called when the
  # asyncify runtime is in Normal state. _start must call
  # crystal_stop_unwind BEFORE calling this method.
  def self.stop_and_get_next : Fiber?
    LibCrystalAsyncify.crystal_stop_unwind
    @@state = State::Normal
    fiber = @@next_fiber
    @@next_fiber = nil
    fiber
  end

  # Called from _start after crystal_stop_unwind has already been called.
  # Returns the next fiber to run, or nil if done.
  # This is safe to call from _start because the asyncify runtime is
  # already in Normal state when this is called.
  def self.get_next_fiber : Fiber?
    @@state = State::Normal
    fiber = @@next_fiber
    @@next_fiber = nil
    fiber
  end

  # Prepare a suspended fiber for rewinding.
  # Called from _start. After this, _start should call run_main.
  def self.prepare_rewind(fiber : Fiber) : Nil
    target_asyncify = fiber.@context.asyncify_data
    @@state = State::Rewinding
    LibCrystalAsyncify.crystal_start_rewind(target_asyncify.as(Void*))
  end

  # Prepare a fresh fiber's asyncify buffer.
  # Called from _start before run_fiber.
  def self.prepare_fresh(fiber : Fiber) : Nil
    ctx = fiber.@context
    target_asyncify = ctx.asyncify_data
    target_asyncify.value = LibAsyncify::Data.new(
      current_location: ctx.stack_low + 16,
      end_location: target_asyncify.value.end_location
    )
  end

  # Check if a fiber is fresh (never suspended via asyncify).
  def self.fiber_fresh?(fiber : Fiber) : Bool
    fiber.@context.asyncify_data.value.current_location.null?
  end

  # Trigger an unwind (suspend the current fiber) via the helper module.
  # The helper's crystal_asyncify_switch is NOT asyncified (it's merged
  # after the asyncify pass), so during rewind it correctly calls
  # asyncify_stop_rewind instead of asyncify_start_unwind.
  def self.unwind(*, unwind_data : LibAsyncify::Data*, target_fiber : Fiber) : Nil
    @@next_fiber = target_fiber
    @@state = State::Unwinding
    LibCrystalAsyncify.crystal_asyncify_switch(unwind_data.as(Void*))
    # During unwind: all asyncified functions save state and return to _start.
    # During rewind: crystal_asyncify_switch calls stop_rewind, then this
    # function returns normally. The caller resumes from the suspension point.
    @@state = State::Normal
  end

  # Debug helper: write message + int to stderr using LibC.write
  def self.debug_print(msg : String, val : Int32) : Nil
    LibC.write(2, msg.to_unsafe, msg.bytesize)
    buf = uninitialized UInt8[16]
    i = 0
    if val < 0
      buf[i] = '-'.ord.to_u8
      i += 1
      val = -val
    end
    if val == 0
      buf[i] = '0'.ord.to_u8
      i += 1
    else
      start = i
      v = val
      while v > 0 && i < 15
        buf[i] = ('0'.ord + (v % 10)).to_u8
        v //= 10
        i += 1
      end
      left = start
      right = i - 1
      while left < right
        buf[left], buf[right] = buf[right], buf[left]
        left += 1
        right -= 1
      end
    end
    buf[i] = '\n'.ord.to_u8
    i += 1
    LibC.write(2, buf.to_unsafe, i)
  end
end
