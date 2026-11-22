module Crystal::InferReuse
  # The build server: a process that accepts builds on a Unix socket and runs
  # each one in a forked *build child*.
  #
  # A server without a typed program (the one `crystal internal-infer-server`
  # starts) types every build from scratch. A server that holds the program of
  # its last build (`KeptProgram`) first asks `Retyper` whether the new build
  # can reuse it.
  #
  # The status pipe of a build child carries one byte, `H`, when the child's
  # build succeeded and the child became the server; the old server then
  # reports the result and exits. When the pipe closes without it the build
  # failed (or the child exec'd a compiler that ended), and the old server
  # reports the child's exit code and keeps serving.
  class Server
    COMMAND  = "internal-infer-server"
    HANDOVER = 'H'.ord.to_u8

    # When this process started waiting for a build, while it waits; `nil`
    # while it builds, and in every process forked from it.
    @@idle_since : Time::Instant? = nil
    @@idle_watcher_started = false

    def initialize(@listener : UNIXServer, @socket_path : String)
    end

    # `crystal internal-infer-server <socket>`: detaches from the client and
    # serves until it is idle for `idle_time`.
    def self.main(socket_path : String) : NoReturn
      detach(socket_path)
      File.delete?(socket_path)
      listener = UNIXServer.new(socket_path)
      File.write("#{socket_path}.pid", "#{::Process.pid}\n")
      new(listener, socket_path).serve(nil)
      exit 0
    end

    # Forks once more so the server is not a child of the client, starts a new
    # session, and sends its output to `<socket>.log`.
    private def self.detach(socket_path : String) : Nil
      if InferReuse.fork_process
        exit 0
      end
      LibC.setsid
      log = File.open("#{socket_path}.log", "a")
      STDIN.reopen(File.open(File::NULL))
      STDOUT.reopen(log)
      STDERR.reopen(log)
    end

    def self.idle_time : Time::Span
      (ENV[IDLE_VARIABLE]?.try(&.to_i?) || DEFAULT_IDLE_SECONDS).seconds
    end

    # Serves builds. Returns only in a build child whose request `kept` could
    # reuse (with the program re-typed for it); every other process this
    # loop makes ends inside it.
    def serve(kept : KeptProgram?) : {KeptProgram, IO::FileDescriptor}
      watch_idle_time
      loop do
        @@idle_since = Time.instant
        client = @listener.accept? || exit(0)
        @@idle_since = nil
        result = serve_one(client, kept)
        return result if result
      end
    end

    # One watcher per process (a forked child has its parent's): it ends the
    # process once it has waited `idle_time` for a build.
    private def watch_idle_time : Nil
      return if @@idle_watcher_started
      @@idle_watcher_started = true
      idle_time = Server.idle_time
      spawn do
        loop do
          sleep 5.seconds
          idle_since = @@idle_since
          if idle_since && Time.instant - idle_since > idle_time
            File.delete?(@socket_path)
            File.delete?("#{@socket_path}.pid")
            exit 0
          end
        end
      end
    end

    # Runs one build. Returns the kept program and status pipe in a build
    # child that reused it; returns `nil` in the server.
    private def serve_one(client : UNIXSocket, kept : KeptProgram?) : {KeptProgram, IO::FileDescriptor}?
      line = client.gets
      unless line
        client.close
        return nil
      end
      request = BuildRequest.from_json(line)

      # The build writes to blocking ends, as to a terminal or a file.
      stdout_reader, stdout_writer = IO.pipe(read_blocking: false, write_blocking: true)
      stderr_reader, stderr_writer = IO.pipe(read_blocking: false, write_blocking: true)
      status_reader, status_writer = IO.pipe(read_blocking: false, write_blocking: true)

      unless pid = InferReuse.fork_process
        # The build child.
        client.close
        stdout_reader.close
        stderr_reader.close
        status_reader.close
        STDOUT.reopen(stdout_writer)
        STDERR.reopen(stderr_writer)
        stdout_writer.close
        stderr_writer.close
        return run_build_child(request, kept, status_writer)
      end

      stdout_writer.close
      stderr_writer.close
      status_writer.close

      handed_over = relay(client, stdout_reader, stderr_reader, status_reader)
      exit_code = handed_over ? 0 : InferReuse.wait_for(pid)
      begin
        Frame.write(client, :exit_code, exit_code.to_s.to_slice)
      rescue IO::Error
        # The client is gone; the build ran all the same.
      end
      client.close

      if handed_over
        # The build child serves from now on, with the newer program.
        @listener.close
        exit 0
      end
      nil
    end

    # Copies the build's output to the client until the build child and every
    # process it started closed it, then reads the status pipe. Returns
    # whether the child became the server.
    private def relay(client : UNIXSocket, stdout_reader : IO, stderr_reader : IO, status_reader : IO) : Bool
      lock = Mutex.new
      done = Channel(Nil).new(2)
      {% for stream in %w(stdout stderr) %}
        spawn do
          buffer = Bytes.new(16 * 1024)
          while (count = {{stream.id}}_reader.read(buffer)) > 0
            lock.synchronize do
              Frame.write(client, :{{stream.id}}, buffer[0, count])
            rescue IO::Error
              # The client is gone: keep draining so the build never blocks.
            end
          end
          {{stream.id}}_reader.close
          done.send(nil)
        end
      {% end %}

      status = status_reader.read_byte
      status_reader.close
      2.times { done.receive }
      status == HANDOVER
    end

    # In the build child: re-type the edit in the kept program and return it
    # (the caller generates code and becomes the server), or exec a fresh
    # compiler for the request.
    private def run_build_child(request : BuildRequest, kept : KeptProgram?, status_writer : IO::FileDescriptor) : {KeptProgram, IO::FileDescriptor}
      Dir.cd(request.working_directory)
      ENV.clear
      request.env.each { |name, value| ENV[name] = value }
      ENV["CRYSTAL_WORKERS"] = "1"

      reason = "the server holds no typed program yet"
      if kept
        decision = Retyper.new(kept, request).run
        if decision.reused?
          return {kept, status_writer}
        end
        reason = decision.reason
      end

      run_fresh_build(request, status_writer, reason)
    end

    # Replaces the build child with a compiler that types the whole program,
    # handing it the listening socket and the status pipe so that it can
    # become the server when its build succeeds.
    private def run_fresh_build(request : BuildRequest, status_writer : IO::FileDescriptor, reason : String) : NoReturn
      Report.new(false, reason).write
      @listener.close_on_exec = false
      status_writer.close_on_exec = false
      env = request.env.dup
      env["CRYSTAL_WORKERS"] = "1"
      env[HANDOFF_VARIABLE] = "#{@listener.fd},#{status_writer.fd}"
      executable = ::Process.executable_path || raise Error.new("can't find the compiler executable")
      ::Process.exec(executable, request.argv, env: env, clear_env: true, chdir: request.working_directory)
    end
  end
end
