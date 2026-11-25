lib LibC
  # Starts a new session, so the build server leaves its client's.
  fun setsid : PidT
end

lib LibGC
  # Starts the collector's parallel marker threads again in a forked child.
  fun start_mark_threads = GC_start_mark_threads
end

module Crystal::InferReuse
  # Forks this process and returns the child's process id in the parent and
  # `nil` in the child.
  #
  # The build server runs with one scheduler thread (`CRYSTAL_WORKERS=1`, see
  # `Server`), so the forked child, which keeps only the calling thread, has
  # every scheduler it needs. The child gets a new event loop, its own signal
  # pipe and an empty child-process table, as `Process.fork` gave a program
  # built without multithreading (Crystal 1.22 dropped `Process.fork`; these
  # hooks stay for this fork alone). The collector marks on one thread in the
  # child (Boehm GC turns parallel marking off in a forked child) until it
  # calls `.mark_in_parallel`.
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
      # No collection runs while the process is copied.
      GC.lock_write
      pid = LibC.fork
      errno = Errno.value
      GC.unlock_write
      if pid == 0
        Thread.keep_only_current_after_fork
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

  # Starts the collector's marker threads in a forked child that forks no
  # build process again (the code generation child): marking a program of
  # several gigabytes on one thread made code generation about twice as slow.
  def self.mark_in_parallel : Nil
    LibGC.start_mark_threads
  end

  # Collects the heap twice with free blocks unmapped: the first collection
  # frees the garbage, the second coalesces the free blocks so they can be
  # unmapped.
  def self.return_free_memory_to_os : Nil
    {% unless flag?(:gc_none) || flag?(:wasm32) %}
      LibGC.set_force_unmap_on_gcollect(1)
      2.times { GC.collect }
      LibGC.set_force_unmap_on_gcollect(0)
    {% end %}
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
