lib LibC
  # Starts a new session, so the build server leaves its client's.
  fun setsid : PidT
end

lib LibGC
  # Starts the parallel marker threads again in a forked child (Boehm GC).
  fun start_mark_threads = GC_start_mark_threads : Void
end

module Crystal::InferReuse
  # Forks this process and returns the child's process id in the parent and
  # `nil` in the child.
  #
  # The build server runs with one scheduler thread (`CRYSTAL_WORKERS=1`, see
  # `Server`), so the forked child, which keeps only the calling thread, has
  # every scheduler it needs. The child gets a new event loop, its own signal
  # pipe and an empty child-process table, as `Process.fork` gives a program
  # built without multithreading, and starts the collector's marker threads.
  def self.fork_process : LibC::PidT?
    STDOUT.flush
    STDERR.flush

    new_mask = uninitialized LibC::SigsetT
    old_mask = uninitialized LibC::SigsetT
    # Signals wait until the child has its own signal pipe; the collector's
    # stop-the-world signals stay open.
    LibC.sigfillset(pointerof(new_mask))
    LibC.sigdelset(pointerof(new_mask), Crystal::System::Thread.sig_suspend)
    LibC.sigdelset(pointerof(new_mask), Crystal::System::Thread.sig_resume)
    LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(new_mask), pointerof(old_mask))
    begin
      pid = LibC.fork
      errno = Errno.value
      if pid == 0
        LibGC.start_mark_threads
        Crystal::EventLoop.current.after_fork
        Crystal::System::Signal.after_fork
        Crystal::System::SignalChildHandler.after_fork
      end
    ensure
      LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(old_mask), nil)
    end

    case pid
    when 0
      nil
    when -1
      raise RuntimeError.from_os_error("fork", errno)
    else
      pid
    end
  end

  # Waits for the forked process *pid* and returns its exit code (128 plus
  # the signal number when a signal ended it).
  def self.wait_for(pid : LibC::PidT) : Int32
    status = ::Process.new(Crystal::System::Process.new(pid)).wait
    if status.normal_exit?
      status.exit_code
    else
      128 + (status.exit_signal?.try(&.value) || 0)
    end
  end
end
