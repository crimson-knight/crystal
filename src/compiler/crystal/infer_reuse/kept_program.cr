module Crystal::InferReuse
  # A program as type inference left it, with what the build that typed it
  # read: kept by the server for the next build.
  class KeptProgram
    getter compiler : Compiler
    getter program : Program
    property node : ASTNode
    getter record : SourceRecord
    getter argv : Array(String)
    getter working_directory : String
    getter env : Hash(String, String)

    def initialize(@compiler, @program, @node, @record, @argv, @working_directory, @env)
    end
  end

  # Keeps the program of a build the server started, once type inference is
  # done (`Compiler#compile_configure_program` calls `#after_semantic`).
  class Holder
    def initialize(@handoff : Handoff)
    end

    # Forks the process that generates code and returns the program's node
    # in it. This process waits: when code generation fails it exits with its
    # exit code; when it succeeds this process becomes the server, keeps the
    # program, and serves builds until one can reuse it, which again returns
    # here in a forked build child.
    def after_semantic(compiler : Compiler, program : Program, node : ASTNode, record : SourceRecord) : ASTNode
      listener = UNIXServer.new(fd: @handoff.listening_fd)
      listener.close_on_exec = true
      status_writer = IO::FileDescriptor.new(@handoff.status_fd)
      status_writer.close_on_exec = true
      socket_path = @handoff.socket_path

      argv = compiler.infer_reuse_argv || [] of String
      kept = KeptProgram.new(compiler, program, node, record, argv, Dir.current, ENV.to_h)

      loop do
        if pid = InferReuse.fork_process
          exit_code = InferReuse.wait_for(pid)
          exit exit_code unless exit_code == 0

          hand_over(status_writer)
          File.write("#{socket_path}.pid", "#{::Process.pid}\n")
          kept, status_writer = Server.new(listener, socket_path).serve(kept)
          # A build child that re-typed an edit: generate code again.
        else
          listener.close
          status_writer.close
          return kept.node
        end
      end
    end

    # Tells the old server that this process serves from now on, after
    # closing the build's output so that the old server sees it end.
    private def hand_over(status_writer : IO::FileDescriptor) : Nil
      STDOUT.flush
      STDERR.flush
      null = File.open(File::NULL, "w")
      STDOUT.reopen(null)
      STDERR.reopen(null)
      status_writer.write_byte(Server::HANDOVER)
      status_writer.close
    end
  end
end
