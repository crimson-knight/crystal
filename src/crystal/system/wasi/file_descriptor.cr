require "../unix/file_descriptor"

# :nodoc:
module Crystal::System::FileDescriptor
  def self.from_stdio(fd)
    # TODO: WASI doesn't offer a way to detect if a 'fd' is a TTY.
    IO::FileDescriptor.new(fd).tap(&.flush_on_newline=(true))
  end

  def self.fcntl(fd, cmd, arg = 0)
    FileDescriptor.fcntl(fd, cmd, arg)
  end

  private def system_fcntl(cmd, arg = 0)
    FileDescriptor.fcntl(fd, cmd, arg)
  end

  def self.get_blocking(fd : Handle)
    raise NotImplementedError.new("Crystal::System::FileDescriptor.get_blocking: blocking mode control is not available in the WASM sandbox. WASI file descriptors are always blocking.")
  end

  def self.set_blocking(fd : Handle, value : Bool)
    raise NotImplementedError.new("Crystal::System::FileDescriptor.set_blocking: blocking mode control is not available in the WASM sandbox. WASI file descriptors are always blocking.")
  end

  protected def system_blocking_init(blocking : Bool?)
  end

  private def system_reopen(other : IO::FileDescriptor)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_reopen: reopening file descriptors is not available in the WASM sandbox."
  end

  private def system_flock_shared(blocking)
    raise NotImplementedError.new "Crystal::System::File#system_flock_shared: file locking is not available in the WASM sandbox. WASI does not support POSIX file locks."
  end

  private def system_flock_exclusive(blocking)
    raise NotImplementedError.new "Crystal::System::File#system_flock_exclusive: file locking is not available in the WASM sandbox. WASI does not support POSIX file locks."
  end

  private def system_flock_unlock
    raise NotImplementedError.new "Crystal::System::File#system_flock_unlock: file locking is not available in the WASM sandbox. WASI does not support POSIX file locks."
  end

  private def flock(op : LibC::FlockOp, blocking : Bool = true)
    raise NotImplementedError.new "Crystal::System::File#flock: file locking is not available in the WASM sandbox. WASI does not support POSIX file locks."
  end

  private def system_echo(enable : Bool)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_echo: terminal control is not available in the WASM sandbox. WASI does not support TTY operations."
  end

  private def system_echo(enable : Bool, & : ->)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_echo: terminal control is not available in the WASM sandbox. WASI does not support TTY operations."
  end

  private def system_raw(enable : Bool)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_raw: terminal control is not available in the WASM sandbox. WASI does not support TTY operations."
  end

  private def system_raw(enable : Bool, & : ->)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_raw: terminal control is not available in the WASM sandbox. WASI does not support TTY operations."
  end
end
