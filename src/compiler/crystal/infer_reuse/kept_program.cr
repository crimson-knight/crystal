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

      # This process keeps the program for as long as it serves. Give the
      # free space type inference left behind back to the system before the
      # code generation child shares the heap, so neither process keeps it.
      InferReuse.return_free_memory_to_os if compiler.shares_typed_program_with_build_server?

      loop do
        if pid = InferReuse.fork_process
          exit_code = InferReuse.wait_for(pid)
          exit exit_code unless exit_code == 0

          hand_over(status_writer)
          File.write("#{socket_path}.pid", "#{::Process.pid}\n")
          walk_owner_shapes(kept)
          kept, status_writer = Server.new(listener, socket_path).serve(kept)
          # A build child that re-typed an edit: generate code again.
        else
          listener.close
          status_writer.close
          InferReuse.mark_in_parallel
          return kept.node
        end
      end
    end

    # Walks the typed defs of the kept program for owner shape sharing once
    # the code generation child is done and the build handed over, so that
    # the next build child walks only what its edit changed (see
    # `OwnerShapeSharing::WalkCache`). Walking while the child built added
    # what the walk allocates (1.0 to 1.3 GB in an Amber app of 300
    # resources) to the build's memory peak; now it is idle time of the
    # server, and a build that comes at once waits for the walk in the
    # listening queue. The walks only save time: a failure leaves the
    # program without them.
    private def walk_owner_shapes(kept : KeptProgram) : Nil
      OwnerShapeSharing.walk_all(kept.program, kept.node)
    rescue ex
      kept.program.owner_shape_walk_cache = nil
      STDERR.puts "owner shapes: the build server could not walk its program: #{ex.message}" if ENV["CRYSTAL_OWNER_SHAPES_STATS"]?
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
