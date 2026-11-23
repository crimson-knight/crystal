module Crystal
  # Holds the frontend to a fixed memory budget: the GC heap may not grow past
  # *bytes*, and an allocation the budget cannot satisfy ends the process with
  # a clear message (exit status 3) instead of a crash or an endless series of
  # collections. In a browser the budget sits below the WebAssembly memory
  # maximum, leaving room for the stacks and the C allocator.
  module FrontendMemoryLimit
    EXIT_STATUS = 3

    lib LibGCLimit
      fun set_oom_fn = GC_set_oom_fn(handler : LibC::SizeT -> Void*)
    end

    def self.apply(bytes : UInt64) : Nil
      LibGC.set_max_heap_size(LibGC::Word.new(bytes))
      LibGCLimit.set_oom_fn(->(size : LibC::SizeT) do
        # Allocating here would fail too: write with no allocation.
        message = "Error: out of memory: the type check needs more than the memory limit (--memory-limit)\n"
        LibC.write(2, message.to_unsafe, message.bytesize)
        LibC.exit(EXIT_STATUS)
        Pointer(Void).null
      end)
    end
  end
end
