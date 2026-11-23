module Crystal::Mica::Encoding
  # Turns UTF-8 into bytes of one encoding, streaming.
  #
  # Input is UTF-8 bytes (a `String`'s bytes, which may be invalid); feed
  # it in chunks of any size and pass `last: true` with the final chunk so
  # the encoder can close an open sequence (ISO-2022-JP returns to ASCII,
  # BIG5-HKSCS writes a held character). Create one with `Codec#encoder`.
  #
  # ```
  # Mica::Encoding::Codec::ShiftJIS.encoder.encode("あ".to_slice) # => Bytes[0x82, 0xA0]
  # ```
  abstract class Encoder
    getter codec : Codec
    getter error_mode : ErrorMode
    # Input bytes consumed since the encoder was created.
    getter position : Int64 = 0_i64

    def initialize(@codec : Codec, @error_mode : ErrorMode)
    end

    # Encodes as much of the UTF-8 *input* as fits into *output* and says
    # why it stopped. *output* must hold at least `MIN_OUTPUT_BYTES` bytes.
    # In `ErrorMode::Fatal` a problem stops the call with `Status::Error`;
    # the encoder then returns to its initial state.
    abstract def convert(input : Bytes, output : Bytes, last : Bool) : Result

    # Returns the encoder to its initial state (`position` keeps counting).
    abstract def reset : Nil

    # Encodes the UTF-8 *input* and returns the bytes.
    #
    # Raises `ConversionError` for a problem in `ErrorMode::Fatal`.
    def encode(input : Bytes, last : Bool = true) : Bytes
      # The bound plus room for the last step, so one call always suffices.
      capacity = @codec.max_encoded_size(input.size, @error_mode) + MIN_OUTPUT_BYTES
      raise ArgumentError.new("Input too large to encode in one call") if capacity > Int32::MAX
      output = Bytes.new(capacity.to_i32)
      result = convert(input, output, last)
      raise_for(result) if result.error?
      output[0, result.written]
    end

    # Encodes the UTF-8 *input* and writes the bytes to *io*.
    #
    # Raises `ConversionError` for a problem in `ErrorMode::Fatal`.
    def encode(input : Bytes, io : IO, last : Bool = true) : Nil
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
      raise ConversionError.new(@codec, result.problem || Problem::InvalidSequence, result.offset, result.code_point)
    end
  end

  enum Codec
    # Returns a new encoder for this encoding. Raises `ArgumentError` for
    # replacement, which has no encoder.
    def encoder(error_mode : ErrorMode = ErrorMode::Fatal) : Encoder
      case self
      when .utf8?
        UTF8Encoder.new(self, error_mode)
      when .utf16?, .utf16_be?, .utf16_le?, .ucs2?, .ucs2_be?, .ucs2_le?
        UTF16Encoder.new(self, error_mode)
      when .utf32?, .utf32_be?, .utf32_le?
        UTF32Encoder.new(self, error_mode)
      when .gbk?, .gb18030?
        GB18030Encoder.new(self, error_mode)
      when .big5?, .big5_hkscs?
        Big5Encoder.new(self, error_mode)
      when .eucjp?
        EUCJPEncoder.new(self, error_mode)
      when .iso2022_jp?
        ISO2022JPEncoder.new(self, error_mode)
      when .shift_jis?
        ShiftJISEncoder.new(self, error_mode)
      when .euckr?
        EUCKREncoder.new(self, error_mode)
      when .replacement?
        raise ArgumentError.new("The replacement encoding has no encoder")
      else
        SingleByteEncoder.new(self, error_mode)
      end
    end
  end

  # The loop every encoder shares: it reads the UTF-8 input with the
  # Encoding Standard's UTF-8 decoder (so a sequence split across chunks
  # is joined and ill-formed input is found per maximal subpart) and hands
  # each code point to the including class's
  # `encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32`,
  # which returns the new output offset and sets `@unmappable` to the
  # code point to report when the encoding has none. The class may define
  # `flush(output, written) : Int32` for the end of the input and
  # `ascii_direct? : Bool` when ASCII bytes are written as themselves.
  module EncoderLoop
    # Room one step may need: at most a 3-byte escape (ISO-2022-JP back to
    # ASCII) and a 10-byte character reference.
    STEP_ROOM = MIN_OUTPUT_BYTES

    @code_point = 0
    @seen = 0
    @needed = 0
    @lower = 0x80
    @upper = 0xBF
    @sequence_start = 0_i64
    # The code point the last `encode_code_point` could not encode, or -1.
    @unmappable = -1

    def reset : Nil
      clear_utf8
      @unmappable = -1
      clear_state
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - STEP_ROOM
      while read < size
        return finish_call(Status::OutputFull, read, written) if written > limit
        byte = input.unsafe_fetch(read).to_i32
        code_point = -1
        if @needed == 0
          if byte < 0x80 && ascii_direct?
            output.unsafe_put(written, byte.to_u8!)
            written += 1
            read += 1
            next
          end
          @sequence_start = @position + read
          read += 1
          if byte < 0x80
            code_point = byte
          elsif byte >= 0xC2 && byte <= 0xDF
            @needed = 1
            @code_point = byte & 0x1F
          elsif byte >= 0xE0 && byte <= 0xEF
            @lower = 0xA0 if byte == 0xE0
            @upper = 0x9F if byte == 0xED
            @needed = 2
            @code_point = byte & 0xF
          elsif byte >= 0xF0 && byte <= 0xF4
            @lower = 0x90 if byte == 0xF0
            @upper = 0x8F if byte == 0xF4
            @needed = 3
            @code_point = byte & 0x7
          else
            code_point = -2
          end
        elsif byte < @lower || byte > @upper
          # Not consumed: the byte may begin the next sequence.
          clear_utf8
          code_point = -2
        else
          read += 1
          @lower = 0x80
          @upper = 0xBF
          @code_point = (@code_point << 6) | (byte & 0x3F)
          @seen += 1
          if @seen == @needed
            code_point = @code_point
            clear_utf8
          end
        end
        if code_point == -2
          return fail(Problem::InvalidSequence, -1, read, written) if @error_mode.fatal?
          next unless @error_mode.replacement?
          code_point = 0xFFFD
        end
        next if code_point < 0
        written = encode_one(code_point, output, written)
        if (unmappable = @unmappable) >= 0
          @unmappable = -1
          return fail(Problem::Unmappable, unmappable, read, written) if @error_mode.fatal?
          written = write_reference(output, written, unmappable) if @error_mode.replacement?
        end
      end
      if last
        return finish_call(Status::OutputFull, read, written) if written > limit
        if @needed != 0
          clear_utf8
          return fail(Problem::IncompleteSequence, -1, read, written) if @error_mode.fatal?
          if @error_mode.replacement?
            written = encode_one(0xFFFD, output, written)
            if (unmappable = @unmappable) >= 0
              @unmappable = -1
              written = write_reference(output, written, unmappable)
            end
          end
        end
        written = flush(output, written)
      end
      finish_call(Status::InputEmpty, read, written)
    end

    @[AlwaysInline]
    private def encode_one(code_point : Int32, output : Bytes, written : Int32) : Int32
      encode_code_point(code_point, output, written)
    end

    private def fail(problem : Problem, code_point : Int32, read : Int32, written : Int32) : Result
      offset = @sequence_start
      reset
      @position += read
      Result.new(Status::Error, read, written, problem, offset, code_point)
    end

    private def finish_call(status : Status, read : Int32, written : Int32) : Result
      @position += read
      Result.new(status, read, written)
    end

    private def clear_utf8 : Nil
      @code_point = 0
      @seen = 0
      @needed = 0
      @lower = 0x80
      @upper = 0xBF
    end

    # Writes the Encoding Standard's "html" replacement: `&#` the decimal
    # value `;`.
    private def write_reference(output : Bytes, written : Int32, code_point : Int32) : Int32
      output[written] = '&'.ord.to_u8
      output[written + 1] = '#'.ord.to_u8
      written += 2
      digits = code_point.to_s
      digits.each_byte do |digit|
        output[written] = digit
        written += 1
      end
      output[written] = ';'.ord.to_u8
      written + 1
    end

    private def ascii_direct? : Bool
      true
    end

    private def flush(output : Bytes, written : Int32) : Int32
      written
    end

    private def clear_state : Nil
    end
  end

  # UTF-8: validates the input and copies it.
  class UTF8Encoder < Encoder
    include EncoderLoop

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      Encoding.put_utf8(output, written, code_point)
    end
  end

  # UTF-16 in either byte order; `UTF-16` writes the byte order mark
  # FF FE first and then little-endian code units (glibc); UCS-2 has no surrogate
  # pairs, so code points above U+FFFF are unmappable.
  class UTF16Encoder < Encoder
    include EncoderLoop

    @big_endian : Bool
    @ucs2 : Bool
    @bom_pending : Bool

    def initialize(codec : Codec, error_mode : ErrorMode)
      super(codec, error_mode)
      @big_endian = codec.utf16_be? || codec.ucs2_be?
      @ucs2 = codec.ucs2? || codec.ucs2_be? || codec.ucs2_le?
      @bom_pending = codec.utf16?
    end

    private def ascii_direct? : Bool
      false
    end

    private def clear_state : Nil
      @bom_pending = @codec.utf16?
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point > 0xFFFF
        if @ucs2
          # A character reference would be ASCII bytes in a UTF-16 stream,
          # so replacement writes U+FFFD instead.
          return put_unit(output, written, 0xFFFD) if @error_mode.replacement?
          @unmappable = code_point
          return written
        end
        offset = code_point - 0x10000
        written = put_unit(output, put_unit(output, written, 0xD800 | (offset >> 10)), 0xDC00 | (offset & 0x3FF))
        return written
      end
      put_unit(output, written, code_point)
    end

    private def put_unit(output : Bytes, written : Int32, unit : Int32) : Int32
      if @bom_pending
        @bom_pending = false
        written = put_unit(output, written, 0xFEFF)
      end
      high = (unit >> 8).to_u8!
      low = (unit & 0xFF).to_u8!
      output[written] = @big_endian ? high : low
      output[written + 1] = @big_endian ? low : high
      written + 2
    end
  end

  # UTF-32 in either byte order; `UTF-32` writes the byte order mark
  # FF FE 00 00 first and then little-endian values, as glibc does.
  class UTF32Encoder < Encoder
    include EncoderLoop

    @big_endian : Bool
    @bom_pending : Bool

    def initialize(codec : Codec, error_mode : ErrorMode)
      super(codec, error_mode)
      @big_endian = codec.utf32_be?
      @bom_pending = codec.utf32?
    end

    private def ascii_direct? : Bool
      false
    end

    private def clear_state : Nil
      @bom_pending = @codec.utf32?
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if @bom_pending
        @bom_pending = false
        written = encode_code_point(0xFEFF, output, written)
      end
      4.times do |index|
        shift = @big_endian ? 24 - 8 * index : 8 * index
        output[written + index] = ((code_point >> shift) & 0xFF).to_u8!
      end
      written + 4
    end
  end

  # Every single-byte encoding: ASCII as itself, the rest through the
  # reverse of its table (or arithmetic for exact ISO-8859-1 and
  # x-user-defined).
  class SingleByteEncoder < Encoder
    include EncoderLoop

    @reverse : ReverseTable?

    def initialize(codec : Codec, error_mode : ErrorMode)
      super(codec, error_mode)
      @reverse = Tables.single_byte_reverse(codec)
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point < 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      offset = if reverse = @reverse
                 reverse.pointer_for(code_point)
               elsif @codec.iso8859_1?
                 code_point <= 0xFF ? code_point - 0x80 : -1
               elsif @codec.x_user_defined?
                 code_point >= 0xF780 && code_point <= 0xF7FF ? code_point - 0xF780 : -1
               else
                 -1
               end
      if offset < 0
        @unmappable = code_point
        return written
      end
      output[written] = (offset + 0x80).to_u8!
      written + 1
    end
  end

  # gb18030, and GBK (the same encoder without four-byte sequences and with
  # U+20AC as 0x80).
  class GB18030Encoder < Encoder
    include EncoderLoop

    # Private Use code points the GB18030-2005 two-byte mapping keeps
    # (the Encoding Standard's side table): their two bytes, or nil.
    def self.private_use_bytes(code_point : Int32) : {UInt8, UInt8}?
      case code_point
      when 0xE78D then {0xA6_u8, 0xD9_u8}
      when 0xE78E then {0xA6_u8, 0xDA_u8}
      when 0xE78F then {0xA6_u8, 0xDB_u8}
      when 0xE790 then {0xA6_u8, 0xDC_u8}
      when 0xE791 then {0xA6_u8, 0xDD_u8}
      when 0xE792 then {0xA6_u8, 0xDE_u8}
      when 0xE793 then {0xA6_u8, 0xDF_u8}
      when 0xE794 then {0xA6_u8, 0xEC_u8}
      when 0xE795 then {0xA6_u8, 0xED_u8}
      when 0xE796 then {0xA6_u8, 0xF3_u8}
      when 0xE81E then {0xFE_u8, 0x59_u8}
      when 0xE826 then {0xFE_u8, 0x61_u8}
      when 0xE82B then {0xFE_u8, 0x66_u8}
      when 0xE82C then {0xFE_u8, 0x67_u8}
      when 0xE832 then {0xFE_u8, 0x6D_u8}
      when 0xE843 then {0xFE_u8, 0x7E_u8}
      when 0xE854 then {0xFE_u8, 0x90_u8}
      when 0xE864 then {0xFE_u8, 0xA0_u8}
      end
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point < 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      if code_point == 0xE5E5
        @unmappable = code_point
        return written
      end
      gbk = @codec.gbk?
      if gbk && code_point == 0x20AC
        output[written] = 0x80_u8
        return written + 1
      end
      if code_point >= 0xE78D && code_point <= 0xE864 && (bytes = GB18030Encoder.private_use_bytes(code_point))
        output[written] = bytes[0]
        output[written + 1] = bytes[1]
        return written + 2
      end
      pointer = Tables.gb18030_encode(code_point)
      if pointer >= 0
        trailing = pointer % 190
        output[written] = (pointer // 190 + 0x81).to_u8!
        output[written + 1] = (trailing + (trailing < 0x3F ? 0x40 : 0x41)).to_u8!
        return written + 2
      end
      if gbk
        @unmappable = code_point
        return written
      end
      pointer = Tables.gb18030_ranges_pointer(code_point)
      output[written] = (pointer // 12600 + 0x81).to_u8!
      pointer %= 12600
      output[written + 1] = (pointer // 1260 + 0x30).to_u8!
      pointer %= 1260
      output[written + 2] = (pointer // 10 + 0x81).to_u8!
      output[written + 3] = (pointer % 10 + 0x30).to_u8!
      written + 4
    end
  end

  # Big5 (the Encoding Standard's: no HKSCS output), and BIG5-HKSCS, which
  # also writes the HKSCS characters and composes U+00CA and U+00EA with a
  # following U+0304 or U+030C into one two-byte code (holding the letter
  # until the next code point or the end of the input).
  class Big5Encoder < Encoder
    include EncoderLoop

    @held = -1

    private def ascii_direct? : Bool
      @held < 0
    end

    private def clear_state : Nil
      @held = -1
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if (held = @held) >= 0
        @held = -1
        if code_point == 0x0304 || code_point == 0x030C
          trailing = held == 0x00CA ? (code_point == 0x0304 ? 0x62 : 0x64) : (code_point == 0x0304 ? 0xA3 : 0xA5)
          output[written] = 0x88_u8
          output[written + 1] = trailing.to_u8
          return written + 2
        end
        written = encode_single(held, output, written)
      end
      if @codec.big5_hkscs? && (code_point == 0x00CA || code_point == 0x00EA)
        @held = code_point
        return written
      end
      encode_single(code_point, output, written)
    end

    private def flush(output : Bytes, written : Int32) : Int32
      held = @held
      return written if held < 0
      @held = -1
      encode_single(held, output, written)
    end

    private def encode_single(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point < 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      pointer = @codec.big5_hkscs? ? Tables.big5_hkscs_encode(code_point) : Tables.big5_encode(code_point)
      if pointer < 0
        @unmappable = code_point
        return written
      end
      trailing = pointer % 157
      output[written] = (pointer // 157 + 0x81).to_u8!
      output[written + 1] = (trailing + (trailing < 0x3F ? 0x40 : 0x62)).to_u8!
      written + 2
    end
  end

  # EUC-JP (JIS X 0208 and halfwidth katakana; JIS X 0212 is decode-only).
  class EUCJPEncoder < Encoder
    include EncoderLoop

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point < 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      if code_point == 0x00A5
        output[written] = 0x5C_u8
        return written + 1
      end
      if code_point == 0x203E
        output[written] = 0x7E_u8
        return written + 1
      end
      if code_point >= 0xFF61 && code_point <= 0xFF9F
        output[written] = 0x8E_u8
        output[written + 1] = (code_point - 0xFF61 + 0xA1).to_u8!
        return written + 2
      end
      code_point = 0xFF0D if code_point == 0x2212
      pointer = Tables.jis0208_encode(code_point)
      if pointer < 0
        @unmappable = code_point
        return written
      end
      output[written] = (pointer // 94 + 0xA1).to_u8!
      output[written + 1] = (pointer % 94 + 0xA1).to_u8!
      written + 2
    end
  end

  # ISO-2022-JP: writes escapes to switch between ASCII, Roman and
  # JIS X 0208, and returns to ASCII at the end of the input.
  class ISO2022JPEncoder < Encoder
    include EncoderLoop

    enum State
      ASCII
      Roman
      JIS0208
    end

    @state = State::ASCII

    private def ascii_direct? : Bool
      false
    end

    private def clear_state : Nil
      @state = State::ASCII
    end

    private def flush(output : Bytes, written : Int32) : Int32
      return written if @state.ascii?
      @state = State::ASCII
      escape(output, written, 0x28, 0x42)
    end

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      loop do
        if (@state.ascii? || @state.roman?) && (code_point == 0x0E || code_point == 0x0F || code_point == 0x1B)
          # Reported as U+FFFD so a replacement never carries the escape.
          @unmappable = 0xFFFD
          return written
        end
        if @state.ascii? && code_point < 0x80
          output[written] = code_point.to_u8!
          return written + 1
        end
        if @state.roman? && ((code_point < 0x80 && code_point != 0x5C && code_point != 0x7E) || code_point == 0x00A5 || code_point == 0x203E)
          output[written] = (code_point == 0x00A5 ? 0x5C : (code_point == 0x203E ? 0x7E : code_point)).to_u8!
          return written + 1
        end
        if code_point < 0x80
          @state = State::ASCII
          written = escape(output, written, 0x28, 0x42)
          next
        end
        if (code_point == 0x00A5 || code_point == 0x203E) && !@state.roman?
          @state = State::Roman
          written = escape(output, written, 0x28, 0x4A)
          next
        end
        code_point = 0xFF0D if code_point == 0x2212
        if code_point >= 0xFF61 && code_point <= 0xFF9F
          code_point = Tables::ISO_2022_JP_KATAKANA[code_point - 0xFF61].to_i32
        end
        pointer = Tables.jis0208_encode(code_point)
        if pointer < 0
          if @state.jis0208?
            @state = State::ASCII
            written = escape(output, written, 0x28, 0x42)
            next
          end
          @unmappable = code_point
          return written
        end
        unless @state.jis0208?
          @state = State::JIS0208
          written = escape(output, written, 0x24, 0x42)
          next
        end
        output[written] = (pointer // 94 + 0x21).to_u8!
        output[written + 1] = (pointer % 94 + 0x21).to_u8!
        return written + 2
      end
    end

    private def escape(output : Bytes, written : Int32, first : Int32, second : Int32) : Int32
      output[written] = 0x1B_u8
      output[written + 1] = first.to_u8
      output[written + 2] = second.to_u8
      written + 3
    end
  end

  # Shift_JIS.
  class ShiftJISEncoder < Encoder
    include EncoderLoop

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point <= 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      if code_point == 0x00A5
        output[written] = 0x5C_u8
        return written + 1
      end
      if code_point == 0x203E
        output[written] = 0x7E_u8
        return written + 1
      end
      if code_point >= 0xFF61 && code_point <= 0xFF9F
        output[written] = (code_point - 0xFF61 + 0xA1).to_u8!
        return written + 1
      end
      code_point = 0xFF0D if code_point == 0x2212
      pointer = Tables.shift_jis_encode(code_point)
      if pointer < 0
        @unmappable = code_point
        return written
      end
      leading = pointer // 188
      trailing = pointer % 188
      output[written] = (leading + (leading < 0x1F ? 0x81 : 0xC1)).to_u8!
      output[written + 1] = (trailing + (trailing < 0x3F ? 0x40 : 0x41)).to_u8!
      written + 2
    end
  end

  # EUC-KR.
  class EUCKREncoder < Encoder
    include EncoderLoop

    private def encode_code_point(code_point : Int32, output : Bytes, written : Int32) : Int32
      if code_point < 0x80
        output[written] = code_point.to_u8!
        return written + 1
      end
      pointer = Tables.euc_kr_encode(code_point)
      if pointer < 0
        @unmappable = code_point
        return written
      end
      output[written] = (pointer // 190 + 0x81).to_u8!
      output[written + 1] = (pointer % 190 + 0x41).to_u8!
      written + 2
    end
  end
end
