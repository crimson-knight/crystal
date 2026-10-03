# Implementation of the `crystal spec` command
#
# This ends up compiling and running some or all files
# inside the `spec` directory of the current project, passing
# `--location file:line` if line numbers were specified.
#
# The spec framework is chosen by the files inside the `spec`
# directory, which usually is just `require "spec"` but could
# be anything else (for example the `minitest` shard).

# Gain access to OptionParser for spec runner to include it in the usage
# instructions.
require "spec/cli"

class Crystal::Command
  private def spec
    compiler = new_compiler
    link_flags = [] of String
    parse_with_crystal_opts do |opts|
      opts.banner = "Usage: crystal spec [options] [files] [-- runtime_options]\n\nOptions:"
      setup_simple_compiler_options compiler, opts

      opts.on("-h", "--help", "Show this message") do
        puts opts
        puts

        # Short flag `-p` might collied with the same parser flag (short for `--progress`),
        # so we don't show it here. It still works when passed as an explicit argument to the
        # runner process (e.g. `crystal spec -- -p`).
        runtime_options = Spec::CLI.new.build_option_parser(without_p: true)
        runtime_options.banner = "Runtime options (passed to spec runner):"
        puts runtime_options
        exit
      end

      opts.on("--link-flags FLAGS", "Additional flags to pass to the linker") do |some_link_flags|
        link_flags << some_link_flags
      end
    end

    compiler.link_flags = link_flags.join(' ') unless link_flags.empty?
    apply_incremental_default(compiler)

    # Assume spec files end with ".cr" and optionally with a colon and a number
    # (for the target line number), or is a directory. Everything else is an option we forward.
    # Run only the examples affected by the changes since the previous run
    # (needs a watcher, see `spec_through_watcher`)
    affected_only = !!options.delete("--affected")

    filenames = options.select do |option|
      option =~ /\.cr(\:\d+)?\Z/ || Dir.exists?(option)
    end
    options.reject! { |option| filenames.includes?(option) }

    locations = [] of {String, String}

    if filenames.empty?
      target_filenames = Dir["spec/**/*_spec.cr"]
    else
      target_filenames = [] of String
      filenames.each do |filename|
        if filename =~ /\A(.+?)\:(\d+)\Z/
          file, line = $1, $2
          unless File.file?(file)
            abort! "'#{file}' is not a file", :USAGE_ERROR
          end
          target_filenames << file
          locations << {file, line}
        else
          if Dir.exists?(filename)
            filename = ::Path[filename].to_posix
            target_filenames.concat Dir["#{filename}/**/*_spec.cr"]
          elsif File.file?(filename)
            target_filenames << filename
          else
            abort! "'#{filename}' is not a file", :USAGE_ERROR
          end
        end
      end
    end

    if target_filenames.size == 1
      if locations.size == 1
        # This is in case other spec runners use `-l`, we keep compatibility
        options << "-l" << locations.first[1]
      end
    else
      locations.each do |(file, line)|
        options << "--location" << "#{file}:#{line}"
      end
    end

    unless @color
      options << "--no-color"
    end

    sources = [Crystal.spec_source(target_filenames)]

    ENV["CRYSTAL_SPEC_COMPILER_BIN"] ||= if crystal_exec_path = ENV["CRYSTAL_EXEC_PATH"]?
                                           File.join(crystal_exec_path, "crystal")
                                         else
                                           Process.executable_path
                                         end

    # A `crystal run` or `crystal watch` of this project keeps the spec
    # program typed: it rebuilds just what changed.
    if watcher_compatible?(compiler) && (response = spec_through_watcher(target_filenames))
      unless response.ok
        STDERR.puts response.errors || response.message
        exit 1
      end
      if affected_only
        affected = response.affected
        if affected && affected.empty?
          puts "No examples affected by the changes since the previous spec run"
          return
        end
        affected.try &.each { |location| options << "--location" << location }
      end
      execute response.binary.not_nil!, options, compiler, error_on_exit: warnings_fail_on_exit?
      return
    end

    output_filename = run_executable(compiler, sources, "spec")
    compiler.compile sources, output_filename
    report_warnings
    execute output_filename, options, compiler, error_on_exit: warnings_fail_on_exit?
  end

  # Asks the watcher of this directory to build the specs of *filenames*.
  # `nil` when there's no watcher.
  private def spec_through_watcher(filenames : Array(String)) : Watch::Coordination::Response?
    root = Dir.current
    status = Watch::Coordination.read_status(root)
    return nil unless status && watcher_alive?(status)

    token = Random::Secure.hex(8)
    files = filenames.map { |filename| File.expand_path(filename) }
    Watch::Coordination.request(root, Watch::Coordination::Request.new(token, "spec", files))
    loop do
      if response = Watch::Coordination.take_response(root, token)
        return response
      end
      return nil unless watcher_alive?(status)
      sleep 50.milliseconds
    end
  end

  # Whether the watcher's compiler settings can serve this command: no
  # flags of its own.
  private def watcher_compatible?(compiler : Compiler) : Bool
    compiler.flags.empty? && !compiler.release? && compiler.emit_targets.none? &&
      compiler.incremental? && !compiler.no_cache? && compiler.link_flags.nil?
  end
end
