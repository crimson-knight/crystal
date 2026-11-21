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
  module GCTuning
    FREE_SPACE_DIVISOR = 10_u64

    class_property? collects_at_stages : Bool = false
    class_property? traces_stages : Bool = false

    def self.configure_from_env : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        divisor = ENV["CRYSTAL_GC_FREE_SPACE_DIVISOR"]?.try(&.to_u64?) || FREE_SPACE_DIVISOR
        divisor = FREE_SPACE_DIVISOR if divisor == 0
        LibGC.set_free_space_divisor(LibGC::Word.new(divisor))
        self.collects_at_stages = ENV["CRYSTAL_GC_COLLECT_AT_STAGES"]? == "1"
        self.traces_stages = ENV["CRYSTAL_GC_TRACE"]? == "1"
      {% end %}
    end

    def self.stage_finished(name : String?) : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        GC.collect if collects_at_stages?
        return unless traces_stages?
        stats = GC.prof_stats
        STDERR.printf("gc-trace stage=%s heap_mb=%.1f free_mb=%.1f unmapped_mb=%.1f since_gc_mb=%.1f collections=%d allocated_mb=%.1f divisor=%d\n",
          (name || "?").gsub(' ', '_'), stats.heap_size / 1e6, stats.free_bytes / 1e6, stats.unmapped_bytes / 1e6,
          stats.bytes_since_gc / 1e6, stats.gc_no, (stats.bytes_before_gc + stats.bytes_since_gc) / 1e6,
          LibGC.get_free_space_divisor)
      {% end %}
    end
  end
end
