require "./file_watcher"
require "./kqueue_watcher"
require "./inotify_watcher"

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

        begin
          result = @compiler.compile(fresh_sources, @output_filename)

          # Extract watched files from program.requires
          watched_files = result.program.requires.dup
          @file_watcher.watch(watched_files)

          print_success "Compiled successfully (watching #{watched_files.size} files)"

          if @run_mode
            kill_running_process
            spawn_run
          end
        rescue ex : Crystal::CodeError
          ex.color = @color
          STDERR.puts ex
          print_error "Compilation failed (watching for changes...)"
        rescue ex : Crystal::Error
          STDERR.puts ex.message
          print_error "Compilation failed (watching for changes...)"
        rescue ex : IO::Error
          STDERR.puts ex.message
          print_error "File read error (watching for changes...)"
        end

        return if @interrupted

        print_status "Watching for changes..."
        changed = @file_watcher.wait_for_changes(@debounce)

        return if @interrupted

        unless changed.empty?
          kill_running_process if @run_mode
          changed.each do |path|
            print_status "Changed: #{Crystal.relative_filename(path)}"
          end
          puts
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
