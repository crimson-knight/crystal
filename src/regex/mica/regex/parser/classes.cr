module Regex::Mica::Regex
  class Parser
    # PCRE2's class_range_state: whether the last item can start a range.
    private enum RangeState
      None
      Started
      ForbidNone
      ForbidStarted
      OkEscaped
      OkLiteral
    end

    # The POSIX class names in PCRE2's order.
    POSIX_NAMES = {"alpha", "lower", "upper", "alnum", "ascii", "blank", "cntrl", "digit", "graph", "print",
                   "punct", "space", "word", "xdigit"}

    # A `[` outside a class; @pos is just after it.
    private def parse_class(start : Int32) : Nil
      if word_boundary_class?
        kind = @bytes[@pos + 2] == '<'.ord ? Ast::AssertionKind::WordStart : Ast::AssertionKind::WordEnd
        @pos += 6
        add_posix_word_assertion(start, kind)
        @quantifiable = true
        return
      end
      if @pos < @bytes.size && posix_opener?(@bytes[@pos])
        if terminator = posix_syntax_end(@pos)
          message = @bytes[@pos] == ':'.ord ? "POSIX named classes are supported only within a class" : "POSIX collating elements are not supported"
          @pos = terminator + 2
          syntax_error(message, @pos)
        end
      end

      class_options = @options
      negated = false
      c = 0
      loop do
        syntax_error("missing terminating ] for character class", @pos) if @pos >= @bytes.size
        c = read_char
        if c == '\\'.ord
          if @pos < @bytes.size && @bytes[@pos] == 'E'.ord
            @pos += 1
          elsif ascii_at?(@pos, "Q\\E")
            @pos += 3
          else
            break
          end
        elsif (c == ' '.ord || c == '\t'.ord) && @options.extended_more?
          next
        elsif !negated && c == '^'.ord
          negated = true
        else
          break
        end
      end

      @ledger.charge_array(0, sizeof(Ast::ClassItem), "a class", start)
      # The items gather in the parser's scratch list (outside the
      # collector's heap, reused for every class); the class gets one
      # array of their exact number.
      @class_items.clear
      state = RangeState::None
      forbid_offset = 0
      if c == ']'.ord
        add_class_range(c, c, start)
        state = RangeState::OkLiteral
        syntax_error("missing terminating ] for character class", @pos) if @pos >= @bytes.size
        c = read_char
      end

      loop do
        charge_work(1)
        if @inside_quote
          if c == '\\'.ord && peek_byte == 'E'.ord
            @inside_quote = false
            @pos += 1
          else
            state = class_literal(c, state, true, forbid_offset, start)
          end
        elsif (c == ' '.ord || c == '\t'.ord) && @options.extended_more?
          # Skipped in extended-more mode.
        elsif c == '['.ord && @bytes.size - @pos >= 3 && posix_opener?(@bytes[@pos]) && (terminator = posix_syntax_end(@pos))
          if state.started?
            @pos = terminator + 2
            syntax_error("invalid range in character class", @pos)
          end
          if state.forbid_started?
            @pos = forbid_offset
            syntax_error("invalid range in character class", @pos)
          end
          unless @bytes[@pos] == ':'.ord
            @pos = terminator + 2
            syntax_error("POSIX collating elements are not supported", @pos)
          end
          @pos += 1
          posix_negated = false
          if @bytes[@pos] == '^'.ord
            posix_negated = true
            @pos += 1
          end
          @ledger.charge_string(terminator - @pos, "a POSIX class name", @pos)
          posix_name = String.new(@bytes[@pos, terminator - @pos])
          @pos = terminator + 2
          index = POSIX_NAMES.index(posix_name) || syntax_error("unknown POSIX class name", @pos)
          add_class_item(posix_class_item(index, posix_negated), start)
          state = RangeState::ForbidNone
        elsif c == ']'.ord
          if state.started?
            add_class_range('-'.ord, '-'.ord, start)
          end
          break
        elsif c == '\\'.ord
          escape = check_escape(in_class: true)
          kind = escape.escape_kind
          if kind.literal?
            state = class_literal(escape.code_point, state, false, forbid_offset, start)
          elsif kind.word_boundary?
            state = class_literal(0x08, state, false, forbid_offset, start)
          elsif kind.named_backreference?
            state = class_literal('k'.ord, state, false, forbid_offset, start)
          elsif kind.quote?
            @inside_quote = true
          elsif kind.end_quote?
            # An orphan \E is ignored.
          elsif kind.not_word_boundary? || kind.line_break? || kind.grapheme_cluster?
            syntax_error("escape sequence is invalid in character class", @pos)
          elsif kind.not_newline?
            syntax_error("\\N is not supported in a class", @pos)
          elsif kind.backreference? || kind.subroutine? || kind.start_of_text? || kind.end_or_final_newline? ||
                kind.end_of_text? || kind.search_start? || kind.keep_out? || kind.single_code_unit?
            syntax_error("escape sequence is invalid in character class", @pos)
          else
            item = if kind.property? || kind.not_property?
                     read_property(kind.not_property?, in_class: true)
                   else
                     class_escape_item(kind)
                   end
            add_class_item(item, start)
            syntax_error("invalid range in character class", @pos) if state.started?
            if state.forbid_started?
              @pos = forbid_offset
              syntax_error("invalid range in character class", @pos)
            end
            state = RangeState::ForbidNone
          end
        elsif c == '-'.ord && (state.ok_escaped? || state.ok_literal?)
          state = RangeState::Started
        elsif c == '-'.ord && state.forbid_none?
          add_class_range('-'.ord, '-'.ord, start)
          state = RangeState::ForbidStarted
          forbid_offset = @pos
        else
          state = class_literal(c, state, true, forbid_offset, start)
        end
        if @pos >= @bytes.size
          syntax_error("missing terminating ] for character class", @pos)
        end
        c = read_char
      end
      charge_node(instance_sizeof(Ast::CharClass), start)
      list_of_items = Array(Ast::ClassItem).new(@class_items.size)
      @class_items.each { |item| list_of_items << item }
      append(Ast::CharClass.new(start, list_of_items, negated, class_options))
      @quantifiable = true
    end

    # A literal character in a class: the end of a pending range, or a new
    # item that may start one.
    private def class_literal(code_point : Int32, state : RangeState,
                              literal : Bool, forbid_offset : Int32, start : Int32) : RangeState
      if state.started?
        last = @class_items.last
        low = last.first
        if code_point == low
          # A one-character range: already present.
        elsif low > code_point
          syntax_error("range out of order in character class", @pos)
        else
          @class_items[-1] = Ast::ClassItem.range(low, code_point)
        end
        return RangeState::None
      end
      if state.forbid_started?
        @pos = forbid_offset
        syntax_error("invalid range in character class", @pos)
      end
      add_class_range(code_point, code_point, start)
      literal ? RangeState::OkLiteral : RangeState::OkEscaped
    end

    private def add_class_range(first : Int32, last : Int32, start : Int32) : Nil
      add_class_item(Ast::ClassItem.range(first, last), start)
    end

    private def add_class_item(item : Ast::ClassItem, start : Int32) : Nil
      @ledger.charge_append(sizeof(Ast::ClassItem), "a class item", start)
      @class_items << item
    end

    # The item for POSIX class *index*: Unicode properties in UCP mode
    # (PCRE2's posix_substitutes), the ASCII tables under `(?aP)`, or for
    # digit and xdigit under `(?aT)`. Without UCP substitution, caseless
    # matching turns upper and lower into alpha.
    private def posix_class_item(index : Int32, negated : Bool) : Ast::ClassItem
      name = POSIX_NAMES[index]
      ascii = @options.ascii_posix? || (@options.ascii_digit? && (name == "digit" || name == "xdigit"))
      unless ascii
        set_id = case name
                 when "alpha"  then Unicode::Tables::SET_GCG_L
                 when "lower"  then Unicode::Tables::SET_GC_LL
                 when "upper"  then Unicode::Tables::SET_GC_LU
                 when "alnum"  then Unicode::Tables::SET_XAN
                 when "blank"  then Unicode::Tables::SET_HSPACE
                 when "cntrl"  then Unicode::Tables::SET_GC_CC
                 when "digit"  then Unicode::Tables::SET_GC_ND
                 when "graph"  then Unicode::Tables::SET_PXGRAPH
                 when "print"  then Unicode::Tables::SET_PXPRINT
                 when "punct"  then Unicode::Tables::SET_PXPUNCT
                 when "space"  then Unicode::Tables::SET_XSP
                 when "word"   then Unicode::Tables::SET_XWD
                 when "xdigit" then Unicode::Tables::SET_PXXDIGIT
                 end
        return Ast::ClassItem.unicode_set(set_id, negated) if set_id
      end
      ascii_set = Ast::AsciiSet.new(index)
      ascii_set = Ast::AsciiSet::Alpha if @options.ignore_case? && (ascii_set.lower? || ascii_set.upper?)
      Ast::ClassItem.ascii(ascii_set, negated)
    end

    # Appends `[[:<:]]` (*kind* `WordStart`) or `[[:>:]]` (`WordEnd`) as
    # PCRE2 lowers it: `\b(?=\w)` or `\b(?<=\w)`, two items, so a
    # quantifier repeats the lookaround alone and the `\b` stays. The
    # lookaround's `\w` is PCRE2's UCP word set (`\p{Xwd}`) even under
    # `(?aW)`, which makes only the `\b` ASCII.
    #
    # Once `\b` holds, the lookaround holds exactly where the Unicode word
    # assertion *kind* does. Under `(?aW)` the `\b` is the ASCII one, and
    # there "a Unicode word character follows" (or precedes) holds exactly
    # where *kind* or the Unicode `\B` does: with the ASCII `\b`, the
    # characters on both sides cannot both be Unicode non-word characters,
    # so the Unicode `\B` means both are word characters.
    private def add_posix_word_assertion(start : Int32, kind : Ast::AssertionKind) : Nil
      ascii = @options.ascii_backslash_w?
      add_assertion(start, Ast::AssertionKind::WordBoundary, ascii)
      unless ascii
        add_assertion(start, kind)
        return
      end
      charge_node(instance_sizeof(Ast::Assertion), start)
      word_side = Ast::Assertion.new(start, kind)
      charge_node(instance_sizeof(Ast::Assertion), start)
      word_both_sides = Ast::Assertion.new(start, Ast::AssertionKind::NotWordBoundary)
      charge_node(instance_sizeof(Ast::Alternation), start)
      @ledger.charge_array(2, sizeof(Ast::Node), "an alternation", start)
      either = Ast::Alternation.new(start, [word_side, word_both_sides] of Ast::Node)
      charge_node(instance_sizeof(Ast::Group), start)
      append(Ast::Group.new(start, 0, nil, either))
    end

    # `[[:<:]]` or `[[:>:]]` (@pos is after the first `[`).
    private def word_boundary_class? : Bool
      ascii_at?(@pos, "[:<:]]") || ascii_at?(@pos, "[:>:]]")
    end

    private def posix_opener?(byte : UInt8) : Bool
      byte == ':'.ord || byte == '.'.ord || byte == '='.ord
    end

    # PCRE2's check_posix_syntax: *offset* is at the `:`, `.` or `=` after a
    # `[`. Returns the offset of the matching terminator (followed by `]`),
    # or nil when the text is not POSIX class syntax.
    private def posix_syntax_end(offset : Int32) : Int32?
      terminator = @bytes[offset]
      cursor = offset + 1
      while @bytes.size - cursor >= 2
        charge_work(1)
        byte = @bytes[cursor]
        following = @bytes[cursor + 1]
        if byte == '\\'.ord && (following == ']'.ord || following == '\\'.ord)
          cursor += 1
        elsif (byte == '['.ord && following == terminator) || byte == ']'.ord
          return nil
        elsif byte == terminator && following == ']'.ord
          return cursor
        end
        cursor += 1
      end
      nil
    end
  end
end
