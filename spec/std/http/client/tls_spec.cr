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

# A Beryl TLS server that requires a client certificate issued by the test CA
# in spec/std/data/beryl_client_certificates. It answers each request with
# "ok" and sends the subject of the certificate the client presented on
# *peer_subjects*, or the error its handshake ended with on *server_errors*.
private def with_client_certificate_server(&)
  context = Crystal::Beryl::TLS::Context::Server.new
  context.certificate_chain = datapath("beryl_client_certificates", "server.pem")
  context.private_key = datapath("beryl_client_certificates", "server.key")
  context.client_verify_mode = Crystal::Beryl::TLS::ClientVerifyMode::Required
  context.client_ca_certificates = datapath("beryl_client_certificates", "ca.pem")

  tcp_server = TCPServer.new("127.0.0.1", 0)
  peer_subjects = Channel(String).new(1)
  server_errors = Channel(Exception).new(1)
  spawn do
    while tcp_socket = tcp_server.accept?
      begin
        tls_socket = Crystal::Beryl::TLS::Socket::Server.new(tcp_socket, context, sync_close: true)
        peer_certificate = tls_socket.peer_certificate
        peer_subjects.send(peer_certificate ? peer_certificate.subject.to_s : "")
        HTTP::Request.from_io(tls_socket)
        tls_socket << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        tls_socket.close
      rescue error
        tcp_socket.close
        server_errors.send(error)
      end
    end
  end

  begin
    yield tcp_server.local_address, peer_subjects, server_errors
  ensure
    tcp_server.close
  end
end

private def client_certificate_context(*, has_certificate : Bool) : HTTP::Client::TLSClientContext
  context = HTTP::Client::TLSClientContext.new
  context.ca_certificates = datapath("beryl_client_certificates", "ca.pem")
  if has_certificate
    context.certificate_chain = datapath("beryl_client_certificates", "client.pem")
    context.private_key = datapath("beryl_client_certificates", "client.key")
  end
  context
end

describe HTTP::Client do
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

    it "presents the context's client certificate to a server that requires one" do
      with_client_certificate_server do |address, peer_subjects, _|
        uri = URI.parse("https://#{address}/")
        client = HTTP::Client.new(uri, tls: client_certificate_context(has_certificate: true))
        response = client.get("/")
        response.status_code.should eq 200
        response.body.should eq "ok"
        peer_subjects.receive.should eq "CN=http-client-spec"
      end
    end

    it "fails with certificate_required when the context has no client certificate" do
      with_client_certificate_server do |address, _, server_errors|
        uri = URI.parse("https://#{address}/")
        client = HTTP::Client.new(uri, tls: client_certificate_context(has_certificate: false))
        error = expect_raises(Crystal::Beryl::TLS::Error, /CertificateRequired/) do
          client.get("/")
        end
        error.alert_description.should eq Crystal::Beryl::TLS::AlertDescription::CertificateRequired
        server_errors.receive.message.should eq "the client sent no certificate, and this server requires one"
      end
    end

    it "uses the system roots for the default context" do
      HTTP::Client.default_tls_context.verify_mode.should eq Crystal::Beryl::TLS::VerifyMode::Peer
    end
  end
end
