require "../../spec_helper"

# `require "http/server"` alone links no OpenSSL; `openssl`, required before
# or after it, or `http/server/tls` adds `HTTP::Server#bind_tls`. Each case is
# its own program, since the answer depends on what the whole program requires.
# Each program gets its own file names, so examples running at once on
# several threads do not overwrite each other's source or executable.
private def run_program(name : String, source : String) : String
  with_tempfile("#{name}.cr") do |source_file|
    File.write(source_file, source)
    compile_file(source_file, bin_name: name) do |executable_file|
      output, error = IO::Memory.new, IO::Memory.new
      status = Process.run(executable_file, output: output, error: error)
      fail "program failed (#{status}):\n#{output}\n#{error}" unless status.success?
      output.to_s
    end
  end
end

# Prints: OpenSSL defined, the full HTTP::Client defined (not only its Response
# class, which http/server uses), HTTP::Server#bind_tls defined.
private PROBE = <<-CRYSTAL
  print({{ @top_level.has_constant?("OpenSSL") }}, " ")
  print({{ @top_level.has_constant?("HTTP") && HTTP.has_constant?("Client") && HTTP::Client.has_constant?("TLSContext") }}, " ")
  print HTTP::Server.new { }.responds_to?(:bind_tls)
  CRYSTAL

describe "HTTP::Server TLS as an opt-in" do
  it "leaves OpenSSL out of a program that requires only http/server", tags: %w[slow] do
    output = run_program("plain_server", <<-CRYSTAL)
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
    output = run_program("websocket_server", <<-CRYSTAL)
      require "http/server"
      require "http/server/handlers/websocket_handler"
      handler = HTTP::WebSocketHandler.new { |socket, _context| socket.send("hello") }
      server = HTTP::Server.new([handler] of HTTP::Handler)
      #{PROBE}
      CRYSTAL
    output.should eq "false false false"
  end

  it "adds the TLS listener when openssl is required after http/server", tags: %w[slow] do
    run_program("openssl_after", %(require "http/server"\nrequire "openssl"\n#{PROBE})).should eq "true false true"
  end

  it "adds the TLS listener when openssl is required before http/server", tags: %w[slow] do
    run_program("openssl_before", %(require "openssl"\nrequire "http/server"\n#{PROBE})).should eq "true false true"
  end

  it "adds the TLS listener with require \"http/server/tls\"", tags: %w[slow] do
    run_program("server_tls", %(require "http/server/tls"\n#{PROBE})).should eq "true false true"
  end

  it "keeps the TLS listener for require \"http\"", tags: %w[slow] do
    run_program("http_all", %(require "http"\n#{PROBE})).should eq "true true true"
  end

  # HTTP::Client speaks TLS through Beryl, so the WebSocket client no longer
  # brings OpenSSL, and with it the OpenSSL listener, into the program.
  it "keeps HTTP::Client, without OpenSSL, for require \"http/web_socket\" with http/server", tags: %w[slow] do
    output = run_program("web_socket_client", <<-CRYSTAL)
      require "http/server"
      require "http/web_socket"
      #{PROBE}
      # Opening a connection still compiles; the proc is never called.
      connect = ->(uri : String) { HTTP::WebSocket.new(uri) }
      print " ", connect.is_a?(Proc)
      CRYSTAL
    output.should eq "false true false true"
  end
end
