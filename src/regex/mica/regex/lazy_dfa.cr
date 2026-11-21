module Regex::Mica::Regex
  # A lazy DFA over a `Program` (roadmap 6.2.1), built one state at a time
  # as a search needs it, in the RE2 and Rust regex design.
  #
  # **Forward** (`reverse? == false`) it finds the end of the
  # leftmost-first match: a DFA state is the ordered list of NFA states the
  # Pike VM would hold (priority order kept), and reaching the match state
  # drops every lower-priority thread, so the last match the scan records
  # before the DFA dies is the end the Pike VM reports.
  #
  # **Reverse** it finds the start: run backward from the match end `e`
  # over a `ReverseNFA`, it records every position `s` where `[s, e)`
  # matches and keeps the smallest. Because the forward match starts at the
  # leftmost position any match starts at, that is its start.
  #
  # **Assertions.** A state carries what the assertions need to know about
  # the bytes already read (whether the position is the start or end of the
  # text, whether the previous byte was a line feed, a word character, a
  # continuation byte or not ASCII), and the next byte is the transition's
  # input, so every assertion is decided when the transition is built: the
  # closure that leads to a match runs one byte late, as in Rust regex. The
  # end of the haystack is an extra input symbol, and (forward, for `$` and
  # `\Z`) so is a line feed that ends the haystack. `\G` is left to the
  # Pike VM.
  #
  # **Unicode word assertions** need a whole character on each side. When a
  # program has one, every byte of a non-ASCII character is read as one of
  # two symbols, its class or its class marked as part of a word character
  # (`word_symbol`), so the transition that reads the next character knows
  # whether it is a word character, and the state after it records whether
  # the previous one was. The search loops decode each non-ASCII character
  # once to choose the symbol (`wide_char`). The DFA never gives up on them.
  # ASCII-mode word assertions (`(?aW)`) in the same pattern read their own
  # look-behind bit, since a non-ASCII letter is a word character for one
  # kind and not for the other.
  #
  # **Cost.** A transition the cache holds costs one table read. Building a
  # state costs one operation per NFA state its closure visits, at most
  # O(m). Every byte read and every state built is charged to the call's
  # `SearchMeter`, and so is every state a cache clear discards. A cache
  # that grows past its ceiling is cleared; when it thrashes (more than
  # `MAX_CLEARS` clears with fewer than `MINIMUM_BYTES_PER_STATE` bytes read
  # per state built since the last one), the DFA gives up and the search
  # runs on the Pike VM. So a search costs O(m·(n + 1)) whatever happens.
  #
  # The definition is immutable and shared; the states live in a
  # `DFACache`, one per search at a time.
  class LazyDFA
    # Search results besides a position.
    NO_MATCH = -1
    GAVE_UP  = -2

    # Cache clears allowed before thrashing can give up.
    MAX_CLEARS = 3
    # The fewest bytes read per state built that does not count as
    # thrashing.
    MINIMUM_BYTES_PER_STATE = 10
    # The most bytes a stepping loop reads between charges. Each chunk is
    # allowed by the meter before it is read (`SearchMeter#readable`).
    CHUNK_BYTES = 4096

    # State flags (the first entry of a state's key).
    TEXT_EDGE             =  0x01 # forward: at the start of the text; reverse: at its end
    PREVIOUS_LF           =  0x02 # the byte read last was a line feed
    PREVIOUS_WORD         =  0x04 # the byte read last was an ASCII word character (ASCII assertions)
    PREVIOUS_WIDE         =  0x08 # the byte read last was not ASCII
    PREVIOUS_TAIL         =  0x10 # reverse: the byte read last was a continuation byte
    FINAL_LF_EDGE         =  0x20 # reverse: just before a line feed that ends the text
    UNANCHORED            =  0x40 # forward: start a thread at every character
    START_PENDING         =  0x80 # forward: start a thread here (anchored start)
    PREVIOUS_UNICODE_WORD = 0x100 # the character read last was a Unicode word character (Unicode assertions)
    MATCH_BEHIND          = 0x200 # the closure before the last byte reached a match
    # A start state never carries `MATCH_BEHIND`, so its flags index a
    # table of this many entries (see `DFACache#start_entry`).
    START_FLAG_COUNT = MATCH_BEHIND

    # Per-state markers in `DFACache` (one byte per state).
    MARK_MATCH = 0x01_u8
    MARK_DEAD  = 0x02_u8
    MARK_START = 0x04_u8

    # The dead state, and the dead state that reports a match first.
    DEAD       = 0
    DEAD_MATCH = 1

    getter program : Program
    getter byte_classes : ByteClasses
    getter? reverse : Bool
    # True for a reverse DFA that reads classes through `ReversedClass`.
    getter? with_reversed_classes : Bool
    # Entries per state in the transition table: one per class, then the
    # end of input, then (forward) a line feed that ends the haystack.
    getter stride : Int32
    @reverse_nfa : ReverseNFA?
    @relevant_flags : Int32
    # The slot of each start's flags in a cache's start table, in two
    # parts (the flags below `UNANCHORED`, and the three above), so the table
    # holds one entry per combination of the flags this DFA reads rather
    # than one per value below `START_FLAG_COUNT` (see `start_slot`).
    @start_slots_low = StaticArray(UInt16, 64).new(0_u16)
    @start_slots_high = StaticArray(UInt16, 8).new(0_u16)
    # The entries of a cache's start table (see `start_slot`).
    getter start_slot_count : Int32
    @unicode_words : Bool
    @final_lf : Bool
    # The first word symbol (see `word_symbol`); every symbol below it is a
    # plain class or an edge symbol.
    @word_offset : Int32

    # :nodoc:
    # The state flags this DFA keeps (see `start_key`), for the build-time
    # tables of `StaticPattern`.
    def relevant_flags : Int32
      @relevant_flags
    end

    # :nodoc:
    # True when non-ASCII bytes are read as word symbols (see `word_symbol`).
    def unicode_words? : Bool
      @unicode_words
    end

    # :nodoc:
    # True for a forward DFA that reads a line feed ending the haystack as
    # its own symbol (`final_lf_symbol`).
    def final_lf? : Bool
      @final_lf
    end

    # :nodoc:
    # The number of input symbols in use: the classes, the two edge symbols
    # and (with Unicode word assertions) a word symbol per class.
    def symbol_count : Int32
      @unicode_words ? @word_offset + @byte_classes.class_count : @word_offset
    end

    # The symbols of the ASCII bytes, found on first use (see
    # `list_of_ascii_symbols`).
    # Published with release ordering and read with acquire, so a thread
    # that sees the list sees its contents.
    @list_of_ascii_symbols = Atomic(Array(Int32)?).new(nil)

    # The distinct symbols of the ASCII bytes, for a forward DFA (none for
    # a reverse one; see `DFACache#mark_ascii_loop`), found on first use.
    # Threads racing here find the same list.
    def list_of_ascii_symbols : Array(Int32)
      if found = @list_of_ascii_symbols.get(:acquire)
        return found
      end
      list = [] of Int32
      unless @reverse
        seen = StaticArray(Bool, 256).new(false)
        0x80.times do |byte|
          symbol = @byte_classes.class_of(byte.to_u8)
          next if seen[symbol]
          seen[symbol] = true
          list << symbol
        end
      end
      @list_of_ascii_symbols.set(list, :release)
      list
    end

    # A reverse DFA *with_reversed_classes* reads each class backward
    # through its `ReversedClass` (see `SearchPlan#widen_reverse`).
    def initialize(@program : Program, @byte_classes : ByteClasses, @reverse : Bool,
                   @with_reversed_classes : Bool = false)
      looks = LazyDFA.looks_used(@program)
      @unicode_words = looks.any? { |kind| LazyDFA.unicode_word?(kind) }
      class_count = @byte_classes.class_count
      @word_offset = class_count + 2
      # The classes, the two edge symbols, and (with Unicode word
      # assertions) a word symbol per class, rounded up to a multiple of 8,
      # so a row offset leaves three low bits free for flags (see `find_end`).
      symbols = @unicode_words ? @word_offset + class_count : @word_offset
      @stride = (symbols + 7) & ~7
      @reverse_nfa = @reverse ? ReverseNFA.new(@program, @with_reversed_classes) : nil
      line_start = looks.includes?(Program::LookKind::StartOfLine)
      text_start = looks.includes?(Program::LookKind::StartOfText)
      text_end = looks.includes?(Program::LookKind::EndOfText)
      final_newline = looks.includes?(Program::LookKind::EndOfTextOrFinalNewline)
      line_end = looks.includes?(Program::LookKind::EndOfLine) ||
                 looks.includes?(Program::LookKind::NotBeforeLineFeed)
      ascii_words = looks.any? { |kind| LazyDFA.ascii_word?(kind) }
      @final_lf = !@reverse && final_newline
      relevant = UNANCHORED | START_PENDING | MATCH_BEHIND
      if @reverse
        relevant |= PREVIOUS_TAIL
        relevant |= TEXT_EDGE if line_start || text_end || final_newline || line_end
        relevant |= FINAL_LF_EDGE if final_newline
        relevant |= PREVIOUS_LF if line_end
      else
        relevant |= TEXT_EDGE if text_start || line_start
        relevant |= PREVIOUS_LF if line_start
      end
      # ASCII and Unicode word assertions disagree on a non-ASCII word
      # character, so each kind keeps its own look-behind bit.
      relevant |= PREVIOUS_WORD if ascii_words
      relevant |= PREVIOUS_UNICODE_WORD if @unicode_words
      @relevant_flags = relevant
      start_flags = relevant & (START_FLAG_COUNT - 1)
      low_mask = start_flags & (UNANCHORED - 1)
      high_mask = start_flags >> 6
      low_bits = low_mask.popcount
      64.times { |value| @start_slots_low[value] = LazyDFA.gather(value, low_mask).to_u16 if value & ~low_mask == 0 }
      8.times { |value| @start_slots_high[value] = (LazyDFA.gather(value, high_mask) << low_bits).to_u16 if value & ~high_mask == 0 }
      @start_slot_count = 1 << start_flags.popcount
    end

    # The slot of a start with *flags* (a start's flags, within
    # `@relevant_flags` and below `START_FLAG_COUNT`) in a cache's start
    # table: the flags' bits gathered to the low end, one slot per
    # combination.
    @[AlwaysInline]
    def start_slot(flags : Int32) : Int32
      (@start_slots_low.unsafe_fetch(flags & (UNANCHORED - 1)) | @start_slots_high.unsafe_fetch(flags >> 6)).to_i32
    end

    # The bits of *value* that *mask* selects, packed to the low end.
    protected def self.gather(value : Int32, mask : Int32) : Int32
      packed = 0
      position = 0
      bits = mask
      while bits != 0
        lowest = bits & -bits
        packed |= 1 << position if value & lowest != 0
        position += 1
        bits &= bits - 1
      end
      packed
    end

    # The NFA states a DFA state can hold: the program's, or (reverse) the
    # `ReverseNFA`'s nodes.
    def node_count : Int32
      if reverse_nfa = @reverse_nfa
        reverse_nfa.node_count
      else
        @program.state_count
      end
    end

    # True when the lazy DFA can run *program*: everything but `\G`.
    def self.supports?(program : Program) : Bool
      !looks_used(program).includes?(Program::LookKind::SearchStart)
    end

    # The assertion kinds *program* uses.
    def self.looks_used(program : Program) : LookSet
      bits = 0_u32
      program.each_distinct_state { |state, _| bits |= 1_u32 << state.argument if state.kind.look? }
      LookSet.new(bits)
    end

    # :nodoc:
    # A set of `Program::LookKind`s, one bit each.
    record LookSet, bits : UInt32 do
      def includes?(kind : Program::LookKind) : Bool
        bits & (1_u32 << kind.value) != 0
      end

      def any?(& : Program::LookKind -> Bool) : Bool
        Program::LookKind.each { |kind| return true if includes?(kind) && yield kind }
        false
      end
    end

    protected def self.unicode_word?(kind : Program::LookKind) : Bool
      kind.word_boundary? || kind.not_word_boundary? || kind.word_start? || kind.word_end?
    end

    protected def self.ascii_word?(kind : Program::LookKind) : Bool
      kind.word_boundary_ascii? || kind.not_word_boundary_ascii? || kind.word_start_ascii? || kind.word_end_ascii?
    end

    # The input symbol for the end of input (forward) or the start of the
    # text (reverse).
    def edge_symbol : Int32
      @byte_classes.class_count
    end

    # The input symbol for a line feed that ends the haystack (forward).
    def final_lf_symbol : Int32
      @byte_classes.class_count + 1
    end

    # The symbol for a byte of class *class_index* that is part of a
    # non-ASCII word character (with Unicode word assertions only).
    def word_symbol(class_index : Int32) : Int32
      @word_offset + class_index
    end

    # :nodoc:
    # Returns the start and end of the character holding byte *at* of the
    # (valid UTF-8) haystack, and whether it is a word character (PCRE2's
    # UCP `\w`).
    def self.wide_char(haystack : Bytes, at : Int32) : {Int32, Int32, Bool}
      start = at
      while start > 0 && at - start < 3 && haystack.unsafe_fetch(start) & 0xC0 == 0x80
        start -= 1
      end
      lead = haystack.unsafe_fetch(start)
      length = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
      {start, start + length, Look.word_after?(haystack, start, false)}
    end

    # A self-loop run in `find_end` shorter than this is short.
    SHORT_RUN = 32
    # The bytes `find_end` steps one by one after a short run.
    RUN_BACKOFF = 1024

    # Searches forward from *start* for the end of the leftmost-first
    # match, reading to the end of *haystack*. Returns the end, `NO_MATCH`,
    # or `GAVE_UP` (the caller then runs the Pike VM). With *earliest*,
    # returns the first match end reached. While the DFA sits in its start
    # state, *scan* (when given) skips to the next position where a literal
    # starts.
    #
    # The loop works on table entries (see `DFACache#entry_of`): a state's
    # row offset with a low bit set for states that need a look (match,
    # dead, start), so the common transition is one load and one test.
    #
    # With *stop*, a search still undecided when it reaches byte *stop*
    # returns `GAVE_UP` there (see `Searcher#find_at_starts`).
    def find_end(cache : DFACache, haystack : Bytes, start : Int32, anchored : Bool, earliest : Bool,
                 scan : PrefilterScan?, meter : SearchMeter, stop : Int32 = Int32::MAX) : Int32
      size = haystack.size
      limit = @final_lf && size > start && haystack.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      current = cache.start_entry(self, start_flags(haystack, start, anchored), meter)
      return GAVE_UP if current < 0
      last_end = NO_MATCH
      at = start
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      words = @unicode_words
      # The character the last non-ASCII byte belonged to (see `wide_char`).
      wide_start = wide_end = 0
      wide_word = false
      # Where self-loop runs may start again (see `RUN_BACKOFF`).
      runs_from = 0
      while true
        if scan && current & START_ENTRY != 0
          candidate = scan.find(at, meter)
          return last_end if candidate < 0
          if candidate > at
            cache.note_bytes(candidate - at)
            at = candidate
            current = cache.start_entry(self, start_flags(haystack, at, anchored), meter)
            return GAVE_UP if current < 0
          end
          scan = nil if scan.ineffective?
        end
        break if at >= limit
        return GAVE_UP if at >= stop
        # The chunk is paid for before it is read: the meter allows its
        # bytes now (`SearchMeter#readable`), and they are charged once
        # read.
        wanted_end = Math.min(Math.min(limit, stop), at + CHUNK_BYTES)
        chunk_end = at + meter.readable(wanted_end - at, at)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at < chunk_end
          byte = bytes[at]
          symbol = class_table[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at) unless wide_start <= at < wide_end
            symbol &+= @word_offset if wide_word
          end
          entry = table[(current & ROW_MASK) &+ symbol]
          if entry < 0
            # Building a state charges the meter too, so the bytes read so
            # far are charged first and the rest of the chunk is allowed
            # again after the build.
            meter.charge(at - chunk_start, at)
            cache.note_bytes(at - chunk_start)
            chunk_start = at
            id = cache.transition(self, current // stride, symbol, meter)
            return GAVE_UP if id < 0
            entry = cache.entry_of(id)
            table = cache.transition_table.to_unsafe
            chunk_end = at + meter.readable(wanted_end - at, at)
          end
          at &+= 1
          if entry == current && at >= runs_from && !words && entry & ASCII_LOOP == 0 &&
             (scan.nil? || entry & START_ENTRY == 0) &&
             (entry & SPECIAL == 0 || (!earliest && cache.list_of_marks.unsafe_fetch(entry // stride) == MARK_MATCH))
            # A state that loops to itself (`.*`, `[^"]*`, the start state
            # between candidates): its row stays, so the loads of the run
            # no longer wait on each other. A short run (the letters of a
            # word under `\w+`) pays more for leaving this loop than it
            # saves, so after one the search steps byte by byte for
            # `RUN_BACKOFF` bytes. In a match state (`(?s).*`, unless the
            # search wants the earliest end) each byte of the run ends a
            # match, so the last one read ends the latest (see below). A
            # state flagged `ASCII_LOOP` skips its ASCII runs faster below.
            run_start = at
            row = entry & ROW_MASK
            while at < chunk_end && table[row &+ class_table[bytes[at]]] == entry
              at &+= 1
            end
            runs_from = at + RUN_BACKOFF if at - run_start < SHORT_RUN
          end
          current = entry
          if entry & (SPECIAL | START_ENTRY | ASCII_LOOP) != 0
            if entry & ASCII_LOOP != 0
              # Every ASCII byte leads back here and the state is neither
              # dead nor a start: a run of them changes nothing, except
              # that in a match state each of them ends a match.
              if entry & SPECIAL != 0
                last_end = at - 1
                break if earliest
                at = Core::ByteScan.skip_ascii(haystack, at, chunk_end)
                last_end = at - 1
              else
                at = Core::ByteScan.skip_ascii(haystack, at, chunk_end)
              end
              next
            end
            break if scan && entry & START_ENTRY != 0
            if entry & SPECIAL != 0
              marks = cache.list_of_marks.unsafe_fetch(entry // stride)
              if marks & MARK_MATCH != 0
                last_end = at - 1
                break if earliest
              end
              break if marks & MARK_DEAD != 0
            end
          end
        end
        meter.charge(at - chunk_start, at)
        cache.note_bytes(at - chunk_start)
        return last_end if earliest && last_end >= 0
        return last_end if cache.list_of_marks.unsafe_fetch(current // stride) & MARK_DEAD != 0
      end
      if at == size - 1 && limit == size - 1
        meter.charge(1, at)
        state = step(cache, current // stride, final_lf_symbol, meter)
        return GAVE_UP if state < 0
        at += 1
        if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
          last_end = at - 1
          return last_end if earliest
        end
        return last_end if cache.list_of_marks.unsafe_fetch(state) & MARK_DEAD != 0
        current = cache.entry_of(state)
      end
      state = step(cache, current // stride, edge_symbol, meter)
      return GAVE_UP if state < 0
      last_end = size if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
      last_end
    end

    # Searches backward from *finish* (a match end) to no lower than
    # *lower_bound* for the leftmost start of a match ending at *finish*.
    # Returns the start, `NO_MATCH`, or `GAVE_UP`.
    def find_start(cache : DFACache, haystack : Bytes, finish : Int32, lower_bound : Int32,
                   meter : SearchMeter) : Int32
      current = cache.start_entry(self, reverse_start_flags(haystack, finish), meter)
      return GAVE_UP if current < 0
      last_start = NO_MATCH
      at = finish
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      words = @unicode_words
      wide_start = wide_end = 0
      wide_word = false
      dead = false
      while at > lower_bound && !dead
        # Paid for before it is read, as in `find_end`.
        wanted_end = Math.max(lower_bound, at - CHUNK_BYTES)
        chunk_end = at - meter.readable(at - wanted_end, at)
        chunk_start = at
        table = cache.transition_table.to_unsafe
        while at > chunk_end
          byte = bytes[at - 1]
          symbol = class_table[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at - 1) unless wide_start <= at - 1 < wide_end
            symbol &+= @word_offset if wide_word
          end
          entry = table[(current & ROW_MASK) &+ symbol]
          if entry < 0
            meter.charge(chunk_start - at, at)
            cache.note_bytes(chunk_start - at)
            chunk_start = at
            id = cache.transition(self, current // stride, symbol, meter)
            return GAVE_UP if id < 0
            entry = cache.entry_of(id)
            table = cache.transition_table.to_unsafe
            chunk_end = at - meter.readable(at - wanted_end, at)
          end
          at &-= 1
          current = entry
          if entry & SPECIAL != 0
            marks = cache.list_of_marks.unsafe_fetch(entry // stride)
            last_start = at + 1 if marks & MARK_MATCH != 0
            if marks & MARK_DEAD != 0
              dead = true
              break
            end
          end
        end
        meter.charge(chunk_start - at, at)
        cache.note_bytes(chunk_start - at)
      end
      return last_start if dead
      symbol = lower_bound > 0 ? symbol_at(haystack, lower_bound - 1) : edge_symbol
      state = step(cache, current // stride, symbol, meter)
      return GAVE_UP if state < 0
      last_start = lower_bound if cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0
      last_start
    end

    # Finds the leftmost-first match at or after *start* by running the DFA
    # anchored at each character start in turn, for a program whose
    # matches are short (*short_match*). Returns the match's start and end,
    # or `NO_MATCH` (or `GAVE_UP`) as the start.
    #
    # The anchored DFA holds one thread per pattern position at most, so it
    # builds few states where the unanchored one, holding a thread for
    # every start still alive, thrashes (`[a-q][^u-z]{13}x`). Each start
    # reads at most `ShortMatch#longest` + 1 bytes before its DFA dies, and
    # that is below the program's state count, so a search costs
    # O(m·(n + 1)), the Pike VM's bound, and far less when most starts die
    # within a few bytes. When every match ends in one of a few bytes, the
    # starts more than `longest` bytes before the next of them (found with
    # `memchr`, each byte read once) are skipped.
    def find_from_each_start(cache : DFACache, haystack : Bytes, start : Int32, earliest : Bool,
                             short_match : ShortMatch, meter : SearchMeter) : {Int32, Int32}
      size = haystack.size
      limit = @final_lf && size > start && haystack.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      bytes = haystack.to_unsafe
      class_table = @byte_classes.table
      stride = @stride
      words = @unicode_words
      wide_start = wide_end = 0
      wide_word = false
      # The operations made since the last charge, and how many the meter
      # allowed then (`SearchMeter#readable`): a byte is read only while
      # `unpaid` is below `allowed`, and while the meter's count is still
      # `allowed_at` (building a state or a `memchr` scan charges the meter
      # itself, using up what it allowed, so the search asks again).
      unpaid = 0
      allowed = 0
      allowed_at = -1_i64
      origin = start
      list_of_final_bytes = short_match.list_of_final_bytes
      longest = short_match.longest
      # The next position of each final byte at or after `origin`, -1 before
      # it is searched, `Int32::MAX` when there is none.
      final_at = StaticArray(Int32, ShortMatch::MAX_FINAL_BYTES).new(-1)
      next_final = -1
      # The next position at or after `origin` of a byte no match holds
      # (`ShortMatch#outside?`), or -1 when none was found yet; the bytes
      # before `clear_to` (from where it was last looked for) hold none.
      skips_short_stretches = short_match.skips_short_stretches?
      shortest = short_match.shortest
      next_outside = -1
      clear_to = start
      tried = false
      while origin <= size
        if unpaid >= allowed || meter.operations != allowed_at
          allowed, allowed_at = settle(cache, meter, unpaid, origin, Math.min(size + 1 - origin, CHUNK_BYTES))
          unpaid = 0
        end
        if origin < size && bytes[origin] & 0xC0 == 0x80
          origin += 1
          unpaid += 1
          next
        end
        unless list_of_final_bytes.empty?
          if next_final < origin
            next_final = Int32::MAX
            list_of_final_bytes.each_with_index do |final_byte, slot|
              found = final_at[slot]
              found = final_at[slot] = next_byte(haystack, final_byte, origin, meter) if found < origin
              next_final = found if found < next_final
            end
            break if next_final == Int32::MAX
          end
          first_possible = next_final - longest + 1
          if origin < first_possible
            origin = first_possible
            next
          end
        end
        # A match holds no outside byte, so one that starts at `origin` ends
        # at or before the next of them; when fewer than `shortest` bytes
        # lie between, no start from here through that byte has a match.
        # It is looked for only up to `shortest` bytes past `origin`, so a
        # long stretch is read once however many searches start in it, and
        # only once a try of this search has failed, so a search whose
        # first try matches (`\p{L}{100}` in a long run of letters) reads
        # nothing twice.
        if skips_short_stretches && tried && origin < size
          if next_outside < origin
            stop = Math.min(size.to_i64, origin.to_i64 + shortest).to_i32
            next_outside = next_outside_byte(haystack, short_match, Math.max(origin, clear_to), stop, meter)
            clear_to = Math.max(clear_to, stop) if next_outside < 0
          end
          if next_outside >= origin
            origin = next_outside + 1
            next
          end
        end
        current = cache.start_entry(self, start_flags(haystack, origin, true), meter)
        return {GAVE_UP, 0} if current < 0
        last_end = NO_MATCH
        at = origin
        table = cache.transition_table.to_unsafe
        dead = false
        stopped = false
        # The try's end steps (`finish_at_end`), paid with its start.
        unpaid += 1
        while at < limit && !stopped
          if unpaid >= allowed || meter.operations != allowed_at
            allowed, allowed_at = settle(cache, meter, unpaid, at, Math.min(limit - at, CHUNK_BYTES))
            unpaid = 0
          end
          window_end = Math.min(limit, at + (allowed - unpaid))
          window_start = at
          while at < window_end
            byte = bytes[at]
            symbol = class_table[byte].to_i32
            if words && byte >= 0x80
              wide_start, wide_end, wide_word = LazyDFA.wide_char(haystack, at) unless wide_start <= at < wide_end
              symbol &+= @word_offset if wide_word
            end
            entry = table[(current & ROW_MASK) &+ symbol]
            if entry < 0
              # Building a state charges the meter too: charge what was
              # read first, and have the rest of the window allowed again.
              meter.charge(unpaid + at - window_start, at)
              cache.note_bytes(unpaid + at - window_start)
              unpaid = 0
              window_start = at
              id = cache.transition(self, current // stride, symbol, meter)
              return {GAVE_UP, 0} if id < 0
              entry = cache.entry_of(id)
              table = cache.transition_table.to_unsafe
              allowed, allowed_at = settle(cache, meter, 0, at, Math.min(limit - at, CHUNK_BYTES))
              window_end = Math.min(limit, at + allowed)
            end
            at &+= 1
            current = entry
            if entry & SPECIAL != 0
              marks = cache.list_of_marks.unsafe_fetch(entry // stride)
              if marks & MARK_MATCH != 0
                last_end = at - 1
                if earliest
                  stopped = true
                  break
                end
              end
              if marks & MARK_DEAD != 0
                dead = stopped = true
                break
              end
            end
          end
          unpaid += at - window_start
        end
        unless dead || (earliest && last_end >= 0)
          last_end = finish_at_end(cache, current // stride, at, size, limit, earliest, last_end, meter)
          return {GAVE_UP, 0} if last_end == GAVE_UP
        end
        if last_end >= 0
          meter.charge(unpaid, at)
          cache.note_bytes(unpaid)
          return {origin, last_end}
        end
        tried = true
        origin += 1
      end
      meter.charge(unpaid, size)
      cache.note_bytes(unpaid)
      {NO_MATCH, 0}
    end

    # Charges the *unpaid* operations a search from each start made (the
    # bytes it read and one per try) and returns how many of the next
    # *wanted* the meter allows before they are made
    # (`SearchMeter#readable`), with the meter's count at that moment.
    private def settle(cache : DFACache, meter : SearchMeter, unpaid : Int32, at : Int32,
                       wanted : Int32) : {Int32, Int64}
      meter.charge(unpaid, at)
      cache.note_bytes(unpaid)
      allowed = meter.readable(Math.max(wanted, 1), at)
      {allowed, meter.operations}
    end

    # The first position at or after *from* holding *byte*, or `Int32::MAX`;
    # charges the bytes `memchr` reads, in windows of at most 4096 bytes
    # that the meter allows before each is read (`SearchMeter#readable`).
    private def next_byte(haystack : Bytes, byte : UInt8, from : Int32, meter : SearchMeter) : Int32
      at = from
      size = haystack.size
      while at < size
        stop = at + meter.readable(Math.min(size - at, 4096), at)
        if found = haystack[at, stop - at].index(byte)
          meter.charge(found + 1, at)
          return at + found
        end
        meter.charge(stop - at, at)
        at = stop
      end
      Int32::MAX
    end

    # The first position from *from* up to *limit* holding a byte no match
    # holds (`ShortMatch#outside?`), or -1; charges the bytes read, in
    # windows of at most 4096 bytes that the meter allows before each is
    # read (`SearchMeter#readable`).
    private def next_outside_byte(haystack : Bytes, short_match : ShortMatch, from : Int32, limit : Int32,
                                  meter : SearchMeter) : Int32
      at = from
      while at < limit
        stop = at + meter.readable(Math.min(limit - at, 4096), at)
        window_start = at
        while at < stop
          if short_match.outside?(haystack.unsafe_fetch(at))
            meter.charge(at + 1 - window_start, at)
            return at
          end
          at += 1
        end
        meter.charge(stop - window_start, stop)
      end
      -1
    end

    # Reads the end of the haystack (the line feed that ends it, then the
    # end of input) from *state* at *at*, after the scan stopped at
    # *limit*, and returns the match end found so far or `GAVE_UP`.
    private def finish_at_end(cache : DFACache, state : Int32, at : Int32, size : Int32, limit : Int32,
                              earliest : Bool, last_end : Int32, meter : SearchMeter) : Int32
      if at == size - 1 && limit == size - 1
        state = step(cache, state, final_lf_symbol, meter)
        return GAVE_UP if state < 0
        at += 1
        marks = cache.list_of_marks.unsafe_fetch(state)
        if marks & MARK_MATCH != 0
          last_end = at - 1
          return last_end if earliest
        end
        return last_end if marks & MARK_DEAD != 0
      end
      return last_end unless at >= size
      state = step(cache, state, edge_symbol, meter)
      return GAVE_UP if state < 0
      cache.list_of_marks.unsafe_fetch(state) & MARK_MATCH != 0 ? size : last_end
    end

    # The low bits of a table entry (see `find_end`): a match or dead state,
    # a start state, and (on the entries of a state's own row only) a
    # state that every ASCII byte leads back to (`DFACache#mark_ascii_loop`).
    SPECIAL     = 1
    START_ENTRY = 2
    ASCII_LOOP  = 4
    # Clears the flag bits of a table entry, leaving the row offset.
    ROW_MASK = ~7

    private def step(cache : DFACache, state : Int32, symbol : Int32, meter : SearchMeter) : Int32
      entry = cache.transition_table.unsafe_fetch(state * @stride + symbol)
      return entry // @stride if entry >= 0
      cache.transition(self, state, symbol, meter)
    end

    private def start_flags(haystack : Bytes, at : Int32, anchored : Bool) : Int32
      flags = anchored ? START_PENDING : UNANCHORED
      if at == 0
        flags |= TEXT_EDGE
      else
        flags |= symbol_flags(haystack.unsafe_fetch(at - 1).to_i32, symbol_at(haystack, at - 1))
      end
      flags & @relevant_flags
    end

    private def reverse_start_flags(haystack : Bytes, at : Int32) : Int32
      size = haystack.size
      flags = 0
      if at == size
        flags |= TEXT_EDGE
      else
        byte = haystack.unsafe_fetch(at)
        flags |= symbol_flags(byte.to_i32, symbol_at(haystack, at))
        flags |= PREVIOUS_TAIL if byte & 0xC0 == 0x80
        flags |= FINAL_LF_EDGE if at == size - 1 && byte == Look::LINE_FEED
      end
      flags & @relevant_flags
    end

    # The flags reading *byte* (read as *symbol*) leaves for the next
    # position. An ASCII word byte sets both word bits; a non-ASCII byte
    # sets only `PREVIOUS_UNICODE_WORD`, when its symbol is a word symbol
    # (with Unicode word assertions).
    private def symbol_flags(byte : Int32, symbol : Int32) : Int32
      flags = 0
      flags |= PREVIOUS_LF if byte == Look::LINE_FEED
      if byte < 0x80
        flags |= PREVIOUS_WORD | PREVIOUS_UNICODE_WORD if Look.word_code_point?(byte, true)
      else
        flags |= PREVIOUS_WIDE
        flags |= PREVIOUS_UNICODE_WORD if symbol >= @word_offset
      end
      flags
    end

    # The symbol the search loops read for byte *at* of *haystack*.
    private def symbol_at(haystack : Bytes, at : Int32) : Int32
      byte = haystack.unsafe_fetch(at)
      symbol = @byte_classes.class_of(byte)
      symbol += @word_offset if @unicode_words && byte >= 0x80 && LazyDFA.wide_char(haystack, at)[2]
      symbol
    end

    # :nodoc:
    # Builds the state reached from the state with *key* on *symbol* and
    # returns its key, or nil when the DFA must give up (a Unicode word
    # assertion next to a non-ASCII byte). Writes into *builder*, and
    # charges each NFA state the closure visits.
    def next_key(key : Slice(Int32), symbol : Int32, builder : DFABuilder, meter : SearchMeter) : Slice(Int32)?
      @reverse ? reverse_next_key(key, symbol, builder, meter) : forward_next_key(key, symbol, builder, meter)
    end

    # The byte a symbol stands for (-1 for the edge of the text; the line
    # feed for the final line feed).
    private def symbol_byte(symbol : Int32) : Int32
      return -1 if symbol == edge_symbol
      return Look::LINE_FEED.to_i32 if symbol == final_lf_symbol
      symbol -= @word_offset if symbol >= @word_offset
      @byte_classes.representative(symbol).to_i32
    end

    # How following a closure ended (see `explore_closure`).
    private enum Closure
      # Every path ended at a consuming state or a failed assertion.
      Open
      # A path reached the match state.
      Matched
      # An assertion needs the Pike VM.
      Quit
    end

    # Follows the closure from NFA state *seed* before *byte* (read as
    # *symbol*, after a position described by *flags*), recording the
    # consuming states it reaches in *builder*, and charging *meter* one
    # operation per state visited.
    private def explore_closure(seed : Int32, flags : Int32, byte : Int32, symbol : Int32, builder : DFABuilder,
                                meter : SearchMeter) : Closure
      builder.push(seed)
      while current = builder.pop?
        while true
          break unless builder.visit(current)
          meter.charge(1, 0)
          state = @program.state_at(current)
          case state.kind
          when .byte_range?, .sparse?
            builder.output(current)
            break
          when .match?
            builder.clear_stack
            return Closure::Matched
          when .split?
            builder.push(state.alternate)
            current = state.next_state
          when .save?
            current = state.next_state
          when .look?
            verdict = forward_look(Program::LookKind.new(state.argument), flags, byte, symbol)
            if verdict.nil?
              builder.clear_stack
              return Closure::Quit
            end
            break unless verdict
            current = state.next_state
          else
            break
          end
        end
      end
      Closure::Open
    end

    private def forward_next_key(key : Slice(Int32), symbol : Int32, builder : DFABuilder,
                                 meter : SearchMeter) : Slice(Int32)?
      flags = key.unsafe_fetch(0)
      byte = symbol_byte(symbol)
      builder.reset
      matched = false
      quit = false
      (1...key.size).each do |index|
        outcome = explore_closure(key.unsafe_fetch(index), flags, byte, symbol, builder, meter)
        matched = outcome.matched?
        quit = outcome.quit?
        break if matched || quit
      end
      boundary = byte < 0x80 || byte >= 0xC0
      if !matched && !quit && (flags & START_PENDING != 0 || (flags & UNANCHORED != 0 && boundary))
        outcome = explore_closure(@program.start_state, flags, byte, symbol, builder, meter)
        matched = outcome.matched?
        quit = outcome.quit?
      end
      return nil if quit
      return dead_key(builder, matched) if byte < 0 && symbol == edge_symbol
      next_flags = matched ? MATCH_BEHIND : 0
      next_flags |= UNANCHORED if flags & UNANCHORED != 0 && !matched
      next_flags |= symbol_flags(byte, symbol)
      builder.begin_targets(next_flags & @relevant_flags)
      builder.each_output do |state_index|
        state = @program.state_at(state_index)
        target = if state.kind.byte_range?
                   state.low <= byte <= state.high ? state.next_state : -1
                 else
                   @program.sparse_target(state_index, state, byte.to_u8)
                 end
        builder.add_target(target) if target >= 0
      end
      targets = builder.targets
      if targets.size == 1 && next_flags & UNANCHORED == 0
        return dead_key(builder, matched)
      end
      targets
    end

    # Returns whether *kind* holds at a position whose earlier bytes are
    # described by *flags* and whose next input is *byte* (-1 at the end),
    # or nil when it cannot be decided without the Pike VM.
    private def forward_look(kind : Program::LookKind, flags : Int32, byte : Int32, symbol : Int32) : Bool?
      at_end = byte < 0
      next_lf = byte == Look::LINE_FEED
      case kind
      in .start_of_text?
        flags & TEXT_EDGE != 0
      in .start_of_line?
        flags & TEXT_EDGE != 0 || (flags & PREVIOUS_LF != 0 && !at_end)
      in .end_of_text?
        at_end
      in .end_of_text_or_final_newline?
        at_end || symbol == final_lf_symbol
      in .end_of_line?
        at_end || next_lf
      in .not_before_line_feed?
        !next_lf
      in .search_start?
        nil
      in .word_boundary?, .not_word_boundary?, .word_start?, .word_end?
        word_look(kind, flags & PREVIOUS_UNICODE_WORD != 0, symbol_word?(byte, symbol))
      in .word_boundary_ascii?, .not_word_boundary_ascii?, .word_start_ascii?, .word_end_ascii?
        word_look(kind, flags & PREVIOUS_WORD != 0, word_byte?(byte))
      end
    end

    private def word_byte?(byte : Int32) : Bool
      byte >= 0 && byte < 0x80 && Look.word_code_point?(byte, true)
    end

    # True when the character *byte* (read as *symbol*) belongs to is a
    # Unicode word character; false at an edge.
    private def symbol_word?(byte : Int32, symbol : Int32) : Bool
      return word_byte?(byte) if byte < 0x80
      symbol >= @word_offset && symbol != edge_symbol && symbol != final_lf_symbol
    end

    private def word_look(kind : Program::LookKind, before : Bool, after : Bool) : Bool
      case kind
      when .word_boundary?, .word_boundary_ascii?         then before != after
      when .not_word_boundary?, .not_word_boundary_ascii? then before == after
      when .word_start?, .word_start_ascii?               then !before && after
      else                                                     before && !after
      end
    end

    private def reverse_next_key(key : Slice(Int32), symbol : Int32, builder : DFABuilder,
                                 meter : SearchMeter) : Slice(Int32)?
      reverse_nfa = @reverse_nfa || raise Mica::Error.new("internal error: no reverse NFA")
      flags = key.unsafe_fetch(0)
      byte = symbol_byte(symbol)
      builder.reset
      accepted = false
      quit = false
      (1...key.size).each { |index| builder.push(key.unsafe_fetch(index)) }
      while current = builder.pop?
        next unless builder.visit(current)
        meter.charge(1, 0)
        accepted = true if current == reverse_nfa.accept_node
        builder.output(current) if reverse_nfa.consumes?(current)
        reverse_nfa.each_epsilon(current) do |target, look|
          if look >= 0
            verdict = reverse_look(Program::LookKind.new(look), flags, byte, symbol)
            if verdict.nil?
              quit = true
              next
            end
            next unless verdict
          end
          builder.push(target)
        end
      end
      return nil if quit
      accepted = false if flags & PREVIOUS_TAIL != 0
      return dead_key(builder, accepted) if byte < 0
      next_flags = accepted ? MATCH_BEHIND : 0
      next_flags |= symbol_flags(byte, symbol)
      next_flags |= PREVIOUS_TAIL if byte & 0xC0 == 0x80
      next_flags |= FINAL_LF_EDGE if flags & TEXT_EDGE != 0 && byte == Look::LINE_FEED
      builder.begin_targets(next_flags & @relevant_flags)
      builder.each_output do |node|
        reverse_nfa.each_byte_target(node, byte.to_u8) { |target| builder.add_target(target) }
      end
      targets = builder.sorted_targets
      return dead_key(builder, accepted) if targets.size == 1
      targets
    end

    # As `forward_look`, read backward: the position's later bytes are in
    # *flags* and its earlier byte is *byte* (-1 at the start of the text).
    private def reverse_look(kind : Program::LookKind, flags : Int32, byte : Int32, symbol : Int32) : Bool?
      at_start = byte < 0
      at_end = flags & TEXT_EDGE != 0
      later_lf = flags & PREVIOUS_LF != 0
      case kind
      in .start_of_text?
        at_start
      in .start_of_line?
        at_start || (!at_end && byte == Look::LINE_FEED)
      in .end_of_text?
        at_end
      in .end_of_text_or_final_newline?
        at_end || flags & FINAL_LF_EDGE != 0
      in .end_of_line?
        at_end || later_lf
      in .not_before_line_feed?
        at_end || !later_lf
      in .search_start?
        nil
      in .word_boundary?, .not_word_boundary?, .word_start?, .word_end?
        word_look(kind, symbol_word?(byte, symbol), flags & PREVIOUS_UNICODE_WORD != 0)
      in .word_boundary_ascii?, .not_word_boundary_ascii?, .word_start_ascii?, .word_end_ascii?
        word_look(kind, word_byte?(byte), flags & PREVIOUS_WORD != 0)
      end
    end

    # :nodoc:
    # The key of a dead state, `DEAD_MATCH` when *matched*, written into
    # *builder* (no allocation).
    def dead_key(builder : DFABuilder, matched : Bool) : Slice(Int32)
      builder.begin_targets(matched ? MATCH_BEHIND : 0)
      builder.targets
    end

    # :nodoc:
    # The key of a start state with *flags*, written into *builder*: no NFA
    # states yet (forward), or the match state (reverse).
    def start_key(flags : Int32, builder : DFABuilder) : Slice(Int32)
      builder.begin_targets(flags)
      if reverse_nfa = @reverse_nfa
        builder.add_target(reverse_nfa.start_node)
      end
      builder.targets
    end

    # :nodoc:
    # True when a state with *key* is a forward start state: no threads,
    # and a new one starts at every character.
    def start_like?(key : Slice(Int32)) : Bool
      !@reverse && key.size == 1 && key.unsafe_fetch(0) & UNANCHORED != 0
    end
  end
end
