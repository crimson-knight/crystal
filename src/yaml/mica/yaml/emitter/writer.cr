class YAML::Mica::YAML::Emitter
  private DOCUMENT_START_INDICATOR      = "---".to_slice
  private DOCUMENT_END_INDICATOR        = "...".to_slice
  private FLOW_SEQUENCE_START_INDICATOR = "[".to_slice
  private FLOW_SEQUENCE_END_INDICATOR   = "]".to_slice
  private FLOW_MAPPING_START_INDICATOR  = "{".to_slice
  private FLOW_MAPPING_END_INDICATOR    = "}".to_slice
  private FLOW_ENTRY_INDICATOR          = ",".to_slice
  private BLOCK_ENTRY_INDICATOR         = "-".to_slice
  private KEY_INDICATOR                 = "?".to_slice
  private VALUE_INDICATOR               = ":".to_slice
  private ANCHOR_INDICATOR              = "&".to_slice
  private ALIAS_INDICATOR               = "*".to_slice
  private VERBATIM_TAG_START_INDICATOR  = "!<".to_slice
  private VERBATIM_TAG_END_INDICATOR    = ">".to_slice
  private SINGLE_QUOTE_INDICATOR        = "'".to_slice
  private DOUBLE_QUOTE_INDICATOR        = "\"".to_slice
  private LITERAL_INDICATOR             = "|".to_slice
  private FOLDED_INDICATOR              = ">".to_slice
  private INDENT_HINT_INDICATOR         = BEST_INDENT.to_s.to_slice
  private STRIP_CHOMPING_INDICATOR      = "-".to_slice
  private KEEP_CHOMPING_INDICATOR       = "+".to_slice
  private UPPERCASE_HEX_DIGITS          = "0123456789ABCDEF".to_slice

  # Writes the buffered bytes to the IO.
  private def flush_buffer : Nil
    return if @buffered == 0
    @io.write(@buffer[0, @buffered])
    @buffered = 0
  end

  # Makes room for one character, as libyaml's FLUSH does: the buffer is
  # written out once fewer than six bytes are free. Afterwards at least six
  # bytes are free (`@buffered + 5 < @buffer.size`), which lets the writers
  # below store up to four bytes without a bound check.
  @[AlwaysInline]
  private def reserve : Nil
    make_room unless @buffered + 5 < @buffer.size
  end

  # The slow half of `reserve`: doubles the buffer while it is smaller than
  # `BUFFER_SIZE`, and writes it out once it is full size.
  @[NoInline]
  private def make_room : Nil
    while @buffered + 5 >= @buffer.size
      if @buffer.size < BUFFER_SIZE
        grown = Bytes.new(Math.min(@buffer.size * 2, BUFFER_SIZE))
        @buffer[0, @buffered].copy_to(grown)
        @buffer = grown
      else
        flush_buffer
      end
    end
  end

  # Returns how many one-byte characters `reserve` lets through before it
  # next grows or writes out the buffer.
  @[AlwaysInline]
  private def room : Int32
    @buffer.size - 5 - @buffered
  end

  # Writes one byte and advances the column.
  @[AlwaysInline]
  private def put(byte : UInt8) : Nil
    reserve
    # reserve left six bytes free, so @buffered is inside the buffer.
    @buffer.to_unsafe[@buffered] = byte
    @buffered += 1
    @column += 1
  end

  # Writes a line break and returns to column 0.
  @[AlwaysInline]
  private def put_break : Nil
    reserve
    # reserve left six bytes free, so @buffered is inside the buffer.
    @buffer.to_unsafe[@buffered] = 0x0A_u8
    @buffered += 1
    @column = 0
  end

  # Copies the bytes of the character at *index* without touching the
  # column and returns the index after it.
  @[AlwaysInline]
  private def copy_character(bytes : Bytes, index : Int32) : Int32
    reserve
    octet = bytes[index]
    if octet < 0x80_u8
      # reserve left six bytes free, so @buffered is inside the buffer.
      @buffer.to_unsafe[@buffered] = octet
      @buffered += 1
      return index + 1
    end
    width = char_width(bytes, index)
    # The checked subslice proves the source bytes exist, and reserve left
    # six bytes free for the at most four bytes of one character.
    bytes[index, width].copy_to(@buffer.to_unsafe + @buffered, width)
    @buffered += width
    index + width
  end

  # Writes the character at *index* (one column wide) and returns the
  # index after it.
  @[AlwaysInline]
  private def write_character(bytes : Bytes, index : Int32) : Int32
    index = copy_character(bytes, index)
    @column += 1
    index
  end

  # Writes the line break at *index* and returns the index after it: LF
  # becomes the output line break, the other breaks are copied as they are.
  private def write_break(bytes : Bytes, index : Int32) : Int32
    if bytes[index] == 0x0A_u8
      put_break
      index + 1
    else
      index = copy_character(bytes, index)
      @column = 0
      index
    end
  end

  # Copies `bytes[index...finish]`, which holds only one-byte characters,
  # one column each, and returns *finish*. The buffer grows or is written
  # out at exactly the points `write_character` once per byte would reach.
  private def write_ascii_run(bytes : Bytes, index : Int32, finish : Int32) : Int32
    while index < finish
      reserve
      length = Math.min(room, finish - index)
      Core::ByteScan.copy_into(@buffer, @buffered, bytes[index, length])
      @buffered += length
      @column += length
      index += length
    end
    finish
  end

  # Writes *count* spaces, growing or writing out the buffer where `put`
  # once per space would.
  private def write_spaces(count : Int32) : Nil
    while count > 0
      reserve
      length = Math.min(room, count)
      @buffer[@buffered, length].fill(0x20_u8)
      @buffered += length
      @column += length
      count -= length
    end
  end

  # Returns the end of the run that starts at *index* and holds printable
  # ASCII characters other than *stop* and *other_stop*. With *fold* set,
  # a space ends the run once it would land past `BEST_WIDTH`, where the
  # scalar writers may break the line; the run is measured from the
  # current column.
  private def text_run_end(bytes : Bytes, index : Int32, stop : UInt8, other_stop : UInt8,
                           fold : Bool) : Int32
    # The byte at `finish` lands in column `@column + finish - index`.
    last_space = fold ? index + BEST_WIDTH - @column : bytes.size
    finish = index
    while finish < bytes.size
      # finish < bytes.size, checked just above.
      octet = bytes.unsafe_fetch(finish)
      if octet == 0x20_u8
        break if finish > last_space
      else
        break unless 0x21_u8 <= octet <= 0x7E_u8 && octet != stop && octet != other_stop
      end
      finish += 1
    end
    finish
  end

  # Returns the end of the run of ASCII characters other than CR and LF
  # that starts at *index*: the rest of a block scalar's line up to its
  # first non-ASCII character. With *fold* set, a space ends the run once
  # it would land past `BEST_WIDTH`, as in `text_run_end`.
  private def line_run_end(bytes : Bytes, index : Int32, fold : Bool) : Int32
    last_space = fold ? index + BEST_WIDTH - @column : bytes.size
    finish = index
    while finish < bytes.size
      # finish < bytes.size, checked just above.
      octet = bytes.unsafe_fetch(finish)
      break if octet >= 0x80_u8 || octet == 0x0A_u8 || octet == 0x0D_u8
      break if octet == 0x20_u8 && finish > last_space
      finish += 1
    end
    finish
  end

  # Writes *bytes* (an indicator, an anchor or a tag handle) one column per
  # character.
  private def write_all(bytes : Bytes) : Nil
    if bytes.size == 1 && bytes[0] < 0x80_u8
      put(bytes[0])
      return
    end
    index = 0
    while index < bytes.size
      index = write_ascii_run(bytes, index, Core::ByteScan.skip_ascii(bytes, index, bytes.size))
      index = write_character(bytes, index) if index < bytes.size
    end
  end

  # Starts a new line when the current one holds anything, then pads to
  # the current indent.
  private def write_indent : Nil
    indent = @indent >= 0 ? @indent : 0
    if !@indention || @column > indent || (@column == indent && !@whitespace)
      put_break
    end
    write_spaces(indent - @column) if @column < indent
    @whitespace = true
    @indention = true
  end

  private def write_indicator(indicator : Bytes, need_whitespace : Bool,
                              is_whitespace : Bool, is_indention : Bool) : Nil
    put(0x20_u8) if need_whitespace && !@whitespace
    write_all(indicator)
    @whitespace = is_whitespace
    @indention = @indention && is_indention
  end

  private def write_anchor(anchor : Bytes) : Nil
    write_all(anchor)
    @whitespace = false
    @indention = false
  end

  private def write_tag_handle(handle : Bytes) : Nil
    put(0x20_u8) unless @whitespace
    write_all(handle)
    @whitespace = false
    @indention = false
  end

  # Returns true for the characters a tag may hold without `%` escaping.
  private def tag_character?(bytes : Bytes, index : Int32) : Bool
    return true if alphanumerical?(bytes, index)
    case bytes[index]
    when ';'.ord, '/'.ord, '?'.ord, ':'.ord, '@'.ord, '&'.ord, '='.ord, '+'.ord, '$'.ord, ','.ord,
         '_'.ord, '.'.ord, '~'.ord, '*'.ord, '\''.ord, '('.ord, ')'.ord, '['.ord, ']'.ord
      true
    else
      false
    end
  end

  private def write_tag_content(content : Bytes, need_whitespace : Bool) : Nil
    put(0x20_u8) if need_whitespace && !@whitespace
    index = 0
    while index < content.size
      if tag_character?(content, index)
        index = write_character(content, index)
      else
        width = char_width(content, index)
        width.times do
          octet = content[index]
          index += 1
          put(0x25_u8)
          put(UPPERCASE_HEX_DIGITS[octet >> 4])
          put(UPPERCASE_HEX_DIGITS[octet & 0x0F])
        end
      end
    end
    @whitespace = false
    @indention = false
  end

  private def write_plain_scalar(value : Bytes, allow_breaks : Bool) : Nil
    spaces = false
    breaks = false

    # An empty plain scalar in block context gets no separating space, so a
    # line never ends in a space.
    put(0x20_u8) if !@whitespace && (!value.empty? || @flow_level > 0)

    index = 0
    while index < value.size
      if space?(value, index)
        if allow_breaks && !spaces && @column > BEST_WIDTH && !space?(value, index + 1)
          write_indent
          index += 1
        else
          index = write_character(value, index)
        end
        spaces = true
      elsif line_break?(value, index)
        put_break if !breaks && value[index] == 0x0A_u8
        index = write_break(value, index)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        index = write_character(value, index)
        finish = text_run_end(value, index, 0_u8, 0_u8, allow_breaks)
        spaces = finish > index && value[finish - 1] == 0x20_u8
        index = write_ascii_run(value, index, finish)
        @indention = false
        breaks = false
      end
    end

    @whitespace = false
    @indention = false
  end

  private def write_single_quoted_scalar(value : Bytes, allow_breaks : Bool) : Nil
    spaces = false
    breaks = false

    write_indicator(SINGLE_QUOTE_INDICATOR, true, false, false)

    index = 0
    while index < value.size
      if space?(value, index)
        if allow_breaks && !spaces && @column > BEST_WIDTH && index != 0 &&
           index != value.size - 1 && !space?(value, index + 1)
          write_indent
          index += 1
        else
          index = write_character(value, index)
        end
        spaces = true
      elsif line_break?(value, index)
        put_break if !breaks && value[index] == 0x0A_u8
        index = write_break(value, index)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        put(0x27_u8) if value[index] == 0x27_u8
        index = write_character(value, index)
        finish = text_run_end(value, index, 0x27_u8, 0_u8, allow_breaks)
        spaces = finish > index && value[finish - 1] == 0x20_u8
        index = write_ascii_run(value, index, finish)
        @indention = false
        breaks = false
      end
    end

    write_indent if breaks
    write_indicator(SINGLE_QUOTE_INDICATOR, false, false, false)

    @whitespace = false
    @indention = false
  end

  # Returns the code point of the character at *index*, which is *width*
  # bytes long.
  private def decode_character(bytes : Bytes, index : Int32, width : Int32) : UInt32
    octet = bytes[index]
    value =
      case width
      when 1 then (octet & 0x7F).to_u32
      when 2 then (octet & 0x1F).to_u32
      when 3 then (octet & 0x0F).to_u32
      else        (octet & 0x07).to_u32
      end
    offset = 1
    while offset < width
      value = (value << 6) + (bytes[index + offset] & 0x3F)
      offset += 1
    end
    value
  end

  # Writes the escape for *code_point* after the backslash.
  private def write_escape(code_point : UInt32) : Nil
    short_escape =
      case code_point
      when   0x00 then '0'
      when   0x07 then 'a'
      when   0x08 then 'b'
      when   0x09 then 't'
      when   0x0A then 'n'
      when   0x0B then 'v'
      when   0x0C then 'f'
      when   0x0D then 'r'
      when   0x1B then 'e'
      when   0x22 then '"'
      when   0x5C then '\\'
      when   0x85 then 'N'
      when   0xA0 then '_'
      when 0x2028 then 'L'
      when 0x2029 then 'P'
      end
    if short_escape
      put(short_escape.ord.to_u8)
      return
    end

    digits =
      if code_point <= 0xFF
        put(0x78_u8)
        2
      elsif code_point <= 0xFFFF
        put(0x75_u8)
        4
      else
        put(0x55_u8)
        8
      end
    shift = (digits - 1) * 4
    while shift >= 0
      put(UPPERCASE_HEX_DIGITS[(code_point >> shift) & 0x0F])
      shift -= 4
    end
  end

  private def write_double_quoted_scalar(value : Bytes, allow_breaks : Bool) : Nil
    spaces = false

    write_indicator(DOUBLE_QUOTE_INDICATOR, true, false, false)

    index = 0
    while index < value.size
      # A run that needs neither an escape nor a line break decision.
      finish = text_run_end(value, index, 0x22_u8, 0x5C_u8, allow_breaks)
      if finish > index
        spaces = value[finish - 1] == 0x20_u8
        index = write_ascii_run(value, index, finish)
        next
      end
      octet = value[index]
      if !printable?(value, index) || byte_order_mark?(value, index) || line_break?(value, index) ||
         octet == 0x22_u8 || octet == 0x5C_u8
        width = char_width(value, index)
        code_point = decode_character(value, index, width)
        index += width
        put(0x5C_u8)
        write_escape(code_point)
        spaces = false
      elsif octet == 0x20_u8
        if allow_breaks && !spaces && @column > BEST_WIDTH && index != 0 && index != value.size - 1
          write_indent
          put(0x5C_u8) if space?(value, index + 1)
          index += 1
        else
          index = write_character(value, index)
        end
        spaces = true
      else
        index = write_character(value, index)
        spaces = false
      end
    end

    write_indicator(DOUBLE_QUOTE_INDICATOR, false, false, false)

    @whitespace = false
    @indention = false
  end

  # Returns the index of the character before the one at *index*.
  private def previous_character(bytes : Bytes, index : Int32) : Int32
    index -= 1
    while index > 0 && bytes[index] & 0xC0 == 0x80
      index -= 1
    end
    index
  end

  # Writes the indentation indicator (when the scalar starts with a space
  # or a line break) and the chomping indicator of a block scalar.
  private def write_block_scalar_hints(value : Bytes) : Nil
    if space?(value, 0) || line_break?(value, 0)
      write_indicator(INDENT_HINT_INDICATOR, false, false, false)
    end

    @open_ended = 0

    chomp_hint = nil
    if value.empty?
      chomp_hint = STRIP_CHOMPING_INDICATOR
    else
      last = previous_character(value, value.size)
      if !line_break?(value, last)
        chomp_hint = STRIP_CHOMPING_INDICATOR
      elsif last == 0
        chomp_hint = KEEP_CHOMPING_INDICATOR
        @open_ended = 2
      elsif line_break?(value, previous_character(value, last))
        chomp_hint = KEEP_CHOMPING_INDICATOR
        @open_ended = 2
      end
    end

    write_indicator(chomp_hint, false, false, false) if chomp_hint
  end

  private def write_literal_scalar(value : Bytes) : Nil
    breaks = true

    write_indicator(LITERAL_INDICATOR, true, false, false)
    write_block_scalar_hints(value)
    put_break
    @indention = true
    @whitespace = true

    index = 0
    while index < value.size
      if line_break?(value, index)
        index = write_break(value, index)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        index = write_character(value, index)
        index = write_ascii_run(value, index, line_run_end(value, index, false))
        @indention = false
        breaks = false
      end
    end
  end

  private def write_folded_scalar(value : Bytes) : Nil
    breaks = true
    leading_spaces = true

    write_indicator(FOLDED_INDICATOR, true, false, false)
    write_block_scalar_hints(value)
    put_break
    @indention = true
    @whitespace = true

    index = 0
    while index < value.size
      if line_break?(value, index)
        if !breaks && !leading_spaces && value[index] == 0x0A_u8
          after_breaks = index
          while line_break?(value, after_breaks)
            after_breaks += char_width(value, after_breaks)
          end
          put_break unless blank_or_break_or_end?(value, after_breaks)
        end
        index = write_break(value, index)
        @indention = true
        breaks = true
      else
        if breaks
          write_indent
          leading_spaces = blank?(value, index)
        end
        if !breaks && space?(value, index) && !space?(value, index + 1) && @column > BEST_WIDTH
          write_indent
          index += 1
        else
          index = write_character(value, index)
        end
        index = write_ascii_run(value, index, line_run_end(value, index, true))
        @indention = false
        breaks = false
      end
    end
  end
end
