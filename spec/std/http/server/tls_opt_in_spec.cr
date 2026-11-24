require "../../spec_helper"

# `require "http/server"` alone links no OpenSSL; `openssl`, required before
# or after it, or `http/server/tls` adds `HTTP::Server#bind_tls`. Each case is
# its own program, since the answer depends on what the whole program requires.
private def run_program(source : String) : String
  status, output, error = compile_and_run_source(source)
  fail "program failed (#{status}):\n#{output}\n#{error}" unless status.success?
  output
end

private PROBE = <<-CRYSTAL
  print({{ @top_level.has_constant?("OpenSSL") }}, " ")
  print({{ @top_level.has_constant?("HTTP") && HTTP.has_constant?("Client") }}, " ")
  print HTTP::Server.new { }.responds_to?(:bind_tls)
  CRYSTAL

describe "HTTP::Server TLS as an opt-in" do
  it "leaves OpenSSL out of a program that requires only http/server", tags: %w[slow] do
    output = run_program(<<-CRYSTAL)
      require "http/server"
      #{PROBE}
      begin
        HTTP::Server.new { }.bind("tls://127.0.0.1:0?key=a&cert=b")
      rescue ex : ArgumentError
        print " ", ex.message
      end
      CRYSTAL
    output.should eq %(false false false Unsupported socket type: tls (TLS needs `require "http/server/tls"` or `require "openssl"`))
  end

  it "leaves OpenSSL and HTTP::Client out of a server that accepts WebSockets", tags: %w[slow] do
    output = run_program(<<-CRYSTAL)
      require "http/server"
      require "http/server/handlers/websocket_handler"
      handler = HTTP::WebSocketHandler.new { |socket, _context| socket.send("hello") }
      server = HTTP::Server.new([handler] of HTTP::Handler)
      #{PROBE}
      CRYSTAL
    output.should eq "false false false"
  end

  it "adds the TLS listener when openssl is required after http/server", tags: %w[slow] do
    run_program(%(require "http/server"\nrequire "openssl"\n#{PROBE})).should eq "true false true"
  end

  it "adds the TLS listener when openssl is required before http/server", tags: %w[slow] do
    run_program(%(require "openssl"\nrequire "http/server"\n#{PROBE})).should eq "true false true"
  end

  it "adds the TLS listener with require \"http/server/tls\"", tags: %w[slow] do
    run_program(%(require "http/server/tls"\n#{PROBE})).should eq "true false true"
  end

  it "keeps the TLS listener for require \"http\"", tags: %w[slow] do
    run_program(%(require "http"\n#{PROBE})).should eq "true true true"
  end

  it "keeps HTTP::Client and the TLS listener for require \"http/web_socket\" with http/server", tags: %w[slow] do
    output = run_program(<<-CRYSTAL)
      require "http/server"
      require "http/web_socket"
      #{PROBE}
      # Opening a connection still compiles; the proc is never called.
      connect = ->(uri : String) { HTTP::WebSocket.new(uri) }
      print " ", connect.is_a?(Proc)
      CRYSTAL
    output.should eq "true true true true"
  end
end
