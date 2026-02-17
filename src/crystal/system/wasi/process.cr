require "c/stdlib"
require "c/unistd"

struct Crystal::System::Process
  getter pid : LibC::PidT

  def initialize(@pid : LibC::PidT)
  end

  def release
    raise NotImplementedError.new("Process#release: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def wait
    raise NotImplementedError.new("Process#wait: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def exists?
    raise NotImplementedError.new("Process#exists?: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def terminate(*, graceful)
    raise NotImplementedError.new("Process#terminate: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.exit(status)
    LibC.exit(status)
  end

  def self.pid
    # TODO: WebAssembly doesn't have the concept of processes.
    1
  end

  def self.pgid
    raise NotImplementedError.new("Process.pgid: process groups are not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.pgid(pid)
    raise NotImplementedError.new("Process.pgid: process groups are not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.ppid
    raise NotImplementedError.new("Process.ppid: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.signal(pid, signal)
    raise NotImplementedError.new("Process.signal: sending signals is not available in the WASM sandbox. WASI does not support signals or process management.")
  end

  @[Deprecated("Use `#on_terminate` instead")]
  def self.on_interrupt(&handler : ->) : Nil
    raise NotImplementedError.new("Process.on_interrupt: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.on_terminate(&handler : ::Process::ExitReason ->) : Nil
    raise NotImplementedError.new("Process.on_terminate: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.ignore_interrupts! : Nil
    raise NotImplementedError.new("Process.ignore_interrupts!: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.restore_interrupts! : Nil
    raise NotImplementedError.new("Process.restore_interrupts!: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.start_interrupt_loop : Nil
  end

  def self.debugger_present? : Bool
    false
  end

  def self.exists?(pid)
    raise NotImplementedError.new("Process.exists?: process management is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.times
    raise NotImplementedError.new("Process.times: process timing is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.fork
    raise NotImplementedError.new("Process.fork: process spawning is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.fork(&)
    raise NotImplementedError.new("Process.fork: process spawning is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.spawn(command, args, shell, env, clear_env, input, output, error, chdir)
    raise NotImplementedError.new("Process.spawn: process spawning is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.replace(command, args, shell, env, clear_env, input, output, error, chdir)
    raise NotImplementedError.new("Process.replace: process spawning is not available in the WASM sandbox. WASI does not support process management.")
  end

  def self.chroot(path)
    raise NotImplementedError.new("Process.chroot: changing root directory is not available in the WASM sandbox. WASI does not support process management.")
  end
end
