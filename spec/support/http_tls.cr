require "openssl"
require "http/client"
require "./ssl"

# An OpenSSL server context and an `HTTP::Client` context that skips
# verification. The client context is Beryl's, so the HTTP specs run Beryl's
# client against an OpenSSL server.
def http_tls_context_pair : {OpenSSL::SSL::Context::Server, HTTP::Client::TLSClientContext}
  server_context, _ = ssl_context_pair
  {server_context, insecure_http_client_context}
end

private def insecure_http_client_context : HTTP::Client::TLSClientContext
  HTTP::Client::TLSClientContext.insecure
end
