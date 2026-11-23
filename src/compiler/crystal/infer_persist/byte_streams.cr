module Crystal::InferPersist
  # A buffered output to a file descriptor, with the encodings a snapshot
  # uses: unsigned LEB128 varints, zigzag varints for signed numbers and raw
  # little-endian words.
  #
  # It writes with `LibC.write` rather than through `IO`: the writer runs in
  # a forked child that keeps only one thread and has no event loop of its
  # own (see `InferReuse.fork_process`).
  class ByteOutput
    BUFFER_SIZE = 1 << 20

    @buffer = Bytes.new(BUFFER_SIZE)
    @position = 0
    getter written_bytesize = 0_i64

    def initialize(@fd : Int32)
    end

    def write_byte(byte : UInt8) : Nil
      flush if @position == BUFFER_SIZE
      @buffer.to_unsafe[@position] = byte
      @position += 1
    end

    def write_varint(value : UInt64) : Nil
      flush if @position > BUFFER_SIZE - 10
      pointer = @buffer.to_unsafe
      while value >= 0x80
        pointer[@position] = (value.to_u8! | 0x80_u8)
        @position += 1
        value >>= 7
      end
      pointer[@position] = value.to_u8!
      @position += 1
    end

    def write_svarint(value : Int64) : Nil
      write_varint(((value << 1) ^ (value >> 63)).to_u64!)
    end

    def write_u64(value : UInt64) : Nil
      flush if @position > BUFFER_SIZE - 8
      (@buffer.to_unsafe + @position).as(UInt64*).value = value
      @position += 8
    end

    def write_bytes(bytes : Bytes) : Nil
      if bytes.size > BUFFER_SIZE - @position
        flush
        if bytes.size > BUFFER_SIZE
          write_fully(bytes)
          return
        end
      end
      bytes.copy_to(@buffer.to_unsafe + @position, bytes.size)
      @position += bytes.size
    end

    def flush : Nil
      write_fully(@buffer[0, @position]) if @position > 0
      @position = 0
    end

    private def write_fully(bytes : Bytes) : Nil
      until bytes.empty?
        count = LibC.write(@fd, bytes, bytes.size)
        if count < 0
          raise Error.new("snapshot: write failed: #{Errno.value.message}") unless Errno.value == Errno::EINTR
          next
        end
        bytes += count
        @written_bytesize += count
      end
    end
  end

  # The reading side of `ByteOutput`, over a file read in large blocks.
  class ByteInput
    BUFFER_SIZE = 1 << 22

    @buffer = Bytes.new(BUFFER_SIZE)
    @position = 0
    @limit = 0

    def initialize(@io : IO)
    end

    def read_byte : UInt8
      fill if @position == @limit
      byte = @buffer.to_unsafe[@position]
      @position += 1
      byte
    end

    def read_varint : UInt64
      if @limit - @position >= 10
        pointer = @buffer.to_unsafe
        result = 0_u64
        shift = 0
        while true
          byte = pointer[@position]
          @position += 1
          result |= (byte & 0x7f).to_u64 << shift
          return result if byte < 0x80
          shift += 7
        end
      end
      result = 0_u64
      shift = 0
      while true
        byte = read_byte
        result |= (byte & 0x7f).to_u64 << shift
        return result if byte < 0x80
        shift += 7
      end
    end

    def read_svarint : Int64
      value = read_varint
      (value >> 1).to_i64! ^ -(value & 1).to_i64!
    end

    def read_u64 : UInt64
      if @limit - @position >= 8
        value = (@buffer.to_unsafe + @position).as(UInt64*).value
        @position += 8
        return value
      end
      result = 0_u64
      8.times { |index| result |= read_byte.to_u64 << (8 * index) }
      result
    end

    def read_string(bytesize : Int32) : String
      if @limit - @position >= bytesize
        string = String.new(@buffer.to_unsafe + @position, bytesize)
        @position += bytesize
        return string
      end
      String.new(bytesize) do |pointer|
        filled = 0
        while filled < bytesize
          fill if @position == @limit
          count = Math.min(bytesize - filled, @limit - @position)
          (pointer + filled).copy_from(@buffer.to_unsafe + @position, count)
          @position += count
          filled += count
        end
        {bytesize, 0}
      end
    end

    private def fill : Nil
      count = @io.read(@buffer)
      raise Error.new("snapshot: unexpected end of file") if count == 0
      @position = 0
      @limit = count
    end
  end
end
