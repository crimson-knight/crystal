require "../spec_helper"
require "http/server"
require "http/client"
require "../../../support/ssl"
require "../../../support/http_tls"

# HTTP::Client's TLS on Beryl, the default: certificates are verified by
# default, and a server that stops at TLS 1.2 gets an error that names
# TLS 1.3. The server is OpenSSL's, as in server_spec.cr.
private def with_tls_server(server_context : OpenSSL::SSL::Context::Server, &)
  server = HTTP::Server.new do |context|
    context.response.print "ok"
  end
  address = server.bind_tls "127.0.0.1", 0, server_context
  spawn { server.listen }
  begin
    yield address
  ensure
    server.close
  end
end

describe HTTP::Client do
  {% unless flag?(:use_openssl) %}
    describe "TLS on Beryl" do
      it "verifies the server's certificate by default" do
        server_context, _ = http_tls_context_pair
        with_tls_server(server_context) do |address|
          expect_raises(Crystal::Beryl::TLS::CertificateRejected) do
            HTTP::Client.get("https://#{address}/")
          end
        end
      end

      it "connects when verification is skipped" do
        server_context, client_context = http_tls_context_pair
        with_tls_server(server_context) do |address|
          HTTP::Client.get("https://#{address}/", tls: client_context).body.should eq "ok"
        end
      end

      it "names the TLS 1.3 requirement when the server stops at TLS 1.2" do
        server_context, client_context = http_tls_context_pair
        server_context.add_options(OpenSSL::SSL::Options::NO_TLS_V1_3)
        with_tls_server(server_context) do |address|
          expect_raises(Crystal::Beryl::TLS::Error, /TLS 1\.3/) do
            HTTP::Client.get("https://#{address}/", tls: client_context)
          end
        end
      end

      it "uses the system roots for the default context" do
        HTTP::Client.default_tls_context.verify_mode.should eq Crystal::Beryl::TLS::VerifyMode::Peer
      end
    end
  {% end %}
end
