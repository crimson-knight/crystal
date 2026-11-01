class LLVM::MemoryBuffer
  def self.from_file(filename : String)
    ret = LibLLVM.create_memory_buffer_with_contents_of_file(filename, out mem_buf, out msg)
    if ret != 0 && msg
      raise LLVM.string_and_dispose(msg)
    end
    new(mem_buf)
  end

  def initialize(@unwrap : LibLLVM::MemoryBufferRef)
    @finalized = false
  end

  def to_slice
    Slice.new(
      LibLLVM.get_buffer_start(@unwrap),
      LibLLVM.get_buffer_size(@unwrap),
    )
  end

  # Disposes this memory buffer. Its contents may not be used afterwards.
  def dispose : Nil
    return if @finalized
    @finalized = true

    LibLLVM.dispose_memory_buffer(@unwrap)
  end

  def finalize
    dispose
  end

  # Records that LLVM took ownership of the buffer (`LLVMParseIRInContext`
  # frees it), so neither `#dispose` nor the finalizer frees it again.
  protected def transfer_ownership_to_llvm : Nil
    @finalized = true
  end

  def to_unsafe
    @unwrap
  end
end
