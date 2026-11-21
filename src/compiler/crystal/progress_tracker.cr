module Crystal
  class ProgressTracker
    # FIXME: This assumption is not always true
    STAGES        = 16
    STAGE_PADDING = 34

    property? stats = false
    property? progress = false

    getter current_stage = 1
    getter current_stage_name : String?
    getter stage_progress = 0
    getter stage_progress_total : Int32?

    # Continues the stage *name* that another process started at
    # *started_at* as stage number *stage_number*, with *stage_progress* of
    # *stage_progress_total* steps already done (see
    # `Compiler::ObjectStage`). The time reported is the whole stage's.
    def resume_stage(name, *, stage_number : Int32, started_at : Time,
                     stage_progress : Int32, stage_progress_total : Int32, &)
      @current_stage = stage_number
      @stage_progress = stage_progress
      @stage_progress_total = stage_progress_total
      stage(name, started_at: started_at) { yield }
    end

    def stage(name, *, started_at : Time? = nil, &)
      @current_stage_name = name

      print_stats
      print_progress

      NodePool.start_stage(name) if name.in?(NodePool::STAGES_WITH_THEIR_OWN_CHUNKS)
      time_start = Time.instant
      retval = yield
      GCTuning.stage_finished(name)
      NodePool.print_trace(name)
      time_taken = started_at ? Time.utc - started_at : time_start.elapsed

      print_stats(time_taken)
      print_progress

      @current_stage += 1
      @stage_progress = 0
      @stage_progress_total = nil

      retval
    end

    def clear
      return unless @progress
      print " " * (STAGE_PADDING + 5)
      print "\r"
    end

    def print_stats(time_taken = nil)
      return unless @stats

      justified_name = "#{current_stage_name}:".ljust(STAGE_PADDING)
      if time_taken
        memory_usage_mb = GC.stats.heap_size / 1024.0 / 1024.0
        memory_usage_str = " (%7.2fMB)" % {memory_usage_mb}
        puts "#{justified_name} #{time_taken}#{memory_usage_str}"
      else
        print "#{justified_name}\r" unless @progress
      end
    end

    def print_progress
      return unless @progress

      if stage_progress_total = @stage_progress_total
        progress = " [#{@stage_progress}/#{stage_progress_total}]"
      end

      stage_name = @current_stage_name.try(&.ljust(STAGE_PADDING))
      print "[#{@current_stage}/#{STAGES}]#{progress} #{stage_name}\r"
    end

    def stage_progress=(@stage_progress)
      print_progress
    end

    def stage_progress_total=(@stage_progress_total)
      print_progress
    end
  end
end
