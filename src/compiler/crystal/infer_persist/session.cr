module Crystal::InferPersist
  # One build's use of the snapshot in its cache folder: `#load` before type
  # inference, `#save` after it, `#finish` once the build ends.
  class Session
    getter filename : String
    @writer_pid : LibC::PidT? = nil
    @temporary_filename : String? = nil
    @save_seconds : Float64? = nil

    def initialize(@compiler : Compiler, cache_directory : String, @list_of_arguments : Array(String))
      @filename = File.join(cache_directory, FILENAME)
    end

    # A session for this build, or `nil` when persisted type inference is
    # off or does not apply (no incremental cache, no code generation, or a
    # build the build server runs).
    def self.for(compiler : Compiler, cache_directory : String) : Session?
      return nil unless InferPersist.enabled?
      list_of_arguments = compiler.infer_persist_argv || return nil
      new(compiler, cache_directory, list_of_arguments)
    end

    # Loads the snapshot and asks the build server's `Retyper` whether this
    # build can reuse it. Returns the re-typed program and its node when it
    # can. Returns `nil` when there is no usable snapshot; the caller types
    # the program as usual. When the reuse is refused after loading, this
    # process is replaced by a fresh one that does not load (see
    # `NO_LOAD_VARIABLE`), so the fresh build does not carry the loaded
    # program.
    def load(fresh_program : Program) : {Program, ASTNode}?
      return nil if InferPersist.load_disabled?
      reason, roots, load_seconds, bytesize = read_snapshot
      unless roots
        InferReuse::Report.new(false, reason).write
        return nil
      end

      kept = roots.kept
      program = kept.program
      adopt(program, fresh_program)
      request = InferReuse::BuildRequest.new(@list_of_arguments, Dir.current, ENV.to_h)
      retyper = InferReuse::Retyper.new(kept, request)
      retyper.loaded_from_snapshot = {load_seconds, bytesize}
      decision = retyper.run
      unless decision.reused?
        run_fresh
      end
      {program, kept.node}
    end

    # Reads the snapshot. Returns why it can't be used, or the roots with the
    # load time and file size.
    private def read_snapshot : {String, Roots?, Float64, Int64}
      unless File.exists?(@filename)
        return {"no snapshot in the cache folder", nil, 0.0, 0_i64}
      end
      started = Time.instant
      bytesize = File.size(@filename).to_i64
      File.open(@filename) do |file|
        magic = Bytes.new(MAGIC.bytesize)
        file.read_fully?(magic)
        return {"the snapshot is not a snapshot file", nil, 0.0, bytesize} unless String.new(magic) == MAGIC
        header_bytesize = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        return {"the snapshot header is damaged", nil, 0.0, bytesize} if header_bytesize > 1_u32 << 24
        header = Header.from_json(file.read_string(header_bytesize))
        if mismatch = header.mismatch(Header.current(@list_of_arguments))
          return {mismatch, nil, 0.0, bytesize}
        end
        externals = [@compiler.as(Void*), STDOUT.as(Void*), STDERR.as(Void*)]
        GC.disable
        begin
          roots = SnapshotReader.new(ByteInput.new(file), externals).read
        ensure
          GC.enable
        end
        Location.restore(roots.location_tables)
        {"loaded", roots, (Time.instant - started).total_seconds, bytesize}
      end
    rescue ex : JSON::ParseException | IO::Error | Error | TypeCastError | IndexError
      {"the snapshot could not be read: #{ex.message}", nil, 0.0, 0_i64}
    end

    # Gives the loaded *program* what belongs to this process: the compiler,
    # its output, progress tracker and target machine, and the parts of the
    # program the snapshot can't hold (hash default blocks) or whose order
    # depended on object addresses (union keys).
    private def adopt(program : Program, fresh_program : Program) : Nil
      program.compiler = @compiler
      program.stdout = fresh_program.stdout
      program.progress_tracker = @compiler.progress_tracker
      program.target_machine = fresh_program.target_machine
      program.color = fresh_program.color?
      program.adopt_after_snapshot
      VirtualFile.current_program_files = program.virtual_files
    end

    # Runs this build again in a new process that types the program from
    # scratch.
    private def run_fresh : NoReturn
      executable = ::Process.executable_path || raise Error.new("can't find the compiler executable")
      STDOUT.flush
      STDERR.flush
      env = ENV.to_h
      env[NO_LOAD_VARIABLE] = "1"
      ::Process.exec(executable, @list_of_arguments, env: env, clear_env: true)
    end

    # Writes the snapshot of *program* as type inference left it. With the
    # default `fork` mode a forked process writes it while this process goes
    # on; `#finish` waits for it. A build with warnings, or one whose reads
    # the record can't compare, removes the old snapshot instead (no later
    # build could reuse either).
    def save(program : Program, node : ASTNode) : Nil
      record = program.infer_reuse_record
      if record.nil? || record.blocked_reason || !@compiler.warnings.infos.empty?
        File.delete?(@filename)
        return
      end
      kept = InferReuse::KeptProgram.new(@compiler, program, node, record, @list_of_arguments, Dir.current, ENV.to_h)
      roots = Roots.new(kept, Location.tables)
      Dir.mkdir_p(File.dirname(@filename))
      temporary_filename = "#{@filename}.#{::Process.pid}.tmp"
      @temporary_filename = temporary_filename

      if ENV[SAVE_MODE_VARIABLE]? == "sync"
        started = Time.instant
        write_file(temporary_filename, roots)
        @save_seconds = (Time.instant - started).total_seconds
        return
      end

      if pid = InferReuse.fork_process
        @writer_pid = pid
      else
        status = 0
        begin
          GC.disable
          write_file(temporary_filename, roots)
        rescue ex
          STDERR.puts "Warning: the type-inference snapshot was not written: #{ex.message}"
          status = 1
        end
        LibC._exit(status)
      end
    end

    private def write_file(filename : String, roots : Roots) : Nil
      fd = LibC.open(filename, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_TRUNC, 0o644)
      raise Error.new("can't create #{filename}: #{Errno.value.message}") if fd < 0
      begin
        output = ByteOutput.new(fd)
        output.write_bytes(MAGIC.to_slice)
        header_json = Header.current(@list_of_arguments).to_json
        header_bytes = Bytes.new(4)
        IO::ByteFormat::LittleEndian.encode(header_json.bytesize.to_u32, header_bytes)
        output.write_bytes(header_bytes)
        output.write_bytes(header_json.to_slice)
        SnapshotWriter.new(roots, @compiler).write(output)
      ensure
        LibC.close(fd)
      end
    end

    # Puts the snapshot in place when the build succeeded (and its writer
    # did), else throws it away.
    def finish(success : Bool) : Nil
      temporary_filename = @temporary_filename || return
      @temporary_filename = nil
      if pid = @writer_pid
        @writer_pid = nil
        started = Time.instant
        written = InferReuse.wait_for(pid) == 0
        @save_seconds = (Time.instant - started).total_seconds
      else
        written = true
      end
      if success && written && File.exists?(temporary_filename)
        File.rename(temporary_filename, @filename)
      else
        File.delete?(temporary_filename)
        File.delete?(@filename)
      end
      if @compiler.progress_tracker.stats?
        STDOUT.puts "Semantic (infer persist): snapshot #{success && written ? "saved" : "not saved"}, waited #{@save_seconds.try(&.round(2))} s, #{File.info?(@filename).try(&.size) || 0} bytes"
      end
    end
  end
end
