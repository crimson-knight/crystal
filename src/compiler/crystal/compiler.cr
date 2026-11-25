require "option_parser"
require "file_utils"
require "colorize"
require "crystal/digest/md5"
require "crystal/digest/sha256"
require "./incremental_cache"
require "./c_allocator"
require "./codegen/cached_object_record"
require "./tools/require_graph_discoverer"
require "./missing_library_hint"
{% if flag?(:msvc) %}
  require "./loader"
{% end %}
{% unless flag?(:without_mt) %}
  require "wait_group"
{% end %}

module Crystal
  # This exception describes an error in the compiler.
  # It usually leads to an unsuccessful process exit.
  class CompilerError < Exception
    getter status

    def self.new(message, exit : Command::Exit)
      new message, status: exit.to_i
    end

    def initialize(message, *, @status : Int32 = 1)
      super message
    end
  end

  @[Flags]
  enum Debug
    LineNumbers
    Variables
    Default     = LineNumbers
  end

  enum FramePointers
    Auto
    Always
    NonLeaf
  end

  # Main interface to the compiler.
  #
  # A Compiler parses source code, type checks it and
  # optionally generates an executable.
  class Compiler
    DEFAULT_LINKER = ENV["CC"]? || {{ env("CRYSTAL_CONFIG_CC") || "cc" }}
    MSVC_LINKER    = ENV["CC"]? || {{ env("CRYSTAL_CONFIG_CC") || "cl.exe" }}

    # A source to the compiler: its filename and source code.
    record Source,
      filename : String,
      code : String

    # The result of a compilation: the program containing all
    # the type and method definitions, and the parsed program
    # as an ASTNode.
    record Result,
      program : Program,
      node : ASTNode

    # If `true`, doesn't generate an executable but instead
    # creates a `.o` file and outputs a command line to link
    # it in the target machine.
    property? cross_compile = false

    # If `true`, generates a shared library (.so/.dylib) instead
    # of an executable. Passes `-shared -fPIC` to the linker and
    # skips the `main` entry point.
    property? shared = false

    # Compiler flags. These will be true when checked in macro
    # code by the `flag?(...)` macro method.
    property flags = [] of String

    # Controls generation of frame pointers.
    property frame_pointers = FramePointers::Auto

    # If `true`, the executable will be generated with debug code
    # that can be understood by `gdb` and `lldb`.
    property debug = Debug::Default

    # If `true`, `.ll` files will be generated in the default cache
    # directory for each generated LLVM module.
    property? dump_ll = false

    # Additional link flags to pass to the linker.
    property link_flags : String?

    # Sets the mcpu. Check LLVM docs to learn about this.
    property mcpu : String?

    # Sets the mattr (features). Check LLVM docs to learn about this.
    property mattr : String?

    # If `false`, color won't be used in output messages.
    property? color = true

    # If `true`, skip cleanup process on semantic analysis.
    property? no_cleanup = false

    # If `true`, no executable will be generated after compilation
    # (useful to type-check a program)
    property? no_codegen = false

    # Maximum number of LLVM modules that are compiled in parallel
    property n_threads : Int32 = {% if Fiber.has_constant?(:ExecutionContext) %}
      Fiber::ExecutionContext.default_workers_count
    {% elsif flag?(:win32) %}
      1
    {% else %}
      8
    {% end %}

    # The compiler executable to start as object-file workers (see
    # `CodegenWorker`). When set, and more than one thread is allowed, a
    # multi-module build writes every module to its bitcode file, frees the
    # modules, and lets `n_threads` worker processes build the object files.
    # The compiler's main program sets it to its own executable; a program
    # that embeds the compiler leaves it unset and compiles objects in-process.
    property codegen_worker_executable : String?

    # Whether the compiler may end a build by replacing its own process image
    # with `crystal internal-object-stage` (see `ObjectStage`), which builds
    # the object files in workers, links, and exits with the build's status.
    # `Compiler#compile` then never returns for a build that reaches the
    # object files. The `crystal build` command turns it on; it takes effect
    # together with `#codegen_worker_executable`.
    property? object_stage_handoff = false

    # The memory the object-file workers may use together, in bytes (see
    # `CodegenWorkerPool`). `nil` takes the default for `n_threads` and this
    # machine's memory. Set by `--object-memory-budget`.
    property codegen_worker_memory_budget_bytes : Int64?

    # The memory budget this compilation was given (see `MemoryBudget`).
    property memory_budget : MemoryBudget?

    # The worker processes that built the object files of the last compilation.
    @last_codegen_worker_pool : CodegenWorkerPool?

    # Default prelude file to use. This ends up adding a
    # `require "prelude"` (or whatever name is set here) to
    # the source file to compile.
    property prelude = "prelude"

    # Optimization mode
    enum OptimizationMode
      # [default] no optimization, fastest compilation, slowest runtime
      O0 = 0

      # low, compilation slower than O0, runtime faster than O0
      O1 = 1

      # middle, compilation slower than O1, runtime faster than O1
      O2 = 2

      # high, slowest compilation, fastest runtime
      # enables with --release flag
      O3 = 3

      # optimize for size, enables most O2 optimizations but aims for smaller
      # code size
      Os

      # optimize aggressively for size rather than speed
      Oz

      def suffix
        ".#{to_s.downcase}"
      end

      def self.from_level?(level : String) : self?
        case level
        when "0" then O0
        when "1" then O1
        when "2" then O2
        when "3" then O3
        when "s" then Os
        when "z" then Oz
        end
      end
    end

    # Sets the Optimization mode.
    property optimization_mode = OptimizationMode::O0

    # Sets the code model. Check LLVM docs to learn about this.
    property mcmodel = LLVM::CodeModel::Default

    # If `true`, generates a single LLVM module. By default
    # one LLVM module is created for each type in a program.
    # --release automatically enable this option
    property? single_module = false

    # The most parts an optimized single-module build (`--release`) is split
    # into for machine code emission, each part emitted on its own thread; the
    # build uses at most `n_threads` parts. With 1 the module is emitted as one
    # object file. The module is optimized as a whole before the split, so the
    # optimized program is the same whatever the number of parts.
    property release_units : Int32 = 8

    # The default of `#resident_ir_megabytes`. A program of 300 Grant models
    # (about 10 GB of IR) generates its IR in the same time with 256 MB in
    # memory as with 1 GB, and its peak is lower by about 1.3 GB. This
    # leaves a program of up to about a thousand modules and under a million
    # instructions entirely in memory.
    DEFAULT_RESIDENT_IR_MEGABYTES = 256

    # How many megabytes of LLVM IR (an estimate, see `ModuleSpill`) stay in
    # memory while LLVM IR is generated in multi-module mode. A program has
    # one module per type; the least recently used idle ones are written to
    # their bitcode file in the cache directory and read back when they are
    # needed again, so the memory used by IR generation does not grow with
    # the size of the program. With 0 there is no limit in bytes.
    property resident_ir_megabytes : Int32 = DEFAULT_RESIDENT_IR_MEGABYTES

    # The default of `#resident_modules`.
    DEFAULT_RESIDENT_MODULES = 0

    # How many idle LLVM modules stay in memory while LLVM IR is generated
    # in multi-module mode, whatever their size (see
    # `#resident_ir_megabytes`). With 0 there is no limit on their number.
    property resident_modules : Int32 = DEFAULT_RESIDENT_MODULES

    # The default of `#module_segment_instructions`.
    DEFAULT_MODULE_SEGMENT_INSTRUCTIONS = 100_000

    # The most LLVM instructions one type's functions hold in one object
    # file, in multi-module mode. A type that grows beyond that is compiled
    # as several object files (*segments*): the functions generated after a
    # segment reached the limit go to the next one. No object file job then
    # needs the time and memory of a whole large type. With 0 every type is
    # one object file.
    property module_segment_instructions : Int32 = DEFAULT_MODULE_SEGMENT_INSTRUCTIONS

    # How many types the last multi-module IR generation compiled as several
    # segments, how many segments those types have together, and the most
    # segments of one type.
    getter last_segmented_type_count = 0
    getter last_segment_count = 0
    getter last_maximum_segment_count = 0

    # The spill counters of the last multi-module IR generation.
    getter last_module_spill : ModuleSpill?

    # A `ProgressTracker` object which tracks compilation progress.
    property progress_tracker = ProgressTracker.new

    # Codegen target to use in the compilation.
    # If not set, asks LLVM the default one for the current machine.
    property codegen_target = Config.host_target

    # If `true`, prints the link command line that is performed
    # to create the executable.
    property? verbose = false

    # If `true`, doc comments are attached to types and methods
    # and can later be used to generate API docs.
    property? wants_doc = false

    # Warning settings and all detected warnings.
    property warnings = WarningCollection.new

    @[Flags]
    enum EmitTarget
      ASM
      OBJ
      LLVM_BC
      LLVM_IR
    end

    # Can be set to a set of flags to emit other files other
    # than the executable file:
    # * asm: assembly files
    # * llvm-bc: LLVM bitcode
    # * llvm-ir: LLVM IR
    # * obj: object file
    property emit_targets : EmitTarget = EmitTarget::None

    # Base filename to use for `emit` output.
    property emit_base_filename : String?

    # By default the compiler cleans up the default cache directory
    # to keep the most recent 10 directories used. If this is set
    # to `false` that cleanup is not performed.
    property? cleanup = true

    # Default standard output to use in a compilation.
    property stdout : IO = STDOUT

    # Default standard error to use in a compilation.
    property stderr : IO = STDERR

    # Whether to show error trace
    property? show_error_trace = false

    # Whether to link statically
    property? static = false

    # Whether to run `dsymutil` after linking on macOS. It writes the
    # `<output>.dwarf` file that exception backtraces read file and line
    # numbers from, and adds about 0.2 s to every build of a mid-size app.
    #
    # `nil` (the default) runs it for optimized builds (`--release` or
    # `-O1` and above) and skips it for unoptimized development builds.
    # `crystal run`, `crystal spec` and `crystal eval` set it to `true`,
    # because they run the program right away. Set by `--dsymutil` and
    # `--no-dsymutil`. Has no effect on other platforms or without debug info.
    property dsymutil : Bool? = nil

    # Returns whether `dsymutil` runs after linking (see `#dsymutil`).
    def dsymutil? : Bool
      dsymutil = @dsymutil
      dsymutil.nil? ? !optimization_mode.o0? : dsymutil
    end

    property dependency_printer : DependencyPrinter? = nil

    # In-memory cache of parsed ASTs for incremental compilation.
    # Survives across compile() calls so the watch loop can skip
    # re-parsing unchanged files.
    property parse_cache : ParseCache = ParseCache.new

    # If `true`, enables incremental compilation features:
    # file fingerprinting, parse caching, and cache persistence.
    property? incremental = false

    # If `true`, cache files are never read during compilation (forces recompile of
    # every module), but are still written. Mutually exclusive with `--incremental`.
    property? no_cache = false

    # Cached incremental data for the current compilation, loaded once.
    # Nil when incremental is disabled, no_cache is set, or no prior cache exists.
    @current_cached_data : IncrementalCacheData? = nil

    # Total number of modules in the last compilation.
    @last_modules_total : Int32 = 0

    # The modules of the last compilation whose object file was built
    # rather than reused from the build before.
    getter last_list_of_rebuilt_module_names = [] of String

    # Phase 6: Signature tracking results from the last compilation.
    @last_body_only_count : Int32 = 0
    @last_structural_count : Int32 = 0
    @last_isolated_body_only_count : Int32 = 0
    @last_file_signatures : Hash(String, FileTopLevelSignature)? = nil
    # File contents read during signature extraction, shared with save_incremental_cache
    # to avoid double file reads. Cleared after cache save completes.
    @last_file_contents : Hash(String, String)? = nil

    # Whether linking was skipped in the last compilation (all .o files reused).
    @link_skipped : Bool = false

    # Whether the entire compilation (semantic + codegen) was skipped because
    # no source files changed and the output binary already exists.
    @compilation_skipped : Bool = false

    # The listening socket and status pipe from the build server that started
    # this compiler, which keeps the typed program for the next build (see
    # `InferReuse::Holder`).
    property infer_reuse_handoff : InferReuse::Handoff? = nil

    # The command line of this build, which a later build must repeat to reuse
    # its typed program.
    property infer_reuse_argv : Array(String)? = nil

    # Whether code generation runs in a process that shares its heap pages
    # with a build server keeping the typed program (`InferReuse::Holder`).
    # Releasing semantic data or typed bodies there frees nothing the system
    # can take back: the server still holds those pages, and every page the
    # release, the collector's sweep or a later allocation writes becomes a
    # private copy in this process. So such a process keeps the program as it
    # is. `CRYSTAL_INFER_REUSE_RELEASE_IN_CHILD=1` releases as before, to
    # measure the difference.
    def shares_typed_program_with_build_server? : Bool
      !@infer_reuse_handoff.nil? && ENV["CRYSTAL_INFER_REUSE_RELEASE_IN_CHILD"]? != "1"
    end

    # Where to write the digest of the typed program (see
    # `InferReuse::TypedProgramDigest`), for a verification of a reused build.
    property infer_reuse_digest_filename : String? = nil

    # The command line of this build, for a snapshot of its typed program
    # (`InferPersist`); `nil` turns snapshots off for this compiler.
    property infer_persist_argv : Array(String)? = nil

    # The snapshot session of the build running now, if any.
    @infer_persist_session : InferPersist::Session? = nil

    # Whether this build reads and writes a type-inference snapshot in its
    # cache folder (`InferPersist`).
    def persists_type_inference? : Bool
      InferPersist.enabled? && @incremental && !@no_cache && !@no_codegen && @infer_reuse_handoff.nil? && !@infer_persist_argv.nil?
    end

    # Program that was created for the last compilation.
    property! program : Program

    # Compiles the given *source*, with *output_filename* as the name
    # of the generated executable.
    #
    # Raises `Crystal::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def compile(source : Source | Array(Source), output_filename : String) : Result
      compile_configure_program(source, output_filename) { }
    end

    # :ditto:
    #
    # Yields a `Program` instance before compiling.
    def compile_configure_program(source : Source | Array(Source), output_filename : String, & : Program -> Nil) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      yield program

      # Reset incremental state from previous compilation (watch mode)
      @compilation_skipped = false
      @sources_checked_at_unix_ms = Time.utc.to_unix_ms
      @link_skipped = false

      node = parse program, source

      # Load incremental cache data once for the entire compilation
      if @incremental && !@no_cache
        output_dir_for_cache = CacheDir.instance.directory_for(source)
        @current_cached_data = IncrementalCache.load(
          output_dir_for_cache, Config.version, @codegen_target.to_s, @flags, @prelude
        )
      else
        @current_cached_data = nil
      end

      # Incremental optimization: detect if any source files changed since
      # the last compilation. If nothing changed and the output binary exists,
      # skip semantic analysis and codegen entirely — they would produce
      # identical results.
      #
      # We check the cached file list directly (not program.requires) because
      # program.requires is only fully populated after semantic analysis.
      compilation_skipped = false
      if @incremental && !@no_codegen
        cached_data = @current_cached_data

        if cached_data && !cached_data.file_fingerprints.empty?
          any_changed = false

          # Check every file from the previous compilation for changes
          cached_data.file_fingerprints.each_value do |fp|
            begin
              info = File.info(fp.filename)
              if info.modification_time.to_unix_ms != fp.mtime_epoch || info.size != fp.byte_size
                any_changed = true
                break
              end
            rescue IO::Error
              # File no longer exists — treat as changed
              any_changed = true
              break
            end
          end

          any_changed ||= !reason_unfingerprinted_inputs_changed(program, cached_data, output_filename).nil?

          unless any_changed
            expanded_output = File.expand_path(output_filename)
            if File.exists?(expanded_output)
              compilation_skipped = true
              @compilation_skipped = true
            end
          end
        end
      end

      unless compilation_skipped
        persist = persists_type_inference? ? InferPersist::Session.for(self, CacheDir.instance.directory_for(source)) : nil
        @infer_persist_session = persist
        if persist && (loaded = persist.load(program))
          program, node = loaded
          @program = program
          yield program
        else
          begin
            node = program.semantic node, cleanup: !no_cleanup?
          rescue ex : SkipMacroCodeCoverageException
            program.macro_expansion_error_hook.try &.call(ex.cause)
          end
        end
        persist.try &.save(program, node)
        build_succeeded = false
        begin
          if digest_filename = @infer_reuse_digest_filename
            File.write(digest_filename, InferReuse::TypedProgramDigest.new(program, node).to_json)
          end

          if (handoff = @infer_reuse_handoff) && (record = program.infer_reuse_record) && !@no_codegen
            # Returns in the process that generates code; the program it typed
            # stays with the build server. A later build may come back here
            # with an edit re-typed in a copy of this program.
            node = InferReuse::Holder.new(handoff).after_semantic(self, program, node, record)
            GCTuning.enter_build_server_child
            if @incremental && !@no_cache
              @current_cached_data = IncrementalCache.load(
                CacheDir.instance.directory_for(source), Config.version, @codegen_target.to_s, @flags, @prelude
              )
            end
          end

          unless @no_codegen
            release_semantic_only_data(program, node)
            units = codegen program, node, source, output_filename
          end

          if @incremental
            @progress_tracker.stage("Signatures") do
              extract_and_compare_signatures(program)
            end
            @progress_tracker.stage("Cache save") do
              save_incremental_cache(program, CacheDir.instance.directory_for(source))
            end
          end
          build_succeeded = true
        ensure
          persist.try &.finish(build_succeeded)
        end
      end

      {% if flag?(:darwin) %}
        # The executable from the previous build was kept as is.
        update_dwarf_companion(File.expand_path(output_filename), linked: false) if compilation_skipped && !@cross_compile
      {% end %}

      @progress_tracker.clear
      print_macro_run_stats(program)
      if units
        @last_list_of_rebuilt_module_names = units.reject(&.reused_previous_compilation?).map(&.original_name)
        print_codegen_stats(units.map(&.summary))
      end
      print_parse_cache_stats
      print_signature_stats
      print_compilation_skip_stats if compilation_skipped

      @current_cached_data = nil

      Result.new program, node
    end

    # Runs the semantic pass on the given source, without generating an
    # executable nor analyzing methods. The returned `Program` in the result will
    # contain all types and methods. This can be useful to generate
    # API docs, analyze type relationships, etc.
    #
    # Raises `Crystal::CodeError` if there's an error in the
    # source code.
    #
    # Raises `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def top_level_semantic(source : Source | Array(Source)) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      node = parse program, source
      node, _ = program.top_level_semantic(node)

      @progress_tracker.clear
      print_macro_run_stats(program)

      Result.new program, node
    end

    # Set maximum level of optimization.
    def release!
      @optimization_mode = OptimizationMode::O3
      @single_module = true
    end

    def release?
      @optimization_mode.o3? && @single_module
    end

    private def new_program(sources)
      @parse_cache.reset_stats if @incremental

      @program = program = Program.new
      program.compiler = self
      program.filename = sources.first.filename
      program.codegen_target = codegen_target
      program.target_machine = create_target_machine
      program.flags << "release" if release?
      program.flags << "debug" unless debug.none?
      program.flags << "static" if static?
      program.flags << "shared" if shared?
      program.user_flags.concat @flags
      program.flags.concat @flags
      program.define_crystal_constants
      program.wants_doc = wants_doc?
      program.color = color?
      program.infer_reuse_record = InferReuse::SourceRecord.new if @infer_reuse_handoff || persists_type_inference?
      program.stdout = stdout
      program.show_error_trace = show_error_trace?
      program.progress_tracker = @progress_tracker
      program.warnings = @warnings
      program.optimization_mode = @optimization_mode

      # Apply allocation hints from previous compilation
      if @incremental
        if hints = @current_cached_data.try(&.allocation_hints)
          # Pre-size the string pool (add 25% headroom)
          if hints.string_pool_capacity > 8
            capacity = (hints.string_pool_capacity * 5 // 4).clamp(8, 1_000_000)
            program.string_pool = StringPool.new(capacity)
          end
        end
      end
      program
    end

    private def parse(program, sources : Array)
      @progress_tracker.stage("Parse") do
        nodes = sources.map do |source|
          # We add the source to the list of required file,
          # so it can't be required again
          program.requires.add source.filename
          parse(program, source).as(ASTNode)
        end
        nodes = Expressions.from(nodes)

        # Prepend the prelude to the parsed program
        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).at(location), nodes] of ASTNode)

        # Discover require graph and parse files in parallel if enabled.
        # Only runs in incremental mode — this double-parses the entire program
        # to pre-populate the parse cache, which is wasteful for one-shot builds.
        if @incremental && parallel_parse?
          begin
            discoverer = RequireGraphDiscoverer.new(program)
            discovered_files = discoverer.discover(nodes, prelude)

            unless discovered_files.empty?
              pre_parsed = parallel_parse_files(program, discovered_files)
              program.pre_parsed_files = pre_parsed unless pre_parsed.empty?
            end
          rescue ex
            # If discovery or parallel parse fails, fall through to sequential.
            # The semantic phase will parse files normally.
            program.pre_parsed_files = nil
          end
        end

        # And normalize
        program.normalize(nodes)
      end
    end

    private def parse(program, source : Source)
      program.infer_reuse_record.try &.add_source(source.filename, source.code)
      parser = program.new_parser(source.code)
      parser.filename = source.filename
      parser.wants_doc = wants_doc?
      parser.parse
    rescue ex : InvalidByteSequenceError
      stderr.print colorize("Error: ").red.bold
      stderr.print colorize("file '#{Crystal.relative_filename(source.filename)}' is not a valid Crystal source file: ").bold
      stderr.puts ex.message
      exit 1
    end

    # Returns true if parallel parsing is enabled.
    # Disabled by setting CRYSTAL_PARALLEL_PARSE=0.
    private def parallel_parse? : Bool
      ENV["CRYSTAL_PARALLEL_PARSE"]? != "0"
    end

    # Parse an array of filenames in parallel (under preview_mt) or
    # sequentially. Each thread gets its own StringPool since StringPool
    # is not thread-safe. Returns a Hash mapping filename to parsed AST.
    private def parallel_parse_files(program, filenames : Array(String)) : Hash(String, ASTNode)
      result = {} of String => ASTNode

      {% if flag?(:preview_mt) %}
        n = {n_threads, filenames.size}.min

        if n > 1
          mutex = Mutex.new
          channel = Channel(String).new(n * 2)
          wg = WaitGroup.new

          n.times do
            wg.spawn do
              local_pool = StringPool.new
              while filename = channel.receive?
                begin
                  content = File.read(filename)
                  parser = Parser.new(content, local_pool)
                  parser.filename = filename
                  parser.wants_doc = wants_doc?
                  parsed = parser.parse
                  mutex.synchronize do
                    result[filename] = parsed
                    program.infer_reuse_record.try &.add_source(filename, content)
                  end
                rescue
                  # Skip files that fail to parse -- semantic phase handles errors
                end
              end
            end
          end

          filenames.each { |f| channel.send(f) }
          channel.close
          wg.wait
        else
          # Single thread -- parse sequentially
          filenames.each do |filename|
            begin
              content = File.read(filename)
              program.infer_reuse_record.try &.add_source(filename, content)
              parser = program.new_parser(content)
              parser.filename = filename
              parser.wants_doc = wants_doc?
              result[filename] = parser.parse
            rescue
              # Skip files that fail to parse
            end
          end
        end
      {% else %}
        # Sequential fallback without preview_mt
        filenames.each do |filename|
          begin
            content = File.read(filename)
            program.infer_reuse_record.try &.add_source(filename, content)
            parser = program.new_parser(content)
            parser.filename = filename
            parser.wants_doc = wants_doc?
            result[filename] = parser.parse
          rescue
            # Skip files that fail to parse
          end
        end
      {% end %}

      result
    end

    # The settings for spilling idle LLVM modules during IR generation, or
    # `nil` when every module stays in memory. A spilled module part is
    # written next to its unit's cached bitcode files and replaces them
    # when the unit is compiled. IR generation runs outside the cache
    # directory's lock, so the spill files carry the process id: two
    # compilations of one program never write the same file.
    private def module_spill_for(output_dir, is_single_module) : ModuleSpill?
      return nil if is_single_module || (@resident_modules <= 0 && @resident_ir_megabytes <= 0)

      remove_spill_files_of_ended_compilations(output_dir)

      module_spill = ModuleSpill.new(@resident_modules, @resident_ir_megabytes.to_i64 * 1024 * 1024, target_machine.triple) do |type_name, part_index|
        File.join(output_dir, "#{CompilationUnit.file_basename(type_name, optimization_mode)}.#{Process.pid}.part#{part_index}.new.bc")
      end
      if (memory_budget = @memory_budget) && module_spill.malloc_relief_bytes == 0
        module_spill.malloc_relief_bytes = memory_budget.malloc_relief_bytes
      end
      module_spill
    end

    # Loads the modules in the bitcode files of *list_of_filenames* into
    # *context* and links them into one module: the first one, with the
    # others moved into it.
    def self.parse_linked_bitcode_files(list_of_filenames : Array(String), context : LLVM::Context) : LLVM::Module
      linked_module = nil
      list_of_filenames.each do |filename|
        bitcode = LLVM::MemoryBuffer.from_file(filename)
        part = begin
          LLVM::Module.parse(bitcode, context)
        ensure
          bitcode.dispose
        end
        if first_part = linked_module
          first_part.link(part)
        else
          linked_module = part
        end
      end
      linked_module || raise "BUG: a module needs at least one bitcode file"
    end

    # The cached bitcode part files (`<unit>.part<N>.bc`) that earlier
    # builds left in an output directory, by unit. The directory is read
    # once, the first time a unit asks: reading it for each of several
    # thousand units took over a minute of a 300-model build.
    @cached_part_bitcode_filenames : Hash(String, Array(String))?
    @cached_part_bitcode_directory : String?
    @cached_part_bitcode_lock = Mutex.new

    # Hands over the part files an earlier build left for the unit whose
    # files are named *unit_basename*, so the unit can delete them. A unit
    # asks before it writes part files of its own.
    protected def take_cached_part_bitcode_filenames(output_dir : String, unit_basename : String) : Array(String)
      @cached_part_bitcode_lock.synchronize do
        filenames_by_unit = @cached_part_bitcode_filenames
        if filenames_by_unit.nil? || @cached_part_bitcode_directory != output_dir
          filenames_by_unit = Hash(String, Array(String)).new
          Dir.each_child(output_dir) do |child|
            next unless match = child.match(/\A(.+)\.part\d+\.bc\z/)

            (filenames_by_unit[match[1]] ||= [] of String) << child
          end
          @cached_part_bitcode_filenames = filenames_by_unit
          @cached_part_bitcode_directory = output_dir
        end
        filenames_by_unit.delete(unit_basename) || [] of String
      end
    end

    # An interrupted compilation leaves its spill files behind.
    private def remove_spill_files_of_ended_compilations(output_dir) : Nil
      Dir.each_child(output_dir) do |child|
        next unless match = child.match(/\.(\d+)\.part\d+\.new\.bc\z/)
        next if Process.exists?(match[1].to_i64)

        File.delete?(File.join(output_dir, child))
      end
    end

    # The flags object files are built with: an object built with other
    # flags is never reused.
    private def current_bc_flags(release_parts = 1) : String
      current_bc_flags = "#{@codegen_target}|#{@mcpu}|#{@mattr}|#{@link_flags}|#{@mcmodel}"
      if release_parts > 1
        current_bc_flags += "|parts=#{release_parts}"
      end
      current_bc_flags
    end

    private def bc_flags_filename(output_dir) : String
      "#{output_dir}/bc_flags#{optimization_mode.suffix}"
    end

    private def bc_flags_changed?(output_dir, release_parts = 1)
      bc_flags_changed = true
      current_bc_flags = current_bc_flags(release_parts)
      bc_flags_filename = bc_flags_filename(output_dir)
      if File.file?(bc_flags_filename)
        previous_bc_flags = File.read(bc_flags_filename).strip
        bc_flags_changed = previous_bc_flags != current_bc_flags
      end
      File.write(bc_flags_filename, current_bc_flags)
      bc_flags_changed
    end

    private def codegen(program, node : ASTNode, sources, output_filename)
      {% if LibLLVM::IS_LT_130 %}
        if @codegen_target.architecture == "aarch64"
          stderr.puts "Error: Target #{@codegen_target} requires a Crystal compiler built with LLVM 13 or a later version."
          exit 1
        end
      {% end %}

      is_single_module = @single_module || @cross_compile || !@emit_targets.none? || program.has_flag?("wasm32")

      output_dir = CacheDir.instance.directory_for(sources)
      @cached_part_bitcode_filenames = nil
      module_spill = @last_module_spill = module_spill_for(output_dir, is_single_module)
      # An incremental build numbers what the build before it numbered the
      # same way. Emitted LLVM IR keeps the names of local values, which
      # such a build drops.
      stable_numbering = @incremental && !@no_cache && @emit_targets.none? ? StableNumbering.load(output_dir) : nil
      program.stable_numbering = stable_numbering
      # The branches a dispatch leaves out depend on the whole program, so the
      # analysis runs before code generation, and the keys of IR skipping
      # record each call's decisions (see `IrSkip::KeyWalker`).
      program.dispatch_prune = nil
      unless DispatchPrune.mode_for(program).off?
        program.dispatch_prune = @progress_tracker.stage("Codegen (prune dispatch)") do
          program.analyze_dispatch_prune(node)
        end
      end
      ir_skip_session = ir_skip_session_for(program, output_dir, is_single_module, stable_numbering, sources)
      program.ir_skip = ir_skip_session
      @last_ir_skip_stats = ir_skip_session.try(&.stats)

      llvm_modules = @progress_tracker.stage("Codegen (crystal)") do
        GCTuning.with_ir_generation_divisor do
          program.codegen node, debug: debug, frame_pointers: frame_pointers,
            single_module: is_single_module, release_typed_bodies: !shares_typed_program_with_build_server?,
            module_spill: module_spill, module_segment_instructions: @module_segment_instructions.to_i64
        end
      end
      program.dispatch_prune = nil
      if @progress_tracker.stats?
        main_part_count = llvm_modules.count { |type_name, _| CodeGenVisitor::MainParts.part_module_name?(type_name) }
        puts "Main parts: #{main_part_count} modules of top-level code" if main_part_count > 0
      end
      if stable_numbering
        stable_numbering.type_ids_by_stable_key = program.llvm_id.type_ids_in_use_by_stable_key
        list_of_part_fun_counts_by_module_name = {} of String => Array(Int32)
        llvm_modules.each do |type_name, info|
          # A module that got no code keeps the cuts of the build before.
          list_of_part_fun_counts = info.skipped_ir_generation? ? info.ir_skip_plan.try(&.recorded.list_of_part_fun_counts) : nil
          list_of_part_fun_counts ||= info.list_of_part_fun_counts
          list_of_part_fun_counts_by_module_name[type_name] = list_of_part_fun_counts unless list_of_part_fun_counts.empty?
        end
        stable_numbering.list_of_part_fun_counts_by_module_name = list_of_part_fun_counts_by_module_name
        segments_by_module_name = {} of String => StableNumbering::Segments
        llvm_modules.each do |type_name, info|
          if segments = CodeGenVisitor.segments_to_keep(info)
            segments_by_module_name[type_name] = segments
          end
        end
        stable_numbering.segments_by_module_name = segments_by_module_name
        stable_numbering.save(output_dir)
      end
      list_of_segment_counts = llvm_modules.each_value.map { |info| info.list_of_later_segments.size + 1 }.select { |count| count > 1 }.to_a
      @last_segmented_type_count = list_of_segment_counts.size
      @last_segment_count = list_of_segment_counts.sum
      @last_maximum_segment_count = list_of_segment_counts.max? || 0
      # Printed as soon as the stage ends: a build that is stopped after IR
      # generation still shows them.
      print_module_spill_stats
      if ir_skip_session
        summarize_ir_skip(ir_skip_session, llvm_modules)
        print_ir_skip_stats(ir_skip_session)
        # The main module is generated in every build, and the moment it
        # gets a declaration (a lib fun, a callee) depends on which functions
        # were skipped. In name order, its bitcode does not.
        if (main_module_info = llvm_modules[""]?) && main_module_info.resident?
          main_module_info.mod.sort_function_declarations_by_name
        end
      end

      release_parts = release_parts_for(program, is_single_module, llvm_modules)
      bc_flags_changed = bc_flags_changed? output_dir, release_parts
      target_triple = target_machine.triple
      list_of_line_patch_checks = @list_of_line_patch_checks = [] of LinePatch::Verification::Check

      units = llvm_modules.map do |type_name, info|
        # A module is either in memory or, all of its parts, on disk.
        if info.resident?
          llvm_mod = info.mod
          llvm_mod.target = target_triple
        end

        # Whether the unit's previous object file is reused is decided by
        # the content of its bitcode (`CompilationUnit#must_compile?`): its
        # hash against the hash the object was built from, or the bitcode
        # itself against the cached bitcode. A module's code depends on more
        # than the files its own defs are in (inlined bodies, callee return
        # types, type layouts).
        list_of_carried_part_hashes = info.skipped_ir_generation? ? info.ir_skip_plan.try(&.recorded.list_of_part_hashes) : nil
        patched_object = info.ir_skip_plan.try(&.line_patch)
        if patched_object && !info.skipped_ir_generation?
          # Generated after all (or in verification): the patched object is
          # only compared with the fresh one, if at all.
          if ir_skip_session && ir_skip_session.verify? && (pending_filename = patched_object.pending_filename)
            list_of_line_patch_checks << LinePatch::Verification::Check.new(type_name, pending_filename,
              Crystal.relative_filename("#{output_dir}/#{CompilationUnit.file_basename(type_name, optimization_mode)}#{codegen_target.object_extension}"))
          else
            patched_object.discard
          end
          patched_object = nil
        end
        CompilationUnit.new(self, program, type_name, llvm_mod, output_dir, bc_flags_changed, release_parts,
          info.list_of_spill_paths, info.list_of_spill_part_hashes, list_of_carried_part_hashes, patched_object)
      end
      @ir_skip_session_to_finish = ir_skip_session
      @list_of_ir_skip_module_infos = ir_skip_session ? llvm_modules.values : nil

      @last_modules_total = units.size

      {% if LibLLVM::IS_LT_170 %}
        # initialize the legacy pass manager once in the main thread/process
        # before we start codegen in threads (MT)
        init_llvm_legacy_pass_manager unless optimization_mode.o0?
      {% end %}

      if @cross_compile
        cross_compile program, units, output_filename
      else
        units = with_file_lock(output_dir) do |build_lock|
          codegen program, units, output_filename, output_dir, build_lock
        end

        {% if flag?(:darwin) %}
          update_dwarf_companion(output_filename, linked: !@link_skipped)
        {% end %}

        {% if flag?(:msvc) %}
          copy_dlls(program, output_filename) unless static?
        {% end %}
      end

      CacheDir.instance.cleanup if @cleanup

      units
    end

    # The number of parts the single optimized module is emitted as: more than
    # one only for an optimized single-module build of an executable or shared
    # library for this host on macOS or Linux, where every part's object goes
    # straight to the linker, and only when LLVM can split the module and
    # compile the parts on several threads; at most `n_threads`.
    private def release_parts_for(program, is_single_module, llvm_modules) : Int32
      return 1 unless is_single_module && llvm_modules.size == 1
      return 1 if @optimization_mode.o0? || @cross_compile || !@emit_targets.none?

      target = program.codegen_target
      return 1 unless target.macos? || (target.linux? && !target.android?)
      return 1 unless llvm_modules.first_value.mod.can_be_split?
      {% unless flag?(:without_mt) %}
        return 1 unless LLVM.multithreaded?
      {% end %}

      @release_units.clamp(1..@n_threads.clamp(1..))
    end

    private def with_file_lock(output_dir, &)
      File.open(File.join(output_dir, "compiler.lock"), "w") do |file|
        file.flock_exclusive do
          yield file
        end
      end
    end

    # Brings `<output>.dwarf` in line with the executable after a build. A
    # fresh link removes the companion an earlier build left, which describes
    # the executable this build replaced; then dsymutil writes a new one when
    # `#dsymutil?` asks for it and the program has debug information. A build
    # that reused the executable keeps its companion, or writes the missing
    # one when asked for.
    private def update_dwarf_companion(output_filename, *, linked : Bool)
      dwarf_filename = "#{output_filename}.dwarf"
      File.delete?(dwarf_filename) if linked
      return if debug.none? || !dsymutil?

      run_dsymutil(output_filename) unless File.exists?(dwarf_filename)
    end

    # Whether dsymutil runs in the background after an incremental build
    # links: the build ends without waiting for the `<output>.dwarf`
    # companion, which appears a few seconds later. Only when nothing asked
    # for dsymutil explicitly (`crystal run` and `crystal spec` ask, because
    # they run the program right away; so does `--dsymutil`).
    def dwarf_companion_in_background? : Bool
      @incremental && @dsymutil.nil?
    end

    # Starts dsymutil for *filename* and returns without waiting for it. It
    # writes the companion under a temporary name and renames it into place,
    # so a program never reads a partial file (a program that starts before
    # then prints its backtraces without file and line). The process keeps
    # *build_lock*, the locked `compiler.lock` of the cache directory, until
    # it ends: the next build of the same program waits for it before it
    # touches the object files dsymutil reads or links a new executable.
    protected def start_dsymutil_in_background(filename : String, build_lock : IO::FileDescriptor?) : Nil
      dsymutil = Process.find_executable("dsymutil")
      return unless dsymutil

      @progress_tracker.stage("dsymutil") do
        # The script first closes every inherited descriptor but the lock:
        # a pipe a caller waits on (the build server's status pipe, a
        # client's socket) must not stay open until dsymutil ends.
        script = %(for fd in $(ls /dev/fd); do if [ "$fd" -gt 2 ] && [ "$fd" != "$3" ]; then eval "exec $fd>&-"; fi; done 2>/dev/null; ) +
                 %("$1" --flat -o "$2.dwarf.tmp" "$2" && mv -f "$2.dwarf.tmp" "$2.dwarf" || rm -f "$2.dwarf.tmp")
        lock_descriptor = build_lock.try(&.fd) || -1
        build_lock.try &.close_on_exec = false
        begin
          Process.new("/bin/sh", ["-c", script, "sh", dsymutil, filename, lock_descriptor.to_s],
            input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
        ensure
          build_lock.try &.close_on_exec = true
        end
      end
    end

    protected def run_dsymutil(filename)
      dsymutil = Process.find_executable("dsymutil")
      return unless dsymutil

      @progress_tracker.stage("dsymutil") do
        status = Process.run(dsymutil, ["--flat", filename])
        # Leave no partial companion behind.
        File.delete?("#{filename}.dwarf") unless status.success?
      end
    end

    private def copy_dlls(program, output_filename)
      not_found = nil
      output_directory = File.dirname(output_filename)

      program.each_dll_path do |path, found|
        if found
          dest = File.join(output_directory, File.basename(path))
          File.copy(path, dest) unless File.exists?(dest)
        else
          not_found ||= [] of String
          not_found << path
        end
      end

      if not_found
        stderr << "Warning: The following DLLs are required at run time, but Crystal is unable to locate them in CRYSTAL_LIBRARY_PATH, the compiler's directory, or PATH: "
        not_found.sort!.join(stderr, ", ")
      end
    end

    private def cross_compile(program, units, output_filename)
      unit = units.first
      llvm_mod = unit.llvm_mod

      @progress_tracker.stage("Codegen (bc+obj)") do
        optimize llvm_mod, target_machine unless @optimization_mode.o0?

        emit_filename = emit_base_filename || output_filename
        unit.emit(@emit_targets | EmitTarget::OBJ, emit_filename, from_cache: false)
      end

      object_names = [output_filename]
      output_filename = output_filename.rchop(unit.object_extension)
      _, command, args = linker_command(program, object_names, output_filename, nil)
      print_command(command, args)
    end

    private def print_command(command, args)
      stdout.puts command.sub(%("${@}"), args && Process.quote(args))
    end

    private def linker_command(program : Program, object_names, output_filename, output_dir, expand = false, source_dir : String? = nil)
      if program.has_flag? "msvc"
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand

        object_arg = Process.quote_windows(object_names)
        output_arg = Process.quote_windows("/Fe#{output_filename}")

        linker, link_args = program.msvc_compiler_and_flags
        linker = Process.quote_windows(linker)
        link_args.map! { |arg| Process.quote_windows(arg) }

        link_args << "/DEBUG:FULL /PDBALTPATH:%_PDB%" unless debug.none?
        link_args << "/INCREMENTAL:NO /STACK:0x800000"
        link_args << lib_flags
        @link_flags.try { |flags| link_args << flags }

        {% if flag?(:msvc) %}
          unless @cross_compile
            extra_suffix = static? ? "-static" : "-dynamic"
            search_result = Loader.search_libraries(Process.parse_arguments_windows(link_args.join(' ').gsub('\n', ' ')), extra_suffix: extra_suffix)
            if not_found = search_result.not_found?
              raise CompilerError.new("Cannot locate the .lib files for the following libraries: #{not_found.join(", ")}", :FAILURE)
            end

            link_args = search_result.remaining_args.concat(search_result.library_paths).map { |arg| Process.quote_windows(arg) }
          end
        {% end %}

        args = %(/nologo #{object_arg} #{output_arg} /link #{link_args.join(' ')}).gsub("\n", " ")
        cmd = "#{linker} #{args}"

        if cmd.to_utf16.size > 32000
          # The command line would be too big, pass the args through a UTF-16-encoded file instead.
          # TODO: Use a proper way to write encoded text to a file when that's supported.
          # The first character is the BOM; it will be converted in the same endianness as the rest.
          args_16 = "\ufeff#{args}".to_utf16
          args_bytes = args_16.to_unsafe_bytes

          args_filename = "#{output_dir}/linker_args.txt"
          File.write(args_filename, args_bytes)
          cmd = "#{linker} #{Process.quote_windows("@" + args_filename)}"
        end

        {linker, cmd, nil}
      elsif program.has_flag? "wasm32"
        link_flags = @link_flags || ""
        link_flags += " --stack-first -z stack-size=8388608"

        link_flags += " --allow-undefined --allow-multiple-definition"

        # WASM exception handling support:
        # - __wasm_lpad_context is emitted directly by codegen (see initialize_wasm_exception_context)
        # - __cpp_exception tag is auto-imported by LLVM (no object file needed)
        # Note: asyncify_helper.wasm is merged AFTER the asyncify pass via
        # wasm-merge (see run_wasm_opt) to avoid name collisions.

        # A WASI reactor (`-Dwithout_main`) has no `_start`: the host calls
        # its `_initialize` once and then its exports.
        link_flags += " --no-entry" if program.has_flag?("without_main")

        # NOTE: wasm-ld does not support --sysroot. WASI SDK sysroot library
        # paths are added via -L flags in lib_flags_wasm (link.cr).

        # A cross-compilation prints the command for another machine, so it
        # names the linker plainly. A local link runs the checked linker,
        # and checks the Binaryen tools of the post-link step before it
        # starts, so a wrong tool stops the build before anything is written.
        if @cross_compile
          wasm_ld = "wasm-ld"
        else
          wasm_ld = Process.quote_posix(wasm32_tool("wasm-ld"))
          wasm32_tool("wasm-opt")
          wasm32_tool("wasm-merge") unless program.has_flag?("frontend_no_fibers")
        end
        {"wasm-ld", %(#{wasm_ld} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} -lc -lwasi-emulated-mman -lwasi-emulated-process-clocks #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag? "avr"
        link_flags = @link_flags || ""
        link_flags += " --target=avr-unknown-unknown -mmcu=#{@mcpu} -Wl,--gc-sections"
        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag?("win32") && program.has_flag?("gnu")
        link_flags = @link_flags || ""
        link_flags += " -Wl,--stack,0x800000"
        link_flags = use_modern_linker(link_flags)
        lib_flags = program.lib_flags(@cross_compile)
        lib_flags = expand_lib_flags(lib_flags) if expand
        cmd = %(#{DEFAULT_LINKER} #{Process.quote_windows(object_names)} -o #{Process.quote_windows(output_filename)} #{link_flags} #{lib_flags}).gsub('\n', ' ')

        if cmd.size > 32000
          # The command line would be too big, pass the args through a file instead.
          # GCC response file does not interpret those args as shell-escaped
          # arguments, we must rebuild the whole command line
          args_filename = "#{output_dir}/linker_args.txt"
          File.open(args_filename, "w") do |f|
            object_names.each do |object_name|
              f << object_name.gsub(GCC_RESPONSE_FILE_TR) << ' '
            end
            f << "-o " << output_filename.gsub(GCC_RESPONSE_FILE_TR) << ' '
            f << link_flags << ' ' << lib_flags
          end
          cmd = "#{DEFAULT_LINKER} #{Process.quote_windows("@" + args_filename)}"
        end

        {DEFAULT_LINKER, cmd, nil}
      elsif program.has_flag? "ios"
        link_flags = @link_flags || ""
        link_flags += " -shared -fPIC" if shared?
        sdk = program.codegen_target.ios_simulator? ? "iphonesimulator" : "iphoneos"
        target_triple = program.codegen_target.to_s
        link_flags += " -isysroot $(xcrun --sdk #{sdk} --show-sdk-path) -target #{target_triple}"

        linker = "xcrun --sdk #{sdk} clang"
        {linker, %(#{linker} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      elsif program.has_flag? "android"
        link_flags = @link_flags || ""
        link_flags += " -shared -fPIC" if shared?
        target_triple = program.codegen_target.to_s
        # Extract API level from environment (e.g. "linux-android31" -> "31")
        api_level = program.codegen_target.environment.scan(/android(\d+)/)[0]?.try(&.[1]) || "21"
        ndk_arch_triple = "#{program.codegen_target.architecture}-linux-android#{api_level}"
        link_flags += " --target=#{ndk_arch_triple}"

        # Find NDK clang from ANDROID_NDK_HOME
        ndk_home = ENV["ANDROID_NDK_HOME"]? || ENV["NDK_HOME"]? || ""
        if ndk_home.empty?
          linker = "clang"
        else
          # NDK prebuilt bin directory
          prebuilt_glob = File.join(ndk_home, "toolchains", "llvm", "prebuilt", "*", "bin", "clang")
          prebuilt_matches = Dir.glob(prebuilt_glob)
          linker = prebuilt_matches.first? || "clang"
        end

        {linker, %(#{Process.quote_posix(linker)} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      else
        link_flags = @link_flags || ""
        link_flags += shared? ? " -shared -fPIC" : " -rdynamic"

        if program.has_flag?("freebsd") || program.has_flag?("openbsd")
          # pkgs are installed to usr/local/lib but it's not in LIBRARY_PATH by
          # default; we declare it to ease linking on these platforms:
          link_flags += " -L/usr/local/lib"
        end

        # On macOS the system linker (ld-prime, Xcode 15 and later) links a
        # large program faster than ld64.lld: 0.7 s against 1.6 to 4 s for
        # Grant300's 7,759 objects (notes/rebuild-30s.md), so it stays.
        link_flags = use_modern_linker(link_flags) unless program.has_flag?("darwin")

        # The system linker warns once per object file built for a newer
        # macOS than it links for, and Clang's default for the link differs
        # from the version in our target triple (macOS 26.0 against 26.5 on
        # one host, 27.2 against 28.0 on another). Linking for the triple's
        # version keeps the two in step.
        if (macos_version = program.codegen_target.environment.lchop?("macosx")) && !macos_version.empty? && !link_flags.includes?("version-min")
          link_flags += " -mmacosx-version-min=#{macos_version}"
        end

        {DEFAULT_LINKER, %(#{DEFAULT_LINKER} "${@}" -o #{Process.quote_posix(output_filename)} #{link_flags} #{program.lib_flags(@cross_compile)}), object_names}
      end
    end

    # The prefix of the symbols a build emitted in parts promotes from private
    # definitions and internal variables (see `LLVM::Module#split_to_bitcode`),
    # which a single-object build does not list in its symbol table.
    PRIVATE_SYMBOL_PREFIX = "__crystal_private."

    # On Mach-O the promoted private symbols carry the linker-private `l`
    # prefix, which Apple's linker leaves out of the output's symbol table and
    # debug map. LLVM's ld64.lld (chosen when `ld.lld` is installed) lists
    # them, so the linker also gets them as a strip list, which both linkers
    # apply to the symbol table and the debug map.
    private def private_symbols_strip_flag(output_dir) : String
      strip_list = File.join(output_dir, "private_symbols_strip_list.txt")
      File.write(strip_list, "l#{PRIVATE_SYMBOL_PREFIX}*\n")
      " -Wl,-non_global_symbols_strip_list,#{Process.quote_posix(File.expand_path(strip_list))}"
    end

    # Removes the promoted private symbols from an ELF output's symbol table,
    # so a build emitted in parts lists the same symbols as a single-object
    # build. ELF linkers have no option for this, so `objcopy` (GNU binutils or
    # LLVM) does it after linking. Without `objcopy` the symbols stay; the
    # program is the same either way.
    private def remove_private_symbols(output_filename)
      objcopy = Process.find_executable("objcopy") || Process.find_executable("llvm-objcopy")
      return unless objcopy

      status = Process.run(objcopy, ["--wildcard", "--strip-symbol=#{PRIVATE_SYMBOL_PREFIX}*", output_filename],
        output: Process::Redirect::Close, error: Process::Redirect::Inherit)
      unless status.success?
        stderr.puts "Warning: #{objcopy} could not remove the #{PRIVATE_SYMBOL_PREFIX}* symbols from #{output_filename}"
      end
    end

    # Tests if `mold` or `lld` are available and prefers them as linkers over
    # the default `ld`. Only works when `cc` is the linker driver and can be
    # disabled with `--link-flags=-fuse-ld=bfd`.
    private def use_modern_linker(link_flags)
      return link_flags unless DEFAULT_LINKER == "cc"
      return link_flags if link_flags.includes?("-fuse-ld=")

      if Process.find_executable("mold")
        link_flags + " -fuse-ld=mold"
      elsif Process.find_executable("ld.lld")
        link_flags + " -fuse-ld=lld"
      else
        link_flags
      end
    end

    private GCC_RESPONSE_FILE_TR = {
      " ":  %q(\ ),
      "'":  %q(\'),
      "\"": %q(\"),
      "\\": "\\\\",
    }

    private def expand_lib_flags(lib_flags)
      lib_flags.gsub(/`(.*?)`/) do
        command = $1
        begin
          error_io = IO::Memory.new
          output = Process.run(command, shell: true, output: :pipe, error: error_io) do |process|
            process.output.gets_to_end
          end
          unless $?.success?
            error_io.rewind
            raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{error_io}", :FAILURE)
          end
          output.chomp
        rescue exc
          raise CompilerError.new("Error executing subcommand for linker flags: #{command.inspect}: #{exc}", :FAILURE)
        end
      end
    end

    private def codegen(program, units : Array(CompilationUnit), output_filename, output_dir, build_lock : File)
      object_names = units.flat_map &.object_filenames

      @progress_tracker.stage(ObjectStage::STAGE_NAME) do
        stage_started_at = Time.utc
        @progress_tracker.stage_progress_total = units.size

        n_threads = @n_threads.clamp(1..units.size)

        if n_threads == 1
          sequential_codegen(units)
        elsif (worker_executable = @codegen_worker_executable) && units.size > 1
          units_started_at = Time.instant
          list_of_jobs = write_bitcode_and_release_modules(units)
          @last_unit_write_seconds = (Time.instant - units_started_at).total_seconds
          # Every unit has its bitcode hash now, and this process may end
          # with the handoff below.
          manifest_started_at = Time.instant
          finish_ir_skip_session(output_dir, units)
          @last_manifest_seconds = (Time.instant - manifest_started_at).total_seconds
          unless list_of_jobs.empty?
            if object_stage_handoff?
              hand_off_object_stage(program, units, list_of_jobs, n_threads, worker_executable,
                output_filename, output_dir, object_names, stage_started_at, build_lock)
            end

            # IR generation leaves garbage behind in the heap. Hand it back
            # before the workers start, so their memory does not stack on top
            # of it. The same goes for the memory the disposed LLVM contexts
            # freed.
            return_free_memory_to_os
            return_free_malloc_memory_to_os
            build_objects_in_workers(list_of_jobs, n_threads, worker_executable)
          end
        else
          parallel_codegen(units, n_threads)
        end
        finish_ir_skip_session(output_dir, units)
        verify_line_patches(@list_of_line_patch_checks)

        if units.size == 1
          units.first.emit(@emit_targets, emit_base_filename || output_filename)
        end
      end

      # We check again because maybe this directory was created in between (maybe with a macro run)
      if Dir.exists?(output_filename)
        raise CompilerError.new("can't use `#{output_filename}` as output filename because it's a directory", :USAGE_ERROR)
      end

      output_filename = File.expand_path(output_filename)

      # Incremental optimization: skip linking when all .o files were reused
      # from cache and the output binary already exists. The linker inputs are
      # identical, so the output would be byte-for-byte the same.
      # An object with patched lines is reused, but not as the link saw it.
      all_reused = @incremental && !@no_cache && units.all? { |unit| unit.reused_previous_compilation? && !unit.patched_lines? }
      @link_skipped = all_reused && File.exists?(output_filename)

      if @link_skipped
        @progress_tracker.stage("Codegen (linking)") { }
      else
        @progress_tracker.stage("Codegen (linking)") do
          linker_name, command, args = linker_invocation(program, units, object_names, output_filename, output_dir)
          Dir.cd(output_dir) { run_linker linker_name, command, args }
          split_into_parts = units.any? { |unit| unit.part_count > 1 }
          remove_private_symbols(output_filename) if split_into_parts && program.codegen_target.linux?
        end
      end

      if program.has_flag?("wasm32")
        @progress_tracker.stage("Codegen (wasm-opt)") do
          # C-4 fix: the frontend-only build (-Dfrontend_no_fibers) removes the
          # asyncify layer, so skip the --asyncify pass and the asyncify_helper
          # merge. This is a runtime check of the *target* program's flags, not
          # a macro flag on the compiler binary itself.
          run_wasm_opt(output_filename, @optimization_mode,
            skip_fibers: program.has_flag?("frontend_no_fibers"),
            needs_pointer_spills: !program.has_flag?("gc_none"))
        end
      end

      units
    end

    private def sequential_codegen(units)
      # A single unit is emitted after this loop (`--emit`), so its module
      # must stay alive. With several units, nothing reads a unit's module
      # once its object file is written: free each one right away instead of
      # holding every optimized module until the GC finalizes them.
      dispose_after_compile = units.size > 1
      units.each do |unit|
        unit.compile
        unit.dispose_module if dispose_after_compile
        @progress_tracker.stage_progress += 1
      end
    end

    # Releases what only semantic analysis needed (untyped def and macro
    # bodies) and hands the freed heap pages back to the OS, so the memory
    # LLVM allocates during codegen does not stack on top of it.
    #
    # Incremental mode's signature pass, which runs after codegen, reads the
    # list of required files and parses them again; it reads no def body.
    private def release_semantic_only_data(program, node : ASTNode)
      @progress_tracker.stage("Semantic (release)") do
        next if shares_typed_program_with_build_server?
        program.release_semantic_only_data(node)
        # The code generation child of the build server (`InferReuse`)
        # shares its heap pages with the server, which keeps the typed
        # program: unmapping free blocks there returns nothing to the
        # system, and the three full collections took about 3 s on Grant300.
        return_free_memory_to_os unless @infer_reuse_handoff
      end
    end

    private def return_free_memory_to_os : Nil
      {% if flag?(:gc_none) || flag?(:wasm32) %}
        # no collector, nothing to return
      {% else %}
        LibGC.set_force_unmap_on_gcollect(1)
        # The first collection frees the released bodies; the next ones
        # coalesce the free blocks so they can be unmapped.
        3.times { GC.collect }
        LibGC.set_force_unmap_on_gcollect(0)
      {% end %}
    end

    # Asks the C allocator to hand its free pages back to the OS. LLVM
    # allocates with `malloc`, and the allocator otherwise keeps most of what
    # a disposed context frees for later allocations.
    private def return_free_malloc_memory_to_os : Nil
      CAllocator.return_free_memory
    end

    # The linker to run from *output_dir* to link *object_names* into
    # *output_filename* (an absolute path): its name, the shell command, and
    # the command's arguments.
    private def linker_invocation(program, units, object_names, output_filename, output_dir) : {String, String, Array(String)?}
      # Save source directory before changing to output_dir so CRYSTAL_PATH
      # relative entries (e.g. "src:lib") resolve correctly in linker_command
      src_dir = Dir.current
      split_into_parts = units.any? { |unit| unit.part_count > 1 }
      Dir.cd(output_dir) do
        linker_name, command, args = linker_command(program, object_names, output_filename, output_dir, expand: true, source_dir: src_dir)
        command += private_symbols_strip_flag(output_dir) if split_into_parts && program.codegen_target.macos?
        {linker_name, command, args}
      end
    end

    # Links the object files with a linker command that was put together
    # earlier (see `#linker_invocation`), as the last step of a build that
    # was handed to `ObjectStage`.
    protected def link_object_files(linker_name : String, command : String, args : Array(String)?,
                                    output_filename : String, output_dir : String) : Nil
      if Dir.exists?(output_filename)
        raise CompilerError.new("can't use `#{output_filename}` as output filename because it's a directory", :USAGE_ERROR)
      end

      @progress_tracker.stage("Codegen (linking)") do
        Dir.cd(output_dir) { run_linker linker_name, command, args }
      end
    end

    # Prepares the units for the object-file workers (see `CodegenWorker`):
    # every unit writes its module to its bitcode file and frees it, so the
    # generated IR leaves this process before any worker starts. Returns the
    # jobs of the units whose object file must be built.
    private def write_bitcode_and_release_modules(units) : Array(CodegenWorker::Job)
      list_of_jobs = [] of CodegenWorker::Job
      units.each do |unit|
        if unit.write_bitcode_and_release_module
          list_of_jobs << unit.codegen_worker_job
        else
          @progress_tracker.stage_progress += 1
        end
      end
      list_of_jobs
    end

    # Builds the object files of *list_of_jobs* in up to *thread_count*
    # worker processes, each compiling one bitcode file at a time, within the
    # workers' memory budget (see `CodegenWorkerPool`).
    protected def build_objects_in_workers(list_of_jobs : Array(CodegenWorker::Job), thread_count : Int32,
                                           worker_executable : String) : Nil
      pool = CodegenWorkerPool.new(worker_executable, CodegenWorker::Settings.from_compiler(self),
        list_of_jobs, thread_count, codegen_worker_memory_budget_bytes_for(thread_count))
      @last_codegen_worker_pool = pool
      pool.perform { @progress_tracker.stage_progress += 1 }
    end

    private def codegen_worker_memory_budget_bytes_for(thread_count : Int32) : Int64
      @codegen_worker_memory_budget_bytes || CodegenWorkerPool.default_memory_budget_bytes(thread_count)
    end

    # Ends this process's part of the build: writes the `ObjectStage::Handoff`
    # and replaces this process image with the compiler's object stage, which
    # builds the object files, links and reports. All the memory of this
    # process returns to the system at that moment, before any worker starts.
    #
    # Returns only when the process image could not be replaced; the build
    # then goes on in this process.
    private def hand_off_object_stage(program, units, list_of_jobs, thread_count, worker_executable,
                                      output_filename, output_dir, object_names, stage_started_at,
                                      build_lock : File) : Nil
      {% unless flag?(:win32) || flag?(:wasm32) %}
        output_filename = File.expand_path(output_filename)
        linker_name, command, args = linker_invocation(program, units, object_names, output_filename, output_dir)
        writes_dwarf_companion = {{ flag?(:darwin) }} && !debug.none? && dsymutil?
        pending_incremental_cache_filename = nil
        incremental_stats_report = ""
        if @incremental
          # This process ends with the handoff, so the incremental cache is
          # written now, under a pending name. The object stage gives it its
          # real name once the executable is linked: a build that fails
          # after this point leaves the previous cache in charge.
          signatures_started_at = Time.instant
          extract_and_compare_signatures(program)
          pending_incremental_cache_filename = File.join(output_dir, IncrementalCache::PENDING_CACHE_FILENAME)
          save_incremental_cache(program, output_dir, IncrementalCache::PENDING_CACHE_FILENAME)
          @last_signature_and_cache_seconds = (Time.instant - signatures_started_at).total_seconds
          incremental_stats_report = String.build do |io|
            print_handoff_preparation_stats(io)
            print_parse_cache_stats(io)
            print_signature_stats(io)
          end
        end

        handoff = ObjectStage::Handoff.new(
          worker_executable: worker_executable,
          settings: CodegenWorker::Settings.from_compiler(self),
          list_of_jobs: list_of_jobs,
          thread_count: thread_count,
          memory_budget_bytes: codegen_worker_memory_budget_bytes_for(thread_count),
          linker_name: linker_name,
          linker_command: command,
          list_of_linker_arguments: args,
          output_directory: output_dir,
          output_filename: output_filename,
          writes_dwarf_companion: writes_dwarf_companion,
          cleans_cache_directory: cleanup?,
          lock_file_descriptor: build_lock.fd,
          verbose: verbose?,
          color: color?,
          stats: @progress_tracker.stats?,
          progress: @progress_tracker.progress?,
          stage_number: @progress_tracker.current_stage,
          stage_started_at_unix_ms: stage_started_at.to_unix_ms,
          stage_progress: @progress_tracker.stage_progress,
          stage_progress_total: units.size,
          list_of_unit_summaries: units.map(&.summary),
          stats_report_before_codegen: String.build { |io| print_macro_run_stats(program, io) },
          stats_report_after_codegen: incremental_stats_report,
          pending_incremental_cache_filename: pending_incremental_cache_filename,
          list_of_warnings: warnings.infos,
          error_on_warnings: warnings.error_on_warnings?,
          list_of_line_patch_checks: @list_of_line_patch_checks,
          writes_dwarf_companion_in_background: writes_dwarf_companion && dwarf_companion_in_background?,
        )
        handoff_filename = File.join(output_dir, "object-stage-handoff.json")
        File.write(handoff_filename, handoff.to_json)

        # The new image does not come back here: the type-inference snapshot,
        # whose program typed without errors, goes in place now.
        if session = @infer_persist_session
          @infer_persist_session = nil
          session.finish(true)
        end

        # The new image inherits the locked file, so the build stays locked.
        build_lock.close_on_exec = false
        STDOUT.flush
        STDERR.flush
        begin
          Process.exec(worker_executable, [ObjectStage::COMMAND, handoff_filename])
        rescue IO::Error
          build_lock.close_on_exec = true
          File.delete?(handoff_filename)
          pending_incremental_cache_filename.try { |filename| File.delete?(filename) }
        end
      {% end %}
    end

    private def parallel_codegen(units, n_threads)
      {% if !flag?(:without_mt) %}
        raise "LLVM isn't multithreaded and cannot fork compiler in multithread mode." unless LLVM.multithreaded?
        mt_codegen(units, n_threads)
      {% else %}
        sequential_codegen(units)
      {% end %}
    end

    private def mt_codegen(units, n_threads)
      channel = Channel(CompilationUnit).new(n_threads * 2)
      wg = WaitGroup.new
      mutex = Sync::Mutex.new

      n_threads.times do
        wg.spawn do
          while unit = channel.receive?
            unit.compile(isolate_context: true)
            mutex.synchronize { @progress_tracker.stage_progress += 1 }
          end
        end
      end

      units.each do |unit|
        # We generate the bitcode in the main thread because LLVM contexts
        # must be unique per compilation unit, but we share different contexts
        # across many modules (or rely on the global context); trying to
        # codegen in parallel would segfault!
        #
        # Luckily generating the bitcode is quick and once the bitcode is
        # generated we don't need the global LLVM contexts anymore but can
        # parse the bitcode in an isolated context and we can parallelize the
        # slowest part: the optimization pass & compiling the object file.
        unit.generate_bitcode

        channel.send(unit)
      end
      channel.close

      wg.wait
    end

    private def print_macro_run_stats(program, io : IO = STDOUT)
      return unless @progress_tracker.stats?
      return if program.compiled_macros_cache.empty?

      io.puts
      io.puts "Macro runs:"
      program.compiled_macros_cache.each do |filename, compiled_macro_run|
        io << " - " << filename << ": "
        if compiled_macro_run.reused
          io << "reused previous compilation (#{compiled_macro_run.elapsed})"
        else
          io << compiled_macro_run.elapsed
        end
        io.puts
      end
    end

    # Whether an incremental build skips IR generation for the modules
    # whose inputs did not change (see `IrSkip`). `CRYSTAL_IR_SKIP=0` turns
    # it off.
    property? ir_skip : Bool = ENV["CRYSTAL_IR_SKIP"]? != "0"

    # Whether such a build generates every module anyway and fails when a
    # module whose key matched the build before produced other bitcode.
    # `CRYSTAL_IR_SKIP_VERIFY=1` turns it on.
    property? ir_skip_verify : Bool = ENV["CRYSTAL_IR_SKIP_VERIFY"]? == "1"

    # What the last compilation skipped and generated, if it kept keys.
    getter last_ir_skip_stats : IrSkip::Stats?

    @ir_skip_session_to_finish : IrSkip::Session?

    # The session of the incremental build whose units are being written,
    # for the main module (see `LinePatch::MainModule`).
    def main_module_line_patch_session : IrSkip::Session?
      @ir_skip_session_to_finish
    end

    # Adds a patched object to compare with the fresh one once objects are
    # built (`CRYSTAL_LINE_PATCH_VERIFY=1`).
    def add_line_patch_check(check : LinePatch::Verification::Check) : Nil
      @list_of_line_patch_checks << check
    end

    # Tells `--stats` what happened to the main module's changed bitcode.
    # What happened to the object of each part of the top-level code in the
    # last build (see `CodeGenVisitor::MainParts`), by unit name: patched or
    # compiled, and why. A part whose bitcode matched is not listed.
    getter main_part_outcomes = {} of String => String
    @main_part_outcomes_lock = Sync::Mutex.new

    def print_main_module_outcome(unit_name : String, outcome : String, seconds : Float64) : Nil
      unless unit_name == "_main"
        @main_part_outcomes_lock.synchronize { @main_part_outcomes[unit_name] = outcome }
      end
      return unless @progress_tracker.stats?

      if unit_name == "_main"
        puts "Main module: #{outcome} (#{seconds.round(2)} s)"
      else
        puts "Main part #{unit_name}: #{outcome} (#{seconds.round(2)} s)"
      end
    end

    @list_of_ir_skip_module_infos : Array(CodeGenVisitor::ModuleInfo)?

    # The patched objects to compare with fresh ones once objects are built
    # (`CRYSTAL_LINE_PATCH_VERIFY=1`).
    @list_of_line_patch_checks = [] of LinePatch::Verification::Check

    # How many patched objects the last build verified, and the differences
    # it found.
    getter last_line_patch_verification : {Int32, Array(String)}?

    # Compares the patched objects of a verification build with the fresh
    # ones, and fails the build when they differ (see `LinePatch::Verification`).
    def verify_line_patches(list_of_checks : Array(LinePatch::Verification::Check)) : Nil
      return if list_of_checks.empty?
      list_of_failures = LinePatch::Verification.run(list_of_checks)
      @last_line_patch_verification = {list_of_checks.size, list_of_failures}
      puts "Line patch verification: #{list_of_checks.size - list_of_failures.size} of #{list_of_checks.size} patched objects match the fresh ones" if @progress_tracker.stats?
      if report_filename = ENV["CRYSTAL_LINE_PATCH_REPORT"]?.presence
        File.write(report_filename, {checked: list_of_checks.size, failures: list_of_failures}.to_pretty_json)
      end
      unless list_of_failures.empty?
        raise CompilerError.new("Line patch verification failed:\n" + list_of_failures.first(50).join("\n"))
      end
    end

    # The session of an incremental build that may skip IR generation for
    # the modules whose inputs did not change (see `IrSkip`), or `nil` for
    # a build that generates everything and keeps no keys.
    # See `#ir_skip?` and `#ir_skip_verify?`.
    private def ir_skip_session_for(program, output_dir, is_single_module, stable_numbering, sources) : IrSkip::Session?
      return nil unless stable_numbering && !is_single_module
      return nil unless ir_skip?
      # Without a hash of the bitcode there is nothing to carry over.
      return nil unless BitcodeHash.of_part(Bytes.empty)

      # Verifying patched objects generates every module, as IR skip
      # verification does.
      mode = ir_skip_verify? || LinePatch::Verification.enabled? ? IrSkip::Session::Mode::Verify : IrSkip::Session::Mode::Skip
      salt = ir_skip_salt(program)
      previous = IrSkip::Manifest.load?(output_dir, salt)
      session = IrSkip::Session.new(mode, salt, previous)
      if previous.nil?
        session.no_candidates_cause = "no manifest of the build before, or one made with other settings"
      elsif !(File.file?(bc_flags_filename(output_dir)) && File.read(bc_flags_filename(output_dir)).strip == current_bc_flags)
        session.no_candidates_cause = "the flags object files are built with changed"
      else
        mark_units_whose_object_is_current(previous, output_dir)
      end
      prepare_line_patch(session, program, sources, output_dir)
      session
    end

    # Whether an incremental build keeps the objects of modules whose lines
    # only moved, with patched debug info (see `LinePatch`).
    # `CRYSTAL_LINE_PATCH=0` turns it off.
    property? line_patch : Bool = ENV["CRYSTAL_LINE_PATCH"]? != "0"

    # Reads the lines of every source file, for the next build, and when the
    # build before recorded its own, maps how they moved.
    private def prepare_line_patch(session : IrSkip::Session, program : Program, sources, output_dir : String) : Nil
      started_at = Time.instant
      list_of_filenames = program.requires.to_a
      sources.each { |source| list_of_filenames << source.filename }
      current = LinePatch.read_source_lines(list_of_filenames.uniq!)
      session.source_lines_by_filename = current

      previous = session.previous
      if line_patch? && previous && session.no_candidates_cause.nil?
        maps = LinePatch::Maps.compute(previous.source_lines_by_filename, current)
        session.line_maps = maps
        object_extension = codegen_target.object_extension
        optimization_mode = self.optimization_mode
        session.line_patcher = LinePatch::UnitPatcher.new(maps, ->(unit_name : String) do
          "#{output_dir}/#{CompilationUnit.file_basename(unit_name, optimization_mode)}#{object_extension}"
        end)
        stats = session.stats
        stats.line_patch = true
        stats.source_files_changed = maps.maps_by_filename.size
        stats.source_files_without_map = maps.maps_by_filename.count { |_, map| map.nil? }
      end
      session.stats.line_map_seconds = (Time.instant - started_at).total_seconds
    end

    # Everything outside the program's source that the code of a function
    # depends on. A manifest made with another salt is not used.
    private def ir_skip_salt(program) : String
      String.build do |io|
        io << Crystal::Config.version << '|' << Crystal::Config.build_commit << '|' << LibLLVM::VERSION
        io << "|compiler=" << IrSkip.compiler_identity
        io << '|' << @codegen_target << '|' << @mcpu << '|' << @mattr << '|' << @mcmodel
        io << '|' << debug.value << '|' << frame_pointers << '|' << optimization_mode
        io << '|' << program.flags.to_a.sort!.join(',')
        io << "|segment=" << @module_segment_instructions
        io << "|prelude=" << prelude
        io << "|shapes=" << program.share_owner_shapes?
        io << "|block_instances=" << ENV["CRYSTAL_SHARE_BLOCK_INSTANCES"]?
        # Every string constant carries the type id of String.
        io << "|string_id=" << program.llvm_id.type_id(program.string)
      end
    end

    # Marks the modules of *previous* whose object file in the cache was
    # built from the bitcode the manifest recorded: only those can go
    # without new bitcode.
    private def mark_units_whose_object_is_current(previous : IrSkip::Manifest, output_dir : String) : Nil
      object_extension = codegen_target.object_extension
      previous.units_by_name.each_value do |recorded_unit|
        basename = CompilationUnit.file_basename(recorded_unit.name, optimization_mode)
        record = CachedObjectRecord.read?("#{output_dir}/#{basename}#{CachedObjectRecord::FILE_EXTENSION}")
        module_hash = BitcodeHash.of_module(recorded_unit.list_of_part_hashes)
        next unless record && module_hash && record.module_hash == module_hash
        next unless record.describes_objects?([Crystal.relative_filename("#{output_dir}/#{basename}#{object_extension}")])

        recorded_unit.object_is_current = true
      end
    end

    # Counts what IR generation skipped and what it generated after all.
    private def summarize_ir_skip(session : IrSkip::Session, llvm_modules) : Nil
      stats = session.stats
      llvm_modules.each do |type_name, info|
        # The main module and the type tables are generated in every build.
        next if type_name.empty? || type_name == CodeGenVisitor::TypeTables::MODULE_NAME

        if info.skipped_ir_generation?
          stats.skipped_units += 1
          next
        end
        stats.generated_units += 1
        next unless (plan = info.ir_skip_plan) && (reason = plan.reason)

        stats.regenerated_units_by_reason[reason.to_s] = (stats.regenerated_units_by_reason[reason.to_s]? || 0) + 1
        if reason.source_position? && plan.source_position_only? && plan.position == plan.recorded.list_of_funs.size
          stats.units_regenerated_for_source_position_alone += 1
        end
        stats.list_of_regenerated_units << "#{type_name}: #{reason} (#{plan.reason_detail})"
      end
    end

    private def print_ir_skip_stats(session : IrSkip::Session) : Nil
      return unless @progress_tracker.stats?

      stats = session.stats
      puts
      puts "IR generation skipped for unchanged modules (#{stats.mode}):"
      if cause = session.no_candidates_cause
        puts " - no module could be skipped: #{cause}"
      end
      puts " - modules without new IR: #{stats.skipped_units}; modules generated: #{stats.generated_units} (#{stats.candidate_units} started as candidates)"
      puts " - functions matched and replayed: #{stats.replayed_functions}; generated: #{stats.generated_functions} (#{stats.late_generated_functions} of them after they had matched)"
      puts " - functions without a key: #{stats.unkeyable_functions}; with a trace that cannot be replayed: #{stats.unreplayable_functions}"
      puts " - computing keys: #{stats.key_seconds.round(1)} s; replaying traces, with the code generation they set off: #{stats.replay_seconds.round(1)} s"
      stats.regenerated_units_by_reason.each do |reason, count|
        puts " - candidate modules generated after all, #{reason}: #{count}"
      end
      puts " - of those, modules in which only source positions changed: #{stats.units_regenerated_for_source_position_alone}"
      stats.units_not_candidate_by_cause.each do |cause, count|
        puts " - modules that were no candidates, #{cause}: #{count}"
      end
      return unless stats.line_patch?

      puts " - line patching: #{stats.source_files_changed} source files changed (#{stats.source_files_without_map} without a line map), mapped in #{stats.line_map_seconds.round(2)} s"
      puts " - functions that matched with moved lines: #{stats.shifted_functions}"
      stats.unshifted_functions_by_cause.each do |cause, count|
        puts " - functions whose lines did not just move, #{cause}: #{count}"
      end
      puts " - modules whose lines moved: #{stats.units_with_moved_lines}; patched: #{stats.units_patched} in #{stats.patch_seconds.round(2)} s"
      stats.patch_refusals_by_cause.each do |cause, count|
        puts " - patches refused, #{cause}: #{count}"
      end
    end

    # Leaves the manifest for the next build, once every unit knows the
    # hash of its bitcode. In verification it first compares each module
    # that matched the build before with the bitcode that build recorded.
    private def finish_ir_skip_session(output_dir : String, units : Array(CompilationUnit)) : Nil
      session = @ir_skip_session_to_finish
      list_of_module_infos = @list_of_ir_skip_module_infos
      return unless session && list_of_module_infos
      @ir_skip_session_to_finish = nil
      @list_of_ir_skip_module_infos = nil
      return unless list_of_module_infos.size == units.size

      stats = session.stats
      manifest = IrSkip::Manifest.new(session.salt)
      manifest.source_lines_by_filename = session.source_lines_by_filename
      list_of_module_infos.each_with_index do |info, index|
        next if info.name.empty?

        plan = info.ir_skip_plan
        if plan && info.skipped_ir_generation?
          recorded = plan.recorded
          if (patched_object = plan.line_patch) && !patched_object.unchanged?
            # The object was patched: its functions are at their new lines.
            recorded = IrSkip::RecordedUnit.new(recorded.name, plan.list_of_funs_with_new_lines,
              patched_object.list_of_part_hashes, recorded.list_of_part_fun_counts, recorded.instruction_count,
              recorded.late_generated?)
          elsif plan.shifted?
            recorded = IrSkip::RecordedUnit.new(recorded.name, plan.list_of_funs_with_new_lines,
              recorded.list_of_part_hashes, recorded.list_of_part_fun_counts, recorded.instruction_count,
              recorded.late_generated?)
          end
          manifest.units_by_name[info.name] = recorded
          next
        end
        next unless list_of_part_hashes = units[index].list_of_part_hashes

        # A module whose lines moved has other bitcode by design; its patched
        # object is verified against the fresh one instead.
        if plan && session.verify? && !plan.invalidated? && !plan.shifted? && plan.position == plan.recorded.list_of_funs.size
          if plan.recorded.late_generated? || plan.recorded.list_of_part_fun_counts != info.list_of_part_fun_counts
            stats.units_not_verifiable += 1
          elsif plan.recorded.list_of_part_hashes != list_of_part_hashes
            stats.list_of_verification_failures << "#{info.name}: every key matched, but the bitcode differs from the recorded one"
          else
            stats.verified_units += 1
          end
        end
        manifest.units_by_name[info.name] = IrSkip::RecordedUnit.new(info.name, info.list_of_recorded_funs,
          list_of_part_hashes, info.list_of_part_fun_counts, info.generated_instruction_count, info.late_generated?)
      end
      manifest.save(output_dir)

      if report_filename = ENV["CRYSTAL_IR_SKIP_REPORT"]?.presence
        File.write(report_filename, stats.to_pretty_json)
      end
      if session.verify?
        puts "IR skip verification: #{stats.verified_units} modules verified, #{stats.units_not_verifiable} not verifiable, #{stats.list_of_verification_failures.size} failures" if @progress_tracker.stats?
        unless stats.list_of_verification_failures.empty?
          raise CompilerError.new("IR skip verification failed:\n" + stats.list_of_verification_failures.first(50).join("\n"))
        end
      end
    end

    private def print_module_spill_stats
      return unless @progress_tracker.stats?

      if @last_segmented_type_count > 0
        puts
        puts "LLVM module segments (limit #{@module_segment_instructions} instructions):"
        puts " - types compiled as several object files: #{@last_segmented_type_count} (#{@last_segment_count} segments, at most #{@last_maximum_segment_count} for one type)"
        STDOUT.flush
      end

      return unless module_spill = @last_module_spill

      megabyte = 1024 * 1024
      puts
      puts "LLVM module spilling:"
      puts " - limits: #{module_spill.resident_ir_bytes // megabyte} MB of estimated IR, #{module_spill.resident_limit} idle modules (0 is no limit)"
      puts " - most in memory at once: #{module_spill.peak_resident_count} modules, #{module_spill.peak_resident_ir_bytes // megabyte} MB of estimated IR"
      puts " - instructions built: #{module_spill.built_instruction_count}"
      spill_seconds = (module_spill.bitcode_time + module_spill.hash_time + module_spill.write_time).total_seconds
      puts " - module parts written to disk: #{module_spill.spill_count} (#{module_spill.written_bitcode_bytes // megabyte} MB, #{spill_seconds.round(1)} s)"
      puts " - of that time: #{module_spill.bitcode_time.total_seconds.round(1)} s making bitcode, " \
           "#{module_spill.hash_time.total_seconds.round(1)} s hashing it, #{module_spill.write_time.total_seconds.round(1)} s putting it in files"
      puts " - modules made of several parts: #{module_spill.multi_part_module_count}"
      puts " - function signatures recorded: #{module_spill.recorded_signature_count}"
      puts " - functions generated after the chain of calls that asked for them: #{module_spill.deferred_fun_count}"
      STDOUT.flush
    end

    protected def print_codegen_stats(units : Array(ObjectStage::UnitSummary))
      return unless @progress_tracker.stats?

      reused = units.count(&.reused_previous_compilation?)

      puts
      puts "Codegen (bc+obj):"
      case reused
      when units.size
        puts " - all previous .o files were reused"
        print_reuse_decision_stats(units)
      when .zero?
        puts " - no previous .o files were reused"
      else
        puts " - #{reused}/#{units.size} .o files were reused"
        print_reuse_decision_stats(units)
        puts
        puts "These modules were not reused:"
        units.each do |unit|
          next if unit.reused_previous_compilation?
          puts " - #{unit.original_name} (#{unit.bitcode_name})"
        end
      end

      if pool = @last_codegen_worker_pool
        megabyte = 1024 * 1024
        puts " - object files were built by #{pool.worker_count} worker processes"
        puts " - modules in flight at most: #{(pool.maximum_in_flight_bitcode_bytes / megabyte).round(1)} MB of bitcode, " \
             "estimated #{pool.maximum_in_flight_memory_bytes // megabyte} MB of worker memory " \
             "(budget #{pool.memory_budget_bytes // megabyte} MB)"
        if longest_job = pool.list_of_longest_jobs.first?
          puts " - processor time of all object file jobs: #{pool.total_cpu_seconds.round(1)} s"
          puts " - longest object file job: #{longest_job.seconds.round(1)} s (#{longest_job.cpu_seconds.round(1)} s of processor time), " \
               "#{longest_job.name} (#{(longest_job.bitcode_bytesize / megabyte).round(1)} MB of bitcode)"
        end
        pool.list_of_longest_jobs.skip(1).each do |job_report|
          puts "   then: #{job_report.seconds.round(1)} s (#{job_report.cpu_seconds.round(1)} s of processor time), " \
               "#{job_report.name} (#{(job_report.bitcode_bytesize / megabyte).round(1)} MB of bitcode)"
        end
        if pool.largest_worker_peak_memory_bytes > 0
          puts " - largest peak memory of one worker process: #{pool.largest_worker_peak_memory_bytes // megabyte} MB"
        end
      end

      if @link_skipped
        puts " - Linking skipped (all .o files reused, binary unchanged)"
      end
    end

    private def print_reuse_decision_stats(units : Array(ObjectStage::UnitSummary)) : Nil
      decided_by_hash = units.count(&.decided_by_bitcode_hash?)
      puts " - object reuse was decided by bitcode hash for #{decided_by_hash} modules, by comparing bitcode files for #{units.size - decided_by_hash}"
    end

    private def print_parse_cache_stats(io : IO = STDOUT)
      return unless @progress_tracker.stats?
      return unless @incremental

      cache = @parse_cache
      total = cache.total_lookups
      return if total == 0

      io.puts
      io.puts "Parse cache:"
      io.puts " - hits: #{cache.hits}, misses: #{cache.misses} (#{sprintf("%.1f", cache.hit_rate)}% hit rate)"
    end

    @last_signature_and_cache_seconds : Float64?
    @last_unit_write_seconds : Float64?
    @last_manifest_seconds : Float64?

    # How long the compiler spent between IR generation and the handoff:
    # writing the bitcode of changed units and checking the cached objects
    # of the others, and saving the IR skip manifest.
    private def print_handoff_preparation_stats(io : IO) : Nil
      return unless @progress_tracker.stats?
      unit_seconds = @last_unit_write_seconds
      manifest_seconds = @last_manifest_seconds
      return unless unit_seconds && manifest_seconds

      io.puts
      io.puts "Before the object stage handoff:"
      io.puts " - units written or matched with their cached objects: #{unit_seconds.round(2)} s"
      io.puts " - IR skip manifest saved: #{manifest_seconds.round(2)} s"
    end

    private def print_signature_stats(io : IO = STDOUT)
      return unless @progress_tracker.stats?
      return unless @incremental

      body_only = @last_body_only_count
      structural = @last_structural_count
      isolated = @last_isolated_body_only_count
      return if body_only == 0 && structural == 0

      io.puts
      io.puts "Signature tracking:"
      if seconds = @last_signature_and_cache_seconds
        io.puts " - signature pass and incremental cache, before the handoff: #{seconds.round(2)} s"
      end
      io.puts " - Files with body-only changes: #{body_only}"
      io.puts " - Files with structural changes: #{structural}"
      if isolated > 0
        io.puts " - Body-only changes with no dependents (safe to skip): #{isolated}"
      end
    end

    @sources_checked_at_unix_ms : Int64?

    # Why the program can have changed though no file of the previous
    # compilation did, or `nil`: a glob require finds other files, or a file
    # that a program its macros ran (`run`) can read changed since that
    # compilation began (see `InferReuse::ProgramRunInputs`).
    private def reason_unfingerprinted_inputs_changed(program : Program, cached_data : IncrementalCacheData, output_filename : String) : String?
      cached_data.glob_requires.try &.each do |glob_require|
        list_of_found_filenames = begin
          program.find_in_path(glob_require.filename, glob_require.relative_to)
        rescue CrystalPath::NotFoundError
          nil
        end
        unless list_of_found_filenames == glob_require.list_of_found_filenames
          return "require \"#{glob_require.filename}\" in #{glob_require.relative_to} finds other files"
        end
      end

      list_of_runs = cached_data.macro_program_runs
      return if list_of_runs.nil? || list_of_runs.empty?

      working_directory = cached_data.working_directory
      sources_checked_at_unix_ms = cached_data.sources_checked_at_unix_ms
      return "the cache does not say when the sources were read" unless working_directory && sources_checked_at_unix_ms

      output_path = File.expand_path(output_filename)
      list_of_output_paths = [output_path, "#{output_path}.dwarf", "#{output_path}.dwarf.tmp"]
      changed_files = InferReuse::ChangedFiles.under(working_directory, Time.unix_ms(sources_checked_at_unix_ms), list_of_output_paths)
      return "more than #{InferReuse::ChangedFiles::MAXIMUM_ENTRY_COUNT} entries under #{working_directory}" if changed_files.overflowed?
      return if changed_files.list_of_paths.empty?

      list_of_run_inputs = list_of_runs.map { |run| {run.filename, run.list_of_arguments} }
      InferReuse::ProgramRunInputs.new(list_of_run_inputs, working_directory).reason_to_run_again(changed_files.list_of_paths) do |path|
        cached_data.file_fingerprints.has_key?(path)
      end
    end

    private def print_compilation_skip_stats
      return unless @progress_tracker.stats?
      puts
      puts "Incremental compilation:"
      puts " - No source changes detected, semantic + codegen skipped"
      puts " - Output binary is unchanged"
    end

    # Phase 6: Extract top-level signatures from all required files and
    # compare with cached signatures to classify changes.
    # Whether an incremental build parses every required file again after
    # code generation to classify the edit (body-only or structural) for
    # `--stats`. Nothing else reads the result, and the second parse took
    # 0.35 to 0.6 s of every Grant300 rebuild, so it is opt-in:
    # `CRYSTAL_SIGNATURE_TRACKING=1`.
    property? signature_tracking : Bool = ENV["CRYSTAL_SIGNATURE_TRACKING"]? == "1"

    private def extract_and_compare_signatures(program)
      @last_body_only_count = 0
      @last_structural_count = 0
      @last_isolated_body_only_count = 0
      return unless signature_tracking?

      new_signatures, file_contents = extract_file_signatures(program)
      @last_file_signatures = new_signatures
      @last_file_contents = file_contents

      return if new_signatures.empty?

      # Load old signatures from cache
      cached_data = @current_cached_data
      old_signatures = cached_data.try(&.file_signatures)

      # Compute changed files
      current_files = Set(String).new
      program.requires.each { |f| current_files.add(f) }

      if cached_data
        changed = IncrementalCache.changed_files(cached_data, current_files)
      else
        # No cached data -- all files are "new" / structural
        changed = current_files
      end

      return if changed.empty?

      # Classify changes
      body_only, structural = IncrementalCache.classify_changes(
        changed, old_signatures, new_signatures
      )

      # Use file dependency graph from previous build for smarter invalidation.
      # Body-only changes in files with no dependents are truly isolated:
      # no other file calls into them, so semantic analysis results are unchanged.
      if (deps = cached_data.try(&.file_dependencies))
        # Build reverse dependency map: provider_file => [user_files that depend on it]
        reverse_deps = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
        deps.each do |user_file, provider_files|
          provider_files.each { |p| reverse_deps[p] << user_file }
        end

        # Separate body-only changes into those with and without dependents
        isolated_body_only = Set(String).new
        body_only.each do |file|
          if reverse_deps[file]?.nil? || reverse_deps[file].empty?
            isolated_body_only.add(file)
          end
        end

        @last_body_only_count = body_only.size
        @last_structural_count = structural.size
        @last_isolated_body_only_count = isolated_body_only.size
      else
        @last_body_only_count = body_only.size
        @last_structural_count = structural.size
        @last_isolated_body_only_count = 0
      end
    end

    # Extract FileTopLevelSignature for each required file by parsing it
    # and running the SignatureExtractor visitor.
    private def extract_file_signatures(program) : {Hash(String, FileTopLevelSignature), Hash(String, String)}
      all_signatures = {} of String => FileTopLevelSignature
      all_contents = {} of String => String

      program.requires.each do |filename|
        begin
          content = File.read(filename)
          all_contents[filename] = content
          content_hash = Crystal::Digest::MD5.hexdigest(content)

          # Reuse cached AST from the parse stage if available (avoids re-parsing)
          parsed = if @incremental && (cached_ast = @parse_cache.get(filename, content_hash))
                     cached_ast
                   else
                     parser = Parser.new(content, program.string_pool)
                     parser.filename = filename
                     parser.parse
                   end

          extractor = SignatureExtractor.new
          parsed.accept(extractor)
          file_sigs = extractor.build_signatures

          # The extractor may produce signatures for the file and for other
          # files referenced by location. We only take the one for this file.
          if sig = file_sigs[filename]?
            all_signatures[filename] = sig
          else
            # File had no top-level declarations -- store an empty signature
            all_signatures[filename] = FileTopLevelSignature.new(
              type_declarations: [] of TypeDeclarationSig,
              method_signatures: [] of MethodSig,
              mixins: [] of String,
              constants: [] of String,
              has_top_level_macro_calls: false,
            )
          end
        rescue
          # If a file can't be read/parsed, skip it.
          # This is best-effort; the main compilation already succeeded.
        end
      end

      {all_signatures, all_contents}
    end

    private def save_incremental_cache(program, output_dir : String, cache_filename : String = IncrementalCache::CACHE_FILENAME)
      fingerprints = {} of String => FileFingerprint
      cold_build = @current_cached_data.nil?
      pre_read = @last_file_contents
      program.requires.each do |filename|
        begin
          if !cold_build && pre_read && (content = pre_read[filename]?)
            # Reuse content already read during signature extraction
            info = File.info(filename)
            content_hash = Crystal::Digest::MD5.hexdigest(content)
            fingerprints[filename] = FileFingerprint.new(
              filename: filename,
              mtime_epoch: info.modification_time.to_unix_ms,
              content_hash: content_hash,
              byte_size: info.size,
            )
          elsif cold_build
            fingerprints[filename] = IncrementalCache.fingerprint_fast(filename)
          else
            fingerprints[filename] = IncrementalCache.fingerprint(filename)
          end
        rescue IO::Error
          # File may have been deleted between compilation and cache save
        end
      end

      # Capture allocation sizing hints from the current compilation
      hints = AllocationHints.new(
        string_pool_capacity: program.string_pool.size,
        unions_capacity: program.unions.size,
        total_types_count: count_all_types(program),
        total_defs_count: count_all_defs(program),
        module_count: @last_modules_total || 1,
      )

      # Capture file-level dependencies (convert Set to sorted Array for JSON)
      file_deps = unless program.file_dependencies.empty?
        result = {} of String => Array(String)
        program.file_dependencies.each do |user_file, provider_set|
          result[user_file] = provider_set.to_a.sort
        end
        result
      end

      data = IncrementalCacheData.new(
        compiler_version: Config.version,
        codegen_target: @codegen_target.to_s,
        flags: @flags.dup,
        prelude: @prelude,
        file_fingerprints: fingerprints,
        file_signatures: @last_file_signatures,
        allocation_hints: hints,
        file_dependencies: file_deps,
        glob_requires: program.list_of_glob_requires.empty? ? nil : program.list_of_glob_requires,
        macro_program_runs: program.set_of_macro_program_runs.empty? ? nil : program.set_of_macro_program_runs.to_a,
        working_directory: Dir.current,
        sources_checked_at_unix_ms: @sources_checked_at_unix_ms,
      )

      IncrementalCache.save(output_dir, data, cache_filename)
      @last_file_contents = nil
    end

    private def count_all_types(program : Program) : Int32
      count = 0
      program.types.each_value { |_| count += 1 }
      count
    end

    private def count_all_defs(program : Program) : Int32
      count = 0
      program.types.each_value do |type|
        if type.responds_to?(:def_instances)
          count += type.def_instances.size
        end
      end
      count
    end

    getter(target_machine : LLVM::TargetMachine) do
      create_target_machine
    end

    def create_target_machine
      @codegen_target.to_target_machine(@mcpu || "", @mattr || "", @optimization_mode, @mcmodel)
    rescue ex : ArgumentError
      stderr.print colorize("Error: ").red.bold
      stderr.print "llc: "
      stderr.puts ex.message
      exit 1
    end

    {% if LibLLVM::IS_LT_170 %}
      property! pass_manager_builder : LLVM::PassManagerBuilder

      private def init_llvm_legacy_pass_manager
        registry = LLVM::PassRegistry.instance
        registry.initialize_all

        builder = LLVM::PassManagerBuilder.new
        builder.size_level = 0

        case optimization_mode
        in .o3?
          builder.opt_level = 3
          builder.use_inliner_with_threshold = 275
        in .o2?
          builder.opt_level = 2
          builder.use_inliner_with_threshold = 275
        in .o1?
          builder.opt_level = 1
          builder.use_inliner_with_threshold = 150
        in .o0?
          # default behaviour, no optimizations
        in .os?
          builder.opt_level = 2
          builder.size_level = 1
          builder.use_inliner_with_threshold = 50
        in .oz?
          builder.opt_level = 2
          builder.size_level = 2
          builder.use_inliner_with_threshold = 5
        end

        @pass_manager_builder = builder
      end

      private def optimize_with_pass_manager(llvm_mod)
        fun_pass_manager = llvm_mod.new_function_pass_manager
        pass_manager_builder.populate fun_pass_manager
        fun_pass_manager.run llvm_mod

        module_pass_manager = LLVM::ModulePassManager.new
        pass_manager_builder.populate module_pass_manager
        module_pass_manager.run llvm_mod
      end
    {% end %}

    # Loads the module in *bitcode_filename* into a context of its own,
    # optimizes it and writes *object_filename*, exactly as a compilation
    # unit is compiled in-process. The module is freed before returning.
    def compile_bitcode_file_to_object(bitcode_filename : String, object_filename : String,
                                       llvm_ir_filename : String? = nil, verifies_module : Bool = false,
                                       list_of_more_bitcode_filenames : Array(String) = [] of String,
                                       hash_record_filename : String? = nil,
                                       list_of_bitcode_part_hashes : Array(String) = [] of String) : Nil
      context = LLVM::Context.new
      begin
        llvm_mod = Compiler.parse_linked_bitcode_files([bitcode_filename] + list_of_more_bitcode_filenames, context)
        llvm_mod.verify if verifies_module

        temporary_object_filename = "#{object_filename}.tmp"
        target_machine = create_target_machine
        begin
          optimize llvm_mod, target_machine unless optimization_mode.o0?
          target_machine.emit_obj_to_file llvm_mod, temporary_object_filename
        ensure
          target_machine.dispose
        end
        File.rename(temporary_object_filename, object_filename)
        if hash_record_filename
          CachedObjectRecord.write(hash_record_filename, list_of_bitcode_part_hashes, [object_filename])
        end

        llvm_mod.print_to_file llvm_ir_filename if llvm_ir_filename
      ensure
        context.dispose
      end
    end

    protected def optimize(llvm_mod, target_machine)
      {% if LibLLVM::IS_LT_130 %}
        optimize_with_pass_manager(llvm_mod)
      {% else %}
        optimization_mode = @optimization_mode
        optimization_mode = OptimizationMode::O2 if optimization_mode.os? || optimization_mode.oz?

        LLVM::PassBuilderOptions.new do |options|
          LLVM.run_passes(llvm_mod, "default<#{optimization_mode}>", target_machine, options)
        end
      {% end %}
    end

    protected def run_linker(linker_name, command, args)
      print_command(command, args) if verbose?
      missing_library_hint = MissingLibraryHint.new

      begin
        Process.run(command, args, shell: true,
          input: Process::Redirect::Close, output: Process::Redirect::Inherit, error: Process::Redirect::Pipe) do |process|
          process.error.each_line(chomp: false) do |line|
            missing_library_hint.read(line)
            hint_string = colorize("(this usually means you need to install the development package for lib\\1)").yellow.bold
            line = line.gsub(/cannot find -l(\S+)\b/, "cannot find -l\\1 #{hint_string}")
            line = line.gsub(/unable to find library -l(\S+)\b/, "unable to find library -l\\1 #{hint_string}")
            line = line.gsub(/library not found for -l(\S+)\b/, "library not found for -l\\1 #{hint_string}")
            STDERR << line
          end
        end
      rescue exc : File::AccessDeniedError | File::NotFoundError
        linker_not_found exc.class, linker_name
      end

      status = $?
      unless status.success?
        exit_code = status.exit_code?
        case exit_code
        when 126
          linker_not_found File::AccessDeniedError, linker_name
        when 127
          linker_not_found File::NotFoundError, linker_name
        when nil
          # abnormal exit
          exit_code = 1
        end
        STDERR << colorize(missing_library_hint.to_s).yellow.bold if missing_library_hint.any_known_library_missing?
        raise CompilerError.new("execution of command failed with exit status #{status}: #{command}", status: exit_code)
      end
    end

    # The post-link step of a wasm32 build. The order of the passes matters:
    #
    # 1. `--asyncify` instruments functions so fibers can unwind and rewind
    #    the stack. It only understands legacy exception handling
    #    (try/catch), so it runs on the freshly linked module.
    #    `crystal_asyncify_switch` is declared an async import so its callers
    #    save and restore their state around it.
    # 2. `wasm-merge` adds asyncify_helper.wasm, whose `crystal_*` wrappers
    #    call the `asyncify_*` functions the pass just created. It runs after
    #    the pass so the helper's imports and the pass's definitions do not
    #    collide.
    # 3. `--translate-to-exnref` turns legacy exception handling into the
    #    try_table/exnref form browsers run. It runs after asyncify.
    # 4. `--spill-pointers` stores pointer-typed locals on the shadow stack at
    #    every call, so Boehm's conservative scan sees them as roots.
    # 5. `-O1` to `-O3`, `-Os` or `-Oz`, matching the compiler's optimization
    #    mode, on the final module (none at `-O0`).
    #
    # Steps 1 and 2 are for fibers only: a program built with
    # `-Dfrontend_no_fibers` never switches fibers, so they are skipped, and
    # with them the asyncify instrumentation that slows every function down
    # and grows the module by about half.
    #
    # Step 4 runs only without asyncify, whose interaction with it is
    # unverified (emscripten/emscripten#18251), and only when there is a
    # collector to scan the roots: with `-Dgc_none` it would spill pointers
    # nobody reads.
    private def run_wasm_opt(output_filename : String, optimization_mode : OptimizationMode,
                             skip_fibers : Bool, needs_pointer_spills : Bool) : Nil
      quoted = Process.quote_posix(output_filename)

      unless skip_fibers
        # _start is the asyncify boundary, so it stays uninstrumented.
        run_wasm_opt_pass(quoted,
          "--asyncify" \
          " --pass-arg=asyncify-removelist@_start" \
          " --pass-arg=asyncify-imports@env.crystal_asyncify_switch",
          "asyncify")
        run_wasm_merge(output_filename)
      end

      run_wasm_opt_pass(quoted, "--translate-to-exnref", "translate-to-exnref")

      if skip_fibers && needs_pointer_spills
        run_wasm_opt_pass(quoted, "--spill-pointers", "spill-pointers")
      end

      if level = Compiler.wasm_opt_level(optimization_mode)
        run_wasm_opt_pass(quoted, level, "optimization")
      end
    end

    # The `wasm-opt` optimization flag that matches *optimization_mode*, or
    # `nil` at `-O0`. A speed level (`-O3`, which `--release` selects) keeps
    # the speed Binaryen's size levels would give up: on the Box3D port,
    # `wasm-opt -Oz` and `-O3` gave modules within 0.1% of each other
    # gzipped, and `-Oz` code ran slower.
    def self.wasm_opt_level(optimization_mode : OptimizationMode) : String?
      return nil if optimization_mode.o0?

      "-#{optimization_mode}"
    end

    private def run_wasm_merge(output_filename)
      helper_path = find_asyncify_helper
      unless helper_path
        raise CompilerError.new("asyncify_helper.wasm not found in CRYSTAL_PATH. " \
                                "This file is required for WASM fiber support.", :FAILURE)
      end

      quoted_output = Process.quote_posix(output_filename)
      quoted_helper = Process.quote_posix(helper_path)
      wasm_merge = Process.quote_posix(wasm32_tool("wasm-merge"))

      # wasm-merge combines two modules:
      #   - main module (named "crystal_main" so helper's imports resolve)
      #   - helper module (named "env" so main's crystal_* imports resolve)
      # Remaining unresolved imports stay as imports in the output.
      cmd = "#{wasm_merge} #{quoted_output} crystal_main #{quoted_helper} env" \
            " -o #{quoted_output} --all-features"
      print_command(cmd, nil) if verbose?
      status = Process.run(cmd, shell: true, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      unless status.success?
        raise CompilerError.new("wasm-merge failed with exit status #{status}: #{cmd}", :FAILURE)
      end
    end

    private def find_asyncify_helper : String?
      crystal_path = ENV["CRYSTAL_PATH"]? || Crystal::Config.path
      crystal_path.split(Process::PATH_DELIMITER, remove_empty: true).each do |path|
        resolved = path.starts_with?('/') ? path : File.expand_path(path)
        helper = File.join(resolved, "crystal", "asyncify_helper.wasm")
        return helper if File.exists?(helper)
      end
      nil
    end

    private def run_wasm_opt_pass(quoted_filename, pass_flag, pass_name)
      wasm_opt = Process.quote_posix(wasm32_tool("wasm-opt"))
      cmd = "#{wasm_opt} #{quoted_filename} -o #{quoted_filename} #{pass_flag} --all-features"
      print_command(cmd, nil) if verbose?
      status = Process.run(cmd, shell: true, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      unless status.success?
        raise CompilerError.new("wasm-opt #{pass_name} pass failed with exit status #{status}: #{cmd}", :FAILURE)
      end
    end

    @list_of_checked_wasm32_tools = {} of String => String

    # The path of the wasm32 build tool *name* (`wasm-ld`, `wasm-opt` or
    # `wasm-merge`) on the `PATH`. When the environment variable
    # `CRYSTAL_<NAME>_SHA256` (for example `CRYSTAL_WASM_OPT_SHA256`) holds a
    # SHA-256, the tool's executable must have that hash or the build stops:
    # that pins the exact binary a build runs. A tool is checked once per
    # compilation.
    private def wasm32_tool(name : String) : String
      if checked_path = @list_of_checked_wasm32_tools[name]?
        return checked_path
      end

      found_path = Process.find_executable(name)
      unless found_path
        raise CompilerError.new("`#{name}` was not found on the PATH; a wasm32 build needs LLD's wasm-ld and Binaryen's wasm-opt (see WASM_GUIDE.md)", :FAILURE)
      end

      variable_name = Compiler.wasm32_tool_hash_variable(name)
      if expected_hash = ENV[variable_name]?.presence
        real_path = File.realpath(found_path)
        actual_hash = File.open(real_path, "rb") { |file| Crystal::Digest::SHA256.new.update(file).final.hexstring }
        unless actual_hash == expected_hash.downcase
          raise CompilerError.new("#{real_path} has SHA-256 #{actual_hash}, but #{variable_name} expects #{expected_hash}", :FAILURE)
        end
      end

      @list_of_checked_wasm32_tools[name] = found_path
    end

    # The environment variable that pins the SHA-256 of the wasm32 build
    # tool *name*: `CRYSTAL_WASM_OPT_SHA256` for `wasm-opt`.
    def self.wasm32_tool_hash_variable(name : String) : String
      "CRYSTAL_#{name.upcase.gsub('-', '_')}_SHA256"
    end

    private def linker_not_found(exc_class, linker_name)
      verbose_info = "\nRun with `--verbose` to print the full linker command." unless verbose?
      case exc_class
      when File::AccessDeniedError
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: Permission denied#{verbose_info}", :FAILURE)
      else
        raise CompilerError.new("Could not execute linker: `#{linker_name}`: File not found#{verbose_info}", :FAILURE)
      end
    end

    private def colorize(obj)
      obj.colorize.toggle(@color)
    end

    # An LLVM::Module with information to compile it.
    class CompilationUnit
      getter compiler
      getter name
      getter original_name
      property? reused_previous_compilation = false
      getter object_extension : String
      @memory_buffer : LLVM::MemoryBuffer?
      @object_name : String?
      # The number of object files this unit is emitted as (see `Compiler#release_units`).
      getter part_count : Int32
      @bc_name : String?
      @llvm_mod : LLVM::Module?
      @worker_verifies_module = false

      # The file a unit's bitcode and object files are named after: the
      # name of the unit's type, made safe for a file system, plus the
      # suffix of the optimization mode.
      def self.file_basename(type_name : String, optimization_mode : OptimizationMode) : String
        type_name = "_main" if type_name == ""
        basename = String.build do |str|
          type_name.each_char do |char|
            case char
            when 'a'..'z', '0'..'9', '_'
              str << char
            when 'A'..'Z'
              # Because OSX has case insensitive filenames, try to avoid
              # clash of 'a' and 'A' by using 'A-' for 'A'.
              str << char << '-'
            when '#'
              # The separator of a module segment's number (see
              # `CodeGenVisitor.segment_module_name`). A `-` that does not
              # follow a capital letter is in no other name.
              str << "-seg"
            else
              str << char.ord
            end
          end
        end

        if basename.size > 50
          # 17 chars from name + 1 (dash) + 32 (md5) = 50
          basename = "#{basename[0..16]}-#{::Crystal::Digest::MD5.hexdigest(basename)}"
        end

        "#{basename}#{optimization_mode.suffix}"
      end

      # *llvm_mod* is the unit's module, unless IR generation spilled it to
      # disk: then *list_of_spilled_bitcode_paths* are the files that hold
      # the bitcode of its parts, in the order they are linked.
      def initialize(@compiler : Compiler, program : Program, @name : String,
                     @llvm_mod : LLVM::Module?, @output_dir : String, @bc_flags_changed : Bool,
                     @part_count : Int32 = 1,
                     list_of_spilled_bitcode_paths : Array(String) = [] of String,
                     list_of_spilled_part_hashes : Array(String) = [] of String,
                     list_of_carried_part_hashes : Array(String)? = nil,
                     @patched_object : LinePatch::PatchedObject? = nil)
        @patched_object_filename = @patched_object.try(&.pending_filename)
        @original_name = @name == "" ? "_main" : @name
        @name = CompilationUnit.file_basename(@name, @compiler.optimization_mode)
        @object_extension = compiler.codegen_target.object_extension
        @list_of_spilled_bitcode_paths = list_of_spilled_bitcode_paths.dup
        @spilled_part_count = list_of_spilled_bitcode_paths.size
        if spilled? && list_of_spilled_part_hashes.size == @spilled_part_count
          @list_of_part_hashes = list_of_spilled_part_hashes.dup
        end
        if list_of_carried_part_hashes
          @carries_cached_bitcode = true
          @list_of_part_hashes = list_of_carried_part_hashes.dup
        end
      end

      # Whether IR generation was skipped for this unit (see `IrSkip`): it
      # has no module and no new bitcode, only the hashes of the bitcode its
      # object file in the cache was built from.
      getter? carries_cached_bitcode = false

      # The hash of the bitcode of each part of this unit's module, in the
      # order the parts are linked (one part for a module that stayed in
      # memory). `nil` until the bitcode exists, and without a hash function.
      getter list_of_part_hashes : Array(String)?

      # Whether the hash of this unit's bitcode told if its previous object
      # file can be reused, without reading the cached bitcode.
      getter? decided_by_bitcode_hash = false

      # What the hash record of the cache says about this unit's bitcode.
      private enum CachedBitcode
        # The object files were built from bitcode with this unit's hash.
        Same
        # They were built from other bitcode.
        Different
        # There is no record of these object files, or no hash.
        Unknown
      end

      private def cached_bitcode : CachedBitcode
        list_of_part_hashes = @list_of_part_hashes
        return CachedBitcode::Unknown unless list_of_part_hashes

        module_hash = BitcodeHash.of_module(list_of_part_hashes)
        record = CachedObjectRecord.read?(hash_record_name)
        return CachedBitcode::Unknown unless module_hash && record
        return CachedBitcode::Unknown unless record.describes_objects?(object_names)

        @decided_by_bitcode_hash = true
        record.module_hash == module_hash ? CachedBitcode::Same : CachedBitcode::Different
      end

      # Leaves the record of the object files that were just built, or that
      # a comparison of the bitcode files found to be up to date.
      private def write_hash_record : Nil
        return if compiler.no_cache?
        return unless list_of_part_hashes = @list_of_part_hashes

        CachedObjectRecord.write(hash_record_name, list_of_part_hashes, object_names)
      end

      # The spill files of this unit's module parts that the cache has not
      # taken over yet.
      @list_of_spilled_bitcode_paths : Array(String)

      # How many parts IR generation spilled this unit's module in (0 for a
      # module that stayed in memory).
      @spilled_part_count : Int32

      private def spilled? : Bool
        @spilled_part_count > 0
      end

      # The unit's module. A module that IR generation spilled to disk is
      # parsed from its bitcode files on first use, in a context of its own.
      def llvm_mod : LLVM::Module
        @llvm_mod ||= load_spilled_module
      end

      # Frees the unit's module, if it is in memory.
      def dispose_module : Nil
        @llvm_mod.try &.context.dispose
      end

      # The cached bitcode file of part *part_index* of a spilled unit. The
      # first part is the unit's `.bc` file.
      private def part_bc_name(part_index : Int32) : String
        part_index == 0 ? bc_name : "#{@output_dir}/#{@name}.part#{part_index}.bc"
      end

      private def list_of_part_bc_names : Array(String)
        Array.new(@spilled_part_count) { |part_index| part_bc_name(part_index) }
      end

      # The cached bitcode files of the parts after the first one.
      private def list_of_more_part_bc_names : Array(String)
        list_of_part_bc_names.skip(1)
      end

      private def load_spilled_module : LLVM::Module
        # The spill files are the unit's cached bitcode files once the cache
        # took them over.
        list_of_paths = @list_of_spilled_bitcode_paths.empty? ? list_of_part_bc_names : @list_of_spilled_bitcode_paths
        spilled_module = Compiler.parse_linked_bitcode_files(list_of_paths, LLVM::Context.new)
        # Modules that stayed in memory were verified when IR generation
        # finished; a spilled one is verified here, the one time it is
        # complete and in memory anyway.
        spilled_module.verify
        spilled_module
      end

      # Deletes the cached bitcode files of every part after the first one,
      # whatever number of parts the build that left them had.
      private def delete_cached_part_files : Nil
        compiler.take_cached_part_bitcode_filenames(@output_dir, @name).each do |part_filename|
          File.delete?(File.join(@output_dir, part_filename))
        end
      end

      # Makes the spill files the unit's cached bitcode files.
      private def move_spilled_bitcode_into_cache : Nil
        delete_cached_part_files
        @list_of_spilled_bitcode_paths.each_with_index do |spilled_bitcode_path, part_index|
          File.rename(spilled_bitcode_path, part_bc_name(part_index))
        end
        @list_of_spilled_bitcode_paths.clear
      end

      def generate_bitcode : LLVM::MemoryBuffer?
        # A spilled unit already is bitcode, on disk, and a unit without
        # generated IR has none to make.
        return nil if spilled? || carries_cached_bitcode?
        @memory_buffer ||= begin
          memory_buffer = llvm_mod.write_bitcode_to_memory_buffer
          if part_hash = BitcodeHash.of_part(memory_buffer.to_slice)
            @list_of_part_hashes = [part_hash]
          end
          memory_buffer
        end
      end

      # To compile a file we first generate a `.bc` file and then create an
      # object file from it. These `.bc` files are stored in the cache
      # directory.
      #
      # On a next compilation of the same project, and if the compile flags
      # didn't change (a combination of the target triple, mcpu and link flags,
      # amongst others), we check if the new bitcode is exactly the same as
      # the old one. In that case the `.o` file will also be the same, so we
      # simply reuse the old one. Generating an `.o` file is what takes most
      # time.
      #
      # "The same" is decided by the hash of the bitcode against the hash in
      # the record next to the `.o` file (`CachedObjectRecord`), without
      # reading the old `.bc` file. Only when there is no record of the `.o`
      # file is the new bitcode compared with the old `.bc` file.
      #
      # However, instead of directly generating the final `.o` file from the
      # `.bc` file, we generate it to a temporary name (`.o.tmp`) and then we
      # rename that file to `.o`. We do this because the compiler could be
      # interrupted while the `.o` file is being generated, leading to a
      # corrupted file that later would cause compilation issues. Moving a file
      # is an atomic operation so no corrupted `.o` file should be generated.
      def compile(isolate_context = false)
        if must_compile? && !patch_main_module_lines
          isolate_module_context if isolate_context
          update_bitcode_cache
          compile_to_object
          write_hash_record
        else
          @reused_previous_compilation = true
        end
        dump_llvm_ir

        # A unit compiled on a worker thread owns its LLVM context, and
        # nothing reads its module after this point (only a single unit is
        # emitted, and a single unit never goes to a worker). Dispose of the
        # context now instead of when the GC finalizes it: hundreds of units
        # otherwise keep their contexts alive for the rest of the
        # compilation, including the codegen of a macro run program that
        # happens in the middle of the main program's semantic phase.
        dispose_module if isolate_context
      end

      private def discard_spilled_bitcode : Nil
        @list_of_spilled_bitcode_paths.each { |spilled_bitcode_path| File.delete?(spilled_bitcode_path) }
        @list_of_spilled_bitcode_paths.clear
      end

      # The same decision as `must_compile?`, for a unit whose new bitcode
      # is in files: each part is compared with its cached bitcode file.
      private def must_compile_spilled? : Bool
        return true unless compiler.emit_targets.none?
        return true if @bc_flags_changed

        cached_bitcode = self.cached_bitcode
        if cached_bitcode.same?
          # The cached bitcode files hold the same module.
          discard_spilled_bitcode
          return false
        end
        return true if cached_bitcode.different?

        return true unless object_names.all? { |name| File.exists?(name) && File.size(name) > 0 }
        # The build that left the objects had more parts.
        return true if File.exists?(part_bc_name(@spilled_part_count))

        unchanged = @list_of_spilled_bitcode_paths.each_with_index.all? do |(spilled_bitcode_path, part_index)|
          cached_bitcode_name = part_bc_name(part_index)
          File.exists?(cached_bitcode_name) && File.open(cached_bitcode_name) do |cached_file|
            File.open(spilled_bitcode_path) { |spilled_file| IO.same_content?(cached_file, spilled_file) }
          end
        end
        if unchanged
          # The cached bitcode files hold the same module from now on.
          discard_spilled_bitcode
          write_hash_record
        end
        !unchanged
      end

      # The size of this unit's bitcode, known once it was generated.
      getter bitcode_bytesize : Int64 = 0_i64

      # Prepares this unit for a `CodegenWorker`: writes the module to its
      # bitcode file unless the previous object file can be reused, and frees
      # the module. Returns whether a worker must build the object file.
      def write_bitcode_and_release_module : Bool
        if carries_cached_bitcode?
          @reused_previous_compilation = true unless must_compile?
          return false
        end
        return hand_spilled_bitcode_to_worker if spilled?

        # Generated even with --no-cache: the worker reads the module from
        # its bitcode file, and the object it writes comes from that file.
        if memory_buffer = generate_bitcode
          @bitcode_bytesize = memory_buffer.to_slice.size.to_i64
        end

        must_compile = must_compile?
        must_compile = false if must_compile && patch_main_module_lines
        if must_compile
          update_bitcode_cache
        else
          @reused_previous_compilation = true
          dump_llvm_ir
        end
        llvm_mod.context.dispose
        must_compile
      end

      # For the main module, which is generated in every build: when its
      # bitcode changed only because lines moved, puts the cached object
      # with patched debug lines in place instead of compiling it again
      # (see `LinePatch::MainModule`). Returns whether it did. Otherwise
      # leaves the digest of the new module's text for the next build.
      private def patch_main_module_lines : Bool
        return false unless main_module_or_part? && @part_count == 1 && !compiler.no_cache?
        session = compiler.main_module_line_patch_session || return false
        list_of_part_hashes = @list_of_part_hashes || return false
        module_hash = BitcodeHash.of_module(list_of_part_hashes) || return false
        memory_buffer = @memory_buffer || return false

        started_at = Time.instant
        maps = session.line_maps
        digests = LinePatch::MainModule.digests(llvm_mod, maps) || return false
        patched, outcome = patch_main_module_object(session, maps, digests, memory_buffer, module_hash)
        unless patched
          # The object is compiled from this bitcode: its text, for the next
          # build. It counts once the object's record names this hash.
          LinePatch::MainModule::Sidecar.new(module_hash, digests.text_digest).write(object_name)
        end
        seconds = (Time.instant - started_at).total_seconds
        if @original_name == "_main"
          session.stats.main_module_outcome = outcome
          session.stats.main_module_seconds = seconds
        end
        compiler.print_main_module_outcome(@original_name, outcome, seconds)
        patched
      end

      # Whether this unit is the main module or a part of the top-level
      # code (see `CodeGenVisitor::MainParts`): both are generated in every
      # build, and their objects are line patched from their text.
      private def main_module_or_part? : Bool
        @original_name == "_main" || CodeGenVisitor::MainParts.part_module_name?(@original_name)
      end

      # Patches the main module's cached object when the new text, with its
      # positions mapped back, is the text the object was built from.
      # Returns whether the object was patched, and what happened.
      private def patch_main_module_object(session : IrSkip::Session, maps : LinePatch::Maps?,
                                           digests : LinePatch::MainModule::Digests,
                                           memory_buffer : LLVM::MemoryBuffer, module_hash : String) : {Bool, String}
        return {false, "compiled: no lines moved"} unless maps && !maps.empty?
        if failure = digests.mapping_failure
          return {false, "compiled: #{failure}"}
        end
        return {false, "compiled: the flags object files are built with changed"} if @bc_flags_changed
        record = CachedObjectRecord.read?(hash_record_name)
        return {false, "compiled: no record of its object"} unless record && record.describes_objects?(object_names)
        sidecar = LinePatch::MainModule::Sidecar.read?(object_name)
        return {false, "compiled: no text digest of its object"} unless sidecar && sidecar.module_hash == record.module_hash
        return {false, "compiled: its code changed"} unless digests.mapped_text_digest == sidecar.text_digest

        patched_bytes = LinePatch::MainModule.patch_object(object_name, maps)
        return {false, "compiled: the patcher refused its object: #{patched_bytes}"} if patched_bytes.is_a?(String)

        pending_filename = "#{object_name}#{LinePatch::UnitPatcher::PENDING_EXTENSION}"
        File.write(pending_filename, patched_bytes)
        if session.verify?
          compiler.add_line_patch_check(LinePatch::Verification::Check.new(@original_name, pending_filename, object_name))
          return {false, "compiled for verification: lines moved, patched object kept to compare"}
        end

        # Same order as for any object put in place: the record goes first,
        # and comes back once the files it describes are there.
        File.delete?(hash_record_name)
        File.write(bc_name, memory_buffer.to_slice)
        File.rename(pending_filename, object_name)
        write_hash_record
        LinePatch::MainModule::Sidecar.new(module_hash, digests.text_digest).write(object_name)
        @patched_object_filename = object_name
        {true, "lines moved, cached object patched"}
      end

      # The same for a unit that IR generation spilled: its bitcode is
      # already in files and its module is not in memory. The spill files
      # become the unit's cached bitcode files, the ones the worker links
      # and compiles (with --no-cache too). Nothing has verified the module
      # yet, so the worker does.
      private def hand_spilled_bitcode_to_worker : Bool
        @bitcode_bytesize = @list_of_spilled_bitcode_paths.sum { |spilled_bitcode_path| File.size(spilled_bitcode_path) }
        must_compile = compiler.no_cache? || must_compile_spilled?
        if must_compile
          delete_object_files
          move_spilled_bitcode_into_cache
          @worker_verifies_module = true
        else
          @reused_previous_compilation = true
          dump_llvm_ir
          dispose_module
        end
        must_compile
      end

      def codegen_worker_job : CodegenWorker::Job
        CodegenWorker::Job.new(
          bitcode_filename: bc_name,
          object_filename: object_name,
          llvm_ir_filename: compiler.dump_ll? ? ll_name : nil,
          verifies_module: @worker_verifies_module,
          list_of_more_bitcode_filenames: list_of_more_part_bc_names,
          hash_record_filename: compiler.no_cache? || @list_of_part_hashes.nil? ? nil : hash_record_name,
          list_of_bitcode_part_hashes: @list_of_part_hashes || [] of String,
          name: original_name,
          bitcode_bytesize: bitcode_bytesize,
          main_module: original_name == "_main",
        )
      end

      # What `--stats` tells about this unit.
      def summary : ObjectStage::UnitSummary
        ObjectStage::UnitSummary.new(
          original_name: original_name,
          bitcode_name: "#{name}.bc",
          reused_previous_compilation: reused_previous_compilation?,
          decided_by_bitcode_hash: decided_by_bitcode_hash?,
        )
      end

      # A unit without generated IR was matched with an object file before
      # IR generation. The build holds no lock on the cache directory in
      # between, so the object is checked again; when another build replaced
      # it there is nothing here to build it from.
      private def must_compile_carried? : Bool
        unless !@bc_flags_changed && cached_bitcode.same?
          @patched_object.try &.discard
          raise CompilerError.new("the cache of this program changed while it was being built " \
                                  "(the object file of #{@original_name} was replaced); build again")
        end
        install_patched_object
        false
      end

      # The object with patched lines (see `LinePatch`), when IR generation
      # matched this unit with moved lines.
      @patched_object : LinePatch::PatchedObject?

      # Whether this unit's object is the cached one with patched lines: it
      # is reused, but the executable must be linked again.
      def patched_lines? : Bool
        !@patched_object_filename.nil?
      end

      @patched_object_filename : String?

      # Puts the patched object in place of the cached one, with the record
      # of what it stands for. The cache directory is locked by now.
      private def install_patched_object : Nil
        patched_object = @patched_object
        return unless patched_object
        @patched_object = nil
        pending_filename = patched_object.pending_filename
        return unless pending_filename

        File.delete?(hash_record_name)
        File.rename(pending_filename, object_name)
        @list_of_part_hashes = patched_object.list_of_part_hashes.dup
        write_hash_record
      end

      private def must_compile?
        return must_compile_carried? if carries_cached_bitcode?
        return true if compiler.no_cache?

        return must_compile_spilled? if spilled?

        memory_buffer = generate_bitcode

        # Only a spilled unit has no bitcode in memory, and it was handled above.
        return true unless memory_buffer

        return true unless compiler.emit_targets.none?
        return true if @bc_flags_changed

        cached_bitcode = self.cached_bitcode
        if cached_bitcode.same?
          memory_buffer.dispose
          return false
        end
        return true if cached_bitcode.different?

        return true unless File.exists?(bc_name)
        # The build that left the objects spilled this module in parts.
        return true if File.exists?(part_bc_name(1))

        # If the user cancelled a previous compilation
        # it might be that a .o file is missing or empty
        return true unless object_names.all? { |name| File.exists?(name) && File.size(name) > 0 }

        memory_io = IO::Memory.new(memory_buffer.to_slice)

        changed = File.open(bc_name) { |bc_file| !IO.same_content?(bc_file, memory_io) }

        unless changed
          memory_buffer.dispose
          write_hash_record
        end

        changed
      end

      # Parse the previously generated bitcode into the LLVM module using a
      # dedicated context, so we can safely optimize & compile the module in
      # multiple threads (llvm contexts can't be shared across threads).
      private def isolate_module_context
        # A spilled unit is parsed from its file into a context of its own
        # by whichever thread compiles it.
        generated_module = @llvm_mod
        return unless generated_module

        @llvm_mod = LLVM::Module.parse(@memory_buffer.not_nil!, LLVM::Context.new)

        # In multi-module mode every module is generated in a context of its
        # own, and only this unit refers to it. Its bitcode now lives in the
        # isolated context, so the generated one can go.
        generated_module.context.dispose
      end

      # Deletes existing .o files, including the parts of any part count
      # (only the main unit is ever split). They cannot be used anymore:
      # every object left next to the .bc file must have been built from
      # it, or a later build (with another part count, or after a
      # --no-cache build) could link objects of another program.
      private def delete_object_files : Nil
        # The record goes first: it never describes other files than the
        # ones it was written for.
        File.delete?(hash_record_name)
        File.delete?(object_name)
        object_names.each { |name| File.delete?(name) }
        delete_part_objects_of_every_count if @original_name == "_main"
      end

      private def update_bitcode_cache
        delete_object_files

        if spilled?
          if compiler.no_cache?
            # The module is compiled from the spill files, which are not kept.
            llvm_mod
            File.delete?(bc_name)
            delete_cached_part_files
            discard_spilled_bitcode
          else
            # The spill files become the bitcode files (for next compilations)
            move_spilled_bitcode_into_cache
          end
        elsif memory_buffer = @memory_buffer
          # Create the .bc file (for next compilations)
          File.write(bc_name, memory_buffer.to_slice)
          memory_buffer.dispose
          delete_cached_part_files
        else
          # --no-cache generates no bitcode: the objects written next do not
          # come from the cached .bc file, so it must not match them later.
          File.delete?(bc_name)
          delete_cached_part_files
        end
      end

      private def delete_part_objects_of_every_count
        part_prefix = "#{@name}.p"
        Dir.each_child(@output_dir) do |child|
          next unless child.starts_with?(part_prefix) && child.ends_with?(@object_extension)
          next unless child[part_prefix.size...-@object_extension.size].matches?(/\A\d+of\d+\z/)

          File.delete?(File.join(@output_dir, child))
        end
      end

      # Optimizes the module as a whole, splits it into `part_count` modules
      # and emits each part's object file on its own thread. Each part is
      # handed over as bitcode and parsed into an LLVM context of its own,
      # because contexts cannot be shared across threads.
      private def compile_parts_to_objects
        target_machine = compiler.create_target_machine
        begin
          compiler.optimize llvm_mod, target_machine
        ensure
          target_machine.dispose
        end

        list_of_part_object_names = object_names

        {% if flag?(:without_mt) %}
          split = llvm_mod.split_to_bitcode(@part_count) do |index, bitcode|
            compile_part_to_object(bitcode, list_of_part_object_names[index])
          end
          raise_unsplittable_module unless split
        {% else %}
          parts_to_compile = Channel({Int32, LLVM::MemoryBuffer}).new(@part_count)
          first_part_failure = nil.as(Exception?)
          failure_lock = Sync::Mutex.new
          workers = WaitGroup.new

          compiler.n_threads.clamp(1..@part_count).times do
            workers.spawn do
              while part = parts_to_compile.receive?
                index, bitcode = part
                begin
                  compile_part_to_object(bitcode, list_of_part_object_names[index])
                rescue ex
                  failure_lock.synchronize { first_part_failure ||= ex }
                end
              end
            end
          end

          split = false
          begin
            # The channel holds every part, so handing one over never blocks
            # the split, even when a worker has stopped on a failure.
            split = llvm_mod.split_to_bitcode(@part_count) do |index, bitcode|
              parts_to_compile.send({index, bitcode})
            end
          ensure
            parts_to_compile.close
            workers.wait
          end

          if failure = failure_lock.synchronize { first_part_failure }
            raise failure
          end
          raise_unsplittable_module unless split
        {% end %}
      end

      private def raise_unsplittable_module
        raise "BUG: --release-units split a module that LLVM cannot split"
      end

      private def compile_part_to_object(bitcode, part_object_name)
        part_context = LLVM::Context.new
        begin
          part_module = LLVM::Module.parse(bitcode, part_context)
          bitcode.dispose
          target_machine = compiler.create_target_machine
          temporary_part_object_name = "#{part_object_name}.tmp"
          begin
            target_machine.emit_obj_to_file part_module, temporary_part_object_name
          ensure
            target_machine.dispose
          end
          File.rename(temporary_part_object_name, part_object_name)
        ensure
          bitcode.dispose
          part_context.dispose
        end
      end

      private def compile_to_object(file_name = object_name, *, optimize = true)
        # A unit split into parts writes one object per part; an explicit
        # emit (`--emit obj` from a fresh module) writes the whole module.
        return compile_parts_to_objects if @part_count > 1 && file_name == object_name

        temporary_object_name = self.temporary_object_name
        target_machine = compiler.create_target_machine
        begin
          compiler.optimize llvm_mod, target_machine if optimize && !compiler.optimization_mode.o0?
          target_machine.emit_obj_to_file llvm_mod, temporary_object_name
        ensure
          # Each unit creates a target machine of its own, and each one holds
          # a few hundred kilobytes until it is released.
          target_machine.dispose
        end
        FileUtils.mv(temporary_object_name, file_name)
      end

      private def dump_llvm_ir
        llvm_mod.print_to_file ll_name if compiler.dump_ll?
      end

      def emit(emit_targets : EmitTarget, output_filename, *, from_cache = true)
        filename = output_filename

        if emit_targets.asm?
          filename = "#{output_filename}.s"
          compiler.target_machine.emit_asm_to_file llvm_mod, filename
        end

        if emit_targets.llvm_bc?
          filename = "#{output_filename}.bc"
          if from_cache
            FileUtils.cp(bc_name, filename)
          else
            llvm_mod.write_bitcode_to_file(filename)
          end
        end

        if emit_targets.llvm_ir?
          filename = "#{output_filename}.ll"
          llvm_mod.print_to_file filename
        end

        if emit_targets.obj?
          filename = "#{output_filename}#{@object_extension}"
          if from_cache
            FileUtils.cp(object_name, filename)
          else
            compile_to_object(filename, optimize: false)
          end
        end
      rescue ex
        # LLVM reports file system errors (eg. a missing output directory)
        # as a plain error string; rewrap it so it surfaces as a proper
        # error message instead of a compiler bug report.
        raise CompilerError.new("Could not write output file '#{filename}': #{ex.message}", :FAILURE)
      end

      def object_name
        Crystal.relative_filename("#{@output_dir}/#{object_filename}")
      end

      def object_filename
        @name + @object_extension
      end

      # The object files this unit is linked as: one, or one per part.
      def object_filenames : Array(String)
        return [object_filename] if @part_count == 1

        Array.new(@part_count) { |index| "#{@name}.p#{index}of#{@part_count}#{@object_extension}" }
      end

      def object_names : Array(String)
        object_filenames.map { |filename| Crystal.relative_filename("#{@output_dir}/#{filename}") }
      end

      def temporary_object_name
        Crystal.relative_filename("#{@output_dir}/#{object_filename}.tmp")
      end

      def bc_name
        "#{@output_dir}/#{@name}.bc"
      end

      def bc_name_new
        "#{@output_dir}/#{@name}.new.bc"
      end

      # The record of the bitcode this unit's object files were built from.
      def hash_record_name
        "#{@output_dir}/#{@name}#{CachedObjectRecord::FILE_EXTENSION}"
      end

      def ll_name
        "#{@output_dir}/#{@name}.ll"
      end
    end
  end
end
