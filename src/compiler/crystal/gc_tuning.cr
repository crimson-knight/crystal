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

    # Runs the block, IR generation, with the divisor
    # `CRYSTAL_GC_IR_FREE_SPACE_DIVISOR` names, when it names one.
    def self.with_ir_generation_divisor(&)
      {% if flag?(:gc_none) || flag?(:wasm32) %}
        yield
      {% else %}
        divisor = ENV["CRYSTAL_GC_IR_FREE_SPACE_DIVISOR"]?.try(&.to_u64?)
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
        STDERR.printf("gc-trace stage=%s t=%.1f heap_mb=%.1f free_mb=%.1f unmapped_mb=%.1f since_gc_mb=%.1f collections=%d allocated_mb=%.1f divisor=%d malloc_mb=%.1f footprint_mb=%.1f footprint_peak_mb=%.1f user_s=%.1f system_s=%.1f\n",
          (name || "?").gsub(' ', '_'), started_at.elapsed.total_seconds, stats.heap_size / 1e6, stats.free_bytes / 1e6,
          stats.unmapped_bytes / 1e6, stats.bytes_since_gc / 1e6, stats.gc_no, (stats.bytes_before_gc + stats.bytes_since_gc) / 1e6,
          LibGC.get_free_space_divisor, PeakProbe.malloc_bytes_in_use / 1e6, footprint / 1e6, footprint_peak / 1e6,
          times.utime, times.stime)
      {% end %}
    end
  end
end
