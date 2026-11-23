module Crystal::InferReuse
  # `crystal build` as a client of the build server: it hands the build to
  # the server for its socket (starting one when there is none), prints what
  # the build prints and exits with the build's exit code.
  module Client
    SERVER_START_TIMEOUT = 30.seconds

    def self.run(argv : Array(String)) : NoReturn
      socket_path = InferReuse.socket_path(argv)
      socket = connect(socket_path) || start_server_and_connect(socket_path)

      request = BuildRequest.new(argv, Dir.current, ENV.to_h)
      socket.puts request.to_json
      socket.flush

      while frame = Frame.read(socket)
        kind, bytes = frame
        case kind
        in .stdout?
          STDOUT.write(bytes)
          STDOUT.flush
        in .stderr?
          STDERR.write(bytes)
          STDERR.flush
        in .exit_code?
          exit String.new(bytes).to_i
        end
      end

      STDERR.puts "Error: the build server for this build stopped before the build ended (#{socket_path})"
      exit 1
    end

    private def self.connect(socket_path : String) : UNIXSocket?
      UNIXSocket.new(socket_path)
    rescue Socket::ConnectError | File::NotFoundError
      nil
    end

    # Starts a server for *socket_path*. The server detaches from this
    # process (see `Server.detach`), so it outlives the client and is not
    # one of the client's processes.
    private def self.start_server_and_connect(socket_path : String) : UNIXSocket
      executable = ::Process.executable_path || raise Error.new("can't find the compiler executable to start a build server")
      env = {"CRYSTAL_WORKERS" => "1"}
      status = ::Process.run(executable, ["internal-infer-server", socket_path], env: env,
        input: ::Process::Redirect::Close, output: ::Process::Redirect::Close, error: ::Process::Redirect::Inherit)
      raise Error.new("the build server did not start (#{status})") unless status.success?

      deadline = Time.instant + SERVER_START_TIMEOUT
      loop do
        if socket = connect(socket_path)
          return socket
        end
        raise Error.new("the build server did not open #{socket_path}") if Time.instant > deadline
        sleep 20.milliseconds
      end
    end
  end
end
