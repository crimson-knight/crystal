module Crystal::System::Signal
  def self.trap(signal, handler) : Nil
    raise NotImplementedError.new("Crystal::System::Signal.trap: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.trap_handler?(signal)
    raise NotImplementedError.new("Crystal::System::Signal.trap_handler?: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.reset(signal) : Nil
    raise NotImplementedError.new("Crystal::System::Signal.reset: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end

  def self.ignore(signal) : Nil
    raise NotImplementedError.new("Crystal::System::Signal.ignore: signal handling is not available in the WASM sandbox. WASI does not support signals.")
  end
end
