# :nodoc:
class Crystal::EventLoop::Wasi < Crystal::EventLoop
  # Represents a pending event registered via `Event#add`. The event loop's
  # `run` method collects all pending events, polls them via `poll_oneoff`,
  # and fires the appropriate callbacks to resume waiting fibers.
  private record PendingEvent,
    event : Wasi::Event,
    timeout_ns : UInt64?

  def self.default_file_blocking?
    false
  end

  def self.default_socket_blocking?
    false
  end

  def initialize(parallelism : Int32)
    @pending_events = Array(PendingEvent).new
  end

  # Registers a pending event to be polled in the next `run` iteration.
  # Called by `Event#add` to schedule the event for processing.
  protected def add_pending_event(event : Wasi::Event, timeout_ns : UInt64?) : Nil
    @pending_events << PendingEvent.new(event, timeout_ns)
  end

  # Removes a pending event from the poll list.
  # Called by `Event#delete` to cancel a previously registered event.
  protected def remove_pending_event(event : Wasi::Event) : Nil
    @pending_events.reject! { |pe| pe.event == event }
  end

  # Runs the event loop.
  #
  # In the WASI single-threaded environment, this collects all pending
  # event subscriptions and performs a single `poll_oneoff` call. When
  # *blocking* is true and there are no pending events, it waits using a
  # clock subscription to avoid busy-waiting. When false, it uses a zero
  # timeout to return immediately.
  #
  # Returns `true` to indicate there may be more work to do. In WASI's
  # single-threaded cooperative model, this always returns `true` since we
  # cannot track registered event count without additional infrastructure.
  def run(blocking : Bool) : Bool
    if @pending_events.empty?
      # No pending events: use a simple clock poll to avoid busy-waiting
      # or return immediately.
      if blocking
        poll_timeout_ns = 100_000_000_u64 # 100ms in nanoseconds
      else
        poll_timeout_ns = 0_u64
      end

      subscription = LibWasi::Subscription.new
      subscription.userdata = 0_u64
      subscription.u_tag = LibWasi::EventType::Clock
      clock = LibWasi::SubscriptionClock.new
      clock.id = 1_u64 # CLOCK_MONOTONIC
      clock.timeout = poll_timeout_ns
      clock.precision = 0_u64
      clock.flags = LibWasi::SubClockFlags::None
      subscription.u = LibWasi::SubscriptionU.new
      subscription.u.clock = clock

      event = LibWasi::Event.new
      nevents = LibWasi::Size.new(0)

      LibWasi.poll_oneoff(pointerof(subscription), pointerof(event), 1, pointerof(nevents))
      return true
    end

    # Build subscriptions array from pending events. Each pending event
    # becomes one or two subscriptions (the event itself, plus an optional
    # clock timeout subscription for FD events).
    pending = @pending_events.dup
    @pending_events.clear

    subscriptions = Array(LibWasi::Subscription).new(pending.size * 2)
    # Map from subscription userdata index back to the pending event index
    # and whether this subscription is the timeout companion.
    sub_map = Array({Int32, Bool}).new(pending.size * 2)

    pending.each_with_index do |pe, idx|
      ev = pe.event
      userdata_base = (idx * 2).to_u64

      case ev.kind
      when .timeout?
        # Clock subscription for timeout events
        sub = LibWasi::Subscription.new
        sub.userdata = userdata_base
        sub.u_tag = LibWasi::EventType::Clock
        clock = LibWasi::SubscriptionClock.new
        clock.id = 1_u64 # CLOCK_MONOTONIC
        clock.timeout = pe.timeout_ns || 0_u64
        clock.precision = 0_u64
        clock.flags = LibWasi::SubClockFlags::None
        sub.u = LibWasi::SubscriptionU.new
        sub.u.clock = clock
        subscriptions << sub
        sub_map << {idx, false}
      when .fd_read?
        # FD_READ subscription
        sub = LibWasi::Subscription.new
        sub.userdata = userdata_base
        sub.u_tag = LibWasi::EventType::FdRead
        fd_rw = LibWasi::SubscriptionFdReadwrite.new
        fd_rw.file_descriptor = ev.fd
        sub.u = LibWasi::SubscriptionU.new
        sub.u.fd_read = fd_rw
        subscriptions << sub
        sub_map << {idx, false}

        # Optional timeout companion
        if timeout_ns = pe.timeout_ns
          timeout_sub = LibWasi::Subscription.new
          timeout_sub.userdata = userdata_base + 1
          timeout_sub.u_tag = LibWasi::EventType::Clock
          clock = LibWasi::SubscriptionClock.new
          clock.id = 1_u64 # CLOCK_MONOTONIC
          clock.timeout = timeout_ns
          clock.precision = 0_u64
          clock.flags = LibWasi::SubClockFlags::None
          timeout_sub.u = LibWasi::SubscriptionU.new
          timeout_sub.u.clock = clock
          subscriptions << timeout_sub
          sub_map << {idx, true}
        end
      when .fd_write?
        # FD_WRITE subscription
        sub = LibWasi::Subscription.new
        sub.userdata = userdata_base
        sub.u_tag = LibWasi::EventType::FdWrite
        fd_rw = LibWasi::SubscriptionFdReadwrite.new
        fd_rw.file_descriptor = ev.fd
        sub.u = LibWasi::SubscriptionU.new
        sub.u.fd_write = fd_rw
        subscriptions << sub
        sub_map << {idx, false}

        # Optional timeout companion
        if timeout_ns = pe.timeout_ns
          timeout_sub = LibWasi::Subscription.new
          timeout_sub.userdata = userdata_base + 1
          timeout_sub.u_tag = LibWasi::EventType::Clock
          clock = LibWasi::SubscriptionClock.new
          clock.id = 1_u64 # CLOCK_MONOTONIC
          clock.timeout = timeout_ns
          clock.precision = 0_u64
          clock.flags = LibWasi::SubClockFlags::None
          timeout_sub.u = LibWasi::SubscriptionU.new
          timeout_sub.u.clock = clock
          subscriptions << timeout_sub
          sub_map << {idx, true}
        end
      end
    end

    # If no subscriptions were built (shouldn't happen, but be safe), just
    # do a minimal clock poll.
    if subscriptions.empty?
      return true
    end

    # Add a clock subscription for non-blocking mode so poll_oneoff returns
    # immediately if no FD events are ready yet.
    unless blocking
      zero_sub = LibWasi::Subscription.new
      zero_sub.userdata = UInt64::MAX # sentinel: not mapped to any pending event
      zero_sub.u_tag = LibWasi::EventType::Clock
      clock = LibWasi::SubscriptionClock.new
      clock.id = 1_u64
      clock.timeout = 0_u64
      clock.precision = 0_u64
      clock.flags = LibWasi::SubClockFlags::None
      zero_sub.u = LibWasi::SubscriptionU.new
      zero_sub.u.clock = clock
      subscriptions << zero_sub
      sub_map << {-1, false} # sentinel index
    end

    nsubs = subscriptions.size.to_u32
    events = Pointer(LibWasi::Event).malloc(nsubs)
    nevents = LibWasi::Size.new(0)

    LibWasi.poll_oneoff(subscriptions.to_unsafe, events, nsubs, pointerof(nevents))

    # Track which pending event indices have been fired so we don't
    # double-fire (e.g. if both the FD event and its timeout fire).
    fired = Set(Int32).new

    nevents.times do |i|
      ev = events[i]
      userdata = ev.userdata

      # Skip sentinel subscriptions
      next if userdata == UInt64::MAX

      # Find the subscription mapping
      sub_idx = subscriptions.index { |s| s.userdata == userdata }
      next unless sub_idx
      pending_idx, is_timeout = sub_map[sub_idx]
      next if pending_idx < 0
      next if fired.includes?(pending_idx)

      pe = pending[pending_idx]
      wasi_event = pe.event

      case wasi_event.kind
      when .timeout?
        # Timeout event: check the fiber's timeout_select_action
        if fiber = wasi_event.fiber
          if select_action = fiber.timeout_select_action
            fiber.timeout_select_action = nil
            if select_action.time_expired?
              fiber.enqueue
            end
          end
        end
        fired << pending_idx
      when .fd_read?
        if io = wasi_event.io
          if is_timeout
            io.resume_read(timed_out: true)
          else
            io.resume_read
          end
        end
        fired << pending_idx
      when .fd_write?
        if io = wasi_event.io
          if is_timeout
            io.resume_write(timed_out: true)
          else
            io.resume_write
          end
        end
        fired << pending_idx
      end
    end

    # Re-enqueue any pending events that were not fired (e.g. in non-blocking
    # mode, FD events that weren't ready yet).
    pending.each_with_index do |pe, idx|
      unless fired.includes?(idx)
        @pending_events << pe
      end
    end

    true
  end

  # Interrupts a blocking run loop.
  #
  # In WASI's single-threaded model, there is no concurrent thread to
  # interrupt. This is a no-op since the run loop will return on its own
  # after the poll timeout expires.
  def interrupt : Nil
    # No-op: WASI is single-threaded; the run loop will return after
    # the poll_oneoff timeout expires.
  end

  # Suspends the current fiber for *duration* using WASI poll_oneoff with
  # a clock subscription.
  def sleep(duration : ::Time::Span) : Nil
    # Convert the duration to nanoseconds for WASI poll_oneoff.
    # Clamp to zero to handle negative durations gracefully.
    timeout_ns = duration.total_nanoseconds
    timeout_ns = 0.0 if timeout_ns < 0
    timeout_ns = timeout_ns.to_u64

    subscription = LibWasi::Subscription.new
    subscription.userdata = 0_u64
    subscription.u_tag = LibWasi::EventType::Clock
    clock = LibWasi::SubscriptionClock.new
    clock.id = 1_u64 # CLOCK_MONOTONIC
    clock.timeout = timeout_ns
    clock.precision = 0_u64
    clock.flags = LibWasi::SubClockFlags::None
    subscription.u = LibWasi::SubscriptionU.new
    subscription.u.clock = clock

    event = LibWasi::Event.new
    nevents = LibWasi::Size.new(0)

    LibWasi.poll_oneoff(pointerof(subscription), pointerof(event), 1, pointerof(nevents))
  end

  # Creates a timeout event for use by `Fiber#timeout` (select expressions).
  #
  # When `add(timeout)` is called on the returned event, it registers a
  # CLOCK subscription with the event loop. The event loop's `run` method
  # will poll it via `poll_oneoff` and check the fiber's
  # `timeout_select_action` when the timer fires.
  def create_timeout_event(fiber) : Crystal::EventLoop::Event
    Wasi::Event.new(self, Wasi::Event::Kind::Timeout, fiber: fiber)
  end

  # Creates a write event for a file descriptor.
  #
  # When `add(timeout)` is called on the returned event, it registers an
  # FD_WRITE subscription with the event loop. The event loop's `run`
  # method will poll it and call `io.resume_write` when the FD is ready
  # or `io.resume_write(timed_out: true)` on timeout.
  def create_fd_write_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::EventLoop::Event
    Wasi::Event.new(self, Wasi::Event::Kind::FdWrite, io: io, fd: io.fd)
  end

  # Creates a read event for a file descriptor.
  #
  # When `add(timeout)` is called on the returned event, it registers an
  # FD_READ subscription with the event loop. The event loop's `run`
  # method will poll it and call `io.resume_read` when the FD is ready
  # or `io.resume_read(timed_out: true)` on timeout.
  def create_fd_read_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::EventLoop::Event
    Wasi::Event.new(self, Wasi::Event::Kind::FdRead, io: io, fd: io.fd)
  end

  def pipe(read_blocking : Bool?, write_blocking : Bool?) : {IO::FileDescriptor, IO::FileDescriptor}
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#pipe: pipes are not available in the WASM sandbox. WASI does not support creating pipes.")
  end

  # Opens a file at *path* using WASI's `path_open` syscall.
  #
  # Translates POSIX open flags (O_RDONLY, O_WRONLY, O_CREAT, etc.) to the
  # corresponding WASI `OpenFlags`, `FdFlags`, and `Rights`. Uses the
  # preopened directory mechanism to resolve the path.
  #
  # In WASI, all file I/O is blocking by nature (single-threaded), so the
  # *blocking* parameter is accepted but effectively always true.
  def open(path : String, flags : Int32, permissions : File::Permissions, blocking : Bool?) : {System::FileDescriptor::Handle, Bool} | Errno | WinError
    path.check_no_null_byte

    # Resolve the path against WASI preopened directories.
    begin
      parent_fd, relative_path = Crystal::System::Wasi.find_path_preopen(path)
    rescue ex : RuntimeError
      return Errno::ENOENT
    end

    # Translate POSIX flags to WASI types.
    oflags = LibWasi::OpenFlags.new(0)
    oflags |= LibWasi::OpenFlags::Creat if flags.bits_set?(LibC::O_CREAT)
    oflags |= LibWasi::OpenFlags::Trunc if flags.bits_set?(LibC::O_TRUNC)
    oflags |= LibWasi::OpenFlags::Excl if flags.bits_set?(LibC::O_EXCL)

    fdflags = LibWasi::FdFlags.new(0)
    fdflags |= LibWasi::FdFlags::Append if flags.bits_set?(LibC::O_APPEND)
    fdflags |= LibWasi::FdFlags::NonBlock if flags.bits_set?(LibC::O_NONBLOCK)
    fdflags |= LibWasi::FdFlags::Sync if flags.bits_set?(LibC::O_SYNC)

    # Determine rights based on read/write mode.
    # O_RDONLY, O_WRONLY, O_RDWR are bitmask flags in WASI libc.
    rights_base = LibWasi::Rights::None
    rights_inheriting = LibWasi::Rights::None

    is_read = flags.bits_set?(LibC::O_RDONLY)
    is_write = flags.bits_set?(LibC::O_WRONLY)

    if is_read
      rights_base |= LibWasi::Rights::FdRead |
        LibWasi::Rights::FdSeek |
        LibWasi::Rights::FdTell |
        LibWasi::Rights::FdFilestatGet |
        LibWasi::Rights::FdReaddir |
        LibWasi::Rights::PollFdReadwrite
    end

    if is_write
      rights_base |= LibWasi::Rights::FdWrite |
        LibWasi::Rights::FdSeek |
        LibWasi::Rights::FdTell |
        LibWasi::Rights::FdFilestatGet |
        LibWasi::Rights::FdDatasync |
        LibWasi::Rights::FdSync |
        LibWasi::Rights::FdAllocate |
        LibWasi::Rights::FdFilestatSetSize |
        LibWasi::Rights::FdFilestatSetTimes |
        LibWasi::Rights::PollFdReadwrite
    end

    # If neither read nor write flag is set, default to read rights.
    if !is_read && !is_write
      rights_base |= LibWasi::Rights::FdRead |
        LibWasi::Rights::FdSeek |
        LibWasi::Rights::FdTell |
        LibWasi::Rights::FdFilestatGet |
        LibWasi::Rights::PollFdReadwrite
    end

    err = LibWasi.path_open(
      parent_fd,
      LibWasi::LookupFlags::SymlinkFollow,
      relative_path,
      oflags,
      rights_base,
      rights_inheriting,
      fdflags,
      out fd
    )

    unless err.success?
      # Map common WASI errors to Errno values directly to avoid
      # the WasiError#to_errno method which references Errno constants
      # that may not be defined on the wasm32 target.
      errno = case err
              when .acces?  then Errno::EACCES
              when .noent?  then Errno::ENOENT
              when .exist?  then Errno::EEXIST
              when .isdir?  then Errno::EISDIR
              when .notdir? then Errno::ENOTDIR
              when .inval?  then Errno::EINVAL
              when .badf?   then Errno::EBADF
              else               Errno::EIO
              end
      return errno
    end

    # In WASI, all I/O is effectively blocking (single-threaded runtime).
    {fd, true}
  end

  # NOTE: The evented_read/evented_write helpers below call Fiber.suspend
  # via IO::Evented#evented_wait_readable/evented_wait_writable. This requires
  # working fiber context switching (Asyncify), which is not yet implemented
  # for wasm32. These methods compile but will not work correctly at runtime
  # for non-blocking file descriptors until fiber support is added.

  def read(file_descriptor : Crystal::System::FileDescriptor, slice : Bytes) : Int32
    evented_read(file_descriptor, "Error reading file_descriptor") do
      LibC.read(file_descriptor.fd, slice, slice.size).tap do |return_code|
        if return_code == -1 && Errno.value == Errno::EBADF
          raise IO::Error.new "File not open for reading", target: file_descriptor
        end
      end
    end
  end

  def wait_readable(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.evented_wait_readable(raise_if_closed: false) do
      raise IO::TimeoutError.new("Read timed out")
    end
  end

  def write(file_descriptor : Crystal::System::FileDescriptor, slice : Bytes) : Int32
    evented_write(file_descriptor, "Error writing file_descriptor") do
      LibC.write(file_descriptor.fd, slice, slice.size).tap do |return_code|
        if return_code == -1 && Errno.value == Errno::EBADF
          raise IO::Error.new "File not open for writing", target: file_descriptor
        end
      end
    end
  end

  def wait_writable(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.evented_wait_writable(raise_if_closed: false) do
      raise IO::TimeoutError.new("Write timed out")
    end
  end

  def reopened(file_descriptor : Crystal::System::FileDescriptor) : Nil
    raise NotImplementedError.new("Crystal::EventLoop#reopened(FileDescriptor): reopening file descriptors is not available in the WASM sandbox.")
  end

  def shutdown(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.evented_close
  end

  def close(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.file_descriptor_close
  end

  def socket(family : ::Socket::Family, type : ::Socket::Type, protocol : ::Socket::Protocol, blocking : Bool?) : {::Socket::Handle, Bool}
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#socket: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def socketpair(type : ::Socket::Type, protocol : ::Socket::Protocol) : Tuple({::Socket::Handle, ::Socket::Handle}, Bool)
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#socketpair: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  # NOTE: Socket evented I/O methods below also depend on Fiber.suspend
  # via IO::Evented. See the note above read(file_descriptor, ...) for details.

  def read(socket : ::Socket, slice : Bytes) : Int32
    evented_read(socket, "Error reading socket") do
      LibC.recv(socket.fd, slice, slice.size, 0).to_i32
    end
  end

  def wait_readable(socket : ::Socket) : Nil
    socket.evented_wait_readable do
      raise IO::TimeoutError.new("Read timed out")
    end
  end

  def write(socket : ::Socket, slice : Bytes) : Int32
    evented_write(socket, "Error writing to socket") do
      LibC.send(socket.fd, slice, slice.size, 0)
    end
  end

  def wait_writable(socket : ::Socket) : Nil
    socket.evented_wait_writable do
      raise IO::TimeoutError.new("Write timed out")
    end
  end

  def receive_from(socket : ::Socket, slice : Bytes) : Tuple(Int32, ::Socket::Address)
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#receive_from: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2."
  end

  def send_to(socket : ::Socket, slice : Bytes, address : ::Socket::Address) : Int32
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#send_to: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2."
  end

  def connect(socket : ::Socket, address : ::Socket::Addrinfo | ::Socket::Address, timeout : ::Time::Span | ::Nil) : IO::Error?
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#connect: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2."
  end

  def accept(socket : ::Socket) : {::Socket::Handle, Bool}?
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#accept: socket operations are not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2."
  end

  def shutdown(socket : ::Socket) : Nil
    socket.evented_close
  end

  def close(socket : ::Socket) : Nil
    socket.socket_close
  end

  # NOTE: evented_read and evented_write loop on EAGAIN and call
  # evented_wait_readable/evented_wait_writable, which suspend the current
  # fiber. This requires Asyncify-based fiber support that is not yet
  # implemented. For blocking file descriptors (the common case in WASI),
  # the yield will never be called because reads/writes complete immediately.

  def evented_read(target, errno_msg : String, &) : Int32
    loop do
      bytes_read = yield
      if bytes_read != -1
        # `to_i32` is acceptable because `Slice#size` is an Int32
        return bytes_read.to_i32
      end

      if Errno.value == Errno::EAGAIN
        target.evented_wait_readable do
          raise IO::TimeoutError.new("Read timed out")
        end
      else
        raise IO::Error.from_errno(errno_msg, target: target)
      end
    end
  ensure
    target.evented_resume_pending_readers
  end

  def evented_write(target, errno_msg : String, &) : Int32
    loop do
      bytes_written = yield
      if bytes_written != -1
        return bytes_written.to_i32
      end

      if Errno.value == Errno::EAGAIN
        target.evented_wait_writable do
          raise IO::TimeoutError.new("Write timed out")
        end
      else
        raise IO::Error.from_errno(errno_msg, target: target)
      end
    end
  ensure
    target.evented_resume_pending_writers
  end
end

struct Crystal::EventLoop::Wasi::Event
  include Crystal::EventLoop::Event

  enum Kind : UInt8
    Timeout # Clock-based timeout (used by Fiber#timeout / select)
    FdRead  # Wait for file descriptor to be readable
    FdWrite # Wait for file descriptor to be writable
  end

  getter kind : Kind
  getter fiber : Fiber?
  getter io : IO::Evented?
  getter fd : Int32

  def initialize(@event_loop : Crystal::EventLoop::Wasi, @kind : Kind, *,
                 @fiber : Fiber? = nil, @io : IO::Evented? = nil, @fd : Int32 = -1)
    @active = false
  end

  # Registers this event with the event loop to be polled in the next
  # `run` iteration. The *timeout* specifies how long to wait: for timeout
  # events this is the timer duration; for FD events this is the maximum
  # wait time before signaling a timeout.
  def add(timeout : Time::Span) : Nil
    timeout_ns = timeout.total_nanoseconds
    timeout_ns = 0.0 if timeout_ns < 0
    @active = true
    @event_loop.add_pending_event(self, timeout_ns.to_u64)
  end

  # Registers this event with the event loop with no timeout.
  # For timeout events, this uses a zero-duration timer (fires immediately).
  # For FD events, this waits indefinitely until the FD is ready.
  def add(timeout : Nil) : Nil
    @active = true
    case @kind
    when .timeout?
      # A timeout event with no duration fires immediately on next run.
      @event_loop.add_pending_event(self, 0_u64)
    else
      # FD event with no timeout: wait indefinitely (no companion clock sub).
      @event_loop.add_pending_event(self, nil)
    end
  end

  # Frees the event, removing it from the event loop if active.
  def free : Nil
    delete if @active
  end

  # Cancels the event, removing it from the pending events list.
  def delete
    @event_loop.remove_pending_event(self) if @active
    @active = false
  end
end
