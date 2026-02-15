# :nodoc:
class Crystal::EventLoop::Wasi < Crystal::EventLoop
  def self.default_file_blocking?
    false
  end

  def self.default_socket_blocking?
    false
  end

  def initialize(parallelism : Int32)
  end

  # Runs the event loop.
  #
  # In the WASI single-threaded environment, this performs a single poll_oneoff
  # call. When *blocking* is true, it waits using a clock subscription to avoid
  # busy-waiting. When false, it uses a zero timeout to return immediately.
  #
  # Returns `true` to indicate there may be more work to do. In WASI's
  # single-threaded cooperative model, this always returns `true` since we
  # cannot track registered event count without additional infrastructure.
  def run(blocking : Bool) : Bool
    if blocking
      # Block for a short duration to avoid busy-waiting.
      # Use a 100ms poll to allow the runtime to periodically check for work.
      poll_timeout_ns = 100_000_000_u64 # 100ms in nanoseconds
    else
      # Non-blocking: use a zero timeout so poll_oneoff returns immediately
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

  # Creates a timeout_event.
  def create_timeout_event(fiber) : Crystal::EventLoop::Event
    raise NotImplementedError.new("Crystal::Wasi::EventLoop.create_timeout_event")
  end

  # Creates a write event for a file descriptor.
  def create_fd_write_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::EventLoop::Event
    raise NotImplementedError.new("Crystal::Wasi::EventLoop.create_fd_write_event")
  end

  # Creates a read event for a file descriptor.
  def create_fd_read_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::EventLoop::Event
    raise NotImplementedError.new("Crystal::Wasi::EventLoop.create_fd_read_event")
  end

  def pipe(read_blocking : Bool?, write_blocking : Bool?) : {IO::FileDescriptor, IO::FileDescriptor}
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#pipe")
  end

  def open(path : String, flags : Int32, permissions : File::Permissions, blocking : Bool?) : {System::FileDescriptor::Handle, Bool} | Errno | WinError
    raise NotImplementedError.new("Crystal::Wasi::EventLoop#open")
  end

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
    raise NotImplementedError.new("Crystal::EventLoop#reopened(FileDescriptor)")
  end

  def shutdown(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.evented_close
  end

  def close(file_descriptor : Crystal::System::FileDescriptor) : Nil
    file_descriptor.file_descriptor_close
  end

  def socket(family : ::Socket::Family, type : ::Socket::Type, protocol : ::Socket::Protocol) : {::Socket::Handle, Bool}
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#socket")
  end

  def socketpair(type : ::Socket::Type, protocol : ::Socket::Protocol, blocking : Bool) : {Handle, Handle}
    raise NotImplementedError.new("Crystal::EventLoop::Wasi#socketpair")
  end

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
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#receive_from"
  end

  def send_to(socket : ::Socket, slice : Bytes, address : ::Socket::Address) : Int32
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#send_to"
  end

  def connect(socket : ::Socket, address : ::Socket::Addrinfo | ::Socket::Address, timeout : ::Time::Span | ::Nil) : IO::Error?
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#connect"
  end

  def accept(socket : ::Socket) : ::Socket::Handle?
    raise NotImplementedError.new "Crystal::Wasi::EventLoop#accept"
  end

  def shutdown(socket : ::Socket) : Nil
    socket.evented_close
  end

  def close(socket : ::Socket) : Nil
    socket.socket_close
  end

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

  def add(timeout : Time::Span) : Nil
  end

  def add(timeout : Nil) : Nil
  end

  def free : Nil
  end

  def delete
  end
end
