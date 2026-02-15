{% skip_file unless flag?(:wasm32) %}
require "crystal/asyncify"

class Fiber
  # :nodoc:
  struct Context
    property stack_low : Void* = Pointer(Void).new(1024)

    private def ctx_data_ptr
      @stack_low.as(Void**)
    end

    def asyncify_data_ptr
      (ctx_data_ptr + 2).as(LibAsyncify::Data*)
    end

    def fiber_main
      return nil if ctx_data_ptr[0].null?
      Proc(Void).new(ctx_data_ptr[0], ctx_data_ptr[1])
    end

    def fiber_main=(value : ->)
      ctx_data_ptr[0] = value.pointer
      ctx_data_ptr[1] = value.closure_data
    end
  end

  # :nodoc:
  def makecontext(stack_ptr : Void**, fiber_main : Fiber ->)
    @context.stack_top = stack_ptr.as(Void*)
    @context.stack_low = (stack_ptr.as(UInt8*) - StackPool::STACK_SIZE + 32).as(Void*)
    @context.resumable = 1
    func = ->{
      fiber_main.call(self)
      Intrinsics.debugtrap
    }
    @context.fiber_main = func
    asyncify_data_ptr = @context.asyncify_data_ptr
    asyncify_data_ptr.value.current_location = Pointer(Void).null
    asyncify_data_ptr.value.end_location = Pointer(Void).null
  end

  # :nodoc:
  @[NoInline]
  def self.swapcontext(current_context, next_context) : Nil
    current_context.value.stack_top = Crystal::Asyncify.stack_pointer
    Crystal::Asyncify.stack_pointer = next_context.value.stack_top
    current_context.value.resumable = 1
    current_asyncify_data_ptr = current_context.value.asyncify_data_ptr
    current_asyncify_data_ptr.value.current_location = (current_context.value.stack_low.as(Void**) + 4).as(Void*)
    current_asyncify_data_ptr.value.end_location = current_context.value.stack_top
    next_context.value.resumable = 0
    next_asyncify_data_ptr = next_context.value.asyncify_data_ptr
    Crystal::Asyncify.unwind(
      unwind_data: current_asyncify_data_ptr,
      rewind_data: next_asyncify_data_ptr.value.current_location.null? ? nil : next_asyncify_data_ptr,
      rewind_func: next_context.value.fiber_main || Crystal::Asyncify.main_func
    )
  end
end
