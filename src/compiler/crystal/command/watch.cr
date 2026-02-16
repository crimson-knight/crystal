# Implementation of the `crystal watch` command
#
# Watches source files for changes and automatically recompiles.
# With --run, also executes the compiled binary after each successful build.

require "../tools/watch/watcher"

class Crystal::Command
  private def watch
    compiler = new_compiler
    compiler.progress_tracker = @progress_tracker
    link_flags = [] of String
    run_mode = false
    clear_screen = false
    debounce_ms = 300
    force_polling = false
    poll_interval_ms = 1000

    option_parser = parse_with_crystal_opts do |opts|
      opts.banner = "Usage: crystal watch [options] [programfile] [--] [arguments]\n\nOptions:"
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

    if filenames.empty?
      STDERR.puts option_parser
      exit 1
    end

    sources = gather_sources(filenames)

    # Enable incremental compilation by default in watch mode
    compiler.incremental = true

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
end
