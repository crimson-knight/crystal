module Regex::Mica::Regex
  # Parses a Crystal-dialect pattern (the PCRE2 subset, read as PCRE2 10.49
  # reads it with `UTF | UCP | DUPNAMES`) into an `Ast::Pattern`.
  #
  # The parser follows PCRE2's own front end (`parse_regex` and
  # `check_escape` in pcre2_compile.c) rule for rule, so a pattern PCRE2
  # rejects is rejected here too, at the same construct. Constructs outside
  # the linear-time dialect raise `UnsupportedConstructError` naming the
  # construct and its byte offset.
  #
  # It never recurses on the pattern's structure: groups live on an
  # explicit stack bounded by `CompileLimits#max_nest_depth`. Every node
  # and list it allocates is charged to the `AllocationLedger` first, and
  # every byte and node to the `Core::WorkMeter`.
  class Parser
    # The largest `{n,m}` count (PCRE2's MAX_REPEAT_COUNT).
    MAX_REPEAT_COUNT = 65_535
    # The longest group name in bytes (PCRE2's MAX_NAME_SIZE).
    MAX_NAME_BYTES = 128
    # The most named groups (PCRE2's MAX_NAME_COUNT).
    MAX_NAME_COUNT = 10_000
    # Bytes charged for reading one `\p{...}` name: the string builder and
    # its buffer, the name, and the substrings the property lookup takes.
    PROPERTY_NAME_BYTES = 512

    # What a frame on the group stack is.
    private enum FrameKind
      Root
      Capture
      NonCapture
    end

    # One open group: its finished branches, the branch being built, and
    # the state to restore at its `)`.
    private class Frame
      getter frame_kind : FrameKind
      getter offset : Int32
      getter capture_index : Int32
      getter group_name : String?
      getter saved_options : CompileOptions
      getter? saved_dupnames : Bool
      getter? branch_reset : Bool
      getter list_of_branches = [] of Ast::Node
      getter list_of_items = [] of Ast::Node
      property reset_group : Int32 = 0
      property max_group : Int32 = 0

      def initialize(@frame_kind : FrameKind, @offset : Int32, @capture_index : Int32, @group_name : String?,
                     @saved_options : CompileOptions, @saved_dupnames : Bool, @branch_reset : Bool)
      end
    end

    @bytes : Bytes
    @pos : Int32
    @options : CompileOptions
    @dupnames = true
    @any_crlf_line_breaks = false
    @inside_quote = false
    # True while a `#` comment has found no line feed yet.
    @comment_open = false
    @quantifiable = false
    @pending_repetition : Ast::Repetition? = nil
    @group_count = 0
    @node_count = 0
    @list_of_frames = [] of Frame
    # The items of the class being parsed (see `parse_class`), freed when
    # `parse` returns.
    @class_items = OffHeapList(Ast::ClassItem).new
    @list_of_group_names = [] of Ast::GroupName
    # The first entry of `@list_of_group_names` for each name and for each
    # group number, and every (name, number) pair recorded, so each new
    # name is checked in constant time. Made with the first group name, so
    # a pattern without one allocates none of them.
    @first_entry_by_name : Hash(String, Int32)? = nil
    @first_entry_by_number : Hash(Int32, Int32)? = nil
    @defined_pairs : Set({String, Int32})? = nil

    # Parses *pattern* (validated as UTF-8 first). *options* are the
    # options in force at the start; *limits*, *ledger* and *meter* bound
    # the work.
    def initialize(pattern : Bytes, options : CompileOptions, @limits : CompileLimits, @ledger : AllocationLedger,
                   @meter : Core::WorkMeter)
      @bytes = pattern
      @pos = 0
      @options = options
    end

    # Parses the whole pattern. Raises `SyntaxError`,
    # `UnsupportedConstructError` or `CompileLimitError`.
    def parse : Ast::Pattern
      if @bytes.size > @limits.max_pattern_bytes
        raise CompileLimitError.new("max_pattern_bytes", @limits.max_pattern_bytes.to_i64,
          "A pattern of #{@bytes.size} bytes", Core::Position.new(0_i64))
      end
      @meter.add_units(@bytes.size)
      read_start_of_pattern_settings
      validate_utf8
      push_frame(FrameKind::Root, 0, 0, nil, @options, branch_reset: false)
      while @pos < @bytes.size
        charge_work(1)
        parse_next_item
      end
      if @list_of_frames.size > 1
        syntax_error("missing closing parenthesis", @bytes.size)
      end
      root_frame = @list_of_frames.pop
      root = finish_branches(root_frame)
      source_end = if @inside_quote
                     Ast::SourceEnd::InQuote
                   elsif @comment_open
                     Ast::SourceEnd::InComment
                   else
                     Ast::SourceEnd::Closed
                   end
      Ast::Pattern.new(root, @group_count, @list_of_group_names, @options, @node_count, source_end)
    ensure
      @class_items.free
    end

    # ---- Start of pattern ---------------------------------------------------

    # Start-of-pattern settings, in PCRE2's pso_list order (each name
    # includes its closing parenthesis or `=`).
    START_SETTINGS = {
      "UTF8)", "UTF)", "UCP)", "NOTEMPTY)", "NOTEMPTY_ATSTART)", "NO_AUTO_POSSESS)", "NO_DOTSTAR_ANCHOR)",
      "NO_JIT)", "NO_START_OPT)", "CASELESS_RESTRICT)", "TURKISH_CASING)", "LIMIT_HEAP=", "LIMIT_MATCH=",
      "LIMIT_DEPTH=", "LIMIT_RECURSION=", "CR)", "LF)", "CRLF)", "ANY)", "NUL)", "ANYCRLF)", "BSR_ANYCRLF)",
      "BSR_UNICODE)",
    }

    private def read_start_of_pattern_settings : Nil
      while @pos + 2 <= @bytes.size && @bytes[@pos] == '('.ord && @bytes[@pos + 1] == '*'.ord
        setting = START_SETTINGS.find { |candidate| ascii_at?(@pos + 2, candidate) }
        break unless setting
        start = @pos
        @pos += 2 + setting.bytesize
        charge_work(setting.bytesize + 2)
        case setting
        when "CASELESS_RESTRICT)"
          @options |= CompileOptions::CaselessRestrict
        when "BSR_ANYCRLF)"
          @any_crlf_line_breaks = true
        when "BSR_UNICODE)"
          @any_crlf_line_breaks = false
        when "NOTEMPTY)", "NOTEMPTY_ATSTART)"
          unsupported("the (*#{setting.rchop}) start-of-pattern setting", start)
        when "TURKISH_CASING)"
          unsupported("the (*TURKISH_CASING) start-of-pattern setting", start)
        when "CR)", "CRLF)", "ANY)", "NUL)", "ANYCRLF)"
          unsupported("a (*#{setting.rchop}) newline convention", start)
        when .ends_with?('=')
          read_limit_setting
        end
      end
    end

    # (*LIMIT_...=digits): Mica::Regex applies its own limits, so the value
    # is read and checked like PCRE2 does, then ignored.
    private def read_limit_setting : Nil
      digits_start = @pos
      value = 0_i64
      while @pos < @bytes.size && digit?(@bytes[@pos])
        break if value > UInt32::MAX // 10 - 1
        value = value * 10 + (@bytes[@pos] - '0'.ord)
        @pos += 1
      end
      if @pos >= @bytes.size || @pos == digits_start || @bytes[@pos] != ')'.ord
        syntax_error("(*VERB) not recognized or malformed", @pos)
      end
      @pos += 1
    end

    private def validate_utf8 : Nil
      offset = 0
      while offset < @bytes.size
        if @bytes[offset] < 0x80
          offset += 1
          next
        end
        code_point, length = Core::UTF8.decode(@bytes, offset, @bytes.size)
        if length == 0
          problem = Core::UTF8.problem(code_point)
          syntax_error("invalid UTF-8 in the pattern: #{problem.describe}", offset)
        end
        offset += length
      end
      charge_work(@bytes.size)
    end

    # ---- Main loop ------------------------------------------------------------

    private def parse_next_item : Nil
      start = @pos
      c = read_char
      if @inside_quote
        if c == '\\'.ord && peek_byte == 'E'.ord
          @inside_quote = false
          @pos += 1
        else
          add_literal(c, start)
          @pending_repetition = nil
        end
        return
      end
      if c == '\\'.ord && (peek_byte == 'Q'.ord || peek_byte == 'E'.ord)
        @inside_quote = peek_byte == 'Q'.ord
        @pos += 1
        return
      end
      if extended?
        return if pattern_white_space?(c)
        if c == '#'.ord
          skip_comment_to_newline
          return
        end
      end
      if c == '('.ord && peek_byte == '?'.ord && peek_byte(1) == '#'.ord
        skip_bracketed_comment
        return
      end

      previous_quantifiable = @quantifiable
      previous_repetition = @pending_repetition
      @quantifiable = false
      @pending_repetition = nil

      if previous_repetition && (c == '?'.ord || c == '+'.ord)
        unsupported("a possessive quantifier", start) if c == '+'.ord
        previous_repetition.greedy = !previous_repetition.greedy?
        return
      end

      case c
      when '\\'.ord then parse_escape(start)
      when '^'.ord
        kind = @options.multiline? ? Ast::AssertionKind::StartOfLine : Ast::AssertionKind::StartOfText
        add_assertion(start, kind)
      when '$'.ord
        add_assertion(start, dollar_kind)
      when '.'.ord
        add_any_character(start, @options.dot_all?)
      when '*'.ord then apply_quantifier(0, nil, start, previous_quantifiable)
      when '+'.ord then apply_quantifier(1, nil, start, previous_quantifiable)
      when '?'.ord then apply_quantifier(0, 1, start, previous_quantifiable)
      when '{'.ord
        counts = read_repeat_counts
        if counts
          apply_quantifier(counts[0], counts[1], start, previous_quantifiable)
        else
          add_literal(c, start)
        end
      when '['.ord then parse_class(start)
      when '('.ord then parse_open_parenthesis(start)
      when '|'.ord then parse_alternation
      when ')'.ord then parse_close_parenthesis(start)
      else
        add_literal(c, start)
      end
    end

    private def dollar_kind : Ast::AssertionKind
      return Ast::AssertionKind::EndOfLine if @options.multiline?
      return Ast::AssertionKind::EndOfText if @options.dollar_end_only?
      Ast::AssertionKind::EndOfTextOrFinalNewline
    end

    # PCRE2's Pattern White Space in extended mode: the C-locale isspace()
    # characters, NEL, U+200E, U+200F, U+2028 and U+2029.
    private def pattern_white_space?(c : Int32) : Bool
      (0x09 <= c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0x200E || c == 0x200F || c == 0x2028 || c == 0x2029
    end

    private def skip_comment_to_newline : Nil
      @comment_open = true
      while @pos < @bytes.size
        byte = @bytes[@pos]
        @pos += 1
        charge_work(1)
        if byte == '\n'.ord
          @comment_open = false
          break
        end
      end
    end

    private def skip_bracketed_comment : Nil
      @pos += 1
      loop do
        @pos += 1
        charge_work(1)
        syntax_error("missing ) after (?# comment", @pos) if @pos >= @bytes.size
        break if @bytes[@pos] == ')'.ord
      end
      @pos += 1
    end

    private def extended? : Bool
      @options.extended? || @options.extended_more?
    end

    # ---- Quantifiers ----------------------------------------------------------

    private def apply_quantifier(minimum : Int32, maximum : Int32?, start : Int32, previous_quantifiable : Bool) : Nil
      syntax_error("quantifier does not follow a repeatable item", @pos) unless previous_quantifiable
      items = current_frame.list_of_items
      child = items.pop? || raise_internal("no item before a quantifier", start)
      charge_node(instance_sizeof(Ast::Repetition), start)
      repetition = Ast::Repetition.new(child.offset, minimum, maximum, !@options.ungreedy?, child)
      items << repetition
      @pending_repetition = repetition
    end

    # Reads `{n}`, `{n,}`, `{n,m}` or `{,m}` (spaces and tabs allowed
    # around the numbers) after a `{`. Returns nil, consuming nothing, when
    # the text is not a quantifier; raises for a count above 65535 or
    # counts out of order.
    private def read_repeat_counts : {Int32, Int32?}?
      cursor = @pos
      while cursor < @bytes.size && space_or_tab?(@bytes[cursor])
        cursor += 1
      end
      scan = cursor
      had_minimum = false
      if scan < @bytes.size && digit?(@bytes[scan])
        had_minimum = true
        while scan < @bytes.size && digit?(@bytes[scan])
          scan += 1
        end
      end
      while scan < @bytes.size && space_or_tab?(@bytes[scan])
        scan += 1
      end
      return nil if scan >= @bytes.size
      if @bytes[scan] == '}'.ord
        return nil unless had_minimum
      else
        return nil unless @bytes[scan] == ','.ord
        scan += 1
        while scan < @bytes.size && space_or_tab?(@bytes[scan])
          scan += 1
        end
        return nil if scan >= @bytes.size
        if digit?(@bytes[scan])
          while scan < @bytes.size && digit?(@bytes[scan])
            scan += 1
          end
        elsif !had_minimum
          return nil
        end
        while scan < @bytes.size && space_or_tab?(@bytes[scan])
          scan += 1
        end
        return nil if scan >= @bytes.size || @bytes[scan] != '}'.ord
      end
      charge_work(scan - @pos + 1)
      minimum = 0
      maximum = nil
      if had_minimum
        minimum, cursor = read_count(cursor)
        while space_or_tab?(@bytes[cursor])
          cursor += 1
        end
        if @bytes[cursor] == '}'.ord
          maximum = minimum
        else
          cursor += 1
          while space_or_tab?(@bytes[cursor])
            cursor += 1
          end
          if digit?(@bytes[cursor])
            maximum, cursor = read_count(cursor)
            syntax_error("numbers out of order in {} quantifier", cursor) if maximum < minimum
          end
        end
      else
        cursor += 1
        while space_or_tab?(@bytes[cursor])
          cursor += 1
        end
        maximum, cursor = read_count(cursor)
      end
      while space_or_tab?(@bytes[cursor])
        cursor += 1
      end
      @pos = cursor + 1
      {minimum, maximum}
    end

    private def read_count(start : Int32) : {Int32, Int32}
      cursor = start
      value = 0
      while cursor < @bytes.size && digit?(@bytes[cursor])
        value = value * 10 + (@bytes[cursor] - '0'.ord)
        cursor += 1
        if value > MAX_REPEAT_COUNT
          while cursor < @bytes.size && digit?(@bytes[cursor])
            cursor += 1
          end
          syntax_error("number too big in {} quantifier", cursor)
        end
      end
      {value, cursor}
    end

    # ---- Groups ---------------------------------------------------------------

    private def parse_open_parenthesis(start : Int32) : Nil
      syntax_error("missing closing parenthesis", @pos) if @pos >= @bytes.size
      next_byte = @bytes[@pos]
      if next_byte == '*'.ord
        parse_star_group(start)
      elsif next_byte != '?'.ord
        if @options.no_auto_capture?
          open_group(FrameKind::NonCapture, start, 0, nil)
        else
          open_group(FrameKind::Capture, start, next_group_number(start), nil)
        end
      else
        @pos += 1
        syntax_error("missing closing parenthesis", @pos) if @pos >= @bytes.size
        parse_question_group(start)
      end
    end

    # `(*...`: alpha assertions such as `(*pla:` and backtracking verbs, all
    # outside the dialect. `(*` before `)` or the end drops the `(`, as in
    # PCRE2, so the `*` then reports a quantifier error.
    private def parse_star_group(start : Int32) : Nil
      return if @bytes.size - @pos <= 1 || @bytes[@pos + 1] == ')'.ord
      @pos += 1
      first = @bytes[@pos]
      if 'a'.ord <= first <= 'z'.ord
        word = read_word
        syntax_error("missing closing parenthesis", @pos) if @pos >= @bytes.size
        unless @bytes[@pos] == ':'.ord
          @pos += 1
          syntax_error("(*alpha_assertion) not recognized", @pos)
        end
        construct = alpha_assertion?(word) || syntax_error("(*alpha_assertion) not recognized", @pos)
        unsupported(construct, start)
      end
      word = read_word
      if @pos >= @bytes.size || (@bytes[@pos] != ':'.ord && @bytes[@pos] != ')'.ord)
        syntax_error("(*VERB) not recognized or malformed", @pos)
      end
      syntax_error("(*VERB) not recognized or malformed", @pos) unless VERBS.includes?(word)
      empty_argument = @bytes[@pos] == ':'.ord && @pos + 1 < @bytes.size && @bytes[@pos + 1] == ')'.ord
      if (word.empty? || word == "MARK") && (@bytes[@pos] != ':'.ord || empty_argument)
        syntax_error("(*MARK) must have an argument", empty_argument ? @pos + 1 : @pos)
      end
      unsupported("a backtracking verb (*#{word.empty? ? "MARK" : word})", start)
    end

    # The construct an alpha assertion *word* names, or nil.
    private def alpha_assertion?(word : String) : String?
      case word
      when "pla", "nla", "positive_lookahead", "negative_lookahead"   then "lookahead"
      when "plb", "nlb", "positive_lookbehind", "negative_lookbehind" then "lookbehind"
      when "napla", "non_atomic_positive_lookahead"                   then "non-atomic lookahead"
      when "naplb", "non_atomic_positive_lookbehind"                  then "non-atomic lookbehind"
      when "scs", "scan_substring"                                    then "a scan substring assertion"
      when "atomic"                                                   then "an atomic group"
      when "sr", "asr", "script_run", "atomic_script_run"             then "a script run"
      end
    end

    VERBS = {"", "MARK", "ACCEPT", "F", "FAIL", "COMMIT", "PRUNE", "SKIP", "THEN"}

    # Reads ASCII word characters (verb and alpha assertion names).
    private def read_word : String
      start = @pos
      while @pos < @bytes.size && ascii_word_byte?(@bytes[@pos])
        @pos += 1
      end
      charge_work(@pos - start)
      @ledger.charge_string(@pos - start, "a setting name", start)
      String.new(@bytes[start, @pos - start])
    end

    private def parse_question_group(start : Int32) : Nil
      byte = @bytes[@pos]
      case byte
      when '-'.ord
        if @bytes.size - @pos > 1 && digit?(@bytes[@pos + 1])
          unsupported("recursion or a subroutine call", start)
        end
        parse_option_group(start)
      when '|'.ord
        @pos += 1
        open_group(FrameKind::NonCapture, start, 0, nil, branch_reset: true)
      when 'P'.ord
        @pos += 1
        syntax_error("missing closing parenthesis", @pos) if @pos >= @bytes.size
        case @bytes[@pos]
        when '<'.ord then parse_named_group(start, '>'.ord)
        when '>'.ord then unsupported("recursion or a subroutine call", start)
        when '='.ord then unsupported("a backreference", start)
        else
          @pos += 1
          syntax_error("unrecognized character after (?P", @pos)
        end
      when 'R'.ord, '&'.ord, '0'.ord..'9'.ord
        unsupported("recursion or a subroutine call", start)
      when '+'.ord
        if @pos + 1 >= @bytes.size
          @pos += 1
          syntax_error("missing closing parenthesis", @pos)
        end
        unless digit?(@bytes[@pos + 1])
          @pos += 2
          syntax_error("digit expected after (?+", @pos)
        end
        unsupported("recursion or a subroutine call", start)
      when 'C'.ord          then unsupported("a callout", start)
      when '('.ord          then unsupported("a conditional group", start)
      when '>'.ord          then unsupported("an atomic group", start)
      when '='.ord, '!'.ord then unsupported("lookahead", start)
      when '*'.ord          then unsupported("non-atomic lookahead", start)
      when '<'.ord
        following = @bytes.size - @pos > 1 ? @bytes[@pos + 1] : 0_u8
        if following == '='.ord || following == '!'.ord
          unsupported("lookbehind", start)
        elsif following == '*'.ord
          unsupported("non-atomic lookbehind", start)
        end
        parse_named_group(start, '>'.ord)
      when '\''.ord
        parse_named_group(start, '\''.ord)
      when '['.ord
        unsupported("an extended character class (?[...])", start)
      else
        parse_option_group(start)
      end
    end

    # `(?imnrsxJU-imnrsxJU)`, `(?^...)`, `(?a...)` and the same before `:`.
    private def parse_option_group(start : Int32) : Nil
      old_options = @options
      old_dupnames = @dupnames
      set = CompileOptions::None
      unset = CompileOptions::None
      set_dupnames = false
      unset_dupnames = false
      negating = false
      hyphen_allowed = true
      options = @options
      if @pos < @bytes.size && @bytes[@pos] == '^'.ord
        options &= ~(CompileOptions::IgnoreCase | CompileOptions::Multiline | CompileOptions::NoAutoCapture |
                     CompileOptions::DotAll | CompileOptions::Extended | CompileOptions::ExtendedMore |
                     CompileOptions::CaselessRestrict)
        hyphen_allowed = false
        @pos += 1
      end
      while @pos < @bytes.size && @bytes[@pos] != ')'.ord && @bytes[@pos] != ':'.ord
        letter = @bytes[@pos]
        @pos += 1
        charge_work(1)
        flags = CompileOptions::None
        case letter
        when '-'.ord
          syntax_error("invalid hyphen in option setting", @pos) unless hyphen_allowed
          negating = true
          hyphen_allowed = false
          next
        when 'a'.ord
          flags = read_ascii_option_letter
        when 'J'.ord
          if negating
            unset_dupnames = true
          else
            set_dupnames = true
          end
          next
        when 'i'.ord then flags = CompileOptions::IgnoreCase
        when 'm'.ord then flags = CompileOptions::Multiline
        when 'n'.ord then flags = CompileOptions::NoAutoCapture
        when 'r'.ord then flags = CompileOptions::CaselessRestrict
        when 's'.ord then flags = CompileOptions::DotAll
        when 'U'.ord then flags = CompileOptions::Ungreedy
        when 'x'.ord
          flags = CompileOptions::Extended
          if @pos < @bytes.size && @bytes[@pos] == 'x'.ord
            flags |= CompileOptions::ExtendedMore
            @pos += 1
          end
        else
          syntax_error("unrecognized character after (? or (?-", @pos)
        end
        if negating
          unset |= flags
        else
          set |= flags
        end
      end
      if (set & (CompileOptions::Extended | CompileOptions::ExtendedMore)) == CompileOptions::Extended || unset.extended?
        unset |= CompileOptions::ExtendedMore
      end
      options = (options | set) & ~unset
      dupnames = (@dupnames || set_dupnames) && !unset_dupnames
      syntax_error("missing closing parenthesis", @pos) if @pos >= @bytes.size
      closing = @bytes[@pos]
      @pos += 1
      if closing == ':'.ord
        open_group(FrameKind::NonCapture, start, 0, nil, saved_options: old_options, saved_dupnames: old_dupnames)
      end
      @options = options
      @dupnames = dupnames
    end

    # After `a` in an option setting: `D`, `P`, `S`, `T`, `W`, or none (all).
    private def read_ascii_option_letter : CompileOptions
      if @pos < @bytes.size
        flags = case @bytes[@pos]
                when 'D'.ord then CompileOptions::AsciiBackslashD
                when 'P'.ord then CompileOptions::AsciiPosix | CompileOptions::AsciiDigit
                when 'S'.ord then CompileOptions::AsciiBackslashS
                when 'T'.ord then CompileOptions::AsciiDigit
                when 'W'.ord then CompileOptions::AsciiBackslashW
                end
        if flags
          @pos += 1
          return flags
        end
      end
      CompileOptions::ASCII_ALL
    end

    # `(?<name>`, `(?'name'` and `(?P<name>`; @pos is at the opening
    # delimiter.
    private def parse_named_group(start : Int32, terminator : Int32) : Nil
      name_offset = @pos + 1
      group_name = read_group_name(terminator)
      number = next_group_number(start)
      define_group_name(group_name, number, name_offset)
      open_group(FrameKind::Capture, start, number, group_name)
    end

    # Reads a group name after its opening delimiter (at @pos) and the
    # terminator, with PCRE2's UTF-mode rules: letters, decimal digits and
    # underscores, not starting with a digit, at most 128 bytes.
    private def read_group_name(terminator : Int32) : String
      @pos += 1
      name_start = @pos
      if @pos >= @bytes.size
        syntax_error("subpattern name expected", @pos)
      end
      first, first_length = Core::UTF8.decode(@bytes, @pos, @bytes.size)
      if decimal_digit?(first)
        @pos += first_length
        syntax_error("subpattern name must start with a non-digit", @pos)
      end
      while @pos < @bytes.size
        code_point, length = Core::UTF8.decode(@bytes, @pos, @bytes.size)
        break unless group_name_character?(code_point)
        @pos += length
        charge_work(1)
      end
      if @pos - name_start > MAX_NAME_BYTES
        syntax_error("subpattern name is too long (maximum #{MAX_NAME_BYTES} code units)", @pos)
      end
      syntax_error("subpattern name expected", @pos) if @pos == name_start
      if @pos >= @bytes.size || @bytes[@pos] != terminator
        syntax_error("syntax error in subpattern name (missing terminator?)", @pos)
      end
      @ledger.charge_string(@pos - name_start, "a group name", name_start)
      group_name = String.new(@bytes[name_start, @pos - name_start])
      @pos += 1
      group_name
    end

    # Letters (`L`), decimal digits (`Nd`) and the underscore; an ASCII
    # name character is answered without the Unicode tables.
    private def group_name_character?(code_point : Int32) : Bool
      if code_point < 0x80
        return code_point == '_'.ord || ('0'.ord <= code_point <= '9'.ord) ||
          ('a'.ord <= code_point | 0x20 <= 'z'.ord)
      end
      Unicode.includes?(Unicode::Tables::SET_GC_ND, code_point) || Unicode.includes?(Unicode::Tables::SET_GCG_L, code_point)
    end

    # True for a decimal digit (`Nd`); an ASCII one without the tables.
    private def decimal_digit?(code_point : Int32) : Bool
      return '0'.ord <= code_point <= '9'.ord if code_point < 0x80
      Unicode.includes?(Unicode::Tables::SET_GC_ND, code_point)
    end

    # Records a group name the way PCRE2 does: the same name on the same
    # number is ignored; the same name on another number needs DUPNAMES;
    # a new name on a number that already has a different name is an error.
    #
    # PCRE2 decides at the first earlier entry with the same name or the
    # same number; the three tables find that entry without a scan.
    private def define_group_name(group_name : String, number : Int32, offset : Int32) : Nil
      if @list_of_group_names.size >= MAX_NAME_COUNT
        syntax_error("too many named subpatterns (maximum #{MAX_NAME_COUNT})", @pos)
      end
      charge_work(3)
      entry_by_name = @first_entry_by_name ||= {} of String => Int32
      entry_by_number = @first_entry_by_number ||= {} of Int32 => Int32
      defined_pairs = @defined_pairs ||= Set({String, Int32}).new
      by_name = entry_by_name[group_name]?
      by_number = entry_by_number[number]?
      if by_number && (by_name.nil? || by_number < by_name)
        syntax_error("different names for subpatterns of the same number are not allowed", @pos)
      end
      if by_name
        return if @list_of_group_names[by_name].capture_index == number
        syntax_error("two named subpatterns have the same name (PCRE2_DUPNAMES not set)", @pos) unless @dupnames
        return if defined_pairs.includes?({group_name, number})
      end
      @ledger.charge_append(sizeof(Ast::GroupName), "a group name", offset)
      @list_of_group_names << Ast::GroupName.new(group_name, number)
      index = @list_of_group_names.size - 1
      unless by_name
        @ledger.charge_hash_entry(sizeof(String) + sizeof(Int32), "a group name", offset)
        entry_by_name[group_name] = index
      end
      unless by_number
        @ledger.charge_hash_entry(sizeof(Int32) * 2, "a group name", offset)
        entry_by_number[number] = index
      end
      @ledger.charge_hash_entry(sizeof({String, Int32}), "a group name", offset)
      defined_pairs << {group_name, number}
    end

    private def next_group_number(start : Int32) : Int32
      if @group_count >= @limits.max_captures
        raise CompileLimitError.new("max_captures", @limits.max_captures.to_i64, "Capturing group #{@group_count + 1}",
          Core::Position.new(start.to_i64))
      end
      @group_count += 1
    end

    private def open_group(kind : FrameKind, start : Int32, capture_index : Int32, group_name : String?,
                           branch_reset : Bool = false, saved_options : CompileOptions? = nil,
                           saved_dupnames : Bool? = nil) : Nil
      if @list_of_frames.size > @limits.max_nest_depth
        raise CompileLimitError.new("max_nest_depth", @limits.max_nest_depth.to_i64,
          "Group nesting of #{@list_of_frames.size}", Core::Position.new(start.to_i64))
      end
      options_to_restore = saved_options || @options
      dupnames_to_restore = saved_dupnames.nil? ? @dupnames : saved_dupnames
      push_frame(kind, start, capture_index, group_name, options_to_restore, branch_reset, dupnames_to_restore)
      frame = current_frame
      if branch_reset
        frame.reset_group = @group_count
        frame.max_group = @group_count
      end
    end

    private def push_frame(kind : FrameKind, start : Int32, capture_index : Int32, group_name : String?,
                           saved_options : CompileOptions, branch_reset : Bool, saved_dupnames : Bool = true) : Nil
      @ledger.charge_object(instance_sizeof(Frame), "a group frame", start)
      @ledger.charge_array(0, sizeof(Ast::Node), "a group frame", start)
      @ledger.charge_array(0, sizeof(Ast::Node), "a group frame", start)
      @ledger.charge_append(sizeof(Frame), "a group frame", start)
      @list_of_frames << Frame.new(kind, start, capture_index, group_name, saved_options, saved_dupnames, branch_reset)
    end

    private def parse_alternation : Nil
      frame = current_frame
      if frame.branch_reset?
        frame.max_group = @group_count if @group_count > frame.max_group
        @group_count = frame.reset_group
      end
      branch = finish_items(frame, frame.list_of_items.empty? ? @pos - 1 : frame.list_of_items.first.offset)
      @ledger.charge_append(sizeof(Ast::Node), "a branch", @pos)
      frame.list_of_branches << branch
      frame.list_of_items.clear
    end

    private def parse_close_parenthesis(start : Int32) : Nil
      @quantifiable = true
      if @list_of_frames.size <= 1
        syntax_error("unmatched closing parenthesis", @pos)
      end
      frame = @list_of_frames.pop
      @options = frame.saved_options
      @dupnames = frame.saved_dupnames?
      if frame.branch_reset? && frame.max_group > @group_count
        @group_count = frame.max_group
      end
      body = finish_branches(frame)
      charge_node(instance_sizeof(Ast::Group), frame.offset)
      group = Ast::Group.new(frame.offset, frame.capture_index, frame.group_name, body)
      append(group)
      @quantifiable = true
    end

    # Turns a frame's branches into one node.
    private def finish_branches(frame : Frame) : Ast::Node
      last = finish_items(frame, frame.list_of_items.empty? ? frame.offset : frame.list_of_items.first.offset)
      branches = frame.list_of_branches
      return last if branches.empty?
      @ledger.charge_append(sizeof(Ast::Node), "a branch", frame.offset)
      branches << last
      charge_node(instance_sizeof(Ast::Alternation), frame.offset)
      @ledger.charge_array(branches.size, sizeof(Ast::Node), "an alternation", frame.offset)
      Ast::Alternation.new(frame.offset, branches.dup)
    end

    private def finish_items(frame : Frame, offset : Int32) : Ast::Node
      items = frame.list_of_items
      if items.empty?
        charge_node(instance_sizeof(Ast::Empty), offset)
        return Ast::Empty.new(offset)
      end
      return items.first if items.size == 1
      charge_node(instance_sizeof(Ast::Concatenation), offset)
      @ledger.charge_array(items.size, sizeof(Ast::Node), "a concatenation", offset)
      Ast::Concatenation.new(offset, items.dup)
    end

    private def current_frame : Frame
      @list_of_frames.last
    end

    # ---- Building -------------------------------------------------------------

    private def add_literal(code_point : Int32, start : Int32) : Nil
      charge_node(instance_sizeof(Ast::Literal), start)
      append(Ast::Literal.new(start, code_point, @options))
      @quantifiable = true
    end

    private def add_assertion(start : Int32, kind : Ast::AssertionKind, ascii_word : Bool = false) : Nil
      charge_node(instance_sizeof(Ast::Assertion), start)
      append(Ast::Assertion.new(start, kind, ascii_word))
    end

    private def add_any_character(start : Int32, matches_newline : Bool) : Nil
      charge_node(instance_sizeof(Ast::AnyCharacter), start)
      append(Ast::AnyCharacter.new(start, matches_newline))
      @quantifiable = true
    end

    # Appends *node*, already charged, to the current branch.
    private def append(node : Ast::Node) : Nil
      @ledger.charge_append(sizeof(Ast::Node), "a list entry", node.offset)
      current_frame.list_of_items << node
    end

    # Charges a syntax node of *bytes* before it is allocated, and counts it.
    private def charge_node(bytes : Int32, offset : Int32) : Nil
      @ledger.charge_object(bytes, "a syntax node", offset)
      @node_count += 1
      charge_work(1)
    end

    private def charge_work(count : Int32) : Nil
      offset = @pos
      @meter.enforce { Core::Position.new(offset.to_i64) } if @meter.charge(count)
    end

    # ---- Bytes and characters -----------------------------------------------

    # Reads the code point at @pos (the pattern is valid UTF-8) and
    # advances past it.
    private def read_char : Int32
      byte = @bytes[@pos]
      if byte < 0x80
        @pos += 1
        return byte.to_i32
      end
      code_point, length = Core::UTF8.decode(@bytes, @pos, @bytes.size)
      @pos += length
      code_point
    end

    private def peek_byte(ahead : Int32 = 0) : Int32
      index = @pos + ahead
      index < @bytes.size ? @bytes[index].to_i32 : -1
    end

    private def ascii_at?(offset : Int32, text : String) : Bool
      return false if offset + text.bytesize > @bytes.size
      text.to_slice == @bytes[offset, text.bytesize]
    end

    private def digit?(byte : UInt8) : Bool
      '0'.ord <= byte <= '9'.ord
    end

    private def space_or_tab?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord
    end

    private def ascii_word_byte?(byte : UInt8) : Bool
      ('a'.ord <= byte <= 'z'.ord) || ('A'.ord <= byte <= 'Z'.ord) || digit?(byte) || byte == '_'.ord
    end

    private def hex_value(byte : UInt8) : Int32
      return byte.to_i32 - '0'.ord if digit?(byte)
      return byte.to_i32 - 'a'.ord + 10 if 'a'.ord <= byte <= 'f'.ord
      return byte.to_i32 - 'A'.ord + 10 if 'A'.ord <= byte <= 'F'.ord
      -1
    end

    # ---- Errors -------------------------------------------------------------

    private def syntax_error(message : String, offset : Int32) : NoReturn
      raise SyntaxError.new(message, Core::Position.new(offset.to_i64))
    end

    private def unsupported(construct : String, offset : Int32) : NoReturn
      raise UnsupportedConstructError.new(construct, Core::Position.new(offset.to_i64))
    end

    private def raise_internal(message : String, offset : Int32) : NoReturn
      raise SyntaxError.new("internal error: #{message}", Core::Position.new(offset.to_i64))
    end
  end
end

require "./parser/escapes"
require "./parser/classes"
