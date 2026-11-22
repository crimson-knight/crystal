class YAML::Mica::YAML::Emitter
  private PRIMARY_TAG_HANDLE   = "!".to_slice
  private SECONDARY_TAG_HANDLE = "!!".to_slice
  private SECONDARY_TAG_PREFIX = "tag:yaml.org,2002:".to_slice

  # Returns true when *bytes* pass libyaml's `yaml_check_utf8`: every
  # sequence has a valid lead byte, its continuation bytes and no overlong
  # form. (Like libyaml, the check accepts encoded surrogates and 4-byte
  # values above U+10FFFF.)
  private def valid_utf8?(bytes : Bytes) : Bool
    index = 0
    while index < bytes.size
      octet = bytes[index]
      width = char_width(bytes, index)
      return false if width == 0
      return false if index + width > bytes.size
      value =
        case width
        when 1 then (octet & 0x7F).to_u32
        when 2 then (octet & 0x1F).to_u32
        when 3 then (octet & 0x0F).to_u32
        else        (octet & 0x07).to_u32
        end
      offset = 1
      while offset < width
        continuation = bytes[index + offset]
        return false unless continuation & 0xC0 == 0x80
        value = (value << 6) + (continuation & 0x3F)
        offset += 1
      end
      return false if width == 2 && value < 0x80
      return false if width == 3 && value < 0x800
      return false if width == 4 && value < 0x10000
      index += width
    end
    true
  end

  # Returns the byte at *index*, or NUL past the end: libyaml keeps a NUL
  # after every string and its character tests read up to two bytes ahead.
  private def byte_at(bytes : Bytes, index : Int32) : UInt8
    index < bytes.size ? bytes[index] : 0_u8
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

  # Returns true for a printable ASCII character that is neither a space
  # nor an indicator `analyze_scalar` looks for after the first character
  # (`,`, `?`, `[`, `]`, `{`, `}`, `:` and `#`).
  @[AlwaysInline]
  private def inert?(octet : UInt8) : Bool
    return false unless 0x21_u8 <= octet <= 0x7E_u8
    case octet
    when 0x2C_u8, 0x3F_u8, 0x5B_u8, 0x5D_u8, 0x7B_u8, 0x7D_u8, 0x3A_u8, 0x23_u8
      false
    else
      true
    end
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
    return true if octet == 0x0A_u8
    return true if 0x20_u8 <= octet <= 0x7E_u8
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

  private def space?(bytes : Bytes, index : Int32) : Bool
    byte_at(bytes, index) == 0x20_u8
  end

  # Returns true for a space or a tab.
  private def blank?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    octet == 0x20_u8 || octet == 0x09_u8
  end

  # Returns true for CR, LF, NEL (U+0085), LS (U+2028) and PS (U+2029).
  private def line_break?(bytes : Bytes, index : Int32) : Bool
    octet = byte_at(bytes, index)
    return true if octet == 0x0D_u8 || octet == 0x0A_u8
    return byte_at(bytes, index + 1) == 0x85_u8 if octet == 0xC2_u8
    return false unless octet == 0xE2_u8 && byte_at(bytes, index + 1) == 0x80_u8
    third = byte_at(bytes, index + 2)
    third == 0xA8_u8 || third == 0xA9_u8
  end

  # Returns true for a space, a tab, a line break, NUL or the end of the
  # string.
  private def blank_or_break_or_end?(bytes : Bytes, index : Int32) : Bool
    blank?(bytes, index) || line_break?(bytes, index) || byte_at(bytes, index) == 0_u8
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
    followed_by_whitespace = blank_or_break_or_end?(value, char_width(value, 0))

    index = 0
    while index < value.size
      octet = value[index]
      if index > 0 && inert?(octet)
        # A run of characters that change nothing but the "previous
        # character" flags: skip to its end, then look ahead once for the
        # character that follows, as the general path does at every step.
        previous_space = false
        previous_break = false
        preceded_by_whitespace = false
        index += 1
        while index < value.size && inert?(value.unsafe_fetch(index))
          index += 1
        end
        if index < value.size
          followed_by_whitespace = blank_or_break_or_end?(value, index + char_width(value, index))
        end
        next
      end
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
      else
        case octet
        when ','.ord, '?'.ord, '['.ord, ']'.ord, '{'.ord, '}'.ord
          flow_indicators = true
        when ':'.ord
          flow_indicators = true
          block_indicators = true if followed_by_whitespace
        when '#'.ord
          if preceded_by_whitespace
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
        trailing_space = true if index + width == value.size
        break_space = true if previous_break
        previous_space = true
        previous_break = false
      elsif is_break
        leading_break = true if index == 0
        trailing_break = true if index + width == value.size
        space_break = true if previous_space
        previous_space = false
        previous_break = true
      else
        previous_space = false
        previous_break = false
      end

      preceded_by_whitespace = blank_or_break_or_end?(value, index)
      index += width
      if index < value.size
        followed_by_whitespace = blank_or_break_or_end?(value, index + char_width(value, index))
      end
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
