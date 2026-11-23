{% if flag?(:darwin) %}
  # :nodoc:
  lib LibDarwinMalloc
    struct MallocStatistics
      blocks_in_use : UInt32
      size_in_use : LibC::SizeT
      max_size_in_use : LibC::SizeT
      size_allocated : LibC::SizeT
    end

    fun malloc_zone_statistics(zone : Void*, stats : MallocStatistics*)

    # With a null zone and a goal of 0, every malloc zone returns as much
    # free memory as it can. Returns the number of bytes released.
    fun malloc_zone_pressure_relief(zone : Void*, goal : LibC::SizeT) : LibC::SizeT
  end
{% elsif flag?(:linux) && flag?(:gnu) %}
  # :nodoc:
  lib LibGlibcMalloc
    # `struct mallinfo2` (glibc 2.33 and later).
    struct Mallinfo2
      arena : LibC::SizeT
      ordblks : LibC::SizeT
      smblks : LibC::SizeT
      hblks : LibC::SizeT
      hblkhd : LibC::SizeT
      usmblks : LibC::SizeT
      fsmblks : LibC::SizeT
      uordblks : LibC::SizeT
      fordblks : LibC::SizeT
      keepcost : LibC::SizeT
    end

    # Returns the free memory of every arena to the OS (the top of each
    # heap is shrunk, and whole free pages inside it are discarded).
    fun malloc_trim(pad : LibC::SizeT) : LibC::Int
  end
{% end %}

module Crystal
  # The C allocator, where LLVM allocates: how much it has handed out, and
  # asking it to give its free memory back to the OS.
  #
  # LLVM frees a disposed context's memory to the allocator, which keeps it
  # for later allocations. On macOS the zones hand it back under pressure;
  # glibc keeps it inside its arenas until `malloc_trim` is called, so on
  # Linux it stays in the process's resident memory for the rest of the
  # build unless the compiler asks.
  module CAllocator
    # The bytes the C allocator has handed out and not got back (0 where
    # the compiler cannot ask).
    def self.bytes_in_use : Int64
      {% if flag?(:darwin) %}
        stats = uninitialized LibDarwinMalloc::MallocStatistics
        LibDarwinMalloc.malloc_zone_statistics(nil, pointerof(stats))
        stats.size_in_use.to_i64
      {% elsif flag?(:linux) && flag?(:gnu) %}
        if info = mallinfo2
          (info.uordblks + info.hblkhd).to_i64
        else
          0_i64
        end
      {% else %}
        0_i64
      {% end %}
    end

    # The bytes the C allocator holds from the OS, in use or free (0 where
    # the compiler cannot ask).
    def self.bytes_allocated : Int64
      {% if flag?(:darwin) %}
        stats = uninitialized LibDarwinMalloc::MallocStatistics
        LibDarwinMalloc.malloc_zone_statistics(nil, pointerof(stats))
        stats.size_allocated.to_i64
      {% elsif flag?(:linux) && flag?(:gnu) %}
        if info = mallinfo2
          (info.arena + info.hblkhd).to_i64
        else
          0_i64
        end
      {% else %}
        0_i64
      {% end %}
    end

    # Asks the C allocator to hand its free memory back to the OS.
    def self.return_free_memory : Nil
      {% if flag?(:darwin) %}
        LibDarwinMalloc.malloc_zone_pressure_relief(nil, 0)
      {% elsif flag?(:linux) && flag?(:gnu) %}
        LibGlibcMalloc.malloc_trim(0)
      {% end %}
    end

    {% if flag?(:linux) && flag?(:gnu) %}
      # `mallinfo2` is looked up when first needed, so the compiler still
      # starts on a glibc older than 2.33 (it then reports 0).
      @@mallinfo2 : Proc(LibGlibcMalloc::Mallinfo2)? = begin
        pointer = LibC.dlsym(LibC::RTLD_DEFAULT, "mallinfo2")
        pointer.null? ? nil : Proc(LibGlibcMalloc::Mallinfo2).new(pointer, Pointer(Void).null)
      end

      private def self.mallinfo2 : LibGlibcMalloc::Mallinfo2?
        @@mallinfo2.try &.call
      end
    {% end %}
  end
end
