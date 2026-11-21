module Regex::Mica::Regex
  class Parser
    # What a backslash sequence turned out to be (PCRE2's ESC_ codes).
    private enum EscapeKind
      # A data character, in `Escape#code_point`.
      Literal
      # `\1`..`\9`, `\g{n}` and the other numbered or named back references.
      Backreference
      # `\g<...>` and `\g'...'`.
      Subroutine
      StartOfText        # \A
      NotWordBoundary    # \B
      WordBoundary       # \b
      SingleCodeUnit     # \C
      NotDigit           # \D
      Digit              # \d
      EndQuote           # \E
      SearchStart        # \G
      NotHorizontalSpace # \H
      HorizontalSpace    # \h
      KeepOut            # \K
      NamedBackreference # \k
      NotNewline         # \N
      NotProperty        # \P
      Property           # \p
      Quote              # \Q
      LineBreak          # \R
      NotSpace           # \S
      Space              # \s
      NotVerticalSpace   # \V
      VerticalSpace      # \v
      NotWord            # \W
      Word               # \w
      GraphemeCluster    # \X
      EndOrFinalNewline  # \Z
      EndOfText          # \z
    end

    private record Escape, escape_kind : EscapeKind, code_point : Int32 = 0

    # A backslash outside a class; @pos is just after the backslash.
    private def parse_escape(start : Int32) : Nil
      escape = check_escape(in_class: false)
      case escape.escape_kind
      in .literal?
        add_literal(escape.code_point, start)
      in .backreference?, .named_backreference?
        check_named_backreference_syntax if escape.escape_kind.named_backreference?
        unsupported("a backreference", start)
      in .subroutine?
        unsupported("recursion or a subroutine call", start)
      in .single_code_unit?
        unsupported("\\C (one code unit)", start)
      in .keep_out?
        unsupported("\\K (reset the match start)", start)
      in .grapheme_cluster?
        unsupported("\\X (an extended grapheme cluster, until milestone R9)", start)
      in .horizontal_space?, .not_horizontal_space?, .vertical_space?, .not_vertical_space?,
         .digit?, .not_digit?, .space?, .not_space?, .word?, .not_word?
        append_class(class_escape_item(escape.escape_kind), start)
      in .property?, .not_property?
        append_class(read_property(escape.escape_kind.not_property?, in_class: false), start)
      in .not_newline?
        add_any_character(start, false)
      in .line_break?
        charge_node(instance_sizeof(Ast::LineBreak), start)
        append(Ast::LineBreak.new(start, @any_crlf_line_breaks))
        @quantifiable = true
      in .start_of_text?
        add_assertion(start, Ast::AssertionKind::StartOfText)
      in .end_of_text?
        add_assertion(start, Ast::AssertionKind::EndOfText)
      in .end_or_final_newline?
        add_assertion(start, Ast::AssertionKind::EndOfTextOrFinalNewline)
      in .word_boundary?
        add_assertion(start, Ast::AssertionKind::WordBoundary, @options.ascii_backslash_w?)
      in .not_word_boundary?
        add_assertion(start, Ast::AssertionKind::NotWordBoundary, @options.ascii_backslash_w?)
      in .search_start?
        add_assertion(start, Ast::AssertionKind::SearchStart)
      in .quote?, .end_quote?
        raise_internal("\\Q and \\E reach the escape parser", start)
      end
    end

    # `\k` must be followed by a braced, angle-bracketed or quoted name.
    private def check_named_backreference_syntax : Nil
      following = peek_byte
      return if following == '{'.ord || following == '<'.ord || following == '\''.ord
      syntax_error("\\k is not followed by a braced, angle-bracketed, or quoted name", @pos)
    end

    # Appends a class of the single *class_item* (a class escape outside
    # brackets).
    private def append_class(class_item : Ast::ClassItem, start : Int32) : Nil
      charge_node(instance_sizeof(Ast::CharClass), start)
      @ledger.charge_array(1, sizeof(Ast::ClassItem), "class items", start)
      append(Ast::CharClass.new(start, [class_item], false, @options))
      @quantifiable = true
    end

    # The class item for `\d \D \s \S \w \W \h \H \v \V`: Unicode sets, or
    # the ASCII tables when `(?aD)`, `(?aS)` or `(?aW)` is in force.
    private def class_escape_item(kind : EscapeKind) : Ast::ClassItem
      case kind
      when .digit?, .not_digit?
        negated = kind.not_digit?
        return Ast::ClassItem.ascii(Ast::AsciiSet::Digit, negated) if @options.ascii_backslash_d?
        Ast::ClassItem.unicode_set(Unicode::Tables::SET_GC_ND, negated)
      when .space?, .not_space?
        negated = kind.not_space?
        return Ast::ClassItem.ascii(Ast::AsciiSet::Space, negated) if @options.ascii_backslash_s?
        Ast::ClassItem.unicode_set(Unicode::Tables::SET_XSP, negated)
      when .word?, .not_word?
        negated = kind.not_word?
        return Ast::ClassItem.ascii(Ast::AsciiSet::Word, negated) if @options.ascii_backslash_w?
        Ast::ClassItem.unicode_set(Unicode::Tables::SET_XWD, negated)
      when .horizontal_space?, .not_horizontal_space?
        Ast::ClassItem.unicode_set(Unicode::Tables::SET_HSPACE, kind.not_horizontal_space?)
      else
        Ast::ClassItem.unicode_set(Unicode::Tables::SET_VSPACE, kind.not_vertical_space?)
      end
    end

    # Reads the property after `\p` or `\P` (@pos is after the letter) with
    # PCRE2's loose matching, and returns its class item. Under
    # `IgnoreCase`, `Lu`, `Ll` and `Lt` become `L&`, as in PCRE2.
    private def read_property(negated : Bool, in_class : Bool) : Ast::ClassItem
      syntax_error("malformed \\P or \\p sequence", @pos) if @pos >= @bytes.size
      @ledger.charge(PROPERTY_NAME_BYTES, "a property name", @pos)
      c = read_char
      loose = ""
      if c == '{'.ord
        syntax_error("malformed \\P or \\p sequence", @pos) if @pos >= @bytes.size
        builder = String::Builder.new
        length = 0
        closed = false
        caret_negated = false
        while length < 49
          syntax_error("malformed \\P or \\p sequence", @pos) if @pos >= @bytes.size
          c = read_char
          charge_work(1)
          next if c == '_'.ord || c == '-'.ord || c == ' '.ord || (0x09 <= c <= 0x0D)
          if length == 0 && c == '^'.ord && !caret_negated
            caret_negated = true
            next
          end
          if c == '}'.ord
            closed = true
            break
          end
          syntax_error("malformed \\P or \\p sequence", @pos) if c < '&'.ord || c > 'z'.ord
          c |= 0x20 if 'A'.ord <= c <= 'Z'.ord
          builder << c.chr
          length += 1
        end
        negated = !negated if caret_negated
        syntax_error("malformed \\P or \\p sequence", @pos) unless closed
        loose = builder.to_s
      elsif 'A'.ord <= c <= 'Z'.ord
        loose = (c | 0x20).chr.to_s
      elsif 'a'.ord <= c <= 'z'.ord
        loose = c.chr.to_s
      else
        syntax_error("malformed \\P or \\p sequence", @pos)
      end
      property = Unicode.lookup(loose) || syntax_error("unknown property after \\P or \\p", @pos)
      set_id = property.set_id
      if @options.ignore_case? && property.kind.general_category? && cased_letter_category?(set_id)
        set_id = Unicode::Tables::SET_LAMP
      end
      Ast::ClassItem.unicode_set(set_id, negated)
    end

    private def cased_letter_category?(set_id : Int32) : Bool
      set_id == Unicode::Tables::SET_GC_LU || set_id == Unicode::Tables::SET_GC_LL || set_id == Unicode::Tables::SET_GC_LT
    end

    # PCRE2's check_escape: @pos is just after the backslash; on return it
    # is after the whole sequence.
    private def check_escape(in_class : Bool) : Escape
      syntax_error("\\ at end of pattern", @pos) if @pos >= @bytes.size
      c = read_char
      charge_work(1)
      return Escape.new(EscapeKind::Literal, c) if c < '0'.ord || c > 'z'.ord
      case c
      when 'a'.ord then Escape.new(EscapeKind::Literal, 0x07)
      when 'e'.ord then Escape.new(EscapeKind::Literal, 0x1B)
      when 'f'.ord then Escape.new(EscapeKind::Literal, 0x0C)
      when 'n'.ord then Escape.new(EscapeKind::Literal, 0x0A)
      when 'r'.ord then Escape.new(EscapeKind::Literal, 0x0D)
      when 't'.ord then Escape.new(EscapeKind::Literal, 0x09)
      when 'A'.ord then Escape.new(EscapeKind::StartOfText)
      when 'B'.ord then Escape.new(EscapeKind::NotWordBoundary)
      when 'b'.ord then Escape.new(EscapeKind::WordBoundary)
      when 'C'.ord then Escape.new(EscapeKind::SingleCodeUnit)
      when 'D'.ord then Escape.new(EscapeKind::NotDigit)
      when 'd'.ord then Escape.new(EscapeKind::Digit)
      when 'E'.ord then Escape.new(EscapeKind::EndQuote)
      when 'G'.ord then Escape.new(EscapeKind::SearchStart)
      when 'H'.ord then Escape.new(EscapeKind::NotHorizontalSpace)
      when 'h'.ord then Escape.new(EscapeKind::HorizontalSpace)
      when 'K'.ord then Escape.new(EscapeKind::KeepOut)
      when 'k'.ord then Escape.new(EscapeKind::NamedBackreference)
      when 'N'.ord then read_backslash_n(in_class)
      when 'P'.ord then Escape.new(EscapeKind::NotProperty)
      when 'p'.ord then Escape.new(EscapeKind::Property)
      when 'Q'.ord then Escape.new(EscapeKind::Quote)
      when 'R'.ord then Escape.new(EscapeKind::LineBreak)
      when 'S'.ord then Escape.new(EscapeKind::NotSpace)
      when 's'.ord then Escape.new(EscapeKind::Space)
      when 'V'.ord then Escape.new(EscapeKind::NotVerticalSpace)
      when 'v'.ord then Escape.new(EscapeKind::VerticalSpace)
      when 'W'.ord then Escape.new(EscapeKind::NotWord)
      when 'w'.ord then Escape.new(EscapeKind::Word)
      when 'X'.ord then Escape.new(EscapeKind::GraphemeCluster)
      when 'Z'.ord then Escape.new(EscapeKind::EndOrFinalNewline)
      when 'z'.ord then Escape.new(EscapeKind::EndOfText)
      when ':'.ord..'@'.ord, '['.ord..'`'.ord
        Escape.new(EscapeKind::Literal, c)
      when 'F'.ord, 'l'.ord, 'L'.ord, 'u'.ord, 'U'.ord
        syntax_error("PCRE2 does not support \\F, \\L, \\l, \\N{name}, \\U, or \\u", @pos)
      when 'g'.ord
        return Escape.new(EscapeKind::Literal, c) if in_class
        read_backslash_g
      when '1'.ord..'9'.ord
        read_backslash_digit(c, in_class)
      when '0'.ord
        read_octal(c)
      when 'o'.ord
        read_braced_octal
      when 'x'.ord
        read_hex
      when 'c'.ord
        read_control
      else
        syntax_error("unrecognized character follows \\", @pos)
      end
    end

    # `\N`, `\N{U+hhhh}`, or `\N` before a `{n,m}` quantifier.
    private def read_backslash_n(in_class : Bool) : Escape
      return Escape.new(EscapeKind::NotNewline) unless peek_byte == '{'.ord
      cursor = @pos + 1
      while cursor < @bytes.size && space_or_tab?(@bytes[cursor])
        cursor += 1
      end
      if @bytes.size - cursor > 1 && @bytes[cursor] == 'U'.ord && @bytes[cursor + 1] == '+'.ord
        @pos = cursor + 2
        return Escape.new(EscapeKind::Literal, read_braced_hex_digits)
      end
      if in_class
        @pos += 1
        syntax_error("PCRE2 does not support \\F, \\L, \\l, \\N{name}, \\U, or \\u", @pos)
      end
      saved = @pos
      @pos += 1
      counts = read_repeat_counts
      @pos = saved
      unless counts
        @pos += 1
        syntax_error("PCRE2 does not support \\F, \\L, \\l, \\N{name}, \\U, or \\u", @pos)
      end
      Escape.new(EscapeKind::NotNewline)
    end

    # `\g` outside a class: a back reference by number or name, or a
    # subroutine call; all outside the dialect, but malformed forms are
    # syntax errors as in PCRE2.
    private def read_backslash_g : Escape
      syntax_error("\\g is not followed by a braced, angle-bracketed, or quoted name/number or by a plain number", @pos) if @pos >= @bytes.size
      following = @bytes[@pos]
      return Escape.new(EscapeKind::Subroutine) if following == '<'.ord || following == '\''.ord
      return Escape.new(EscapeKind::Backreference) if following == '{'.ord
      signed = (following == '+'.ord || following == '-'.ord) && @pos + 1 < @bytes.size && digit?(@bytes[@pos + 1])
      return Escape.new(EscapeKind::Backreference) if digit?(following) || signed
      syntax_error("\\g is not followed by a braced, angle-bracketed, or quoted name/number or by a plain number", @pos)
    end

    # `\1`..`\9` and longer numbers: a back reference outside a class when
    # below 10, starting with 8 or 9, or no larger than the groups opened so
    # far; otherwise (and always inside a class) up to three octal digits.
    private def read_backslash_digit(first : Int32, in_class : Bool) : Escape
      unless in_class
        digits_start = @pos - 1
        cursor = digits_start
        value = 0
        too_big = false
        while cursor < @bytes.size && digit?(@bytes[cursor])
          value = value * 10 + (@bytes[cursor] - '0'.ord)
          cursor += 1
          if value > CompileLimits::MAX_GROUP_NUMBER
            too_big = true
            while cursor < @bytes.size && digit?(@bytes[cursor])
              cursor += 1
            end
            break
          end
        end
        if too_big
          if first >= '8'.ord
            @pos = cursor
            syntax_error("subpattern number is too big", @pos)
          end
        elsif value < 10 || first >= '8'.ord || value <= @group_count
          @pos = cursor
          return Escape.new(EscapeKind::Backreference)
        end
      end
      return Escape.new(EscapeKind::Literal, first) if first >= '8'.ord
      read_octal(first)
    end

    # Up to three octal digits, the first already read.
    private def read_octal(first : Int32) : Escape
      value = first - '0'.ord
      2.times do
        break unless @pos < @bytes.size && '0'.ord <= @bytes[@pos] <= '7'.ord
        value = value * 8 + (@bytes[@pos] - '0'.ord)
        @pos += 1
      end
      Escape.new(EscapeKind::Literal, value)
    end

    # `\o{ddd}`.
    private def read_braced_octal : Escape
      if @pos >= @bytes.size || @bytes[@pos] != '{'.ord
        syntax_error("missing opening brace after \\o", @pos)
      end
      @pos += 1
      while @pos < @bytes.size && space_or_tab?(@bytes[@pos])
        @pos += 1
      end
      if @pos >= @bytes.size || @bytes[@pos] == '}'.ord
        syntax_error("digits missing after \\x or in \\x{} or \\o{} or \\N{U+}", @pos)
      end
      value = 0
      overflow = false
      while @pos < @bytes.size && '0'.ord <= @bytes[@pos] <= '7'.ord
        digit = @bytes[@pos] - '0'.ord
        @pos += 1
        next if value == 0 && digit == 0
        value = (value << 3) + digit
        if value > 0x10FFFF
          overflow = true
          break
        end
      end
      while @pos < @bytes.size && space_or_tab?(@bytes[@pos])
        @pos += 1
      end
      if overflow
        while @pos < @bytes.size && '0'.ord <= @bytes[@pos] <= '7'.ord
          @pos += 1
        end
        syntax_error("character code point value in \\x{} or \\o{} is too large", @pos)
      end
      check_not_surrogate(value)
      if @pos < @bytes.size && @bytes[@pos] == '}'.ord
        @pos += 1
      else
        forward_one_character if @pos < @bytes.size
        syntax_error("non-octal character in \\o{} (closing brace missing?)", @pos)
      end
      Escape.new(EscapeKind::Literal, value)
    end

    # `\xhh` (one or two digits) or `\x{h...}`.
    private def read_hex : Escape
      if @pos < @bytes.size && @bytes[@pos] == '{'.ord
        @pos += 1
        while @pos < @bytes.size && space_or_tab?(@bytes[@pos])
          @pos += 1
        end
        return Escape.new(EscapeKind::Literal, read_braced_hex_digits)
      end
      if @pos >= @bytes.size || hex_value(@bytes[@pos]) < 0
        syntax_error("digits missing after \\x or in \\x{} or \\o{} or \\N{U+}", @pos)
      end
      value = hex_value(@bytes[@pos])
      @pos += 1
      if @pos < @bytes.size && hex_value(@bytes[@pos]) >= 0
        value = (value << 4) | hex_value(@bytes[@pos])
        @pos += 1
      end
      Escape.new(EscapeKind::Literal, value)
    end

    # The digits and closing brace of `\x{...}` or `\N{U+...}`; @pos is at
    # the first digit.
    private def read_braced_hex_digits : Int32
      if @pos >= @bytes.size || @bytes[@pos] == '}'.ord
        syntax_error("digits missing after \\x or in \\x{} or \\o{} or \\N{U+}", @pos)
      end
      value = 0
      overflow = false
      while @pos < @bytes.size && hex_value(@bytes[@pos]) >= 0
        digit = hex_value(@bytes[@pos])
        @pos += 1
        charge_work(1)
        next if value == 0 && digit == 0
        value = (value << 4) | digit
        if value > 0x10FFFF
          overflow = true
          break
        end
      end
      while @pos < @bytes.size && space_or_tab?(@bytes[@pos])
        @pos += 1
      end
      if overflow
        while @pos < @bytes.size && hex_value(@bytes[@pos]) >= 0
          @pos += 1
        end
        syntax_error("character code point value in \\x{} or \\o{} is too large", @pos)
      end
      check_not_surrogate(value)
      if @pos < @bytes.size && @bytes[@pos] == '}'.ord
        @pos += 1
      else
        forward_one_character if @pos < @bytes.size
        syntax_error("non-hex character in \\x{} (closing brace missing?)", @pos)
      end
      value
    end

    private def check_not_surrogate(value : Int32) : Nil
      return unless 0xD800 <= value <= 0xDFFF
      syntax_error("disallowed Unicode code point (>= 0xd800 && <= 0xdfff)", @pos)
    end

    # `\cX`: a printable ASCII character, upper-cased, with bit 0x40 flipped.
    private def read_control : Escape
      syntax_error("\\c at end of pattern", @pos) if @pos >= @bytes.size
      value = @bytes[@pos].to_i32
      if value >= 0x80
        forward_one_character
        syntax_error("\\c must be followed by a printable ASCII character", @pos)
      end
      value -= 32 if 'a'.ord <= value <= 'z'.ord
      if value < 32 || value > 126
        @pos += 1
        syntax_error("\\c must be followed by a printable ASCII character", @pos)
      end
      @pos += 1
      Escape.new(EscapeKind::Literal, value ^ 0x40)
    end

    private def forward_one_character : Nil
      @pos += Core::UTF8.sequence_length(@bytes[@pos])
    end
  end
end
