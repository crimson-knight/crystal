require "openssl"
require "../server"

# The TLS listener of `HTTP::Server`.
#
# `require "http/server"` alone links no OpenSSL. These methods, and the
# `tls://` scheme of `HTTP::Server#bind`, are defined once the program
# requires `openssl` (directly, or through `http/client`, `http/web_socket`
# or `http`) or this file, in either order.
#
# ```
# require "http/server"
# require "http/server/tls"
#
# server = HTTP::Server.new { }
# context = OpenSSL::SSL::Context::Server.new
# context.certificate_chain = "openssl.crt"
# context.private_key = "openssl.key"
# server.bind_tls "127.0.0.1", 8080, context
# ```
class HTTP::Server
  # Creates an `OpenSSL::SSL::Server` and adds it as a socket.
  #
  # The SSL server wraps a `TCPServer` listening on `host:port`.
  #
  # ```
  # require "http/server"
  # require "http/server/tls"
  #
  # server = HTTP::Server.new { }
  # context = OpenSSL::SSL::Context::Server.new
  # context.certificate_chain = "openssl.crt"
  # context.private_key = "openssl.key"
  # server.bind_tls "127.0.0.1", 8080, context
  # ```
  def bind_tls(host : String, port : Int32, context : OpenSSL::SSL::Context::Server, reuse_port : Bool = false) : Socket::IPAddress
    tcp_server = TCPServer.new(host, port, reuse_port: reuse_port)
    server = OpenSSL::SSL::Server.new(tcp_server, context)
    server.start_immediately = false

    begin
      bind(server)
    rescue exc
      server.close
      raise exc
    end

    tcp_server.local_address
  end

  # Creates an `OpenSSL::SSL::Server` and adds it as a socket.
  #
  # The SSL server wraps a `TCPServer` listening on an unused port on *host*.
  #
  # ```
  # require "http/server"
  # require "http/server/tls"
  #
  # server = HTTP::Server.new { }
  # context = OpenSSL::SSL::Context::Server.new
  # context.certificate_chain = "openssl.crt"
  # context.private_key = "openssl.key"
  # address = server.bind_tls "127.0.0.1", context
  # ```
  def bind_tls(host : String, context : OpenSSL::SSL::Context::Server) : Socket::IPAddress
    bind_tls(host, 0, context)
  end

  # Creates an `OpenSSL::SSL::Server` and adds it as a socket.
  #
  # The SSL server wraps a `TCPServer` listening on an unused port on *host*.
  #
  # ```
  # require "http/server"
  # require "http/server/tls"
  #
  # server = HTTP::Server.new { }
  # context = OpenSSL::SSL::Context::Server.new
  # context.certificate_chain = "openssl.crt"
  # context.private_key = "openssl.key"
  # address = server.bind_tls Socket::IPAddress.new("127.0.0.1", 8000), context
  # ```
  def bind_tls(address : Socket::IPAddress, context : OpenSSL::SSL::Context::Server) : Socket::IPAddress
    bind_tls(address.address, address.port, context)
  end
end
