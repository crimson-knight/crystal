module Crystal::System
  def self.hostname
    raise NotImplementedError.new("Crystal::System.hostname: hostname is not available in the WASM sandbox. WASI does not expose host system information.")
  end
end
