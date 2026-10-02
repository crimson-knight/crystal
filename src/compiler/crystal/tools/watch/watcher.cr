require "./file_watcher"
require "./kqueue_watcher"
require "./inotify_watcher"
require "./coordination"

module Crystal
  module Watch
    class Watcher
      @compiler : Compiler
      @sources : Array(Compiler::Source)
      @output_filename : String
      @run_mode : Bool
      @run_args : Array(String)
      @clear_screen : Bool
      @debounce : Time::Span
      @file_watcher : FileWatcher
      @running_process : Process?
      @color : Bool
      @interrupted : Bool = false

      # With `--strict-signatures` the typed program is kept between builds,
      # and a change that only edits method bodies types just those again
      # (see `IncrementalSemantic`).
      @result : Compiler::Result?
      @incremental_semantic : IncrementalSemantic?
      @changed = [] of String

      # See `Coordination`: the project directory with `.crystal-watch/`, the
      # number of the last finished build and the request it answers.
      @root : String = Dir.current
      @build = 0
      @request : String? = nil
      @last_state = "compiling"
      @last_errors : String? = nil

      def initialize(
        @compiler : Compiler,
        @sources : Array(Compiler::Source),
        @output_filename : String,
        @run_mode : Bool = false,
        @run_args : Array(String) = [] of String,
        @clear_screen : Bool = false,
        @debounce : Time::Span = 300.milliseconds,
        @file_watcher : FileWatcher = FileWatcher.create,
        @color : Bool = true,
      )
      end

      def run : Nil
        setup_signal_handler
        Coordination.setup(@root)
        @request = Coordination.requested(@root)

        loop do
          break if @interrupted
          clear_terminal if @clear_screen
          compile_and_watch
        end
      ensure
        cleanup
      end

      private def compile_and_watch
        source_file = @sources.first?.try(&.filename) || "unknown"
        print_status "Compiling #{Crystal.relative_filename(source_file)}..."

        # Re-read source files from disk (content may have changed)
        fresh_sources = @sources.map do |source|
          Compiler::Source.new(source.filename, File.read(source.filename))
        end

        write_status "compiling", "Compiling"
        begin
          result = compile_incrementally(fresh_sources) || compile_fully(fresh_sources)

          # Watch the program's files, the ones its macros read (templates, a
          # `run` program's data) and `.crystal-watch/`
          watched_files = result.program.requires.dup
          watched_files.concat IncrementalSemantic.macro_input_paths(result.program)
          watched_files << Coordination.dir(@root)
          @file_watcher.watch(watched_files)

          print_success "Compiled successfully (watching #{watched_files.size} files)"
          finish_build "ok", "Compiled successfully"

          if @run_mode
            kill_running_process
            spawn_run
          end
        rescue ex : Crystal::CodeError
          # The kept program may be half updated: start over next time.
          @incremental_semantic = nil
          ex.color = false
          errors = ex.to_s
          ex.color = @color
          STDERR.puts ex
          print_error "Compilation failed (watching for changes...)"
          finish_build "failed", "Compilation failed", errors
        rescue ex : Crystal::Error
          STDERR.puts ex.message
          print_error "Compilation failed (watching for changes...)"
          finish_build "failed", "Compilation failed", ex.message
        rescue ex : IO::Error
          STDERR.puts ex.message
          print_error "File read error (watching for changes...)"
          finish_build "failed", "File read error", ex.message
        end

        return if @interrupted

        print_status "Watching for changes..."
        changed = wait_for_changes_to_build

        return if @interrupted

        @changed = changed
        unless changed.empty?
          kill_running_process if @run_mode
          changed.each do |path|
            print_status "Changed: #{Crystal.relative_filename(path)}"
          end
          puts
        end
      end

      # Waits for changes worth a build. Waits longer while a hold is in
      # effect (`crystal watch hold`), answers requests (`crystal watch build`)
      # that need no build, and ignores events that didn't change anything.
      private def wait_for_changes_to_build : Array(String)
        loop do
          events = @file_watcher.wait_for_changes(@debounce)
          return [] of String if @interrupted

          if reason = Coordination.held?(@root)
            print_status "Held by #{reason}: building when released (crystal watch release)"
            write_status "held", "Held by #{reason}"
            while Coordination.held?(@root) && !@interrupted
              sleep 200.milliseconds
            end
            return [] of String if @interrupted
            @file_watcher.drain
          end

          # A request answered by the next build is the one made by now.
          @request = Coordination.requested(@root)
          changed = changes_since_last_build(events)
          return changed unless changed.empty?

          write_status @last_state, "No changes since the last build", @last_errors
        end
      end

      # What changed since the last build: by content when the program is
      # kept (so a file saved without changes, or a hold released after no
      # change, builds nothing); otherwise any watched file that changed.
      private def changes_since_last_build(events : Array(String)) : Array(String)
        control = Coordination.dir(@root)
        if incremental = @incremental_semantic
          incremental.changed_files
        elsif @last_state == "failed" || events.any? { |path| path != control && !path.starts_with?(File.join(control, "")) }
          [@sources.first.filename]
        else
          [] of String
        end
      end

      private def finish_build(state : String, message : String, errors : String? = nil) : Nil
        @build += 1
        @last_state = state
        @last_errors = errors
        write_status state, message, errors
      end

      private def write_status(state : String, message : String, errors : String? = nil) : Nil
        Coordination.write_status(@root, Coordination::Status.new(
          state: state, build: @build, request: @request, pid: Process.pid.to_i64,
          updated_at: Time.utc, message: message, errors: errors))
      end

      private def compile_fully(sources : Array(Compiler::Source)) : Compiler::Result
        @incremental_semantic = nil
        strict = @compiler.strict_signatures?
        result = @compiler.compile_configure_program(sources, @output_filename) do |program|
          if strict
            program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
            program.codegen_snapshot = Program::CodegenSnapshot.new
          end
        end
        @result = result

        if strict
          program_sources = result.program.requires.to_h { |filename| {filename, File.read(filename)} }
          sources.each { |source| program_sources[source.filename] = source.code }
          @incremental_semantic = IncrementalSemantic.new(result.program, program_sources)
        end
        result
      end

      # Applies the changed files to the kept program when only method bodies
      # changed. Returns `nil` when a full compilation is needed.
      private def compile_incrementally(sources : Array(Compiler::Source)) : Compiler::Result?
        incremental = @incremental_semantic
        result = @result
        return nil unless incremental && result && !@changed.empty?

        start = Time.instant
        program = result.program
        new_instances = program.collected_def_instances = [] of Def
        begin
          changed_sources, changed_inputs = @changed.partition { |filename| incremental.source?(filename) }
          incremental.apply(changed_sources.to_h { |filename| {filename, File.read(filename)} }, changed_inputs)
        rescue ex : IncrementalSemantic::Unsupported
          print_status "Full compilation: #{ex.message}"
          return nil
        ensure
          program.collected_def_instances = nil
        end
        typing = start.elapsed

        verify_incremental(sources, program) if ENV["CRYSTAL_INCREMENTAL_SEMANTIC_VERIFY"]? == "1"

        codegen = ""
        unless @compiler.no_codegen?
          changed_types = (incremental.retyped + new_instances).map(&.owner)
          if reason = @compiler.codegen_again(result, sources, @output_filename, changed_types)
            codegen = ", full codegen (#{reason})"
          else
            modules = changed_types.uniq.size
            codegen = ", codegen of #{modules} module#{modules == 1 ? "" : "s"}"
          end
        end
        print_status "Typed #{incremental.retyped.size} method instantiation#{incremental.retyped.size == 1 ? "" : "s"} again in #{typing.total_milliseconds.round(1)}ms#{codegen}, total #{start.elapsed.total_seconds.round(2)}s"
        result
      end

      # Compares the incrementally updated program with typing the sources
      # from scratch, and reports any difference.
      private def verify_incremental(sources : Array(Compiler::Source), program : Program) : Nil
        verifier = Compiler.new
        verifier.flags = @compiler.flags.dup
        verifier.prelude = @compiler.prelude
        verifier.no_codegen = true
        verifier.incremental = false
        fresh = verifier.compile_configure_program(sources, @output_filename) do |fresh_program|
          fresh_program.strict_signatures_root = program.strict_signatures_root
          fresh_program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
        end

        root = program.strict_signatures_root.not_nil!
        expected = IncrementalSemantic.typed_methods(fresh.program, root)
        actual = IncrementalSemantic.typed_methods(program, root)
        mismatches = expected.select { |key, description| actual[key]? != description }
        if mismatches.empty?
          print_success "Verified: #{expected.size} typed methods match a full compilation"
        else
          mismatches.each do |key, description|
            STDERR.puts "MISMATCH #{key}\n--- full:\n#{description}\n--- incremental:\n#{actual[key]? || "(missing)"}"
          end
          print_error "Verification failed: #{mismatches.size} of #{expected.size} typed methods differ"
        end
      end

      private def spawn_run : Nil
        executable = @output_filename

        if wasm_target?
          wasmtime = find_wasmtime
          unless wasmtime
            print_error "wasmtime not found in PATH. Cannot run WASM binary."
            return
          end

          args = ["run", "--wasm", "exceptions", executable] + @run_args
          print_status "Running via wasmtime: #{executable}"
          @running_process = Process.new(
            wasmtime,
            args: args,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit
          )
        else
          print_status "Running: #{executable}"
          @running_process = Process.new(
            executable,
            args: @run_args,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit
          )
        end
      end

      private def kill_running_process : Nil
        if process = @running_process
          @running_process = nil
          begin
            # Try graceful termination first
            process.signal(Signal::TERM)

            # Wait up to 2 seconds for graceful shutdown
            terminated = false
            20.times do
              if process.terminated?
                terminated = true
                break
              end
              sleep 100.milliseconds
            end

            # Force kill if still running
            unless terminated
              process.signal(Signal::KILL)
              process.wait
            end
          rescue ex
            # Process already exited, ignore
          end
        end
      end

      private def cleanup
        kill_running_process
        @file_watcher.close
      end

      private def wasm_target? : Bool
        @compiler.codegen_target.architecture == "wasm32"
      end

      private def find_wasmtime : String?
        # Check common locations
        home_wasmtime = File.join(::Path.home, ".wasmtime", "bin", "wasmtime")
        return home_wasmtime if File::Info.executable?(home_wasmtime)

        Process.find_executable("wasmtime")
      end

      private def clear_terminal
        print "\e[2J\e[H"
      end

      private def setup_signal_handler
        {% unless flag?(:wasm32) %}
          watcher = self
          Signal::INT.trap do
            watcher.handle_interrupt
          end
        {% end %}
      end

      # Called from signal handler -- must be safe for signal context.
      # Sets a flag and lets the main loop exit gracefully.
      protected def handle_interrupt
        @interrupted = true
        STDERR.puts "\n[watch] Interrupted, shutting down..."
        cleanup
        exit 0
      end

      private def print_status(message : String)
        if @color
          STDOUT.puts "[watch] #{message}".colorize(:cyan)
        else
          STDOUT.puts "[watch] #{message}"
        end
      end

      private def print_success(message : String)
        if @color
          STDOUT.puts "[watch] #{message}".colorize(:green)
        else
          STDOUT.puts "[watch] #{message}"
        end
      end

      private def print_error(message : String)
        if @color
          STDERR.puts "[watch] #{message}".colorize(:red)
        else
          STDERR.puts "[watch] #{message}"
        end
      end
    end
  end
end
