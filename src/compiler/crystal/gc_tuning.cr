{% if flag?(:darwin) %}
  # :nodoc:
  lib LibDarwinProcessUsage
    RUSAGE_INFO_V4 = 4

    fun proc_pid_rusage(pid : Int32, flavor : Int32, buffer : Void*) : Int32
  end
{% end %}

{% unless flag?(:gc_none) || flag?(:wasm32) %}
  lib LibGC
    fun set_free_space_divisor = GC_set_free_space_divisor(value : Word)
    fun get_free_space_divisor = GC_get_free_space_divisor : Word
    fun set_min_bytes_allocd = GC_set_min_bytes_allocd(value : SizeT)
  end
{% end %}

module Crystal
  # How the compiler runs its own garbage collector.
  #
  # The collector lets the heap grow by `heap / free_space_divisor` before it
  # collects again, so a larger divisor keeps the heap closer to the live data
  # and pays for it with more collections. The compiler runs with
  # `FREE_SPACE_DIVISOR`; the collector's own default is 3. Measured on a
  # program whose type inference keeps 3.5 GB (notes/infer-state.md): the
  # heap at the end of type inference is 4.7 GB with 3 and 4.1 GB with 10, in
  # the same wall time, for 60% more CPU time spent by the mark threads. With
  # 16 the wall time rises by a quarter. Environment variables are for
  # measuring the trade:
  #
  # * `CRYSTAL_GC_FREE_SPACE_DIVISOR=N` sets the divisor (3 gives the
  #   collector's default back).
  # * `CRYSTAL_GC_COLLECT_AT_STAGES=1` runs a full collection when a compiler
  #   stage ends.
  # * `CRYSTAL_GC_TRACE=1` prints the collector's numbers to standard error
  #   when a stage ends.
  # * `CRYSTAL_GC_IR_FREE_SPACE_DIVISOR=N` sets the divisor for IR generation
  #   alone (see `with_ir_generation_divisor`).
  module GCTuning
    FREE_SPACE_DIVISOR = 10_u64

    # The divisor for IR generation that a memory budget asks for (see
    # `MemoryBudget`), if any.
    class_property ir_generation_divisor : UInt64?

    # The heap size from which the collector runs with `@@tight_divisor`
    # (0: never; see `#tighten_above`).
    @@tight_heap_bytes = 0_u64
    @@tight_divisor = FREE_SPACE_DIVISOR

    # Makes the collector collect with *divisor* (more often) once its heap
    # has grown to *heap_bytes*, and during IR generation. While the heap is
    # smaller it keeps collecting as before, so a build that stays far below
    # a memory budget pays nothing for it.
    def self.tighten_above(heap_bytes : Int64, divisor : UInt64) : Nil
      @@tight_heap_bytes = heap_bytes.to_u64
      @@tight_divisor = divisor
      self.ir_generation_divisor = divisor
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        LibGC.set_on_heap_resize ->(heap_size : LibGC::Word) { GCTuning.heap_resized(heap_size.to_u64) }
        heap_resized(GC.stats.heap_size)
      {% end %}
    end

    # Called by the collector (with its lock held) when its heap grew.
    # :nodoc:
    def self.heap_resized(heap_size : UInt64) : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        return if @@tight_heap_bytes == 0 || heap_size < @@tight_heap_bytes
        return if LibGC.get_free_space_divisor >= @@tight_divisor
        LibGC.set_free_space_divisor(LibGC::Word.new(@@tight_divisor))
      {% end %}
    end

    # Runs the block, IR generation, with the divisor
    # `CRYSTAL_GC_IR_FREE_SPACE_DIVISOR` names, or else the one a memory
    # budget asks for, if any.
    def self.with_ir_generation_divisor(&)
      {% if flag?(:gc_none) || flag?(:wasm32) %}
        yield
      {% else %}
        divisor = ENV["CRYSTAL_GC_IR_FREE_SPACE_DIVISOR"]?.try(&.to_u64?) || ir_generation_divisor
        if divisor && divisor > 0
          previous_divisor = LibGC.get_free_space_divisor
          LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
          begin
            yield
          ensure
            LibGC.set_free_space_divisor(previous_divisor)
          end
        else
          yield
        end
      {% end %}
    end

    # How much a code generation child of the build server allocates, at
    # least, between two collections (see `enter_build_server_child`).
    BUILD_SERVER_CHILD_MIN_BYTES_ALLOCATED = 500_000_000_u64

    # Sets how often the collector of a code generation child of the build
    # server (`InferReuse`) collects. The child starts with the typed program
    # of the server (4.4 GB of live data in an Amber app of 300 resources).
    #
    # A free space divisor of 1 (#64) let the child collect less while it
    # generated the code of an edit, but in the first build, whose child
    # generates the code of the whole program, it let the heap grow from 4.5
    # to 7.8 GB (2.7 GB more than the compiler's divisor); 2 and 3 did the
    # same (two collections in either case). Measured on amber300
    # (notes/rebuild-round3.md), the child now keeps the compiler's divisor
    # and collects after `BUILD_SERVER_CHILD_MIN_BYTES_ALLOCATED` at least:
    #
    # | Child setting | First build peak | Body edit peak | Collections in an edit |
    # |---|---|---|---|
    # | divisor 1 | 9.7 GB | 9.4 GB | 1 |
    # | compiler's divisor (10) | 9.2 GB | 8.6 GB | 2 |
    # | floor of 1 GB | 8.9 GB | 8.7 GB | 2 |
    # | floor of 500 MB | 8.7 GB | 8.7 GB | 2 |
    #
    # (The first-build peaks of the floors also leave out the owner shape walk,
    # see `Holder#walk_owner_shapes`.) An edit saves one collection at most with
    # a lower divisor, a fraction of a second, so the floor is set for memory.
    #
    # For measuring: `CRYSTAL_GC_CHILD_MIN_BYTES_ALLOCATED=N` sets the floor
    # (0 keeps the collector's), and `CRYSTAL_GC_CHILD_FREE_SPACE_DIVISOR=N` sets
    # a divisor as well (0 or unset keeps the compiler's).
    def self.enter_build_server_child : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        min_bytes_allocated = ENV["CRYSTAL_GC_CHILD_MIN_BYTES_ALLOCATED"]?.try(&.to_u64?) || BUILD_SERVER_CHILD_MIN_BYTES_ALLOCATED
        LibGC.set_min_bytes_allocd(LibC::SizeT.new(min_bytes_allocated)) if min_bytes_allocated > 0

        divisor = ENV["CRYSTAL_GC_CHILD_FREE_SPACE_DIVISOR"]?.try(&.to_u64?) || 0_u64
        return if divisor == 0

        LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
        @@tight_divisor = divisor if @@tight_heap_bytes > 0 && @@tight_divisor > divisor
      {% end %}
    end

    # The divisor of a build server's build child while it re-types an edit
    # (see `with_build_server_retype_divisor`).
    BUILD_SERVER_RETYPE_FREE_SPACE_DIVISOR = 2_u64

    # How much a re-typing may grow the heap before the build child gives
    # the free space back to the system (see `InferReuse::Server`).
    RETYPE_HEAP_GROWTH_TO_RETURN = 2_000_000_000_u64

    # Runs the block, the re-typing of an edit in a build child of the build
    # server, with a smaller divisor. The child starts with the server's
    # heap (5 GB in an Amber app of 300 resources). Typing the top-level code
    # of that app's routes file alone allocates about 19 GB; with the
    # compiler's divisor that was 26 full collections, 50 of the 54 s the
    # re-typing took. With 1 it took 13 to 16 s, and the heap grew to 12.8 GB;
    # 2 lets it grow by half before each collection. A body edit allocates
    # little and collects as before. `CRYSTAL_GC_RETYPE_FREE_SPACE_DIVISOR=N`
    # sets another one (0 keeps the compiler's), for measuring.
    def self.with_build_server_retype_divisor(&)
      {% if flag?(:gc_none) || flag?(:wasm32) %}
        yield
      {% else %}
        divisor = ENV["CRYSTAL_GC_RETYPE_FREE_SPACE_DIVISOR"]?.try(&.to_u64?) || BUILD_SERVER_RETYPE_FREE_SPACE_DIVISOR
        return yield if divisor == 0

        previous_divisor = LibGC.get_free_space_divisor
        LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
        begin
          yield
        ensure
          LibGC.set_free_space_divisor(previous_divisor)
        end
      {% end %}
    end

    class_property? collects_at_stages : Bool = false
    class_property? traces_stages : Bool = false

    def self.configure_from_env : Nil
      started_at
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        divisor = ENV["CRYSTAL_GC_FREE_SPACE_DIVISOR"]?.try(&.to_u64?) || FREE_SPACE_DIVISOR
        divisor = FREE_SPACE_DIVISOR if divisor == 0
        LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
        self.collects_at_stages = ENV["CRYSTAL_GC_COLLECT_AT_STAGES"]? == "1"
        self.traces_stages = ENV["CRYSTAL_GC_TRACE"]? == "1"
      {% end %}
    end

    class_getter started_at : Time::Instant = Time.instant

    # The process footprint now and its largest value so far, in bytes, as
    # the system counts them (macOS: `phys_footprint`; Linux: `VmRSS` and
    # `VmHWM`). Zero where neither is known.
    def self.footprint_bytes : {Int64, Int64}
      {% if flag?(:darwin) %}
        usage = uninitialized StaticArray(UInt64, 64)
        if LibDarwinProcessUsage.proc_pid_rusage(Process.pid.to_i32, LibDarwinProcessUsage::RUSAGE_INFO_V4, usage.to_unsafe.as(Void*)) == 0
          # rusage_info_v4: after the 16-byte UUID, ri_phys_footprint is the
          # 8th 64-bit field and ri_lifetime_max_phys_footprint the 29th.
          return {usage[9].to_i64, usage[30].to_i64}
        end
      {% elsif flag?(:linux) %}
        status = File.read("/proc/self/status") rescue nil
        if status
          resident = status.match(/^VmRSS:\s+(\d+)/m).try(&.[1].to_i64) || 0_i64
          resident_peak = status.match(/^VmHWM:\s+(\d+)/m).try(&.[1].to_i64) || 0_i64
          return {resident * 1024, resident_peak * 1024}
        end
      {% end %}
      {0_i64, 0_i64}
    end

    # With `CRYSTAL_GC_TRACE=1`, prints one line per finished stage: seconds
    # since the compiler started, the collector's numbers, the C allocator's
    # bytes in use (LLVM allocates there), the process footprint now and its
    # peak so far, and the processor time used so far.
    def self.stage_finished(name : String?) : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        GC.collect if collects_at_stages?
        return unless traces_stages?
        stats = GC.prof_stats
        footprint, footprint_peak = footprint_bytes
        times = Process.times
        # The C allocator's bytes come from the code generator's peak probe; the
        # LLVM-free frontend (`-Dwithout_llvm`) has no code generator to require.
        malloc_bytes = {% if flag?(:without_llvm) %} 0_i64 {% else %} PeakProbe.malloc_bytes_in_use {% end %}
        STDERR.printf("gc-trace stage=%s t=%.1f heap_mb=%.1f free_mb=%.1f unmapped_mb=%.1f since_gc_mb=%.1f collections=%d allocated_mb=%.1f divisor=%d malloc_mb=%.1f footprint_mb=%.1f footprint_peak_mb=%.1f user_s=%.1f system_s=%.1f\n",
          (name || "?").gsub(' ', '_'), started_at.elapsed.total_seconds, stats.heap_size / 1e6, stats.free_bytes / 1e6,
          stats.unmapped_bytes / 1e6, stats.bytes_since_gc / 1e6, stats.gc_no, (stats.bytes_before_gc + stats.bytes_since_gc) / 1e6,
          LibGC.get_free_space_divisor, malloc_bytes / 1e6, footprint / 1e6, footprint_peak / 1e6,
          times.utime, times.stime)
      {% end %}
    end
  end
end
