# The scanner in this file is a port of scanner.c from libyaml 0.2.5,
# with the YAML 1.2 rules added; libyaml is distributed under the MIT
# license:
#
# Copyright (c) 2017-2020 Ingy döt Net
# Copyright (c) 2006-2016 Kirill Simonov
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

module YAML::Mica::YAML
  # Turns YAML text into tokens. The design follows libyaml's scanner (a
  # token queue, a stack of indentation levels and one candidate simple key
  # per flow level), reading the whole input from memory instead of
  # through a character queue.
  #
  # The input is checked once before scanning: it must be UTF-8 and hold
  # only characters YAML allows. The scanner stops at the first byte that
  # fails that check and reports it when it gets there, so everything
  # before it scans as usual.
  #
  # :nodoc:
  class Scanner
    BLANK = 0x01_u8
    BREAK = 0x02_u8
    NUL   = 0x04_u8
    FLOW  = 0x08_u8
    COLON = 0x10_u8
    WIDE  = 0x20_u8
    ALPHA = 0x40_u8
    QUOTE = 0x80_u8

    # A simple key (a key with no `?` indicator) is limited to one line and
    # this many characters.
    MAX_SIMPLE_KEY_CHARS = 1024

    private LINE_FEED       = 1_u8
    private LINE_SEPARATOR  = 2_u8
    private PARAGRAPH_BREAK = 3_u8

    # A place where a simple key may start.
    private struct SimpleKey
      getter? possible : Bool
      getter? required : Bool
      getter token_number : Int64
      getter mark : Mark
      getter char_index : Int64

      def initialize(@possible : Bool, @required : Bool, @token_number : Int64, @mark : Mark, @char_index : Int64)
      end

      def self.none : self
        new(false, false, 0_i64, Mark.new(0, 0, 0), 0_i64)
      end
    end

    getter? stream_end_produced : Bool = false
    getter flow_level : Int32 = 0

    @buffer : Bytes
    @pos : Int32 = 0
    @limit : Int32
    @line : Int32 = 0
    @line_start : Int32 = 0
    # Characters before the current line (a CR LF pair counts as two).
    @line_start_chars : Int64 = 0_i64
    @ascii_only : Bool
    # Continuation bytes counted in `@buffer[@line_start...@column_cache_pos]`.
    @column_cache_pos : Int32 = 0
    @column_cache_count : Int32 = 0
    @column_cache_line_start : Int32 = -1

    @invalid_message : String?
    @classes : StaticArray(UInt8, 256)
    @wide_breaks : Bool
    @strict : Bool

    @tokens : Array(Token)
    @tokens_head : Int32 = 0
    @tokens_parsed : Int64 = 0_i64
    @token_available : Bool = false
    @stream_start_produced : Bool = false

    @indent : Int32 = -1
    @indents : Array(Int32)
    @simple_key_allowed : Bool = false
    @simple_keys : Array(SimpleKey)
    # Every key below this index in `@simple_keys` is known not possible.
    @first_possible_key : Int32 = 0

    # Strict dialect: one entry per flow level, true for a flow mapping.
    @flow_mappings : Array(Bool)
    # Strict dialect: the previous token was a quoted scalar or closed a
    # flow collection, so a ':' right after it is a value indicator.
    @after_json_like : Bool = false
    # Strict dialect: a tab was skipped as white space on this line in
    # the block context, so no block collection may start on it.
    @tab_on_line : Bool = false

    @text : ByteBuffer
    @breaks : ByteBuffer
    @segment_start : Int32 = 0

    def initialize(@buffer : Bytes, @dialect : Dialect, @limits : ParseLimits, @meter : Core::WorkMeter)
      @strict = @dialect.yaml12?
      @wide_breaks = !@strict
      @classes = Scanner.build_classes(@wide_breaks)
      @tokens = Array(Token).new(16)
      @indents = Array(Int32).new(16)
      @simple_keys = Array(SimpleKey).new(8)
      @flow_mappings = Array(Bool).new(8)
      @text = ByteBuffer.new
      @breaks = ByteBuffer.new(16)
      @limit = @buffer.size
      @ascii_only = Core::ByteScan.skip_ascii(@buffer, 0, @limit) == @limit
      check_characters
    end

    # :nodoc:
    def self.build_classes(wide_breaks : Bool) : StaticArray(UInt8, 256)
      classes = StaticArray(UInt8, 256).new(0_u8)
      classes[0x20] = BLANK
      classes[0x09] = BLANK
      classes[0x0A] = BREAK
      classes[0x0D] = BREAK
      classes[0x00] = NUL
      {',', '[', ']', '{', '}'}.each { |char| classes[char.ord] = FLOW }
      classes[':'.ord] = COLON
      if wide_breaks
        classes[0xC2] = WIDE
        classes[0xE2] = WIDE
      end
      ('0'..'9').each { |char| classes[char.ord] = ALPHA }
      ('A'..'Z').each { |char| classes[char.ord] = ALPHA }
      ('a'..'z').each { |char| classes[char.ord] = ALPHA }
      classes['_'.ord] = ALPHA
      classes['-'.ord] = ALPHA
      classes['\''.ord] = QUOTE
      classes['"'.ord] = QUOTE
      classes['\\'.ord] = QUOTE
      classes
    end

    # --- Input checks -------------------------------------------------

    # Finds the first byte that is not valid UTF-8 or starts a character
    # YAML does not allow, and ends the scanned window there.
    private def check_characters : Nil
      stop = @limit
      unless @ascii_only
        if invalid = Core::UTF8.first_invalid_offset(@buffer)
          stop = invalid
          @invalid_message = describe_invalid_utf8(invalid)
        end
      end
      index = 0
      while index < stop
        byte = @buffer.unsafe_fetch(index) # index < stop <= @buffer.size
        if byte >= 0x20 && byte < 0x7F
          index += 1
        elsif byte == 0x0A || byte == 0x09 || byte == 0x0D
          index += 1
        elsif byte < 0x80
          break
        elsif byte == 0xC2
          # stop ends on a character boundary, so the next byte is inside.
          following = @buffer[index + 1]
          break if following < 0xA0 && following != 0x85
          index += 2
        elsif byte == 0xEF
          second = @buffer[index + 1]
          third = @buffer[index + 2]
          break if second == 0xBF && third >= 0xBE
          index += 3
        else
          index += 1
        end
      end
      if index < stop
        @invalid_message = "control characters are not allowed"
        stop = index
      end
      @limit = stop
    end

    # Names what is wrong with the UTF-8 sequence at *offset*, in the
    # words of libyaml's reader.
    private def describe_invalid_utf8(offset : Int32) : String
      lead = @buffer[offset]
      width = if lead & 0x80 == 0x00
                1
              elsif lead & 0xE0 == 0xC0
                2
              elsif lead & 0xF0 == 0xE0
                3
              elsif lead & 0xF8 == 0xF0
                4
              else
                0
              end
      return "invalid leading UTF-8 octet" if width == 0
      return "incomplete UTF-8 octet sequence" if offset + width > @buffer.size
      value = if width == 1
                lead.to_u32
              elsif width == 2
                (lead & 0x1F).to_u32
              elsif width == 3
                (lead & 0x0F).to_u32
              else
                (lead & 0x07).to_u32
              end
      (1...width).each do |step|
        octet = @buffer[offset + step]
        return "invalid trailing UTF-8 octet" unless octet & 0xC0 == 0x80
        value = (value << 6) + (octet & 0x3F)
      end
      unless width == 1 || (width == 2 && value >= 0x80) || (width == 3 && value >= 0x800) || (width == 4 && value >= 0x10000)
        return "invalid length of a UTF-8 sequence"
      end
      "invalid Unicode character"
    end

    # --- Positions ----------------------------------------------------

    @[AlwaysInline]
    private def byte_at(pos : Int32) : UInt8
      # 0 <= pos, and pos < @limit <= @buffer.size: the read is in bounds.
      pos < @limit ? @buffer.unsafe_fetch(pos) : 0_u8
    end

    @[AlwaysInline]
    private def class_at(pos : Int32) : UInt8
      @classes.unsafe_fetch(byte_at(pos)) # a UInt8 indexes all 256 entries
    end

    # Returns the 0-based column (in characters) of *pos* on the current
    # line.
    private def column_at(pos : Int32) : Int32
      return pos - @line_start if @ascii_only
      if @column_cache_line_start != @line_start || pos < @column_cache_pos
        @column_cache_line_start = @line_start
        @column_cache_pos = @line_start
        @column_cache_count = 0
      end
      index = @column_cache_pos
      count = @column_cache_count
      stop = pos < @limit ? pos : @limit
      while index < stop
        count += 1 if @buffer.unsafe_fetch(index) & 0xC0 == 0x80 # index < stop <= @limit
        index += 1
      end
      @column_cache_pos = index
      @column_cache_count = count
      pos - @line_start - count
    end

    @[AlwaysInline]
    private def column : Int32
      column_at(@pos)
    end

    private def mark : Mark
      Mark.new(@pos, @line, column_at(@pos))
    end

    private def char_index : Int64
      @line_start_chars + column_at(@pos)
    end

    # Returns the current position for errors raised outside the scanner.
    def position : Core::Position
      mark.position
    end

    # --- Character tests ------------------------------------------------

    @[AlwaysInline]
    private def blank_at?(pos : Int32) : Bool
      byte = byte_at(pos)
      byte == 0x20 || byte == 0x09
    end

    # Returns the width in bytes of the line break at *pos*, or 0.
    @[AlwaysInline]
    private def break_width(pos : Int32) : Int32
      byte = byte_at(pos)
      if byte == 0x0A
        1
      elsif byte == 0x0D
        byte_at(pos + 1) == 0x0A ? 2 : 1
      elsif byte >= 0xC2 && @wide_breaks
        wide_break_width(pos, byte)
      else
        0
      end
    end

    private def wide_break_width(pos : Int32, byte : UInt8) : Int32
      if byte == 0xC2 && byte_at(pos + 1) == 0x85
        2
      elsif byte == 0xE2 && byte_at(pos + 1) == 0x80 && byte_at(pos + 2) & 0xFE == 0xA8
        3
      else
        0
      end
    end

    @[AlwaysInline]
    private def break_at?(pos : Int32) : Bool
      break_width(pos) != 0
    end

    @[AlwaysInline]
    private def end_at?(pos : Int32) : Bool
      pos >= @limit
    end

    @[AlwaysInline]
    private def blankz_at?(pos : Int32) : Bool
      cls = class_at(pos)
      return true if cls & (BLANK | BREAK | NUL) != 0
      cls & WIDE != 0 && break_width(pos) != 0
    end

    @[AlwaysInline]
    private def breakz_at?(pos : Int32) : Bool
      cls = class_at(pos)
      return true if cls & (BREAK | NUL) != 0
      cls & WIDE != 0 && break_width(pos) != 0
    end

    private def digit_at?(pos : Int32) : Bool
      byte = byte_at(pos)
      byte >= 0x30 && byte <= 0x39
    end

    private def hex_value_at(pos : Int32) : Int32
      byte = byte_at(pos)
      if byte >= 0x30 && byte <= 0x39
        (byte - 0x30).to_i32
      elsif byte >= 0x41 && byte <= 0x46
        (byte - 0x41).to_i32 + 10
      elsif byte >= 0x61 && byte <= 0x66
        (byte - 0x61).to_i32 + 10
      else
        -1
      end
    end

    private def document_indicator_at?(pos : Int32) : Bool
      first = byte_at(pos)
      return false unless first == 0x2D || first == 0x2E
      byte_at(pos + 1) == first && byte_at(pos + 2) == first && blankz_at?(pos + 3)
    end

    # Moves past the line break at `@pos` (of *width* bytes) and returns
    # what a scalar keeps of it: a line feed for CR, LF, CR LF and NEL, the
    # separator itself for LS and PS.
    private def skip_line(width : Int32) : UInt8
      kind = LINE_FEED
      if width == 3
        kind = byte_at(@pos + 2) == 0xA8 ? LINE_SEPARATOR : PARAGRAPH_BREAK
      end
      crlf = width == 2 && byte_at(@pos) == 0x0D
      @line_start_chars += column_at(@pos) + (crlf ? 2 : 1)
      @pos += width
      @line += 1
      @line_start = @pos
      @tab_on_line = false
      kind
    end

    private def write_break(buffer : ByteBuffer, kind : UInt8) : Nil
      if kind == LINE_FEED
        buffer << 0x0A_u8
      else
        buffer << 0xE2_u8
        buffer << 0x80_u8
        buffer << (kind == LINE_SEPARATOR ? 0xA8_u8 : 0xA9_u8)
      end
    end

    # --- Errors -----------------------------------------------------------

    private def scanner_error(context : String?, context_mark : Mark, problem : String) : NoReturn
      raise_invalid_character if @pos >= @limit
      if context
        raise SyntaxError.new(problem, mark.position, context, context_mark.position)
      end
      raise SyntaxError.new(problem, mark.position)
    end

    # Raises the input-check error when the scanner has reached the byte
    # that failed it.
    private def raise_invalid_character : Nil
      if message = @invalid_message
        raise InvalidCharacterError.new(message, Core::Position.new(@limit.to_i64, @line + 1, column_at(@limit) + 1))
      end
    end

    private def limit_error(limit : String, message : String) : NoReturn
      raise ParseLimitError.new(message, mark.position, limit)
    end

    @[AlwaysInline]
    private def charge(count : Int32) : Nil
      @meter.enforce("while scanning") { mark.position } if @meter.charge(count)
    end

    # --- Token queue ------------------------------------------------------

    # Returns the next token without consuming it.
    def peek : Token
      fetch_more_tokens unless @token_available
      @tokens.unsafe_fetch(@tokens_head) # fetch_more_tokens left a token at the head
    end

    # Consumes the token `peek` returned.
    def skip : Nil
      @token_available = false
      @tokens_parsed += 1
      @stream_end_produced = @tokens[@tokens_head].kind.stream_end?
      @tokens_head += 1
      if @tokens_head == @tokens.size
        @tokens.clear
        @tokens_head = 0
      end
    end

    private def queued : Int32
      @tokens.size - @tokens_head
    end

    private def enqueue(token : Token) : Nil
      @tokens << token
    end

    private def insert_token(number : Int64, token : Token) : Nil
      offset = (number - @tokens_parsed).to_i32
      charge(queued - offset)
      @tokens.insert(@tokens_head + offset, token)
    end

    private def fetch_more_tokens : Nil
      loop do
        need_more = false
        if @tokens_head == @tokens.size
          need_more = true
        else
          stale_simple_keys
          index = @first_possible_key
          while index < @simple_keys.size
            key = @simple_keys.unsafe_fetch(index) # index < @simple_keys.size
            if key.possible?
              need_more = key.token_number == @tokens_parsed
              break
            end
            index += 1
          end
          # Keys below index are not possible; skip them next time.
          @first_possible_key = index
        end
        break unless need_more
        fetch_next_token
      end
      @token_available = true
    end

    private def fetch_next_token : Nil
      return fetch_stream_start unless @stream_start_produced
      start = @pos
      scan_to_next_token
      stale_simple_keys
      unroll_indent(column)
      byte = byte_at(@pos)
      if byte == 0 && @pos >= @limit
        raise_invalid_character
        fetch_stream_end
      elsif @pos == @line_start && byte == 0x25 && !(@strict && @flow_level > 0) # '%'
        fetch_directive
      elsif @pos == @line_start && (byte == 0x2D || byte == 0x2E) && document_indicator_at?(@pos)
        fetch_document_indicator(byte == 0x2D ? Token::Kind::DocumentStart : Token::Kind::DocumentEnd)
      elsif @strict
        json_like = @after_json_like
        @after_json_like = false
        fetch_strict_content_token(byte, json_like)
      else
        fetch_content_token(byte)
      end
      charge(@pos - start + 1)
    end

    private def fetch_content_token(byte : UInt8) : Nil
      case byte
      when 0x5B # '['
        fetch_flow_collection_start(Token::Kind::FlowSequenceStart)
      when 0x7B # '{'
        fetch_flow_collection_start(Token::Kind::FlowMappingStart)
      when 0x5D # ']'
        fetch_flow_collection_end(Token::Kind::FlowSequenceEnd)
      when 0x7D # '}'
        fetch_flow_collection_end(Token::Kind::FlowMappingEnd)
      when 0x2C # ','
        fetch_flow_entry
      when 0x2D # '-'
        if blankz_at?(@pos + 1)
          fetch_block_entry
        else
          fetch_plain_scalar
        end
      when 0x3F # '?'
        if @flow_level > 0 || blankz_at?(@pos + 1)
          fetch_key
        else
          fetch_plain_scalar
        end
      when 0x3A # ':'
        if @flow_level > 0 || blankz_at?(@pos + 1)
          fetch_value
        else
          fetch_plain_scalar
        end
      when 0x2A # '*'
        fetch_anchor(Token::Kind::Alias)
      when 0x26 # '&'
        fetch_anchor(Token::Kind::Anchor)
      when 0x21 # '!'
        fetch_tag
      when 0x7C # '|'
        @flow_level == 0 ? fetch_block_scalar(true) : cannot_start_token
      when 0x3E # '>'
        @flow_level == 0 ? fetch_block_scalar(false) : cannot_start_token
      when 0x27 # '\''
        fetch_flow_scalar(true)
      when 0x22 # '"'
        fetch_flow_scalar(false)
      when 0x23, 0x25, 0x40, 0x60 # '#', '%', '@', '`'
        cannot_start_token
      else
        # Blanks, breaks and the end of input were consumed before the
        # dispatch, except a tab the block context does not skip.
        blankz_at?(@pos) ? cannot_start_token : fetch_plain_scalar
      end
    end

    private def flow_indicator_at?(pos : Int32) : Bool
      class_at(pos) & FLOW != 0
    end

    # The YAML 1.2 dispatch: '-', '?' and ':' are indicators only before
    # white space (':' also before a flow indicator, or right after a
    # quoted scalar or flow collection, inside a flow collection).
    private def fetch_strict_content_token(byte : UInt8, json_like : Bool) : Nil
      case byte
      when 0x2D # '-'
        if blankz_at?(@pos + 1)
          fetch_block_entry
        elsif @flow_level > 0 && flow_indicator_at?(@pos + 1)
          cannot_start_token
        else
          fetch_plain_scalar
        end
      when 0x3F # '?'
        if blankz_at?(@pos + 1)
          fetch_key
        elsif @flow_level > 0 && flow_indicator_at?(@pos + 1)
          cannot_start_token
        else
          fetch_plain_scalar
        end
      when 0x3A # ':'
        if blankz_at?(@pos + 1) || (@flow_level > 0 && (json_like || flow_indicator_at?(@pos + 1)))
          fetch_value
        else
          fetch_plain_scalar
        end
      when 0x5D, 0x7D # ']', '}'
        fetch_content_token(byte)
        @after_json_like = true
      when 0x27, 0x22 # quotes
        fetch_content_token(byte)
        @after_json_like = true
      else
        fetch_content_token(byte)
      end
    end

    private def cannot_start_token : NoReturn
      scanner_error("while scanning for the next token", mark, "found character that cannot start any token")
    end

    # --- Simple keys and indentation ---------------------------------------

    private def stale?(key : SimpleKey) : Bool
      key.mark.line < @line || key.char_index + MAX_SIMPLE_KEY_CHARS < char_index
    end

    # Drops the candidate simple keys that can no longer be keys (the
    # current position is on a later line or more than 1,024 characters
    # on). Keys are saved in input order, one per flow level, so the stale
    # ones are the oldest: the scan starts at the first key that may still
    # be possible and stops at the first one that is not stale, which keeps
    # the total work linear however deep the flow nesting.
    private def stale_simple_keys : Nil
      index = @first_possible_key
      while index < @simple_keys.size
        key = @simple_keys.unsafe_fetch(index) # index < @simple_keys.size
        if key.possible?
          # In YAML 1.2 a key in a flow mapping may span lines and has no
          # length limit; the keys above it in the stack are younger, so
          # the scan stops here.
          break if @strict && index > 0 && @flow_mappings[index - 1]
          break unless stale?(key)
          if key.required?
            scanner_error("while scanning a simple key", key.mark, "could not find expected ':'")
          end
          @simple_keys[index] = SimpleKey.none
        end
        index += 1
      end
      @first_possible_key = index
    end

    private def save_simple_key : Nil
      required = @flow_level == 0 && @indent == column
      return unless @simple_key_allowed
      remove_simple_key
      top = @simple_keys.size - 1
      @simple_keys[top] = SimpleKey.new(true, required, @tokens_parsed + queued, mark, char_index)
      @first_possible_key = top if @first_possible_key > top
    end

    private def remove_simple_key : Nil
      top = @simple_keys.size - 1
      key = @simple_keys[top]
      if key.possible?
        if key.required?
          scanner_error("while scanning a simple key", key.mark, "could not find expected ':'")
        end
        @simple_keys[top] = SimpleKey.none
      end
    end

    private def increase_flow_level(mapping : Bool) : Nil
      @flow_mappings << mapping
      if @flow_level >= @limits.max_depth
        limit_error("max_depth", "Flow collections nest deeper than max_depth (#{@limits.max_depth})")
      end
      @simple_keys << SimpleKey.none
      @flow_level += 1
    end

    private def decrease_flow_level : Nil
      return if @flow_level == 0
      @flow_level -= 1
      @simple_keys.pop
      @flow_mappings.pop
      @first_possible_key = @simple_keys.size if @first_possible_key > @simple_keys.size
    end

    private def roll_indent(column : Int32, number : Int64, kind : Token::Kind, mark : Mark) : Nil
      return if @flow_level > 0
      return unless @indent < column
      if @tab_on_line
        scanner_error(nil, mark, "found a tab character where an indentation space is expected")
      end
      if @indents.size >= @limits.max_depth
        limit_error("max_depth", "Block collections nest deeper than max_depth (#{@limits.max_depth})")
      end
      @indents << @indent
      @indent = column
      token = Token.new(kind, mark, mark)
      if number < 0
        enqueue(token)
      else
        insert_token(number, token)
      end
    end

    private def unroll_indent(column : Int32) : Nil
      return if @flow_level > 0
      while @indent > column
        here = mark
        enqueue(Token.new(Token::Kind::BlockEnd, here, here))
        @indent = @indents.pop
      end
    end

    # --- Fetchers -----------------------------------------------------------

    private def fetch_stream_start : Nil
      @indent = -1
      @simple_keys << SimpleKey.none
      @simple_key_allowed = true
      @stream_start_produced = true
      here = mark
      enqueue(Token.new(Token::Kind::StreamStart, here, here))
    end

    private def fetch_stream_end : Nil
      # Force a new line, as libyaml does, so the end mark sits on its own
      # line.
      if @pos != @line_start
        @line_start_chars += column_at(@pos)
        @line += 1
        @line_start = @pos
      end
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      here = mark
      enqueue(Token.new(Token::Kind::StreamEnd, here, here))
    end

    private def fetch_directive : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      if token = scan_directive
        enqueue(token)
      end
    end

    private def fetch_document_indicator(kind : Token::Kind) : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      start_mark = mark
      @pos += 3
      end_mark = mark
      if @strict && kind.document_end?
        pos = @pos
        while blank_at?(pos)
          pos += 1
        end
        unless breakz_at?(pos) || (byte_at(pos) == 0x23 && pos > @pos)
          @pos = pos
          scanner_error(nil, mark, "did not find expected comment or line break")
        end
      end
      enqueue(Token.new(kind, start_mark, end_mark))
    end

    private def fetch_flow_collection_start(kind : Token::Kind) : Nil
      save_simple_key
      increase_flow_level(kind.flow_mapping_start?)
      @simple_key_allowed = true
      enqueue_indicator(kind)
    end

    private def fetch_flow_collection_end(kind : Token::Kind) : Nil
      remove_simple_key
      decrease_flow_level
      @simple_key_allowed = false
      enqueue_indicator(kind)
    end

    private def fetch_flow_entry : Nil
      remove_simple_key
      @simple_key_allowed = true
      enqueue_indicator(Token::Kind::FlowEntry)
    end

    private def fetch_block_entry : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error(nil, mark, "block sequence entries are not allowed in this context")
        end
        roll_indent(column, -1_i64, Token::Kind::BlockSequenceStart, mark)
      end
      remove_simple_key
      @simple_key_allowed = true
      enqueue_indicator(Token::Kind::BlockEntry)
    end

    private def fetch_key : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error(nil, mark, "mapping keys are not allowed in this context")
        end
        roll_indent(column, -1_i64, Token::Kind::BlockMappingStart, mark)
      end
      remove_simple_key
      @simple_key_allowed = @flow_level == 0
      enqueue_indicator(Token::Kind::Key)
    end

    private def fetch_value : Nil
      top = @simple_keys.size - 1
      key = @simple_keys[top]
      if key.possible?
        insert_token(key.token_number, Token.new(Token::Kind::Key, key.mark, key.mark))
        roll_indent(key.mark.column, key.token_number, Token::Kind::BlockMappingStart, key.mark)
        @simple_keys[top] = SimpleKey.none
        @simple_key_allowed = false
      else
        if @flow_level == 0
          unless @simple_key_allowed
            scanner_error(nil, mark, "mapping values are not allowed in this context")
          end
          roll_indent(column, -1_i64, Token::Kind::BlockMappingStart, mark)
        end
        @simple_key_allowed = @flow_level == 0
      end
      enqueue_indicator(Token::Kind::Value)
    end

    private def enqueue_indicator(kind : Token::Kind) : Nil
      start_mark = mark
      @pos += 1
      enqueue(Token.new(kind, start_mark, mark))
    end

    private def fetch_anchor(kind : Token::Kind) : Nil
      save_simple_key
      @simple_key_allowed = false
      enqueue(scan_anchor(kind))
    end

    private def fetch_tag : Nil
      save_simple_key
      @simple_key_allowed = false
      enqueue(scan_tag)
    end

    private def fetch_block_scalar(literal : Bool) : Nil
      remove_simple_key
      @simple_key_allowed = true
      enqueue(scan_block_scalar(literal))
    end

    private def fetch_flow_scalar(single : Bool) : Nil
      save_simple_key
      @simple_key_allowed = false
      enqueue(scan_flow_scalar(single))
    end

    private def fetch_plain_scalar : Nil
      save_simple_key
      @simple_key_allowed = false
      enqueue(scan_plain_scalar)
    end

    # --- Scanners -----------------------------------------------------------

    private def scan_to_next_token : Nil
      return scan_to_next_token_strictly if @strict
      loop do
        pos = @pos
        # A byte order mark may start a line.
        pos += 3 if pos == @line_start && byte_at(pos) == 0xEF && byte_at(pos + 1) == 0xBB && byte_at(pos + 2) == 0xBF
        if @flow_level > 0 || !@simple_key_allowed
          while blank_at?(pos)
            pos += 1
          end
        else
          while byte_at(pos) == 0x20
            pos += 1
          end
        end
        if byte_at(pos) == 0x23 # '#'
          pos = skip_to_line_end(pos)
        end
        @pos = pos
        width = break_width(pos)
        break if width == 0
        charge(pos - @line_start + 1)
        skip_line(width)
        @simple_key_allowed = true if @flow_level == 0
      end
    end

    # The YAML 1.2 rules: tabs separate tokens anywhere but are never
    # indentation, a comment needs white space before it, and a line inside
    # a flow collection is indented past the enclosing block.
    private def scan_to_next_token_strictly : Nil
      crossed_line = false
      loop do
        pos = @pos
        pos += 3 if pos == @line_start && byte_at(pos) == 0xEF && byte_at(pos + 1) == 0xBB && byte_at(pos + 2) == 0xBF
        while byte_at(pos) == 0x20
          pos += 1
        end
        if byte_at(pos) == 0x09
          tab_column = column_at(pos)
          leading = pos - @line_start == tab_column && only_spaces_between?(@line_start, pos)
          while blank_at?(pos)
            pos += 1
          end
          if @flow_level == 0
            if leading && tab_column < @indent && !breakz_at?(pos) && byte_at(pos) != 0x23
              @pos = pos
              scanner_error(nil, mark, "found a tab character where an indentation space is expected")
            end
            @tab_on_line = true
          end
        end
        if byte_at(pos) == 0x23 && (pos == @line_start || blank_at?(pos - 1)) # '#'
          pos = skip_to_line_end(pos)
        end
        @pos = pos
        width = break_width(pos)
        break if width == 0
        charge(pos - @line_start + 1)
        skip_line(width)
        crossed_line = true
        @simple_key_allowed = true if @flow_level == 0
      end
      if crossed_line && @flow_level > 0 && !end_at?(@pos)
        check_flow_indentation
      end
    end

    private def only_spaces_between?(from : Int32, to : Int32) : Bool
      index = from
      while index < to
        return false unless byte_at(index) == 0x20
        index += 1
      end
      true
    end

    # Raises unless the current line starts with more spaces than the
    # enclosing block's indentation (YAML 1.2: lines of a flow collection
    # or a multi-line quoted scalar are indented like block content).
    private def check_flow_indentation : Nil
      spaces = 0
      while byte_at(@line_start + spaces) == 0x20
        spaces += 1
      end
      return if spaces > @indent
      scanner_error(nil, mark, "found a line indented less than the block that holds it")
    end

    # Returns the position of the line break or end of input at or after
    # *pos*.
    private def skip_to_line_end(pos : Int32) : Int32
      loop do
        cls = class_at(pos)
        if cls & (BREAK | NUL | WIDE) == 0
          pos += 1
        elsif cls & WIDE != 0 && break_width(pos) == 0
          pos += 1
        else
          return pos
        end
      end
    end

    private def scan_directive : Token?
      start_mark = mark
      @pos += 1
      name_start = @pos
      if @strict
        until blankz_at?(@pos)
          @pos += 1
        end
      else
        while class_at(@pos) & ALPHA != 0
          @pos += 1
        end
      end
      if @pos == name_start
        scanner_error("while scanning a directive", start_mark, "could not find expected directive name")
      end
      unless blankz_at?(@pos)
        scanner_error("while scanning a directive", start_mark, "found unexpected non-alphabetical character")
      end
      name = @buffer[name_start, @pos - name_start]
      if name == "YAML".to_slice
        major, minor = scan_version_directive_value(start_mark)
        token = Token.new(Token::Kind::VersionDirective, start_mark, mark, major: major, minor: minor)
      elsif name == "TAG".to_slice
        handle, prefix = scan_tag_directive_value(start_mark)
        token = Token.new(Token::Kind::TagDirective, start_mark, mark, value: prefix, handle: handle)
      elsif @strict
        # A reserved directive: YAML 1.2 says to ignore it.
        @pos = skip_to_line_end(@pos)
        token = nil
      else
        scanner_error("while scanning a directive", start_mark, "found unknown directive name")
      end
      blanks_start = @pos
      while blank_at?(@pos)
        @pos += 1
      end
      @pos = skip_to_line_end(@pos) if byte_at(@pos) == 0x23 && (!@strict || @pos > blanks_start)
      unless breakz_at?(@pos)
        scanner_error("while scanning a directive", start_mark, "did not find expected comment or line break")
      end
      width = break_width(@pos)
      skip_line(width) if width != 0
      token
    end

    private def scan_version_directive_value(start_mark : Mark) : {Int32, Int32}
      while blank_at?(@pos)
        @pos += 1
      end
      major = scan_version_directive_number(start_mark)
      unless byte_at(@pos) == 0x2E
        scanner_error("while scanning a %YAML directive", start_mark, "did not find expected digit or '.' character")
      end
      @pos += 1
      {major, scan_version_directive_number(start_mark)}
    end

    private def scan_version_directive_number(start_mark : Mark) : Int32
      value = 0
      length = 0
      while digit_at?(@pos)
        length += 1
        if length > 9
          scanner_error("while scanning a %YAML directive", start_mark, "found extremely long version number")
        end
        value = value * 10 + (byte_at(@pos) - 0x30)
        @pos += 1
      end
      if length == 0
        scanner_error("while scanning a %YAML directive", start_mark, "did not find expected version number")
      end
      value
    end

    private def scan_tag_directive_value(start_mark : Mark) : {String, String}
      while blank_at?(@pos)
        @pos += 1
      end
      handle = scan_tag_handle(true, start_mark)
      unless blank_at?(@pos)
        scanner_error("while scanning a %TAG directive", start_mark, "did not find expected whitespace")
      end
      while blank_at?(@pos)
        @pos += 1
      end
      prefix = scan_tag_uri(true, true, nil, start_mark)
      unless blankz_at?(@pos)
        scanner_error("while scanning a %TAG directive", start_mark, "did not find expected whitespace or line break")
      end
      {handle, prefix}
    end

    private def scan_anchor(kind : Token::Kind) : Token
      start_mark = mark
      @pos += 1
      name_start = @pos
      if @strict
        until blankz_at?(@pos) || flow_indicator_at?(@pos)
          @pos += 1
        end
      else
        while class_at(@pos) & ALPHA != 0
          @pos += 1
        end
      end
      length = @pos - name_start
      following = byte_at(@pos)
      unless length > 0 && (@strict || blankz_at?(@pos) || following == 0x3F || following == 0x3A || following == 0x2C ||
             following == 0x5D || following == 0x7D || following == 0x25 || following == 0x40 || following == 0x60)
        scanner_error(kind.anchor? ? "while scanning an anchor" : "while scanning an alias", start_mark,
          "did not find expected alphabetic or numeric character")
      end
      Token.new(kind, start_mark, mark, value: String.new(@buffer[name_start, length]))
    end

    private def scan_tag : Token
      start_mark = mark
      if byte_at(@pos + 1) == 0x3C # '<'
        handle = ""
        @pos += 2
        suffix = scan_tag_uri(true, false, nil, start_mark)
        unless byte_at(@pos) == 0x3E
          scanner_error("while scanning a tag", start_mark, "did not find the expected '>'")
        end
        @pos += 1
      else
        handle = scan_tag_handle(false, start_mark)
        if handle.bytesize > 1 && handle.to_slice[handle.bytesize - 1] == 0x21
          suffix = scan_tag_uri(false, false, nil, start_mark)
        else
          suffix = scan_tag_uri(false, false, handle, start_mark)
          handle = "!"
          if suffix.empty?
            handle = ""
            suffix = "!"
          end
        end
      end
      unless blankz_at?(@pos)
        unless @flow_level > 0 && byte_at(@pos) == 0x2C
          scanner_error("while scanning a tag", start_mark, "did not find expected whitespace or line break")
        end
      end
      Token.new(Token::Kind::Tag, start_mark, mark, value: suffix, handle: handle)
    end

    private def scan_tag_handle(directive : Bool, start_mark : Mark) : String
      unless byte_at(@pos) == 0x21
        scanner_error(directive ? "while scanning a tag directive" : "while scanning a tag", start_mark,
          "did not find expected '!'")
      end
      start = @pos
      @pos += 1
      while class_at(@pos) & ALPHA != 0
        @pos += 1
      end
      if byte_at(@pos) == 0x21
        @pos += 1
      elsif directive && @pos - start != 1
        scanner_error("while parsing a tag directive", start_mark, "did not find expected '!'")
      end
      String.new(@buffer[start, @pos - start])
    end

    private def tag_uri_char?(byte : UInt8, verbatim : Bool) : Bool
      return true if @classes.unsafe_fetch(byte) & ALPHA != 0 # a UInt8 indexes all 256 entries
      case byte
      when 0x3B, 0x2F, 0x3F, 0x3A, 0x40, 0x26, 0x3D, 0x2B, 0x24, 0x2E, 0x25, 0x21, 0x7E, 0x2A, 0x27, 0x28, 0x29
        true
      when 0x2C, 0x5B, 0x5D
        verbatim
      else
        false
      end
    end

    private def scan_tag_uri(verbatim : Bool, directive : Bool, head : String?, start_mark : Mark) : String
      @text.clear
      length = 0
      if head
        length = head.bytesize
        # The leading '!' of the head is not part of the suffix.
        @text.write(head.to_slice[1, head.bytesize - 1]) if head.bytesize > 1
      end
      while tag_uri_char?(byte_at(@pos), verbatim)
        if byte_at(@pos) == 0x25
          scan_uri_escapes(directive, start_mark)
        else
          @text << byte_at(@pos)
          @pos += 1
        end
        length += 1
      end
      if length == 0
        scanner_error(directive ? "while parsing a %TAG directive" : "while parsing a tag", start_mark,
          "did not find expected tag URI")
      end
      String.new(@text.to_slice)
    end

    private def scan_uri_escapes(directive : Bool, start_mark : Mark) : Nil
      context = directive ? "while parsing a %TAG directive" : "while parsing a tag"
      width = 0
      loop do
        high = byte_at(@pos) == 0x25 ? hex_value_at(@pos + 1) : -1
        low = high < 0 ? -1 : hex_value_at(@pos + 2)
        scanner_error(context, start_mark, "did not find URI escaped octet") if high < 0 || low < 0
        octet = ((high << 4) + low).to_u8
        if width == 0
          width = if octet & 0x80 == 0x00
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
          scanner_error(context, start_mark, "found an incorrect leading UTF-8 octet") if width == 0
        elsif octet & 0xC0 != 0x80
          scanner_error(context, start_mark, "found an incorrect trailing UTF-8 octet")
        end
        @text << octet
        @pos += 3
        width -= 1
        break if width == 0
      end
    end

    private def scan_block_scalar(literal : Bool) : Token
      start_mark = mark
      @pos += 1
      chomping = 0
      increment = 0
      byte = byte_at(@pos)
      if byte == 0x2B || byte == 0x2D
        chomping = byte == 0x2B ? 1 : -1
        @pos += 1
        if digit_at?(@pos)
          increment = scan_block_scalar_increment(start_mark)
        end
      elsif digit_at?(@pos)
        increment = scan_block_scalar_increment(start_mark)
        byte = byte_at(@pos)
        if byte == 0x2B || byte == 0x2D
          chomping = byte == 0x2B ? 1 : -1
          @pos += 1
        end
      end
      blanks_start = @pos
      while blank_at?(@pos)
        @pos += 1
      end
      # YAML 1.2: a comment needs white space before it.
      @pos = skip_to_line_end(@pos) if byte_at(@pos) == 0x23 && (!@strict || @pos > blanks_start)
      unless breakz_at?(@pos)
        scanner_error("while scanning a block scalar", start_mark, "did not find expected comment or line break")
      end
      width = break_width(@pos)
      skip_line(width) if width != 0
      # -1 while the indentation is not known yet.
      indent = -1
      if increment > 0
        indent = @indent >= 0 ? @indent + increment : increment
      end
      @text.clear
      @breaks.clear
      indent, end_mark = scan_block_scalar_breaks(indent, start_mark)
      leading_break = 0_u8
      leading_blank = false
      while @pos - @line_start == indent && !end_at?(@pos)
        # YAML 1.2: a scalar at the top level may have no indentation, and
        # then a document marker ends it.
        break if indent == 0 && document_indicator_at?(@pos)
        trailing_blank = blank_at?(@pos)
        if !literal && leading_break == LINE_FEED && !leading_blank && !trailing_blank
          @text << 0x20_u8 if @breaks.empty?
        elsif leading_break != 0
          write_break(@text, leading_break)
        end
        leading_break = 0_u8
        @text.write(@breaks)
        @breaks.clear
        leading_blank = blank_at?(@pos)
        line_end = skip_to_line_end(@pos)
        @text.write(@buffer[@pos, line_end - @pos])
        charge(line_end - @pos + 1)
        @pos = line_end
        width = break_width(@pos)
        if width != 0
          leading_break = skip_line(width)
        elsif @strict
          # YAML 1.2 parsers read the end of input after a line's content
          # as that line's break.
          leading_break = LINE_FEED
        end
        indent, end_mark = scan_block_scalar_breaks(indent, start_mark)
      end
      if chomping != -1 && leading_break != 0
        write_break(@text, leading_break)
      end
      @text.write(@breaks) if chomping == 1
      style = literal ? ScalarStyle::Literal : ScalarStyle::Folded
      Token.new(Token::Kind::Scalar, start_mark, end_mark, value: String.new(@text.to_slice), style: style)
    end

    private def scan_block_scalar_increment(start_mark : Mark) : Int32
      if byte_at(@pos) == 0x30
        scanner_error("while scanning a block scalar", start_mark, "found an indentation indicator equal to 0")
      end
      increment = (byte_at(@pos) - 0x30).to_i32
      @pos += 1
      increment
    end

    # Reads the indentation and empty lines before a block scalar line,
    # collecting the line breaks in `@breaks`, and settles the scalar's
    # indentation when it is not known yet (*indent* is -1). Returns the
    # indentation and the mark after the last line break.
    private def scan_block_scalar_breaks(indent : Int32, start_mark : Mark) : {Int32, Mark}
      max_indent = 0
      widest_empty_line = 0
      end_mark = mark
      loop do
        # Only spaces sit between the line start and here, so the column
        # is the byte distance.
        while (indent < 0 || @pos - @line_start < indent) && byte_at(@pos) == 0x20
          @pos += 1
        end
        column = @pos - @line_start
        max_indent = column if column > max_indent
        if byte_at(@pos) == 0x09
          if @strict
            if column < (indent < 0 ? @indent + 1 : indent)
              scanner_error("while scanning a block scalar", start_mark,
                "found a tab character where an indentation space is expected")
            end
          elsif indent < 0 || column < indent
            scanner_error("while scanning a block scalar", start_mark,
              "found a tab character where an indentation space is expected")
          end
        end
        width = break_width(@pos)
        if width == 0
          # YAML 1.2 parsers read spaces before the end of input as an
          # empty line.
          @breaks << 0x0A_u8 if @strict && end_at?(@pos) && column > 0 && only_spaces_between?(@line_start, @pos)
          break
        end
        widest_empty_line = column if column > widest_empty_line
        charge(column + 1)
        write_break(@breaks, skip_line(width))
        end_mark = mark
      end
      if indent < 0
        if @strict
          indent = @pos - @line_start
          indent = @indent + 1 if indent < @indent + 1
          if widest_empty_line > indent && !end_at?(@pos)
            scanner_error("while scanning a block scalar", start_mark,
              "found an empty line indented more than the first line of text")
          end
        else
          indent = max_indent
          indent = @indent + 1 if indent < @indent + 1
          indent = 1 if indent < 1
        end
      end
      {indent, end_mark}
    end

    # Appends the pending raw segment `@buffer[@segment_start...stop]` to
    # the scalar being built.
    private def flush_segment(stop : Int32) : Nil
      @text.write(@buffer[@segment_start, stop - @segment_start]) if stop > @segment_start
    end

    # Returns the scalar: the pending raw segment alone when nothing was
    # folded or unescaped, the built text plus the segment otherwise.
    private def finish_scalar(stop : Int32) : String
      if @text.empty?
        String.new(@buffer[@segment_start, stop - @segment_start])
      else
        flush_segment(stop)
        String.new(@text.to_slice)
      end
    end

    # Writes what a folded line break becomes: a space for a lone line
    # feed, the further breaks when there are any, and the breaks as they
    # are after a break that is not a line feed.
    private def write_fold(leading_break : UInt8) : Nil
      if leading_break == LINE_FEED
        if @breaks.empty?
          @text << 0x20_u8
        else
          @text.write(@breaks)
        end
      else
        write_break(@text, leading_break) if leading_break != 0
        @text.write(@breaks)
      end
      @breaks.clear
    end

    private def scan_flow_scalar(single : Bool) : Token
      start_mark = mark
      quote = single ? 0x27_u8 : 0x22_u8
      @pos += 1
      @text.clear
      @breaks.clear
      @segment_start = @pos
      loop do
        if @pos == @line_start && document_indicator_at?(@pos)
          scanner_error("while scanning a quoted scalar", start_mark, "found unexpected document indicator")
        end
        if end_at?(@pos)
          scanner_error("while scanning a quoted scalar", start_mark, "found unexpected end of stream")
        end
        leading_blanks = false
        leading_break = 0_u8
        pos = @pos
        loop do
          cls = class_at(pos)
          if cls & (BLANK | BREAK | NUL | WIDE | QUOTE) == 0
            pos += 1
            next
          end
          byte = byte_at(pos)
          if cls & QUOTE != 0
            if byte == quote
              if single && byte_at(pos + 1) == 0x27
                flush_segment(pos + 1)
                pos += 2
                @segment_start = pos
              else
                break
              end
            elsif !single && byte == 0x5C # '\\'
              flush_segment(pos)
              @pos = pos
              width = break_width(pos + 1)
              if width != 0
                @pos += 1
                skip_line(width)
                leading_blanks = true
                pos = @pos
                @segment_start = pos
                break
              end
              scan_escape(start_mark)
              pos = @pos
              @segment_start = pos
            else
              pos += 1
            end
          elsif cls & WIDE != 0 && break_width(pos) == 0
            pos += 1
          else
            break
          end
        end
        charge(pos - @pos + 1)
        @pos = pos
        break if byte_at(@pos) == quote && !end_at?(@pos)
        blanks_start = @pos
        loop do
          if blank_at?(@pos)
            @pos += 1
          else
            width = break_width(@pos)
            break if width == 0
            kind = skip_line(width)
            if leading_blanks
              write_break(@breaks, kind)
            else
              leading_break = kind
              leading_blanks = true
            end
          end
        end
        if leading_blanks
          flush_segment(blanks_start)
          write_fold(leading_break)
          @segment_start = @pos
          check_flow_indentation if @strict && !end_at?(@pos)
        end
      end
      value = finish_scalar(@pos)
      @pos += 1
      style = single ? ScalarStyle::SingleQuoted : ScalarStyle::DoubleQuoted
      Token.new(Token::Kind::Scalar, start_mark, mark, value: value, style: style)
    end

    # Decodes the escape sequence at `@pos` (a backslash) into `@text`.
    private def scan_escape(start_mark : Mark) : Nil
      code_length = 0
      case byte_at(@pos + 1)
      when 0x30       then @text << 0x00_u8 # '0'
      when 0x61       then @text << 0x07_u8 # 'a'
      when 0x62       then @text << 0x08_u8 # 'b'
      when 0x74, 0x09 then @text << 0x09_u8 # 't', tab
      when 0x6E       then @text << 0x0A_u8 # 'n'
      when 0x76       then @text << 0x0B_u8 # 'v'
      when 0x66       then @text << 0x0C_u8 # 'f'
      when 0x72       then @text << 0x0D_u8 # 'r'
      when 0x65       then @text << 0x1B_u8 # 'e'
      when 0x20       then @text << 0x20_u8
      when 0x22       then @text << 0x22_u8
      when 0x2F       then @text << 0x2F_u8
      when 0x5C       then @text << 0x5C_u8
      when 0x4E # 'N'
        @text << 0xC2_u8
        @text << 0x85_u8
      when 0x5F # '_'
        @text << 0xC2_u8
        @text << 0xA0_u8
      when 0x4C # 'L'
        @text << 0xE2_u8
        @text << 0x80_u8
        @text << 0xA8_u8
      when 0x50 # 'P'
        @text << 0xE2_u8
        @text << 0x80_u8
        @text << 0xA9_u8
      when 0x78 then code_length = 2
      when 0x75 then code_length = 4
      when 0x55 then code_length = 8
      else
        scanner_error("while parsing a quoted scalar", start_mark, "found unknown escape character")
      end
      @pos += 2
      return if code_length == 0
      value = 0_u32
      code_length.times do |index|
        digit = hex_value_at(@pos + index)
        if digit < 0
          scanner_error("while parsing a quoted scalar", start_mark, "did not find expected hexdecimal number")
        end
        value = (value << 4) + digit.to_u32
      end
      if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF
        scanner_error("while parsing a quoted scalar", start_mark, "found invalid Unicode character escape code")
      end
      encoded = uninitialized UInt8[4]
      size = Core::UTF8.encode(value.to_i32, encoded.to_slice)
      @text.write(encoded.to_slice[0, size])
      @pos += code_length
    end

    # libyaml rejects any tab before a plain scalar's indentation; YAML
    # 1.2 only when text follows it on the line.
    private def plain_tab_is_indentation? : Bool
      return true unless @strict
      pos = @pos
      while blank_at?(pos)
        pos += 1
      end
      !breakz_at?(pos)
    end

    private def scan_plain_scalar : Token
      start_mark = mark
      end_mark = start_mark
      indent = @indent + 1
      leading_blanks = false
      leading_break = 0_u8
      @text.clear
      @breaks.clear
      @segment_start = @pos
      word_end = @pos
      stop_mask = BLANK | BREAK | NUL | WIDE | COLON
      stop_mask |= FLOW if @flow_level > 0
      loop do
        break if @pos == @line_start && document_indicator_at?(@pos)
        break if byte_at(@pos) == 0x23
        pos = @pos
        loop do
          cls = class_at(pos)
          if cls & stop_mask == 0
            pos += 1
          elsif cls & COLON != 0
            if @flow_level > 0 && @strict
              break if flow_indicator_at?(pos + 1)
            elsif @flow_level > 0
              following = byte_at(pos + 1)
              if following == 0x2C || following == 0x3F || following == 0x5B || following == 0x5D ||
                 following == 0x7B || following == 0x7D
                @pos = pos
                scanner_error("while scanning a plain scalar", start_mark, "found unexpected ':'")
              end
            end
            break if blankz_at?(pos + 1)
            pos += 1
          elsif cls & WIDE != 0 && break_width(pos) == 0
            pos += 1
          else
            break
          end
        end
        if pos > @pos
          if leading_blanks
            flush_segment(word_end)
            write_fold(leading_break)
            leading_blanks = false
            @segment_start = @pos
          end
          charge(pos - @pos)
          @pos = pos
          word_end = pos
          end_mark = mark
        end
        break unless blank_at?(@pos) || break_at?(@pos)
        loop do
          if blank_at?(@pos)
            if leading_blanks && byte_at(@pos) == 0x09 && column < indent && plain_tab_is_indentation?
              scanner_error("while scanning a plain scalar", start_mark,
                "found a tab character that violates indentation")
            end
            @pos += 1
          else
            width = break_width(@pos)
            break if width == 0
            kind = skip_line(width)
            if leading_blanks
              write_break(@breaks, kind)
            else
              leading_break = kind
              leading_blanks = true
            end
          end
        end
        break if @flow_level == 0 && column < indent
      end
      value = finish_scalar(word_end)
      @simple_key_allowed = true if leading_blanks
      Token.new(Token::Kind::Scalar, start_mark, end_mark, value: value, style: ScalarStyle::Plain)
    end
  end
end
