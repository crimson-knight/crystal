{% if flag?(:use_openssl) %}
  require "openssl"
{% else %}
  require "crystal/vendor/beryl"
{% end %}

class HTTP::Client
  {% if flag?(:use_openssl) %}
    # The TLS settings type `HTTP::Client` and `HTTP::WebSocket` take:
    # `OpenSSL::SSL::Context::Client` in a `-Duse_openssl` build.
    alias TLSClientContext = OpenSSL::SSL::Context::Client

    # :nodoc:
    alias TLSClientSocket = OpenSSL::SSL::Socket::Client

    # Returns the TLS settings used for `tls: true` and for `https://` and
    # `wss://` URIs given no context: OpenSSL's defaults.
    def self.default_tls_context : TLSClientContext
      TLSClientContext.new
    end

    # :nodoc:
    def self.open_tls_socket(io : IO, context : TLSClientContext, hostname : String) : TLSClientSocket
      TLSClientSocket.new(io, context: context, sync_close: true, hostname: hostname)
    end
  {% else %}
    # The TLS settings type `HTTP::Client` and `HTTP::WebSocket` take. TLS
    # runs on Beryl (TLS 1.3, written in Crystal; no OpenSSL is linked) unless
    # the program is built with `-Duse_openssl`, which selects
    # `OpenSSL::SSL::Context::Client` for one release.
    #
    # ```
    # context = HTTP::Client::TLSClientContext.new # system roots, name checked
    # context.ca_certificates = "/path/to/ca.pem"  # or trust one CA only
    # HTTP::Client.get("https://example.com", tls: context)
    #
    # # A client certificate, for a server that asks for one (mutual TLS)
    # context.certificate_chain = "/path/to/client.pem"
    # context.private_key = "/path/to/client.key"
    #
    # HTTP::Client.get("https://localhost:8443", tls: HTTP::Client::TLSClientContext.insecure) # no verification
    # ```
    alias TLSClientContext = Crystal::Beryl::TLS::Context::Client

    # :nodoc:
    alias TLSClientSocket = Crystal::Beryl::TLS::Socket::Client

    # Returns the TLS settings used for `tls: true` and for `https://` and
    # `wss://` URIs given no context: the server's chain is checked against
    # the system roots (the file `SSL_CERT_FILE` names, else the operating
    # system bundle; Beryl's pinned Mozilla roots where neither exists) and
    # its certificate against the host name.
    def self.default_tls_context : TLSClientContext
      context = TLSClientContext.new
      if trust_store = system_trust_store
        context.trust_store = trust_store
      end
      context
    end

    # The alerts that mean the server and Beryl share no protocol version: a
    # server that stops at TLS 1.2 answers a TLS 1.3 ClientHello with one of
    # them (or with a TLS 1.2 ServerHello, refused with protocol_version).
    LIST_OF_TLS_VERSION_ALERTS = [
      Crystal::Beryl::TLS::AlertDescription::ProtocolVersion,
      Crystal::Beryl::TLS::AlertDescription::HandshakeFailure,
      Crystal::Beryl::TLS::AlertDescription::InsufficientSecurity,
    ]

    # :nodoc:
    #
    # Runs the TLS handshake over *io*. A server that cannot speak TLS 1.3
    # gets an error that says so, of the same class (`Crystal::Beryl::TLS::Error`).
    def self.open_tls_socket(io : IO, context : TLSClientContext, hostname : String) : TLSClientSocket
      TLSClientSocket.new(io, context: context, sync_close: true, hostname: hostname)
    rescue error : Crystal::Beryl::TLS::CertificateRejected
      raise error
    rescue error : Crystal::Beryl::TLS::Error
      raise error unless LIST_OF_TLS_VERSION_ALERTS.includes?(error.alert_description)
      raise Crystal::Beryl::TLS::Error.new(
        "#{hostname} did not agree to TLS 1.3 (#{error.message}). HTTP::Client speaks TLS 1.3 only; " \
        "build with -Duse_openssl to reach servers that stop at TLS 1.2", error.alert_description)
    end

    @@system_trust_store : Crystal::Beryl::Certificates::TrustStore? = nil
    @@has_looked_for_system_trust_store = false
    @@system_trust_store_mutex = Mutex.new

    # The system roots, read once per process and shared by every client
    # (a trust store is not changed after it is built), or `nil` when the
    # machine has no bundle.
    private def self.system_trust_store : Crystal::Beryl::Certificates::TrustStore?
      @@system_trust_store_mutex.synchronize do
        unless @@has_looked_for_system_trust_store
          @@has_looked_for_system_trust_store = true
          @@system_trust_store = read_system_trust_store
        end
        @@system_trust_store
      end
    end

    private def self.read_system_trust_store : Crystal::Beryl::Certificates::TrustStore?
      Crystal::Beryl::Certificates::TrustStore.system
    rescue Crystal::Beryl::Certificates::Error
      nil
    end
  {% end %}
end
