require "json"
require "./codegen_worker_pool"

module Crystal
  class Compiler
    # The end of a build, from the object files to the linked executable,
    # run by a compiler process that holds nothing else.
    #
    # Once IR generation has written every module to its bitcode file, the
    # compiler no longer needs anything it has in memory: what is left is
    # building object files in worker processes, linking, and `dsymutil`.
    # It writes that work down as a `Handoff` and replaces its own process
    # image with `crystal internal-object-stage <handoff file>`, which returns
    # all of its memory to the system at once, before the workers start. The
    # new image has the same process id, prints the rest of `--stats` and
    # `--progress`, reports the warnings, and exits with the build's status.
    class ObjectStage
      # The hidden subcommand of the compiler binary that runs this stage.
      COMMAND = "internal-object-stage"

      # The stage of the build that starts before the handoff and ends after it.
      STAGE_NAME = "Codegen (bc+obj)"

      # What `--stats` tells about one compilation unit.
      struct UnitSummary
        include JSON::Serializable

        getter original_name : String
        getter bitcode_name : String
        getter? reused_previous_compilation : Bool

        def initialize(@original_name, @bitcode_name, @reused_previous_compilation)
        end
      end

      # Everything the end of the build needs from the compiler that
      # generated the IR.
      struct Handoff
        include JSON::Serializable

        # The object files to build, and how.
        getter worker_executable : String
        getter settings : CodegenWorker::Settings
        getter list_of_jobs : Array(CodegenWorker::Job)
        getter thread_count : Int32
        getter memory_budget_bytes : Int64

        # The link, run from `output_directory`, and what follows it.
        getter linker_name : String
        getter linker_command : String
        getter list_of_linker_arguments : Array(String)?
        getter output_directory : String
        getter output_filename : String
        getter? writes_dwarf_companion : Bool
        getter? cleans_cache_directory : Bool

        # The open, locked `compiler.lock` of the output directory, inherited
        # by the new process image so the build stays locked throughout.
        getter lock_file_descriptor : Int32?

        # How the build reports: the stage under way, the reports that were
        # ready before the handoff, and the warnings.
        getter? verbose : Bool
        getter? color : Bool
        getter? stats : Bool
        getter? progress : Bool
        getter stage_number : Int32
        getter stage_started_at_unix_ms : Int64
        getter stage_progress : Int32
        getter stage_progress_total : Int32
        getter list_of_unit_summaries : Array(UnitSummary)
        getter stats_report_before_codegen : String
        getter stats_report_after_codegen : String

        # The incremental cache of this build, written under a pending name:
        # it becomes the cache once the executable is linked.
        getter pending_incremental_cache_filename : String?
        getter list_of_warnings : Array(String)
        getter? error_on_warnings : Bool

        def initialize(*, @worker_executable, @settings, @list_of_jobs, @thread_count, @memory_budget_bytes,
                       @linker_name, @linker_command, @list_of_linker_arguments, @output_directory,
                       @output_filename, @writes_dwarf_companion, @cleans_cache_directory,
                       @lock_file_descriptor, @verbose, @color, @stats, @progress, @stage_number,
                       @stage_started_at_unix_ms, @stage_progress, @stage_progress_total,
                       @list_of_unit_summaries, @stats_report_before_codegen, @stats_report_after_codegen,
                       @pending_incremental_cache_filename, @list_of_warnings, @error_on_warnings)
        end

        # A compiler that builds objects, links and reports as the one this
        # handoff was written by.
        def to_compiler : Compiler
          compiler = settings.to_compiler
          compiler.verbose = verbose?
          compiler.color = color?
          compiler.cleanup = cleans_cache_directory?
          compiler.codegen_worker_memory_budget_bytes = memory_budget_bytes
          compiler.warnings.infos = list_of_warnings
          compiler.warnings.error_on_warnings = error_on_warnings?
          compiler
        end
      end

      # Reads the handoff the compiler wrote to *handoff_filename* and removes
      # the file.
      def self.read_handoff(handoff_filename : String) : Handoff
        handoff = File.open(handoff_filename) { |file| Handoff.from_json(file) }
        File.delete?(handoff_filename)
        handoff
      rescue ex : IO::Error | JSON::ParseException
        raise CompilerError.new("can't read the object stage handoff `#{handoff_filename}`: #{ex.message}")
      end

      @build_lock : IO::FileDescriptor?

      def initialize(@handoff : Handoff, @compiler : Compiler, @progress_tracker : ProgressTracker)
      end

      # Builds the object files, links, writes the debug companion, and
      # prints the reports of the build.
      def perform : Nil
        keep_build_lock
        @progress_tracker.stats = @handoff.stats?
        @progress_tracker.progress = @handoff.progress?
        @compiler.progress_tracker = @progress_tracker

        build_object_files
        @compiler.link_object_files(@handoff.linker_name, @handoff.linker_command,
          @handoff.list_of_linker_arguments, @handoff.output_filename, @handoff.output_directory)
        write_dwarf_companion
        keep_incremental_cache
        CacheDir.instance.cleanup if @handoff.cleans_cache_directory?

        @progress_tracker.clear
        if @handoff.stats?
          print @handoff.stats_report_before_codegen
          @compiler.print_codegen_stats(@handoff.list_of_unit_summaries)
          puts " - object files were built and linked by a compiler process of their own (object stage handoff)"
          print @handoff.stats_report_after_codegen
        end
      end

      private def keep_build_lock : Nil
        lock_file_descriptor = @handoff.lock_file_descriptor
        return unless lock_file_descriptor

        build_lock = IO::FileDescriptor.new(lock_file_descriptor)
        build_lock.close_on_exec = true
        @build_lock = build_lock
      end

      private def build_object_files : Nil
        stage_started_at = Time.unix_ms(@handoff.stage_started_at_unix_ms)
        @progress_tracker.resume_stage(STAGE_NAME,
          stage_number: @handoff.stage_number, started_at: stage_started_at,
          stage_progress: @handoff.stage_progress, stage_progress_total: @handoff.stage_progress_total) do
          @compiler.build_objects_in_workers(@handoff.list_of_jobs, @handoff.thread_count, @handoff.worker_executable)
        end
      end

      # The executable is linked: the cache written before the handoff
      # describes it from now on.
      private def keep_incremental_cache : Nil
        pending_incremental_cache_filename = @handoff.pending_incremental_cache_filename
        return unless pending_incremental_cache_filename
        # Writing the cache is best effort: without the file, the next build
        # compares against the previous cache and compiles again.
        return unless File.exists?(pending_incremental_cache_filename)

        File.rename(pending_incremental_cache_filename,
          File.join(File.dirname(pending_incremental_cache_filename), IncrementalCache::CACHE_FILENAME))
      end

      private def write_dwarf_companion : Nil
        {% if flag?(:darwin) %}
          File.delete?("#{@handoff.output_filename}.dwarf")
          @compiler.run_dsymutil(@handoff.output_filename) if @handoff.writes_dwarf_companion?
        {% end %}
      end
    end
  end
end
