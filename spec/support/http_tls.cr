require "openssl"
require "http/client"
require "./ssl"

# An OpenSSL server context and an `HTTP::Client` context that skips
# verification. The client context is Beryl's by default and OpenSSL's in a
# `-Duse_openssl` build, so the HTTP specs run on whichever backend the
# build selects, against an OpenSSL server either way.
def http_tls_context_pair : {OpenSSL::SSL::Context::Server, HTTP::Client::TLSClientContext}
  server_context, _ = ssl_context_pair
  {server_context, insecure_http_client_context}
end

private def insecure_http_client_context : HTTP::Client::TLSClientContext
  {% if flag?(:use_openssl) %}
    context = HTTP::Client::TLSClientContext.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    context
  {% else %}
    HTTP::Client::TLSClientContext.insecure
  {% end %}
end
