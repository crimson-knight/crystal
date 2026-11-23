module Crystal::Mica::Encoding
  # The byte loop shared by the legacy multi-byte decoders, which are
  # written as the Encoding Standard writes them: a handler that takes one
  # byte (or the end of the queue) and returns a code point, CONTINUE,
  # ERROR or FINISHED, and may restore the last bytes it consumed to the
  # front of the queue. Including it gives the decoder `convert`.
  #
  # The including class implements `step(byte : Int32) : Int32`,
  # `idle? : Bool` (no sequence open) and `clear_state`.
  module LegacyByteLoop
    END_OF_QUEUE = -1
    CONTINUE     = -1
    ERROR        = -2
    FINISHED     = -3

    # Restored bytes waiting to be read before the next input byte, with
    # their offsets in the source; at most four are ever held.
    @pending = StaticArray(UInt8, 8).new(0_u8)
    @pending_offsets = StaticArray(Int64, 8).new(0_i64)
    @pending_size = 0
    # Offset of the byte `step` is handling; restored bytes count back
    # from it.
    @current_offset = 0_i64
    @sequence_start = 0_i64
    # A second code point from the last step (Big5's composed pairs).
    @extra_code_point = -1

    def reset : Nil
      clear_state
      @pending_size = 0
      @extra_code_point = -1
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 8
      loop do
        return finish_call(Status::OutputFull, read, written) if written > limit
        if @pending_size > 0
          byte = @pending[0].to_i32
          @current_offset = @pending_offsets[0]
          @pending_size -= 1
          @pending_size.times do |index|
            @pending[index] = @pending[index + 1]
            @pending_offsets[index] = @pending_offsets[index + 1]
          end
        elsif read < size
          byte = input.unsafe_fetch(read).to_i32
          @current_offset = @position + read
          read += 1
          if byte < 0x80 && ascii_passthrough?
            # An ASCII byte with no sequence open is itself.
            output.unsafe_put(written, byte.to_u8!)
            written += 1
            next
          end
        elsif last
          byte = END_OF_QUEUE
        else
          break
        end
        @sequence_start = @current_offset if byte != END_OF_QUEUE && idle?
        result = step(byte)
        if result >= 0
          written = Encoding.put_utf8(output, written, result)
          if (extra = @extra_code_point) >= 0
            @extra_code_point = -1
            written = Encoding.put_utf8(output, written, extra)
          end
        elsif result == FINISHED
          break
        elsif result == ERROR
          problem = byte == END_OF_QUEUE ? Problem::IncompleteSequence : Problem::InvalidSequence
          if @error_mode.fatal?
            offset = @sequence_start
            clear_state
            @extra_code_point = -1
            read = unconsume_restored(read)
            return finish_with_problem(problem, offset, read, written)
          elsif @error_mode.replacement?
            written = Encoding.put_utf8(output, written, 0xFFFD)
          end
        end
      end
      finish_call(Status::InputEmpty, read, written)
    end

    # Puts *bytes*, the last ones consumed (the current byte last), back at
    # the front of the queue.
    private def restore(*bytes : Int32) : Nil
      count = bytes.size
      @pending_size.downto(1) do |index|
        @pending[index - 1 + count] = @pending[index - 1]
        @pending_offsets[index - 1 + count] = @pending_offsets[index - 1]
      end
      bytes.each_with_index do |byte, index|
        @pending[index] = byte.to_u8!
        @pending_offsets[index] = @current_offset - (count - 1 - index)
      end
      @pending_size += count
    end

    # After a fatal error, restored bytes that came from this call's input
    # go back to the caller (not consumed); restored bytes from earlier
    # calls stay pending. Returns the corrected read count.
    private def unconsume_restored(read : Int32) : Int32
      kept = 0
      @pending_size.times do |index|
        offset = @pending_offsets[index]
        if offset < @position
          @pending[kept] = @pending[index]
          @pending_offsets[kept] = offset
          kept += 1
        else
          read = Math.min(read, (offset - @position).to_i32)
        end
      end
      @pending_size = kept
      read
    end

    # True when an ASCII input byte can be written straight out: no
    # sequence is open and nothing is pending. Decoders whose ASCII bytes
    # mean something else in some state (ISO-2022-JP) override it.
    @[AlwaysInline]
    private def ascii_passthrough? : Bool
      idle?
    end
  end

  # gb18030 and GBK (they share the decoder).
  class GB18030Decoder < Decoder
    include LegacyByteLoop

    @first = 0
    @second = 0
    @third = 0

    private def idle? : Bool
      @first == 0
    end

    private def clear_state : Nil
      @first = 0
      @second = 0
      @third = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @first == 0 && @second == 0 && @third == 0
        clear_state
        return ERROR
      end
      if @third != 0
        if byte < 0x30 || byte > 0x39
          restore(@second, @third, byte)
          clear_state
          return ERROR
        end
        pointer = ((@first - 0x81) * (10 * 126 * 10)) + ((@second - 0x30) * (10 * 126)) + ((@third - 0x81) * 10) + byte - 0x30
        clear_state
        code_point = Tables.gb18030_ranges_code_point(pointer)
        return code_point < 0 ? ERROR : code_point
      end
      if @second != 0
        if byte >= 0x81 && byte <= 0xFE
          @third = byte
          return CONTINUE
        end
        restore(@second, byte)
        @first = 0
        @second = 0
        return ERROR
      end
      if @first != 0
        if byte >= 0x30 && byte <= 0x39
          @second = byte
          return CONTINUE
        end
        leading = @first
        @first = 0
        offset = byte < 0x7F ? 0x40 : 0x41
        code_point = -1
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFE)
          code_point = Tables.code_point(Tables::GB18030, (leading - 0x81) * 190 + (byte - offset))
        end
        return code_point if code_point >= 0
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      return 0x20AC if byte == 0x80
      if byte >= 0x81 && byte <= 0xFE
        @first = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # Big5 (the Encoding Standard's, which includes HKSCS); also the
  # decoder for BIG5-HKSCS.
  class Big5Decoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        offset = byte < 0x7F ? 0x40 : 0x62
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0xA1 && byte <= 0xFE)
          pointer = (leading - 0x81) * 157 + (byte - offset)
          case pointer
          when 1133
            @extra_code_point = 0x0304
            return 0x00CA
          when 1135
            @extra_code_point = 0x030C
            return 0x00CA
          when 1164
            @extra_code_point = 0x0304
            return 0x00EA
          when 1166
            @extra_code_point = 0x030C
            return 0x00EA
          end
          code_point = Tables.code_point(Tables::BIG5, pointer)
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte >= 0x81 && byte <= 0xFE
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # EUC-JP (JIS X 0208, JIS X 0212 and halfwidth katakana).
  class EUCJPDecoder < Decoder
    include LegacyByteLoop

    @leading = 0
    @jis0212 = false

    private def idle? : Bool
      @leading == 0
    end

    private def clear_state : Nil
      @leading = 0
      @jis0212 = false
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading == 0x8E && byte >= 0xA1 && byte <= 0xDF
        @leading = 0
        return 0xFF61 - 0xA1 + byte
      end
      if @leading == 0x8F && byte >= 0xA1 && byte <= 0xFE
        @jis0212 = true
        @leading = byte
        return CONTINUE
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        code_point = -1
        if leading >= 0xA1 && leading <= 0xFE && byte >= 0xA1 && byte <= 0xFE
          pointer = (leading - 0xA1) * 94 + byte - 0xA1
          code_point = Tables.code_point(@jis0212 ? Tables::JIS0212 : Tables::JIS0208, pointer)
        end
        @jis0212 = false
        return code_point if code_point >= 0
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte == 0x8E || byte == 0x8F || (byte >= 0xA1 && byte <= 0xFE)
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # ISO-2022-JP: ASCII, JIS X 0201 Roman, halfwidth katakana and JIS X 0208,
  # switched by escape sequences.
  class ISO2022JPDecoder < Decoder
    include LegacyByteLoop

    enum State
      ASCII
      Roman
      Katakana
      LeadByte
      TrailByte
      EscapeStart
      Escape
    end

    @state = State::ASCII
    @output_state = State::ASCII
    @leading = 0
    @output = false

    private def idle? : Bool
      @state.ascii? || @state.roman? || @state.katakana? || @state.lead_byte?
    end

    private def ascii_passthrough? : Bool
      false
    end

    private def clear_state : Nil
      @state = State::ASCII
      @output_state = State::ASCII
      @leading = 0
      @output = false
    end

    private def step(byte : Int32) : Int32
      case @state
      in .ascii?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return byte if byte <= 0x7F && byte != 0x0E && byte != 0x0F
        ERROR
      in .roman?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return 0x00A5 if byte == 0x5C
        return 0x203E if byte == 0x7E
        return byte if byte <= 0x7F && byte != 0x0E && byte != 0x0F
        ERROR
      in .katakana?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return 0xFF61 - 0x21 + byte if byte >= 0x21 && byte <= 0x5F
        ERROR
      in .lead_byte?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        if byte >= 0x21 && byte <= 0x7E
          @leading = byte
          @state = State::TrailByte
          return CONTINUE
        end
        ERROR
      in .trail_byte?
        if byte == 0x1B
          @state = State::EscapeStart
          return ERROR
        end
        @state = State::LeadByte
        if byte >= 0x21 && byte <= 0x7E
          code_point = Tables.code_point(Tables::JIS0208, (@leading - 0x21) * 94 + byte - 0x21)
          return code_point < 0 ? ERROR : code_point
        end
        ERROR
      in .escape_start?
        if byte == 0x24 || byte == 0x28
          @leading = byte
          @state = State::Escape
          return CONTINUE
        end
        restore(byte) unless byte == END_OF_QUEUE
        @output = false
        @state = @output_state
        ERROR
      in .escape?
        leading = @leading
        @leading = 0
        state = if leading == 0x28 && byte == 0x42
                  State::ASCII
                elsif leading == 0x28 && byte == 0x4A
                  State::Roman
                elsif leading == 0x28 && byte == 0x49
                  State::Katakana
                elsif leading == 0x24 && (byte == 0x40 || byte == 0x42)
                  State::LeadByte
                end
        if state
          @state = state
          @output_state = state
          output = @output
          @output = true
          return output ? ERROR : CONTINUE
        end
        if byte == END_OF_QUEUE
          restore(leading)
        else
          restore(leading, byte)
        end
        @output = false
        @state = @output_state
        ERROR
      end
    end

    private def escape_start : Int32
      @state = State::EscapeStart
      CONTINUE
    end
  end

  # Shift_JIS (with the Windows extensions the Encoding Standard keeps).
  class ShiftJISDecoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        offset = byte < 0x7F ? 0x40 : 0x41
        leading_offset = leading < 0xA0 ? 0x81 : 0xC1
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFC)
          pointer = (leading - leading_offset) * 188 + byte - offset
          return 0xE000 - 8836 + pointer if pointer >= 8836 && pointer <= 10715
          code_point = Tables.code_point(Tables::JIS0208, pointer)
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80 || byte == 0x80
      return 0xFF61 - 0xA1 + byte if byte >= 0xA1 && byte <= 0xDF
      if (byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC)
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # EUC-KR (the Unified Hangul Code, Windows code page 949).
  class EUCKRDecoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        if byte >= 0x41 && byte <= 0xFE
          code_point = Tables.code_point(Tables::EUC_KR, (leading - 0x81) * 190 + (byte - 0x41))
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte >= 0x81 && byte <= 0xFE
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # The replacement encoding: any input at all becomes one error.
  class ReplacementDecoder < Decoder
    include LegacyByteLoop

    @error_returned = false

    private def idle? : Bool
      true
    end

    private def ascii_passthrough? : Bool
      false
    end

    private def clear_state : Nil
      @error_returned = false
    end

    private def step(byte : Int32) : Int32
      return FINISHED if byte == END_OF_QUEUE
      return CONTINUE if @error_returned
      @error_returned = true
      ERROR
    end
  end
end
