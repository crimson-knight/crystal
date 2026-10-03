require "c/signal"
require "c/unistd"
{% if flag?(:linux) && flag?(:gnu) && !flag?(:interpreted) %}
  require "c/spawn"
{% end %}

struct Crystal::System::Process
  def self.spawn(prepared_args, shell, env, clear_env, input, output, error, chdir, &)
    {% if LibC.has_method?(:posix_spawnp) %}
      # `posix_spawn` doesn't support changing the working directory portably
      # (`addchdir_np` needs glibc 2.29), so that case still forks.
      unless chdir
        return posix_spawn(prepared_args, env, clear_env, input, output, error) do |errno, command|
          yield errno, command
        end
      end
    {% end %}

    r, w = FileDescriptor.system_pipe

    envp = Env.make_envp(env, clear_env)

    pid = self.fork_for_exec
    if !pid
      LibC.close(r)
      begin
        self.try_replace(prepared_args, envp, input, output, error, chdir)
        byte = 1_u8
        errno = Errno.value.to_i32
        FileDescriptor.write_fully(w, pointerof(byte))
        FileDescriptor.write_fully(w, pointerof(errno))
      rescue ex
        byte = 0_u8
        message = ex.inspect_with_backtrace
        FileDescriptor.write_fully(w, pointerof(byte))
        FileDescriptor.write_fully(w, message.to_slice)
      ensure
        LibC.close(w)
        LibC._exit 127
      end
    end

    LibC.close(w)
    reader_pipe = IO::FileDescriptor.new(r)

    begin
      case reader_pipe.read_byte
      when nil
        # Pipe was closed, no error
      when 0
        # Error message coming
        message = reader_pipe.gets_to_end
        raise RuntimeError.new("Error executing process: '#{prepared_args[0]}': #{message}")
      when 1
        # Errno coming
        # can't use IO#read_bytes(Int32) because we skipped system/network
        # endianness check when writing the integer while read_bytes would;
        # we thus read it in the same as order as written
        buf = uninitialized StaticArray(UInt8, 4)
        reader_pipe.read_fully(buf.to_slice)
        raise_exception_from_errno(prepared_args[0], Errno.new(buf.unsafe_as(Int32))) do |errno, command|
          yield errno, command
        end
      else
        raise RuntimeError.new("BUG: Invalid error response received from subprocess")
      end
    ensure
      reader_pipe.close
    end

    pid
  end

  {% if LibC.has_method?(:posix_spawnp) %}
    # Spawns without `fork`: glibc starts the child with `clone(CLONE_VM |
    # CLONE_VFORK)`, so the cost doesn't grow with the parent's memory. A
    # `fork` copies the page tables first, which takes ~0.1s for a parent of a
    # few GB such as the compiler.
    #
    # The child ends up as with `fork_for_exec` + `try_replace`: standard
    # streams redirected, an empty signal mask and the trapped signals reset to
    # their default action (ignored ones stay ignored, as with `fork`).
    private def self.posix_spawn(prepared_args, env, clear_env, input, output, error, &)
      envp = Env.make_envp(env, clear_env)

      file_actions = uninitialized LibC::PosixSpawnFileActionsT
      attr = uninitialized LibC::PosixSpawnattrT
      check_spawn_call("posix_spawn_file_actions_init", LibC.posix_spawn_file_actions_init(pointerof(file_actions)))
      begin
        check_spawn_call("posix_spawnattr_init", LibC.posix_spawnattr_init(pointerof(attr)))
        begin
          add_spawn_io(pointerof(file_actions), input, ORIGINAL_STDIN)
          add_spawn_io(pointerof(file_actions), output, ORIGINAL_STDOUT)
          add_spawn_io(pointerof(file_actions), error, ORIGINAL_STDERR)

          sigmask = uninitialized LibC::SigsetT
          LibC.sigemptyset(pointerof(sigmask))
          sigdefault = Crystal::System::Signal.trapped_sigset

          check_spawn_call("posix_spawnattr_setsigmask", LibC.posix_spawnattr_setsigmask(pointerof(attr), pointerof(sigmask)))
          check_spawn_call("posix_spawnattr_setsigdefault", LibC.posix_spawnattr_setsigdefault(pointerof(attr), pointerof(sigdefault)))
          flags = LibC::POSIX_SPAWN_SETSIGMASK | LibC::POSIX_SPAWN_SETSIGDEF
          check_spawn_call("posix_spawnattr_setflags", LibC.posix_spawnattr_setflags(pointerof(attr), flags.to_i16))

          pid = uninitialized LibC::PidT
          file, argv = prepared_args
          ret = LibC.posix_spawnp(pointerof(pid), file, pointerof(file_actions), pointerof(attr), argv, envp)
          unless ret == 0
            raise_exception_from_errno(file, Errno.new(ret)) do |errno, command|
              yield errno, command
            end
          end
          pid
        ensure
          LibC.posix_spawnattr_destroy(pointerof(attr))
        end
      ensure
        LibC.posix_spawn_file_actions_destroy(pointerof(file_actions))
      end
    end

    # Mirrors `reopen_io`, as file actions run in the child.
    private def self.add_spawn_io(file_actions, src_io : IO::FileDescriptor, dst_io : IO::FileDescriptor)
      if src_io.closed?
        check_spawn_call("posix_spawn_file_actions_addclose", LibC.posix_spawn_file_actions_addclose(file_actions, dst_io.fd))
      else
        src_io = to_real_fd(src_io)
        # `reopen_io` makes the descriptor blocking in the child; the flag is
        # shared with the parent's file description, so set it here instead.
        FileDescriptor.set_blocking(src_io.fd, true)
        # A dup2 onto itself clears FD_CLOEXEC (glibc >= 2.29, POSIX 2024).
        check_spawn_call("posix_spawn_file_actions_adddup2", LibC.posix_spawn_file_actions_adddup2(file_actions, src_io.fd, dst_io.fd))
      end
    end

    private def self.check_spawn_call(name, ret)
      raise RuntimeError.from_os_error(name, Errno.new(ret)) unless ret == 0
    end
  {% end %}

  private def self.fork_for_exec
    pid, errno = lock_write do
      pthread_disable_cancelstate do
        block_signals do |sigmask|
          pid = LibC.fork
          if pid == 0
            # forked process

            Crystal::System::Signal.after_fork_before_exec

            # reset sigmask (inherited on exec)
            LibC.sigemptyset(sigmask)
          end
          {pid, Errno.value}
        end
      end
    end

    case pid
    when 0
      # forked process
      nil
    when -1
      # forking process: error
      raise RuntimeError.from_os_error("fork", errno)
    else
      # forking process: success
      pid
    end
  end

  # This method is similar to `.replace` (used for `Process.exec`) with some
  # differences because we're limited in what we can do in the pre-exec phase
  # between `fork` and `exec`.
  private def self.try_replace(prepared_args, envp, input, output, error, chdir)
    reopen_io(input, ORIGINAL_STDIN)
    reopen_io(output, ORIGINAL_STDOUT)
    reopen_io(error, ORIGINAL_STDERR)

    if chdir
      if 0 != LibC.chdir(chdir)
        return
      end
    end

    execvpe(*prepared_args, envp)
  end
end
