# :nodoc:
#
# Readiness waiting for file descriptors and sockets under the WASI event loop.
#
# Upstream dropped `IO::Evented` in 1.21 (#17032); the fork's WASI event loop
# still polls FD_READ/FD_WRITE subscriptions through `poll_oneoff` and resumes
# the waiting fiber through `resume_read`/`resume_write`, so it keeps this
# mixin of its own. WASI preview 1 has one thread, so the waiting fibers are
# plain deques rather than thread-local values.
module Crystal::EventLoop::Wasi::Evented
  @read_timed_out = false
  @write_timed_out = false

  @readers : Deque(Fiber)? = nil
  @writers : Deque(Fiber)? = nil

  @read_event : Crystal::EventLoop::Event? = nil
  @write_event : Crystal::EventLoop::Event? = nil

  # :nodoc:
  def resume_read(timed_out = false) : Nil
    @read_timed_out = timed_out

    if reader = @readers.try &.shift?
      reader.enqueue
    end
  end

  # :nodoc:
  def resume_write(timed_out = false) : Nil
    @write_timed_out = timed_out

    if writer = @writers.try &.shift?
      writer.enqueue
    end
  end

  # :nodoc:
  def evented_wait_readable(timeout = @read_timeout, *, raise_if_closed = true, &) : Nil
    readers = @readers ||= Deque(Fiber).new
    readers << Fiber.current
    add_read_event(timeout)
    Fiber.suspend

    if @read_timed_out
      @read_timed_out = false
      yield
    end

    check_open if raise_if_closed
  end

  private def add_read_event(timeout = @read_timeout) : Nil
    event = @read_event ||= Crystal::EventLoop.current.as(Crystal::EventLoop::Wasi).create_fd_read_event(self)
    event.add timeout
  end

  # :nodoc:
  def evented_wait_writable(timeout = @write_timeout, *, raise_if_closed = true, &) : Nil
    writers = @writers ||= Deque(Fiber).new
    writers << Fiber.current
    add_write_event(timeout)
    Fiber.suspend

    if @write_timed_out
      @write_timed_out = false
      yield
    end

    check_open if raise_if_closed
  end

  private def add_write_event(timeout = @write_timeout) : Nil
    event = @write_event ||= Crystal::EventLoop.current.as(Crystal::EventLoop::Wasi).create_fd_write_event(self)
    event.add timeout
  end

  # :nodoc:
  def evented_close : Nil
    @read_event.try &.free
    @read_event = nil
    @write_event.try &.free
    @write_event = nil

    @readers.try &.each(&.enqueue)
    @readers = nil
    @writers.try &.each(&.enqueue)
    @writers = nil
  end

  # :nodoc:
  def evented_resume_pending_readers : Nil
    if (readers = @readers) && !readers.empty?
      add_read_event
    end
  end

  # :nodoc:
  def evented_resume_pending_writers : Nil
    if (writers = @writers) && !writers.empty?
      add_write_event
    end
  end
end

module Crystal::System::FileDescriptor
  include Crystal::EventLoop::Wasi::Evented
end

module Crystal::System::Socket
  include Crystal::EventLoop::Wasi::Evented
end
