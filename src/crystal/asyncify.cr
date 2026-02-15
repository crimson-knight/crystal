{% skip_file unless flag?(:wasm32) %}

@[Link(wasm_import_module: "asyncify")]
lib LibAsyncify
  struct Data
    current_location : Void*
    end_location : Void*
  end
  fun start_unwind(data : Data*)
  fun stop_unwind
  fun start_rewind(data : Data*)
  fun stop_rewind
end

module Crystal::Asyncify
  enum State
    Normal
    Unwinding
    Rewinding
  end

  @@state = State::Normal
  class_getter! main_func, current_func

  # Reads the __stack_pointer global via inline WASM assembly
  def self.stack_pointer
    stack_pointer = uninitialized Void*
    asm("
      .globaltype __stack_pointer, i32
      global.get __stack_pointer
      local.set $0
    " : "=r"(stack_pointer))
    stack_pointer
  end

  # Sets the __stack_pointer global via inline WASM assembly
  def self.stack_pointer=(stack_pointer : Void*)
    asm("
      .globaltype __stack_pointer, i32
      local.get $0
      global.set __stack_pointer
    " :: "r"(stack_pointer))
  end

  # Wraps the entrypoint to capture/stop unwindings and trigger rewinds
  @[NoInline]
  def self.wrap_main(&block)
    @@main_func = block
    @@current_func = block
    block.call

    until @@state.normal?
      @@state = State::Normal
      LibAsyncify.stop_unwind
      if before_rewind = @@before_rewind
        before_rewind.call
      end
      if rewind_data = @@rewind_data
        @@state = State::Rewinding
        LibAsyncify.start_rewind(rewind_data)
      end
      func = @@rewind_func.not_nil!
      @@current_func = func
      func.call
    end
  end

  # Triggers stack unwind, optionally followed by rewind to another fiber
  def self.unwind(*, unwind_data, rewind_data, rewind_func, before_rewind = nil)
    @@rewind_data = rewind_data
    @@rewind_func = rewind_func
    @@before_rewind = before_rewind
    real_unwind(unwind_data)
  end

  @[NoInline]
  private def self.real_unwind(unwind_data)
    if @@state.rewinding?
      @@state = State::Normal
      LibAsyncify.stop_rewind
      return
    end
    @@state = State::Unwinding
    LibAsyncify.start_unwind(unwind_data)
  end
end
