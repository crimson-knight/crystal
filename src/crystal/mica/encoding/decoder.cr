module Crystal::Mica::Encoding
  # Every output buffer passed to `Decoder#convert` or `Encoder#convert`
  # must hold at least this many bytes: one step of any converter writes
  # at most this much.
  MIN_OUTPUT_BYTES = 16

  # Turns bytes in one encoding into UTF-8, streaming.
  #
  # Feed the input in chunks of any size; pass `last: true` with the final
  # chunk (it may be empty) so a sequence left open at the end becomes a
  # problem. The output never depends on where the chunks split. Create one
  # with `Codec#decoder`.
  #
  # ```
  # decoder = Mica::Encoding::Codec::ShiftJIS.decoder
  # decoder.decode(Bytes[0x82, 0xA0]) # => "あ"
  # ```
  abstract class Decoder
    getter codec : Codec
    getter error_mode : ErrorMode
    # Source bytes consumed since the decoder was created.
    getter position : Int64 = 0_i64

    def initialize(@codec : Codec, @error_mode : ErrorMode)
    end

    # Decodes as much of *input* as fits into *output* and says why it
    # stopped. *output* must hold at least `MIN_OUTPUT_BYTES` bytes.
    # In `ErrorMode::Fatal` a problem stops the call with `Status::Error`
    # (the failing bytes are consumed) and the decoder returns to its
    # initial state.
    abstract def convert(input : Bytes, output : Bytes, last : Bool) : Result

    # Returns the decoder to its initial state (`position` keeps counting).
    abstract def reset : Nil

    # Decodes *input* and returns the text. With *last* false, a sequence
    # left open at the end is kept for the next call.
    #
    # Raises `ConversionError` for a problem in `ErrorMode::Fatal`.
    def decode(input : Bytes, last : Bool = true) : String
      # The bound plus room for the last step, so one call always suffices.
      capacity = @codec.max_decoded_size(input.size) + MIN_OUTPUT_BYTES
      raise ArgumentError.new("Input too large to decode into one String") if capacity > Int32::MAX - 1
      capacity = capacity.to_i32
      String.new(capacity) do |buffer|
        result = convert(input, Bytes.new(buffer, capacity), last)
        raise_for(result) if result.error?
        {result.written, 0}
      end
    end

    # Decodes *input* and writes the UTF-8 to *io*.
    #
    # Raises `ConversionError` for a problem in `ErrorMode::Fatal`.
    def decode(input : Bytes, io : IO, last : Bool = true) : Nil
      buffer = uninitialized UInt8[4096]
      output = buffer.to_slice
      remaining = input
      loop do
        result = convert(remaining, output, last)
        io.write(output[0, result.written])
        raise_for(result) if result.error?
        remaining = remaining[result.read..]
        break unless result.output_full?
      end
    end

    protected def check_output(output : Bytes) : Nil
      if output.size < MIN_OUTPUT_BYTES
        raise ArgumentError.new("Output buffer must hold at least #{MIN_OUTPUT_BYTES} bytes")
      end
    end

    private def raise_for(result : Result) : NoReturn
      raise ConversionError.new(@codec, result.problem || Problem::InvalidSequence, result.offset)
    end
  end

  enum Codec
    # Returns a new decoder for this encoding. *strip_bom* drops a leading
    # U+FEFF from UTF-8, UTF-16BE and UTF-16LE output, as the Encoding
    # Standard's `TextDecoder` does unless `ignoreBOM` is set; the
    # iconv-compatible names leave it in, as iconv does (`UTF16` and
    # `UTF32` always consume the byte order mark they read).
    def decoder(error_mode : ErrorMode = ErrorMode::Replacement, strip_bom : Bool = false) : Decoder
      case self
      when .utf8?
        UTF8Decoder.new(self, error_mode, strip_bom)
      when .utf16_be?, .ucs2_be?
        UTF16Decoder.new(self, error_mode, big_endian: true, strip_bom: strip_bom)
      when .utf16_le?, .ucs2_le?, .utf16?, .ucs2?
        UTF16Decoder.new(self, error_mode, big_endian: false, strip_bom: strip_bom)
      when .utf32?, .utf32_be?, .utf32_le?
        UTF32Decoder.new(self, error_mode)
      when .gbk?, .gb18030?
        GB18030Decoder.new(self, error_mode)
      when .big5?, .big5_hkscs?
        Big5Decoder.new(self, error_mode)
      when .eucjp?
        EUCJPDecoder.new(self, error_mode)
      when .iso2022_jp?
        ISO2022JPDecoder.new(self, error_mode)
      when .shift_jis?
        ShiftJISDecoder.new(self, error_mode)
      when .euckr?
        EUCKRDecoder.new(self, error_mode)
      when .replacement?
        ReplacementDecoder.new(self, error_mode)
      else
        SingleByteDecoder.new(self, error_mode)
      end
    end
  end

  # Writes *code_point* as UTF-8 at *offset* in *output*, which has room,
  # and returns the offset after it.
  # :nodoc:
  @[AlwaysInline]
  def self.put_utf8(output : Bytes, offset : Int32, code_point : Int32) : Int32
    if code_point < 0x80
      output.unsafe_put(offset, code_point.to_u8!)
      offset + 1
    elsif code_point < 0x800
      output.unsafe_put(offset, (0xC0 | (code_point >> 6)).to_u8!)
      output.unsafe_put(offset + 1, (0x80 | (code_point & 0x3F)).to_u8!)
      offset + 2
    elsif code_point < 0x10000
      output.unsafe_put(offset, (0xE0 | (code_point >> 12)).to_u8!)
      output.unsafe_put(offset + 1, (0x80 | ((code_point >> 6) & 0x3F)).to_u8!)
      output.unsafe_put(offset + 2, (0x80 | (code_point & 0x3F)).to_u8!)
      offset + 3
    else
      output.unsafe_put(offset, (0xF0 | (code_point >> 18)).to_u8!)
      output.unsafe_put(offset + 1, (0x80 | ((code_point >> 12) & 0x3F)).to_u8!)
      output.unsafe_put(offset + 2, (0x80 | ((code_point >> 6) & 0x3F)).to_u8!)
      output.unsafe_put(offset + 3, (0x80 | (code_point & 0x3F)).to_u8!)
      offset + 4
    end
  end
end
