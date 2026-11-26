class YAML::Mica::YAML::Emitter
  private PRIMARY_TAG_HANDLE   = "!".to_slice
  private SECONDARY_TAG_HANDLE = "!!".to_slice
  private SECONDARY_TAG_PREFIX = "tag:yaml.org,2002:".to_slice

  # Returns true when *bytes* pass libyaml's `yaml_check_utf8`: every
  # sequence has a valid lead byte, its continuation bytes and no overlong
  # form. (Like libyaml, the check accepts encoded surrogates and 4-byte
  # values above U+10FFFF.) ASCII is skipped eight bytes at a time; only
  # the multi-byte sequences are decoded.
  private def valid_utf8?(bytes : Bytes) : Bool
    size = bytes.size
    index = 0
    while true
      index = Core::ByteScan.skip_ascii(bytes, index, size)
      return true if index == size
      # skip_ascii returned index < size, and bytes[index] is not ASCII.
      octet = bytes.unsafe_fetch(index)
      if octet & 0xE0 == 0xC0
        width = 2
        value = (octet & 0x1F).to_u32
      elsif octet & 0xF0 == 0xE0
        width = 3
        value = (octet & 0x0F).to_u32
      elsif octet & 0xF8 == 0xF0
        width = 4
        value = (octet & 0x07).to_u32
      else
        return false
      end
      return false if index + width > size
      offset = 1
      while offset < width
        # index + offset < index + width <= size.
        continuation = bytes.unsafe_fetch(index + offset)
        return false unless continuation & 0xC0 == 0x80
        value = (value << 6) + (continuation & 0x3F)
        offset += 1
      end
      return false if width == 2 && value < 0x80
      return false if width == 3 && value < 0x800
      return false if width == 4 && value < 0x10000
      index += width
    end
  end

  # Returns the byte at *index*, or NUL past the end: libyaml keeps a NUL
  # after every string and its character tests read up to two bytes ahead.
  @[AlwaysInline]
  private def byte_at(bytes : Bytes, index : Int32) : UInt8
    return 0_u8 if index >= bytes.size
    return bytes[index] if index < 0
    # 0 <= index < bytes.size.
    bytes.unsafe_fetch(index)
  end

  # Returns the length in bytes of the character whose lead byte is at
  # *index*, or 0 when that byte cannot start a character.
  private def char_width(bytes : Bytes, index : Int32) : Int32
    octet = byte_at(bytes, index)
    if octet & 0x80 == 0x00
      1
    elsif octet & 0xE0 == 0xC0
      2
    elsif octet & 0xF0 == 0xE0
      3
    elsif octet & 0xF8 == 0xF0
      4
    else
      0
    end
  end

  # Classes of an ASCII byte for `analyze_scalar`, one bit each.
  #
  # LF or a character from 0x20 through 0x7E (what `printable?` accepts).
  private SCALAR_PRINTABLE = 0x01_u8
  # A space, a tab, CR, LF or NUL (`blank_or_break_or_end?`).
  private SCALAR_WHITESPACE = 0x02_u8
  # A space, or a printable character that is not an indicator
  # `analyze_scalar` looks for after the first character (`,`, `?`, `[`,
  # `]`, `{`, `}`, `:` and `#`): a run of these changes only the "previous
  # character" flags.
  private SCALAR_RUN = 0x04_u8

  # One entry per byte value; non-ASCII bytes have no class bits.
  private SCALAR_CLASSES = begin
    table = StaticArray(UInt8, 256).new(0_u8)
    128.times do |octet|
      classes = 0_u8
      classes |= SCALAR_PRINTABLE if octet == 0x0A || 0x20 <= octet <= 0x7E
      classes |= SCALAR_WHITESPACE if {0x00, 0x09, 0x0A, 0x0D, 0x20}.includes?(octet)
      if 0x20 <= octet <= 0x7E && !",?[]{}:#".includes?(octet.chr)
        classes |= SCALAR_RUN
      end
      table[octet] = classes
    end
    table
  end

  # Returns true for an ASCII letter, a digit, `_` or `-`.
  private def alphanumerical?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    (0x30_u8 <= octet <= 0x39_u8) || (0x41_u8 <= octet <= 0x5A_u8) ||
      (0x61_u8 <= octet <= 0x7A_u8) || octet == 0x5F_u8 || octet == 0x2D_u8
  end

  # Returns true when the character at *index* may appear unescaped: LF,
  # printable ASCII, and U+00A0 through U+FFFD except the surrogates and
  # U+FEFF. Characters above U+FFFF count as not printable, as in libyaml.
  private def printable?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    return octet == 0x0A_u8 || 0x20_u8 <= octet <= 0x7E_u8 if octet < 0x80_u8
    return byte_at(bytes, index + 1) >= 0xA0_u8 if octet == 0xC2_u8
    return true if 0xC2_u8 < octet < 0xED_u8
    return byte_at(bytes, index + 1) < 0xA0_u8 if octet == 0xED_u8
    return true if octet == 0xEE_u8
    return false unless octet == 0xEF_u8
    second = byte_at(bytes, index + 1)
    third = byte_at(bytes, index + 2)
    return false if second == 0xBB_u8 && third == 0xBF_u8
    return false if second == 0xBF_u8 && (third == 0xBE_u8 || third == 0xBF_u8)
    true
  end

  # Returns true for U+FEFF.
  private def byte_order_mark?(bytes : Bytes, index : Int32) : Bool
    byte_at(bytes, index) == 0xEF_u8 && byte_at(bytes, index + 1) == 0xBB_u8 &&
      byte_at(bytes, index + 2) == 0xBF_u8
  end

  @[AlwaysInline]
  private def space?(bytes : Bytes, index : Int32) : Bool
    byte_at(bytes, index) == 0x20_u8
  end

  # Returns true for a space or a tab.
  @[AlwaysInline]
  private def blank?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    octet == 0x20_u8 || octet == 0x09_u8
  end

  # Returns true for CR, LF, NEL (U+0085), LS (U+2028) and PS (U+2029).
  @[AlwaysInline]
  private def line_break?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    return octet == 0x0D_u8 || octet == 0x0A_u8 if octet < 0x80_u8
    multi_byte_line_break?(bytes, index, octet)
  end

  # Returns true for NEL, LS and PS, given the lead byte *octet* of the
  # character at *index*, which is not ASCII.
  private def multi_byte_line_break?(bytes : Bytes, index : Int32, octet : UInt8) : Bool
    return byte_at(bytes, index + 1) == 0x85_u8 if octet == 0xC2_u8
    return false unless octet == 0xE2_u8 && byte_at(bytes, index + 1) == 0x80_u8
    third = byte_at(bytes, index + 2)
    third == 0xA8_u8 || third == 0xA9_u8
  end

  # Returns true for a space, a tab, a line break, NUL or the end of the
  # string.
  @[AlwaysInline]
  private def blank_or_break_or_end?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    # Bits 0x00, 0x09, 0x0A, 0x0D and 0x20 of the mask: NUL, tab, LF, CR
    # and space.
    return octet <= 0x20_u8 && (0x1_0000_2601_u64 >> octet) & 1 != 0 if octet < 0x80_u8
    multi_byte_line_break?(bytes, index, octet)
  end

  # Checks the event at the head of the queue and records its anchor, tag
  # and scalar properties for the state machine.
  private def analyze_event(event : Event) : Nil
    @anchor = nil
    @tag_handle = nil
    @tag_suffix = nil
    @scalar_value = Bytes.empty

    kind = event.kind
    anchor = event.anchor
    tag = event.tag
    if kind.alias?
      analyze_anchor(anchor, true) if anchor
    elsif kind.scalar?
      analyze_anchor(anchor, false) if anchor
      analyze_tag(tag) if tag && !event.implicit && !event.quoted_implicit
      analyze_scalar(event.value)
    elsif kind.sequence_start? || kind.mapping_start?
      analyze_anchor(anchor, false) if anchor
      analyze_tag(tag) if tag && !event.implicit
    end
  end

  private def analyze_anchor(anchor : Bytes, is_alias : Bool) : Nil
    if anchor.empty?
      fail(is_alias ? "alias value must not be empty" : "anchor value must not be empty")
    end
    index = 0
    while index < anchor.size
      unless alphanumerical?(anchor, index)
        fail(is_alias ? "alias value must contain alphanumerical characters only" : "anchor value must contain alphanumerical characters only")
      end
      index += char_width(anchor, index)
    end
    @anchor = anchor
    @anchor_is_alias = is_alias
  end

  # Splits *tag* into a handle and a suffix using the two default tag
  # directives (`!` for `!` and `!!` for `tag:yaml.org,2002:`), which are
  # in force between DOCUMENT-START and DOCUMENT-END.
  private def analyze_tag(tag : Bytes) : Nil
    fail("tag value must not be empty") if tag.empty?
    if @has_tag_directives
      if tag.size > PRIMARY_TAG_HANDLE.size && tag[0] == 0x21_u8
        @tag_handle = PRIMARY_TAG_HANDLE
        @tag_suffix = tag[PRIMARY_TAG_HANDLE.size, tag.size - PRIMARY_TAG_HANDLE.size]
        return
      end
      prefix_size = SECONDARY_TAG_PREFIX.size
      if tag.size > prefix_size && tag[0, prefix_size] == SECONDARY_TAG_PREFIX
        @tag_handle = SECONDARY_TAG_HANDLE
        @tag_suffix = tag[prefix_size, tag.size - prefix_size]
        return
      end
    end
    @tag_suffix = tag
  end

  # Decides which scalar styles can represent *value*.
  private def analyze_scalar(value : Bytes) : Nil
    @scalar_value = value

    if value.empty?
      @scalar_multiline = false
      @flow_plain_allowed = false
      @block_plain_allowed = true
      @single_quoted_allowed = true
      @block_allowed = false
      return
    end

    block_indicators = false
    flow_indicators = false
    line_breaks = false
    special_characters = false
    leading_space = false
    leading_break = false
    trailing_space = false
    trailing_break = false
    break_space = false
    space_break = false
    previous_space = false
    previous_break = false

    first = value[0]
    if (first == 0x2D_u8 || first == 0x2E_u8) && byte_at(value, 1) == first && byte_at(value, 2) == first
      block_indicators = true
      flow_indicators = true
    end

    preceded_by_whitespace = true
    # Only the first character reads this; a `:` later in the value looks
    # at the character after it where it stands.
    followed_by_whitespace = blank_or_break_or_end?(value, char_width(value, 0))

    class_table = SCALAR_CLASSES.to_unsafe
    size = value.size
    index = 0
    while index < size
      # index < size.
      octet = value.unsafe_fetch(index)
      if index > 0 && octet < 0x80
        # An ASCII character after the first: one table lookup decides it.
        # octet < 0x80 < 256, inside the table.
        octet_classes = class_table[octet]
        if octet_classes & SCALAR_RUN != 0
          # A run of spaces and characters that are not indicators: inside
          # it only the first character can follow a break and only the
          # last can end the value, so skip to its end and set the flags
          # from those two.
          break_space = true if previous_break && octet == 0x20_u8
          index += 1
          # index < size before each read; every byte is below 256.
          while index < size && class_table[value.unsafe_fetch(index)] & SCALAR_RUN != 0
            index += 1
          end
          # The run holds at least the byte at the old index, so index - 1
          # is inside it.
          previous_space = value.unsafe_fetch(index - 1) == 0x20_u8
          previous_break = false
          preceded_by_whitespace = previous_space
          trailing_space = true if previous_space && index == size
          next
        end

        case octet
        when ','.ord, '?'.ord, '['.ord, ']'.ord, '{'.ord, '}'.ord
          flow_indicators = true
        when ':'.ord
          flow_indicators = true
          block_indicators = true if blank_or_break_or_end?(value, index + 1)
        when '#'.ord
          if preceded_by_whitespace
            flow_indicators = true
            block_indicators = true
          end
        end

        special_characters = true if octet_classes & SCALAR_PRINTABLE == 0

        if octet == 0x0A_u8 || octet == 0x0D_u8
          line_breaks = true
          trailing_break = true if index + 1 == size
          space_break = true if previous_space
          previous_space = false
          previous_break = true
        else
          previous_space = false
          previous_break = false
        end

        preceded_by_whitespace = octet_classes & SCALAR_WHITESPACE != 0
        index += 1
        next
      end

      # The first character, and every character that is not ASCII.
      if index == 0
        case octet
        when '#'.ord, ','.ord, '['.ord, ']'.ord, '{'.ord, '}'.ord, '&'.ord, '*'.ord, '!'.ord, '|'.ord, '>'.ord, '\''.ord, '"'.ord, '%'.ord, '@'.ord, '`'.ord
          flow_indicators = true
          block_indicators = true
        when '?'.ord, ':'.ord
          flow_indicators = true
          block_indicators = true if followed_by_whitespace
        when '-'.ord
          if followed_by_whitespace
            flow_indicators = true
            block_indicators = true
          end
        end
      end

      special_characters = true unless printable?(value, index)

      width = char_width(value, index)
      is_break = line_break?(value, index)
      line_breaks = true if is_break

      if octet == 0x20_u8
        leading_space = true if index == 0
        trailing_space = true if index + width == size
        break_space = true if previous_break
        previous_space = true
        previous_break = false
      elsif is_break
        leading_break = true if index == 0
        trailing_break = true if index + width == size
        space_break = true if previous_space
        previous_space = false
        previous_break = true
      else
        previous_space = false
        previous_break = false
      end

      preceded_by_whitespace = blank_or_break_or_end?(value, index)
      index += width
    end

    @scalar_multiline = line_breaks
    plain_allowed = true
    @single_quoted_allowed = true
    @block_allowed = true

    plain_allowed = false if leading_space || leading_break || trailing_space || trailing_break
    @block_allowed = false if trailing_space
    if break_space
      plain_allowed = false
      @single_quoted_allowed = false
    end
    if space_break || special_characters
      plain_allowed = false
      @single_quoted_allowed = false
      @block_allowed = false
    end
    plain_allowed = false if line_breaks

    @flow_plain_allowed = plain_allowed && !flow_indicators
    @block_plain_allowed = plain_allowed && !block_indicators
  end
end
