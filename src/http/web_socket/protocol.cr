require "socket"
require "../headers"
require "base64"
require "crystal/digest/sha1"
require "uri"

# :nodoc:
class HTTP::WebSocket::Protocol
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @[::Flags]
  enum Flags : UInt8
    FINAL = 0x80
    RSV1  = 0x40
    RSV2  = 0x20
    RSV3  = 0x10
  end

  enum Opcode : UInt8
    CONTINUATION = 0x0
    TEXT         = 0x1
    BINARY       = 0x2
    CLOSE        = 0x8
    PING         = 0x9
    PONG         = 0xA
  end

  MASK_BIT = 128_u8
  VERSION  = "13"

  record PacketInfo,
    opcode : Opcode,
    size : Int32,
    final : Bool

  getter protocol : String?

  def initialize(@io : IO, masked = false, @sync_close = true, @protocol : String? = nil)
    @header = uninitialized UInt8[2]
    @mask = uninitialized UInt8[4]
    @mask_offset = 0
    @opcode = Opcode::CONTINUATION
    @remaining = 0_u64

    # If true, outgoing data is masked and incoming data is unmasked.
    @masked = !!masked
  end

  class StreamIO < IO
    getter? closed = false

    def initialize(@websocket : Protocol, binary, frame_size)
      @opcode = binary ? Opcode::BINARY : Opcode::TEXT
      @buffer = Bytes.new(frame_size)
      @pos = 0
    end

    def write(slice : Bytes) : Nil
      check_open
      return if slice.empty?

      count = Math.min(@buffer.size - @pos, slice.size)
      (@buffer + @pos).copy_from(slice.to_unsafe, count)
      @pos += count

      if @pos == @buffer.size
        send_frame(final: false)
      end

      if count < slice.size
        write(slice + count)
      end
    end

    def read(slice : Bytes) : NoReturn
      raise "This IO is write-only"
    end

    private def send_frame(final = false) : Nil
      @websocket.send(
        @buffer[0...@pos],
        @opcode,
        flags: final ? Flags::FINAL : Flags::None,
        flush: final
      )
      @opcode = Opcode::CONTINUATION
      @pos = 0
    end

    def close
      return if closed?
      @closed = true
      send_frame(final: true)
    end
  end

  def send(data : String) : Nil
    send(data.to_slice, Opcode::TEXT)
  end

  def send(data : Bytes) : Nil
    send(data, Opcode::BINARY)
  end

  def stream(binary = true, frame_size = 1024, &)
    stream_io = StreamIO.new(self, binary, frame_size)
    yield(stream_io)
    stream_io.close
  end

  def send(data : Bytes, opcode : Opcode, flags : Flags = Flags::FINAL, flush : Bool = true) : Nil
    write_header(data.size, opcode, flags)
    write_payload(data)
    @io.flush if flush
  end

  def receive(buffer : Bytes) : PacketInfo
    if @remaining == 0
      opcode = read_header
    else
      opcode = @opcode
    end

    read = read_payload(buffer)
    @remaining -= read
    PacketInfo.new(opcode, read.to_i, final? && @remaining == 0)
  end

  private def write_header(size, opcode, flags)
    @io.write_byte(flags.value | opcode.value)

    mask = @masked ? MASK_BIT : 0_u8
    if size <= 125
      @io.write_byte(size.to_u8 | mask)
    elsif size <= UInt16::MAX
      @io.write_byte(126_u8 | mask)
      @io.write_bytes(size.to_u16, IO::ByteFormat::NetworkEndian)
    else
      @io.write_byte(127_u8 | mask)
      @io.write_bytes(size.to_u64, IO::ByteFormat::NetworkEndian)
    end
  end

  private def write_payload(data)
    return @io.write(data) unless @masked

    key = Random.next_int
    mask_array = key.unsafe_as(StaticArray(UInt8, 4))
    @io.write mask_array.to_slice

    write_masked_data(data, mask_array)
  end

  private def write_masked_data(data, mask_array)
    # We are going to write the data, masked, into a temporary buffer.
    masked_data = uninitialized UInt8[IO::DEFAULT_BUFFER_SIZE]

    # We'll do it by chunks of at most IO::DEFAULT_BUFFER_SIZE
    remaining_data = data
    until remaining_data.empty?
      # How much data can we write?
      # Either IO::DEFAULT_BUFFER_SIZE or whatever remains.
      chunk_size = Math.min(remaining_data.size, IO::DEFAULT_BUFFER_SIZE)

      # Mask the data
      chunk = remaining_data[0, chunk_size]
      chunk.each_with_index do |byte, index|
        mask = mask_array[index & 0b11] # x & 0b11 == x % 4
        masked_data[index] = byte ^ mask
      end

      # Write the masked data
      @io.write(masked_data.to_slice[0, chunk_size])

      # Discard the written data
      remaining_data = remaining_data[chunk_size..]
    end
  end

  private def read_header
    # First byte: FIN (1 bit), RSV1,2,3 (3 bits), Opcode (4 bits)
    # Second byte: MASK (1 bit), Payload Length (7 bits)
    @io.read_fully(@header.to_slice)

    opcode = read_opcode
    @remaining = read_size

    header_masked = (@header[1] & 0x80_u8) != 0_u8

    if @masked
      if header_masked
        close :ProtocolError
        raise "Protocol error: expected unmasked frame"
      end
    else
      if !header_masked
        close :ProtocolError
        raise "Protocol error: expected masked frame"
      end

      @io.read_fully(@mask.to_slice)
      @mask_offset = 0
    end

    opcode
  end

  private def read_opcode
    raw_opcode = @header[0] & 0x0f_u8

    parsed_opcode = Opcode.from_value?(raw_opcode)
    unless parsed_opcode
      raise "Invalid packet opcode: #{raw_opcode}"
    end

    if parsed_opcode == Opcode::CONTINUATION
      @opcode
    elsif control?
      parsed_opcode
    else
      @opcode = parsed_opcode
    end
  end

  private def read_size
    size = (@header[1] & 0x7f_u8).to_u64
    case size
    when 126
      size = 0_u64
      2.times { size <<= 8; size += @io.read_byte.not_nil! }
    when 127
      size = 0_u64
      8.times { size <<= 8; size += @io.read_byte.not_nil! }
    else
      # not a special case
    end
    size
  end

  private def read_payload(buffer)
    count = Math.min(@remaining, buffer.size)
    @io.read_fully(buffer[0, count])
    unless @masked
      count.times do |i|
        buffer[i] ^= @mask[@mask_offset & 0b11] # x & 0b11 == x % 4
        @mask_offset += 1
      end
    end
    count
  end

  private def control?
    (@header[0] & 0x08_u8) != 0_u8
  end

  private def final?
    (@header[0] & 0x80_u8) != 0_u8
  end

  def ping(message = nil)
    if message
      send(message.to_slice, Opcode::PING)
    else
      send(Bytes.empty, Opcode::PING)
    end
  end

  def pong(message = nil) : Nil
    if message
      send(message.to_slice, Opcode::PONG)
    else
      send(Bytes.empty, Opcode::PONG)
    end
  end

  def close(code : CloseCode? = nil, message = nil) : Nil
    return if @io.closed?

    if message
      message = message.to_slice
      code ||= CloseCode::NormalClosure

      payload = Bytes.new(2 + message.size)
      IO::ByteFormat::NetworkEndian.encode(code.to_u16, payload)
      message.copy_to(payload + 2)
    else
      if code
        payload = Bytes.new(2)
        IO::ByteFormat::NetworkEndian.encode(code.to_u16, payload)
      else
        payload = Bytes.empty
      end
    end

    send(payload, Opcode::CLOSE)

    @io.close if @sync_close
  end

  def close(code : Int, message : String? = nil) : Nil
    close(CloseCode.new(code), message)
  end

  # The handshake hash (RFC 6455, section 1.3) uses the standard library's own
  # SHA-1, so a WebSocket server or client links no OpenSSL for it.
  def self.key_challenge(key : String) : String
    ::Crystal::Digest::SHA1.base64digest(key + GUID)
  end
end
