{% skip_file unless flag?(:wasm32) %}

require "crystal/asyncify"

class Fiber
  # Size of the asyncify buffer allocated for the main fiber's context.
  # 16-byte header + 8KB asyncify data buffer.
  MAIN_FIBER_ASYNCIFY_SIZE = 8192 + 16

  struct Context
    # Bottom of the fiber's memory region. The first 16 bytes contain a header
    # with the fiber_main proc pointer and Asyncify buffer pointers.
    property stack_low : Void* = Pointer(Void).null

    # Access the 4-pointer header at the bottom of the fiber's stack region.
    # Layout (4 x i32 = 16 bytes):
    #   [0] = fiber_main function pointer
    #   [1] = fiber_main closure data
    #   [2] = asyncify_data.current_location (grows upward from header)
    #   [3] = asyncify_data.end_location (upper bound of asyncify buffer)
    protected def ctx_data_ptr : Pointer(Void*)
      @stack_low.as(Pointer(Void*))
    end

    # Pointer to the LibAsyncify::Data struct embedded in the header (offsets 2-3)
    protected def asyncify_data_ptr : LibAsyncify::Data*
      (ctx_data_ptr + 2).as(LibAsyncify::Data*)
    end

    # Get/set the fiber_main entry function from the header
    protected def fiber_main : Fiber ->
      Proc(Fiber, Nil).new(ctx_data_ptr[0], ctx_data_ptr[1])
    end

    protected def fiber_main=(proc : Fiber ->)
      ctx_data_ptr[0] = proc.pointer
      ctx_data_ptr[1] = proc.closure_data
    end

    # Check if this context belongs to the main fiber (no fiber_main set)
    def main_fiber? : Bool
      ctx_data_ptr[0].null?
    end

    # Get the fiber_main function pointer and closure data for
    # calling from outside the Fiber class hierarchy.
    def fiber_main_pointers : {Pointer(Void), Pointer(Void)}
      {ctx_data_ptr[0], ctx_data_ptr[1]}
    end

    # Public access to the asyncify data pointer for wrap_main/swapcontext.
    def asyncify_data : LibAsyncify::Data*
      asyncify_data_ptr
    end

    # Initialize asyncify context for the main fiber. The main fiber
    # doesn't go through makecontext, so we must set up its asyncify
    # header separately so swapcontext can save its state.
    protected def init_main_fiber_asyncify : Nil
      buf = Pointer(UInt8).malloc(Fiber::MAIN_FIBER_ASYNCIFY_SIZE)
      @stack_low = buf.as(Void*)

      # Zero the header (fiber_main pointers are null for main fiber,
      # distinguishing it from spawned fibers)
      header = @stack_low.as(Pointer(Void*))
      header[0] = Pointer(Void).null
      header[1] = Pointer(Void).null

      # Set up asyncify data — current_location starts right after
      # header so asyncify can write state here during unwind.
      asyncify = asyncify_data_ptr
      asyncify.value = LibAsyncify::Data.new(
        current_location: @stack_low + 16,
        end_location: @stack_low + Fiber::MAIN_FIBER_ASYNCIFY_SIZE
      )
    end
  end

  # :nodoc:
  #
  # Set up the fiber's stack for Asyncify-based context switching.
  #
  # Memory layout per fiber:
  #   +--------+---------------------------+------------------------+
  #   | Header | Asyncify buffer =>        |               <= Stack |
  #   +--------+---------------------------+------------------------+
  #   ^        ^                                                    ^
  #   stack_low  (+ 16 bytes)                                  stack_ptr
  #
  # The header (16 bytes) stores fiber_main and asyncify buffer pointers.
  # The asyncify buffer grows upward from after the header.
  # The shadow stack grows downward from stack_ptr.
  def makecontext(stack_ptr, fiber_main) : Nil
    @context.stack_low = @stack.pointer
    @context.stack_top = stack_ptr.as(Void*)

    # Set up the header at the bottom of the memory region
    header = @context.ctx_data_ptr

    # Store fiber_main proc
    header[0] = fiber_main.pointer
    header[1] = fiber_main.closure_data

    # Set up asyncify data pointers
    # A null current_location indicates a fresh (never-suspended) fiber
    asyncify_data = @context.asyncify_data_ptr
    asyncify_data.value = LibAsyncify::Data.new(
      current_location: Pointer(Void).null,
      end_location: stack_ptr.as(Void*)
    )

    @context.resumable = 1
  end

  # :nodoc:
  #
  # Switch from the current fiber to the target fiber using Asyncify.
  #
  # ALL fiber switches use Asyncify unwind/rewind. The current fiber's
  # call stack is unwound (saved to its asyncify buffer) and control
  # returns to wrap_main. wrap_main then either:
  # - Starts a fresh fiber by calling its entry function directly
  # - Rewinds a suspended fiber by replaying its saved call stack
  #
  # During rewind, this function is replayed. When we detect the
  # rewinding state, we stop the rewind — this is where the fiber
  # was suspended, so this is where it should resume.
  @[NoInline]
  def self.swapcontext(current_context, new_context) : Nil
    # Mark current fiber as suspended
    current_context.value.resumable = 1

    # Reset the current fiber's asyncify buffer write position so
    # asyncify writes state from the beginning of the buffer.
    current_asyncify = current_context.value.asyncify_data
    current_asyncify.value = LibAsyncify::Data.new(
      current_location: current_context.value.stack_low + 16,
      end_location: current_asyncify.value.end_location
    )

    # Unwind the current fiber via the C helper.
    # During rewind, the C helper calls stop_rewind and this call
    # returns normally, resuming the fiber at this point.
    Crystal::Asyncify.unwind(
      unwind_data: current_asyncify,
      target_fiber: Fiber.current # Note: scheduler already set current_fiber = target
    )
  end
end
