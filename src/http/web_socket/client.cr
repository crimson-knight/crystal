require "../client"
require "./core"

# Opening a WebSocket connection to a server, over TLS when the URI asks for
# it. This needs `HTTP::Client` and so OpenSSL; `require "http/web_socket"`
# brings it in, the server side (`HTTP::WebSocketHandler`) does not.
class HTTP::WebSocket
  # Opens a new websocket using the information provided by the URI. This will also handle the handshake
  # and will raise an exception if the handshake did not complete successfully. This method will also raise
  # an exception if the URI is missing the host and/or the path.
  #
  # Please note that the scheme will only be used to identify if TLS should be used or not. Therefore, schemes
  # apart from `wss` and `https` will be treated as the default which is `ws`.
  #
  # ```
  # require "http/web_socket"
  #
  # HTTP::WebSocket.new(URI.parse("ws://websocket.example.com/chat"))        # Creates a new WebSocket to `websocket.example.com`
  # HTTP::WebSocket.new(URI.parse("wss://websocket.example.com/chat"))       # Creates a new WebSocket with TLS to `websocket.example.com`
  # HTTP::WebSocket.new(URI.parse("http://websocket.example.com:8080/chat")) # Creates a new WebSocket to `websocket.example.com` on port `8080`
  # HTTP::WebSocket.new(URI.parse("ws://websocket.example.com/chat"),        # Creates a new WebSocket to `websocket.example.com` with an Authorization header
  #   HTTP::Headers{"Authorization" => "Bearer authtoken"})
  # HTTP::WebSocket.new(
  #   URI.parse("ws://user:password@websocket.example.com/chat")) # Creates a new WebSocket to `websocket.example.com` with an HTTP basic auth Authorization header
  # ```
  def self.new(uri : URI | String, headers : HTTP::Headers = HTTP::Headers.new) : self
    new(Protocol.new(uri, headers: headers))
  end

  # Opens a new websocket to the target host. This will also handle the handshake
  # and will raise an exception if the handshake did not complete successfully.
  #
  # ```
  # require "http/web_socket"
  #
  # HTTP::WebSocket.new("websocket.example.com", "/chat")            # Creates a new WebSocket to `websocket.example.com`
  # HTTP::WebSocket.new("websocket.example.com", "/chat", tls: true) # Creates a new WebSocket with TLS to `ẁebsocket.example.com`
  # ```
  def self.new(host : String, path : String, port : Int32? = nil, tls : HTTP::Client::TLSContext = nil, headers : HTTP::Headers = HTTP::Headers.new) : self
    new(Protocol.new(host, path, port, tls, headers))
  end
end

class HTTP::WebSocket::Protocol
  def self.new(host : String, path : String, port : Int32? = nil, tls : HTTP::Client::TLSContext = nil, headers : HTTP::Headers = HTTP::Headers.new, protocols : Enumerable(String)? = nil) : self
    {% if flag?(:without_openssl) %}
      if tls
        raise "WebSocket TLS is disabled because `-D without_openssl` was passed at compile time"
      end
    {% end %}

    port ||= tls ? 443 : 80

    socket = TCPSocket.new(host, port)
    accepted_protocol = nil
    begin
      {% if !flag?(:without_openssl) %}
        if tls
          if tls.is_a?(Bool) # true, but we want to get rid of the union
            context = OpenSSL::SSL::Context::Client.new
          else
            context = tls
          end
          socket = OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: host)
        end
      {% end %}

      random_key = Base64.strict_encode(StaticArray(UInt8, 16).new { rand(256).to_u8 })

      headers["Host"] = "#{host}:#{port}"
      headers["Connection"] = "Upgrade"
      headers["Upgrade"] = "websocket"
      headers["Sec-WebSocket-Version"] = VERSION
      headers["Sec-WebSocket-Key"] = random_key
      headers["Sec-WebSocket-Protocol"] = protocols.join(",") if protocols && !protocols.empty?

      path = "/" if path.empty?
      handshake = HTTP::Request.new("GET", path, headers)
      handshake.to_io(socket)
      socket.flush

      handshake_response = HTTP::Client::Response.from_io(socket, ignore_body: true)
      unless handshake_response.status.switching_protocols?
        raise Socket::Error.new("Handshake got denied. Status code was #{handshake_response.status.code}.")
      end

      challenge_response = Protocol.key_challenge(random_key)
      unless handshake_response.headers["Sec-WebSocket-Accept"]? == challenge_response
        raise Socket::Error.new("Handshake got denied. Server did not verify WebSocket challenge.")
      end

      if protocols && !protocols.empty?
        if server_protocol = handshake_response.headers["Sec-WebSocket-Protocol"]?
          unless protocols.includes?(server_protocol)
            raise Socket::Error.new("Handshake got denied. Server responded with an invalid Sec-WebSocket-Protocol.")
          end
          accepted_protocol = server_protocol
        else
          raise Socket::Error.new("Handshake got denied. Server did not respond with Sec-WebSocket-Protocol.")
        end
      end
    rescue exc
      socket.close
      raise exc
    end

    new(socket, masked: true, protocol: accepted_protocol)
  end

  def self.new(uri : URI | String, headers : HTTP::Headers = HTTP::Headers.new) : self
    uri = URI.parse(uri) if uri.is_a?(String)

    if (host = uri.hostname) && (path = uri.request_target)
      tls = uri.scheme.in?("https", "wss")
      if (user = uri.user) && (password = uri.password)
        headers["Authorization"] ||= "Basic #{Base64.strict_encode("#{user}:#{password}")}"
      end
      return new(host, path, uri.port, tls, headers)
    end

    raise ArgumentError.new("No host or path specified which are required.")
  end
end
