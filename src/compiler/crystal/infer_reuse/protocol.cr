module Crystal::InferReuse
  # What a client asks the server to build: the command line after
  # `crystal`, where, and with which environment.
  struct BuildRequest
    include JSON::Serializable

    getter argv : Array(String)
    getter working_directory : String
    getter env : Hash(String, String)

    def initialize(@argv, @working_directory, @env)
    end
  end

  # The server's answer is a sequence of frames: the build's standard output
  # and error as they come, then its exit code.
  module Frame
    enum Kind : UInt8
      Stdout   = 1
      Stderr   = 2
      ExitCode = 3
    end

    def self.write(io : IO, kind : Kind, bytes : Bytes) : Nil
      io.write_byte(kind.value)
      io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write(bytes)
      io.flush
    end

    # Reads one frame, or returns `nil` at the end of the stream.
    def self.read(io : IO) : {Kind, Bytes}?
      kind_value = io.read_byte || return nil
      size = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      bytes = Bytes.new(size)
      io.read_fully(bytes)
      {Kind.new(kind_value), bytes}
    rescue IO::EOFError
      nil
    end
  end
end
