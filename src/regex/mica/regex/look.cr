module Regex::Mica::Regex
  # Evaluates the zero-width assertions of a `Program` at a position of a
  # valid UTF-8 haystack. Every check reads at most one character on each
  # side of the position, so it costs constant work.
  #
  # The meanings follow PCRE2 with Crystal's options (the newline is LF):
  #
  # - `StartOfLine` (`^` with `Multiline`) holds at the start and after a
  #   line feed, except after a line feed that ends the haystack;
  # - `EndOfTextOrFinalNewline` (`$` and `\Z`) holds at the end and before
  #   a line feed that ends the haystack;
  # - `EndOfLine` (`$` with `Multiline`) holds at the end and before any
  #   line feed;
  # - the word assertions compare the characters on each side, Unicode or
  #   ASCII word characters as the pattern asked;
  # - `SearchStart` (`\G`) holds at the position the search started from.
  module Look
    LINE_FEED = 0x0A_u8

    # Returns true when *kind* holds at byte *at* of *haystack*, for a
    # search that started at *search_start*.
    def self.holds?(kind : Program::LookKind, haystack : Bytes, at : Int32, search_start : Int32) : Bool
      size = haystack.size
      case kind
      in .start_of_text?
        at == 0
      in .start_of_line?
        at == 0 || (at < size && haystack.unsafe_fetch(at - 1) == LINE_FEED)
      in .end_of_text?
        at == size
      in .end_of_text_or_final_newline?
        at == size || (at == size - 1 && haystack.unsafe_fetch(at) == LINE_FEED)
      in .end_of_line?
        at == size || haystack.unsafe_fetch(at) == LINE_FEED
      in .word_boundary?
        word_before?(haystack, at, false) != word_after?(haystack, at, false)
      in .not_word_boundary?
        word_before?(haystack, at, false) == word_after?(haystack, at, false)
      in .word_start?
        !word_before?(haystack, at, false) && word_after?(haystack, at, false)
      in .word_end?
        word_before?(haystack, at, false) && !word_after?(haystack, at, false)
      in .word_boundary_ascii?
        word_before?(haystack, at, true) != word_after?(haystack, at, true)
      in .not_word_boundary_ascii?
        word_before?(haystack, at, true) == word_after?(haystack, at, true)
      in .word_start_ascii?
        !word_before?(haystack, at, true) && word_after?(haystack, at, true)
      in .word_end_ascii?
        word_before?(haystack, at, true) && !word_after?(haystack, at, true)
      in .search_start?
        at == search_start
      in .not_before_line_feed?
        at == size || haystack.unsafe_fetch(at) != LINE_FEED
      end
    end

    # Returns true when the character that ends at *at* is a word character.
    def self.word_before?(haystack : Bytes, at : Int32, ascii : Bool) : Bool
      return false if at == 0
      start = at - 1
      # Step back over at most three continuation bytes to the lead byte.
      while start > 0 && at - start < 4 && haystack.unsafe_fetch(start) & 0xC0 == 0x80
        start -= 1
      end
      word_code_point?(decode(haystack, start), ascii)
    end

    # Returns true when the character that starts at *at* is a word
    # character.
    def self.word_after?(haystack : Bytes, at : Int32, ascii : Bool) : Bool
      return false if at >= haystack.size
      word_code_point?(decode(haystack, at), ascii)
    end

    # Returns true when *code_point* is a word character: `[0-9A-Za-z_]`
    # in ASCII mode, PCRE2's UCP word set (`\p{Xwd}`) otherwise.
    def self.word_code_point?(code_point : Int32, ascii : Bool) : Bool
      if code_point < 0x80
        return (0x30 <= code_point <= 0x39) || (0x41 <= code_point <= 0x5A) || (0x61 <= code_point <= 0x7A) ||
          code_point == 0x5F
      end
      return false if ascii
      if code_point < 0x10000
        return Unicode::Tables::WORD_BITS.unsafe_fetch(code_point >> 6) & (1_u64 << (code_point & 63)) != 0
      end
      Unicode.includes?(Unicode::Tables::SET_XWD, code_point)
    end

    # Decodes the (valid) UTF-8 sequence that starts at *at*.
    private def self.decode(haystack : Bytes, at : Int32) : Int32
      lead = haystack.unsafe_fetch(at).to_i32
      return lead if lead < 0x80
      if lead < 0xE0
        ((lead & 0x1F) << 6) | continuation(haystack, at + 1)
      elsif lead < 0xF0
        ((lead & 0x0F) << 12) | (continuation(haystack, at + 1) << 6) | continuation(haystack, at + 2)
      else
        ((lead & 0x07) << 18) | (continuation(haystack, at + 1) << 12) | (continuation(haystack, at + 2) << 6) |
          continuation(haystack, at + 3)
      end
    end

    private def self.continuation(haystack : Bytes, index : Int32) : Int32
      return 0 if index >= haystack.size
      haystack.unsafe_fetch(index).to_i32 & 0x3F
    end
  end
end
