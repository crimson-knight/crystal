# Implementation of the `crystal watch` command
#
# Watches source files for changes and automatically recompiles.
# With --run, also executes the compiled binary after each successful build.

require "../tools/watch/watcher"

class Crystal::Command
  private def watch
    case options.first?
    when "hold"
      options.shift
      Watch::Coordination.hold(Dir.current, options.join(' ').presence || "hold")
      return
    when "release"
      Watch::Coordination.release(Dir.current)
      return
    when "build"
      options.shift
      exit watch_build
    when "status"
      exit watch_status
    when "hooks"
      puts WATCH_HOOKS
      return
    end

    compiler = new_compiler
    compiler.progress_tracker = @progress_tracker
    link_flags = [] of String
    run_mode = false
    clear_screen = false
    debounce_ms = 300
    force_polling = false
    poll_interval_ms = 1000

    option_parser = parse_with_crystal_opts do |opts|
      opts.banner = <<-USAGE
        Usage: crystal watch [options] [programfile] [--] [arguments]
               crystal watch hold [reason]   # don't build until released (before editing)
               crystal watch release         # build what changed meanwhile
               crystal watch build           # build now, wait, print errors (exit 0/1)
               crystal watch status          # state of the last build
               crystal watch hooks           # Claude Code hooks doing hold/release

        Options:
        USAGE
      setup_simple_compiler_options compiler, opts

      opts.on("--run", "Run the compiled binary after each successful build") do
        run_mode = true
      end

      opts.on("--clear", "Clear the terminal before each compilation") do
        clear_screen = true
      end

      opts.on("--debounce MS", "Debounce window in milliseconds (default: 300)") do |ms|
        debounce_ms = ms.to_i? || raise Crystal::Error.new("Invalid debounce value: #{ms}")
      end

      opts.on("--poll", "Force polling mode (no kqueue/inotify)") do
        force_polling = true
      end

      opts.on("--poll-interval MS", "Polling interval in milliseconds (default: 1000)") do |ms|
        poll_interval_ms = ms.to_i? || raise Crystal::Error.new("Invalid poll-interval value: #{ms}")
      end

      opts.on("--link-flags FLAGS", "Additional flags to pass to the linker") do |some_link_flags|
        link_flags << some_link_flags
      end
    end

    compiler.link_flags = link_flags.join(' ') unless link_flags.empty?

    # After parsing, `options` contains remaining unrecognized arguments.
    # Separate filenames (ending in .cr or existing files) from run arguments.
    filenames = [] of String
    run_args = [] of String
    found_separator = false

    options.each do |opt|
      if opt == "--"
        found_separator = true
        next
      end

      if found_separator
        run_args << opt
      elsif opt.ends_with?(".cr") || File.file?(opt)
        filenames << opt
      else
        # Treat as run argument if it doesn't look like a source file
        run_args << opt
      end
    end

    if filenames.empty? && (main = Crystal.project_main_file)
      filenames << main
    end

    if filenames.empty?
      STDERR.puts option_parser
      exit 1
    end

    sources = gather_sources(filenames)

    apply_incremental_default(compiler)

    # Determine output filename
    output_extension = compiler.codegen_target.executable_extension
    first_filename = sources.first.filename
    output_filename = "#{::Path[first_filename].stem}#{output_extension}"

    file_watcher = Watch::FileWatcher.create(
      force_polling: force_polling,
      poll_interval: poll_interval_ms.milliseconds
    )

    watcher = Watch::Watcher.new(
      compiler: compiler,
      sources: sources,
      output_filename: output_filename,
      run_mode: run_mode,
      run_args: run_mode ? run_args : [] of String,
      clear_screen: clear_screen,
      debounce: debounce_ms.milliseconds,
      file_watcher: file_watcher,
      color: @color
    )

    watcher.run
  end

  # `crystal watch build`: makes the watcher of this directory build what
  # changed (lifting a hold), waits for it and prints the result.
  private def watch_build : Int32
    root = Dir.current
    timeout = 10.minutes
    if index = options.index("--timeout")
      timeout = (options[index + 1]?.try(&.to_i?) || abort!("--timeout needs seconds", :USAGE_ERROR)).seconds
    end

    status = Watch::Coordination.read_status(root)
    unless status && watcher_alive?(status)
      STDERR.puts "No `crystal watch` or `crystal run` is watching #{root}"
      return 2
    end

    token = Random::Secure.hex(8)
    Watch::Coordination.release(root)
    Watch::Coordination.request(root, token)

    deadline = Time.instant + timeout
    loop do
      status = Watch::Coordination.read_status(root)
      if status && status.request == token && status.finished?
        puts "#{status.message} (build #{status.build})"
        if errors = status.errors
          puts errors
        end
        return status.state == "ok" ? 0 : 1
      end
      if status && !watcher_alive?(status)
        STDERR.puts "The watcher stopped"
        return 2
      end
      if Time.instant > deadline
        STDERR.puts "Timed out waiting for the build"
        return 2
      end
      sleep 100.milliseconds
    end
  end

  private def watch_status : Int32
    root = Dir.current
    status = Watch::Coordination.read_status(root)
    unless status && watcher_alive?(status)
      puts "Not watching"
      return 2
    end

    held = Watch::Coordination.held?(root)
    puts "#{status.state}: #{status.message} (build #{status.build}, #{status.updated_at.to_local})"
    puts "Held by #{held}" if held && status.state != "held"
    if errors = status.errors
      puts errors
    end
    status.state == "failed" ? 1 : 0
  end

  private def watcher_alive?(status) : Bool
    Process.exists?(status.pid)
  end

  WATCH_HOOKS = <<-JSON
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Edit|Write|MultiEdit|NotebookEdit",
            "hooks": [{ "type": "command", "command": "crystal watch hold claude" }]
          }
        ],
        "Stop": [
          {
            "hooks": [{ "type": "command", "command": "crystal watch release" }]
          }
        ]
      }
    }
    JSON
end
