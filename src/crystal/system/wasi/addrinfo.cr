module Crystal::System::Addrinfo
  alias Handle = NoReturn

  protected def initialize(addrinfo : Handle)
    raise NotImplementedError.new("Crystal::System::Addrinfo#initialize: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def system_ip_address : ::Socket::IPAddress
    raise NotImplementedError.new("Crystal::System::Addrinfo#system_ip_address: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def to_unsafe
    raise NotImplementedError.new("Crystal::System::Addrinfo#to_unsafe: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def self.getaddrinfo(domain, service, family, type, protocol, timeout, flags = 0) : Handle
    raise NotImplementedError.new("Crystal::System::Addrinfo.getaddrinfo: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def self.next_addrinfo(addrinfo : Handle) : Handle
    raise NotImplementedError.new("Crystal::System::Addrinfo.next_addrinfo: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end

  def self.free_addrinfo(addrinfo : Handle)
    raise NotImplementedError.new("Crystal::System::Addrinfo.free_addrinfo: DNS resolution is not available in WASI Preview 1. Networking support will be added when Crystal targets WASI Preview 2.")
  end
end
