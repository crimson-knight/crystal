require "./codegen"

{% if flag?(:darwin) %}
  lib LibC
    fun system(command : UInt8*) : Int
  end
{% end %}

module Crystal
  # Measures what the compiler holds when IR generation ends, the moment of
  # a large build's peak memory. A diagnostic: it frees the generated IR to
  # measure it, so the compiler exits when the report is written.
  #
  # Enabled by setting `CRYSTAL_PEAK_PROBE` to a directory. The probe writes
  # there:
  #
  # * `probe.txt`: the collector's numbers and the C allocator's bytes in use
  #   at the end of IR generation, then the C allocator's bytes after freeing,
  #   in turn, the function-signature module, the modules in memory and the
  #   main module, and the collector's numbers after a full collection.
  # * `vmmap-*.txt` and `footprint-*.txt` (macOS): the system's own account
  #   of the process at the end of IR generation and after each step.
  # * `census.txt`: the memory census (see `MemoryCensus`) after everything
  #   IR generation held was freed.
  module PeakProbe
    def self.directory : String?
      ENV["CRYSTAL_PEAK_PROBE"]?.presence
    end

    def self.enabled? : Bool
      !directory.nil?
    end

    # The bytes the C allocator has handed out and not got back. LLVM
    # allocates there.
    def self.malloc_bytes_in_use : Int64
      CAllocator.bytes_in_use
    end

    def self.malloc_bytes_allocated : Int64
      CAllocator.bytes_allocated
    end

    # With `CRYSTAL_PEAK_TRACE=1`, IR generation prints the collector's
    # numbers and the C allocator's bytes to standard error as it goes
    # (see `CodeGenVisitor#trace_peak`).
    class_getter?(traces : Bool) { ENV["CRYSTAL_PEAK_TRACE"]? == "1" }

    def self.record(io : IO, label : String, system_report : Bool = true) : Nil
      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        stats = GC.prof_stats
        io.printf("%-44s gc_heap_mb=%.1f gc_free_mb=%.1f gc_unmapped_mb=%.1f gc_since_gc_mb=%.1f gc_collections=%d malloc_in_use_mb=%.1f malloc_allocated_mb=%.1f\n",
          label, stats.heap_size / 1e6, stats.free_bytes / 1e6, stats.unmapped_bytes / 1e6,
          stats.bytes_since_gc / 1e6, stats.gc_no, malloc_bytes_in_use / 1e6, malloc_bytes_allocated / 1e6)
        io.flush
      {% end %}
      {% if flag?(:darwin) %}
        if system_report && (directory = self.directory)
          name = label.gsub(/[^a-z0-9]+/i, "-")
          LibC.system("/usr/bin/vmmap -summary #{Process.pid} > #{Process.quote(File.join(directory, "vmmap-#{name}.txt"))} 2>&1")
          LibC.system("/usr/bin/footprint #{Process.pid} > #{Process.quote(File.join(directory, "footprint-#{name}.txt"))} 2>&1")
        end
      {% end %}
    end
  end

  class CodeGenVisitor
    # For the node classes that fill the heap: how many objects are live,
    # and how many of them still have type-inference edges (the ones
    # `InferenceEdgeReleaser` did not reach).
    private def report_live_nodes_with_edges(io : IO) : Nil
      {% for node_class in %w(Call Var MetaVar Assign If Path InstanceVar TypeFilteredNode Block Def Arg) %}
        live_count = 0
        with_dependencies = 0
        with_observers = 0
        MemoryCensus.each_object_of({{node_class.id}}.crystal_instance_type_id, instance_sizeof({{node_class.id}})) do |pointer|
          node = pointer.as({{node_class.id}})
          live_count += 1
          with_dependencies += 1 if node.dependencies.first?
          with_observers += 1 if node.@observers.first?
        end
        io.printf("live %-18s %9d objects, %9d with dependencies, %9d with observers\n",
          {{node_class}}, live_count, with_dependencies, with_observers)
      {% end %}
      io.flush
    end

    # How many functions IR generation has started (for `trace_peak`).
    @peak_trace_fun_count = 0

    # Prints one line of `PeakProbe` numbers with the modules in memory.
    def trace_peak(label : String) : Nil
      return unless PeakProbe.traces?

      footprint, footprint_peak = GCTuning.footprint_bytes
      STDERR.printf("peak-trace t=%.1f footprint_mb=%.1f footprint_peak_mb=%.1f generated_functions=%d modules_in_memory=%d estimated_ir_mb=%.1f spills=%d ",
        GCTuning.started_at.elapsed.total_seconds, footprint / 1e6, footprint_peak / 1e6, @peak_trace_fun_count,
        @resident_modules.size, @resident_ir_bytes / 1e6, @module_spill.try(&.spill_count) || 0)
      list_of_pinned_modules = @resident_modules.reject(&.idle?)
      largest_pinned_module = list_of_pinned_modules.max_by?(&.estimated_ir_bytes)
      STDERR.printf("pinned_modules=%d pinned_estimated_mb=%.1f largest_pinned=%s:%.1f main_estimated_mb=%.1f signatures_estimated_mb=%.1f ",
        list_of_pinned_modules.size, list_of_pinned_modules.sum(&.estimated_ir_bytes) / 1e6,
        largest_pinned_module.try(&.name.gsub(/\s+/, "_")) || "-", (largest_pinned_module.try(&.estimated_ir_bytes) || 0) / 1e6,
        @main_module_info.estimated_ir_bytes / 1e6, @fun_signatures.try(&.estimated_ir_bytes).try(&./(1e6)) || 0.0)
      PeakProbe.record(STDERR, label, system_report: false)
    end

    # See `PeakProbe`. Exits the compiler.
    def run_peak_probe(node : ASTNode) : NoReturn
      directory = PeakProbe.directory || raise "BUG: the peak probe ran without CRYSTAL_PEAK_PROBE"
      Dir.mkdir_p(directory)
      File.open(File.join(directory, "probe.txt"), "w") do |io|
        PeakProbe.record(io, "end of IR generation")

        resident = @modules.values.select { |info| info.resident? && !info.same?(@main_module_info) }
        io.printf("modules in memory: %d (of %d), estimated IR %.1f MB, generated functions in them %d\n",
          resident.size, @modules.size, resident.sum(&.estimated_ir_bytes) / 1e6,
          resident.sum(&.list_of_generated_fun_names.size))

        if signatures = @fun_signatures
          io.printf("function signatures: %d declarations\n", signatures.fun_types.size)
          context = signatures.mod.context
          signatures.detach
          context.dispose
          @fun_signatures = nil
        end
        PeakProbe.record(io, "after freeing the signature module", system_report: false)

        resident.each do |info|
          context = info.mod.context
          info.detach
          context.dispose
        end
        PeakProbe.record(io, "after freeing the modules in memory", system_report: false)

        main_context = @main_module_info.mod.context
        @main_module_info.detach
        main_context.dispose
        PeakProbe.record(io, "after freeing the main module")

        {% unless flag?(:gc_none) || flag?(:wasm32) %}
          GC.collect
          PeakProbe.record(io, "after a full collection", system_report: false)
          LibGC.set_force_unmap_on_gcollect(1)
          3.times { GC.collect }
          LibGC.set_force_unmap_on_gcollect(0)
          CAllocator.return_free_memory
          PeakProbe.record(io, "after unmapping free heap blocks")
          report_live_nodes_with_edges(io)
        {% end %}
      end
      MemoryCensus.report(@program, node, "Codegen (crystal)", File.join(directory, "census.txt"))
      exit 0
    end
  end
end
