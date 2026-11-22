module Regex::Mica::Regex
  # :nodoc:
  # The layout of a static capture pass's stack scratch (see
  # `StaticMatcher#backtrack_pass` and `StaticMatcher#capture_pass`),
  # shared by the build-time table writer and the matcher. The two passes
  # take turns in the same words: the backtracker runs first, and the Pike
  # VM only when it declines.
  module StaticScratch
    # The most (state, position) pairs the backtracker's visited bitset
    # holds: 16 Ki bits, 2 KiB.
    BACKTRACK_BITS = 16_384
    # The most jobs the backtracker's stack holds (two words each, 8 KiB);
    # a search that needs more leaves the groups to the Pike VM.
    BACKTRACK_JOBS = 1_024

    # The 32-bit words of scratch for *state_count* NFA states and
    # *slot_count* slots: the groups found, then the larger of the Pike VM's
    # part (two slot tables, two sparse sets, the closure stack and one
    # slot vector) and the backtracker's (one slot vector, the visited
    # bitset and the job stack).
    def self.words_for(state_count : Int32, slot_count : Int32) : Int32
      pike = 2 * state_count * slot_count + 6 * state_count + slot_count
      slot_count + Math.max(pike, backtrack_words(slot_count))
    end

    # The words of the backtracker's part for *slot_count* slots.
    def self.backtrack_words(slot_count : Int32) : Int32
      slot_count + BACKTRACK_BITS // 32 + 2 * BACKTRACK_JOBS
    end
  end

  # :nodoc:
  # The search code and tables of a pattern compiled while the application
  # built (see `Mica::Regex.static`). `F` and `R` are the state-id types of
  # the forward and reverse DFA tables and `N` that of the capture pass's
  # NFA (each `UInt8` or `UInt16`). The code is shared by every static
  # pattern with the same three widths: the per-pattern parts (the size of
  # the capture pass's stack scratch) live in `StaticPattern`.
  #
  # **Search.** The forward DFA finds the end of the leftmost-first match,
  # the reverse DFA its start (exactly as the runtime engine's lazy DFAs
  # do, but with every state built in advance), and when groups are asked
  # for, the one-pass DFA or a Pike VM reads the match span alone. Nothing
  # is allocated: the tables are read-only data in the binary, and the
  # meter and the capture scratch live in the caller's stack frame.
  #
  # **Limits.** The work budget is `SearchLimits#work_budget` for the
  # program's state count, as on the runtime engine; every chunk of bytes
  # is allowed by the meter before it is read, and the deadline is read
  # when the call starts and at each clock checkpoint.
  struct StaticMatcher(F, R, N)
    # The search result that is not a position.
    NO_MATCH = -1
    # The most bytes read between charges.
    CHUNK_BYTES = 4096
    # The dead state's id and the id of the dead state that reports a
    # match; every id below `DEAD_LIMIT` is one of them.
    DEAD       = 0
    DEAD_MATCH = 1
    DEAD_LIMIT = 2
    # The `start_scan` of a pattern whose searches do not scan for start
    # bytes (`StaticByteScan::SKIP_ASCII` is -1).
    NO_START_SCAN = -2

    getter source : String
    getter options : CompileOptions
    getter slot_count : Int32
    @classes : Slice(UInt8)
    @forward : StaticDirection(F)
    @reverse : StaticDirection(R)
    @program : StaticProgram(N)
    @one_pass : StaticOnePass
    @prefilter : StaticPrefilter
    @required_bytes : Slice(UInt8)
    # The fewest bytes a match spans (`StartFilter#minimum_bytes`).
    @minimum_bytes : Int32
    # The `StaticByteScan` code for the bytes a match can start with, or
    # `NO_START_SCAN` (see `find_at_start_bytes`).
    @start_scan : Int32
    @unicode_words : Bool
    @final_lf : Bool
    @anchored_start : Bool
    @budget_states : Int32
    # Where the forward start states of a search from the start of the
    # text sit in `StaticDirection#starts` (the unanchored one, then the
    # anchored one).
    @text_start_index : Int32
    # The words of stack scratch `search_groups` needs.
    getter scratch_words : Int32

    def initialize(*, @source : String, @options : CompileOptions, @classes : Slice(UInt8),
                   @forward : StaticDirection(F), @reverse : StaticDirection(R), @program : StaticProgram(N),
                   @one_pass : StaticOnePass, @unicode_words : Bool, @final_lf : Bool, @anchored_start : Bool,
                   @budget_states : Int32, @slot_count : Int32, @prefilter : StaticPrefilter = StaticPrefilter.none,
                   @required_bytes : Slice(UInt8) = Slice(UInt8).empty, @minimum_bytes : Int32 = 0,
                   @start_scan : Int32 = NO_START_SCAN)
      @scratch_words = @slot_count > 2 ? StaticScratch.words_for(@program.size, @slot_count) : @slot_count
      @text_start_index = @forward.start_index(LazyDFA::TEXT_EDGE) * 2
    end

    # The number of capturing groups (group 0 not included).
    def capture_count : Int32
      @slot_count // 2 - 1
    end

    # True when *haystack* has a match at or after *byte_offset*; stops at
    # the first match end it reaches.
    def matches?(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                 validate : Bool) : Bool
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      bytes = haystack.to_slice
      return false unless start_allowed?(bytes, byte_offset)
      return false if required_byte_missing?(bytes, byte_offset, meter)
      if candidate_search?(bytes, byte_offset, meter)
        start, resume = find_at_candidates(bytes, byte_offset, true, meter)
        return start >= 0 unless start == RESUME
        byte_offset = resume
      end
      find_end(bytes, byte_offset, @anchored_start, true, meter) >= 0
    end

    # The span of the leftmost-first match at or after *byte_offset*, or
    # nil.
    def search_span(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                    validate : Bool) : Span?
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      find_span(haystack.to_slice, byte_offset, meter)
    end

    # Finds the leftmost-first match at or after *byte_offset* and writes
    # its groups to the first `slot_count` words of *scratch* (which holds
    # *scratch_words* words, the rest for the capture pass); returns false
    # when nothing matches.
    def search_groups(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                      validate : Bool, scratch : Pointer(Int32), scratch_words : Int32) : Bool
      if scratch_words < @scratch_words
        raise Mica::Error.new("internal error: #{scratch_words} words of capture scratch for #{@source.inspect}")
      end
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      bytes = haystack.to_slice
      if direct_backtrack?(bytes, byte_offset)
        return false if required_byte_missing?(bytes, byte_offset, meter)
        # A short haystack: the backtracker searches it outright, and its
        # first match in priority order is the leftmost-first match.
        answer = backtrack_pass(bytes, byte_offset, bytes.size, byte_offset, meter, scratch + @slot_count,
          @anchored_start, false)
        return answer == BACKTRACK_MATCHED unless answer == BACKTRACK_DECLINED
      end
      start, finish, lower_bound = find_ends(bytes, byte_offset, meter)
      return false if finish < 0
      if @slot_count > 2
        # Without a one-pass DFA, a match whose start the forward search
        # left open is read by the backtracker from the lowest start on: it
        # finds the start and the groups in one pass, with no reverse scan.
        if start == UNKNOWN_START && !@one_pass.present? &&
           backtrack_pass(bytes, lower_bound, finish, byte_offset, meter, scratch + @slot_count, false, true) == BACKTRACK_MATCHED
          return true
        end
        start = start_by_reverse(bytes, finish, lower_bound, meter) if start == UNKNOWN_START
        read_by_one_pass = @one_pass.present? &&
                           @one_pass.captures(bytes, start, finish, byte_offset, @classes.to_unsafe, scratch,
                             @slot_count, meter)
        unless read_by_one_pass ||
               backtrack_pass(bytes, start, finish, byte_offset, meter, scratch + @slot_count, true, true) == BACKTRACK_MATCHED
          capture_pass(bytes, start, finish, byte_offset, meter, scratch + @slot_count)
        end
      else
        start = start_by_reverse(bytes, finish, lower_bound, meter) if start == UNKNOWN_START
        scratch[0] = start
        scratch[1] = finish
      end
      true
    end

    # The most (state, position) pairs a haystack may take for
    # `search_groups` to search it with the backtracker alone.
    DIRECT_BACKTRACK_BITS = 4_096

    # True when `search_groups` searches *bytes* from *byte_offset* with
    # the backtracker alone: the pattern has groups, is not anchored at its
    # start (the DFA ends such a search within a few bytes when nothing
    # matches) and has neither a one-pass DFA nor a prefilter, and the
    # haystack left is short enough
    # (`DIRECT_BACKTRACK_BITS`).
    private def direct_backtrack?(bytes : Bytes, byte_offset : Int32) : Bool
      return false if @slot_count <= 2 || @one_pass.present? || @prefilter.present? || @anchored_start
      return false unless start_allowed?(bytes, byte_offset)
      @program.size.to_i64 * (bytes.size - byte_offset + 1) <= DIRECT_BACKTRACK_BITS
    end

    # Yields each leftmost-first match of *haystack* in turn, stepping over
    # one character after an empty match as `String#scan` does. One work
    # budget and one deadline cover the whole call.
    def each_span(haystack : String, limits : SearchLimits, deadline : Time::Span?, & : Span ->) : Nil
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, true)
      bytes = haystack.to_slice
      byte_offset = 0
      while byte_offset <= bytes.size
        span = find_span(bytes, byte_offset, meter)
        break unless span
        yield span
        meter.enforce_deadline(span.byte_end)
        byte_offset = if !span.empty?
                        span.byte_end
                      elsif span.byte_end >= bytes.size
                        bytes.size + 1
                      else
                        span.byte_end + Core::UTF8.sequence_length(bytes.unsafe_fetch(span.byte_end))
                      end
      end
    end

    # Starts a call's meter, reads the deadline and (with *validate*)
    # checks that *haystack* is valid UTF-8 (see `ValidateInWindows`).
    private def open(counters : Pointer(Int64), haystack : String, limits : SearchLimits, deadline : Time::Span?,
                     validate : Bool) : StaticMeter
      meter = StaticMeter.new(counters, limits, @budget_states, haystack.bytesize, deadline)
      # The deadline is read before the haystack is, as on the runtime
      # engine.
      meter.enforce_deadline(0) if deadline
      # Validation reads every byte once, one operation per byte, in
      # windows the meter allows before each is read, so the deadline and
      # `max_work` stop it as they stop a scan.
      ValidateInWindows.new(haystack.to_slice, meter).perform if validate
      meter
    end

    @[AlwaysInline]
    private def start_allowed?(bytes : Bytes, byte_offset : Int32) : Bool
      if byte_offset < 0 || (byte_offset < bytes.size && bytes.unsafe_fetch(byte_offset) & 0xC0 == 0x80)
        raise_offset_error(byte_offset)
      end
      # Past the end, or fewer bytes are left than any match spans.
      byte_offset <= bytes.size - @minimum_bytes
    end

    # Raises the `ArgumentError` for a *byte_offset* that is negative or
    # inside a character (kept out of `start_allowed?`, which every call
    # runs).
    private def raise_offset_error(byte_offset : Int32) : NoReturn
      raise ArgumentError.new("Negative byte index: #{byte_offset}") if byte_offset < 0
      raise ArgumentError.new("Byte index #{byte_offset} is inside a UTF-8 character")
    end

    private def find_span(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : Span?
      start, finish, lower_bound = find_ends(bytes, byte_offset, meter)
      return nil if finish < 0
      start = start_by_reverse(bytes, finish, lower_bound, meter) if start == UNKNOWN_START
      Span.new(start, finish)
    end

    # The start `find_ends` returns when only the reverse DFA can tell it.
    UNKNOWN_START = -3

    # The end of the leftmost-first match at or after *byte_offset*, and
    # its start when the search knows it without the reverse DFA (anchored,
    # or found at a prefilter candidate), else `UNKNOWN_START`; the end is
    # `NO_MATCH` when nothing matches. The third value is the lowest
    # position the match can start at.
    private def find_ends(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : {Int32, Int32, Int32}
      return {NO_MATCH, NO_MATCH, byte_offset} unless start_allowed?(bytes, byte_offset)
      return {NO_MATCH, NO_MATCH, byte_offset} if required_byte_missing?(bytes, byte_offset, meter)
      if candidate_search?(bytes, byte_offset, meter)
        start, finish = find_at_candidates(bytes, byte_offset, false, meter)
        unless start == RESUME
          return start >= 0 ? {start, finish, byte_offset} : {NO_MATCH, NO_MATCH, byte_offset}
        end
        byte_offset = finish
      end
      anchored = @anchored_start
      finish = find_end(bytes, byte_offset, anchored, false, meter)
      return {NO_MATCH, NO_MATCH, byte_offset} if finish < 0
      {anchored ? byte_offset : UNKNOWN_START, finish, byte_offset}
    end

    # The start of the match ending at *finish*, from the reverse DFA.
    private def start_by_reverse(bytes : Bytes, finish : Int32, lower_bound : Int32, meter : StaticMeter) : Int32
      start = find_start(bytes, finish, lower_bound, meter)
      raise Mica::Error.new("internal error: the reverse DFA found no start for #{finish}") if start < 0
      start
    end

    # The start `find_at_candidates` returns when the search continues on
    # the forward and reverse DFAs from the position it returns.
    RESUME = -2
    # What `find_end` returns when it reached its *stop* undecided.
    UNDECIDED = -4
    # The most bytes one anchored try at a candidate or start byte reads.
    # A try still undecided there (a long match, or a long failure such
    # as `(a|aa)*b` over a run of a's, where every try reads to the end)
    # hands the search to the DFAs from that candidate, so the tries cost
    # the call at most this many bytes more than the DFAs alone.
    TRY_REACH = 256
    # The bytes failed tries may read beyond twice the bytes the search
    # has moved past before it hands the search to the DFAs: tries that
    # fail far from their start, close together (`(a|aa)*b` over a short
    # run of a's), cost less on the DFAs, which read each byte once.
    FAILED_TRY_ROOM = 64_i64
    # The bytes failed anchored tries may read beyond the bytes the search
    # covers before the search continues on the DFAs (room for
    # `CandidateSearch::MAX_TRIES` short tries near the end of the
    # haystack, as on the runtime engine).
    FAILED_TRY_SLACK = CandidateSearch::MAX_TRIES.to_i64 * (CandidateSearch::TRY_REACH + 1)
    # The most operations per remaining byte a search at candidates can
    # make: the scan reads each byte once, the failed tries at most the
    # bytes again (plus `FAILED_TRY_SLACK`), and a search that continues on
    # the DFAs reads them twice more.
    CANDIDATE_WORK_PER_BYTE = 4_i64

    # True when a byte every match contains (`StartFilter#list_of_required_bytes`,
    # ASCII, rarest first) is missing from the haystack at or after
    # *byte_offset*, so no match starts there: found with `memchr` in the
    # windows the meter allows, one operation per byte read, as on the
    # runtime engine. A pattern anchored at its start, or one with a
    # prefilter (which finds where a literal starts), does not look, nor
    # does a search whose allowance does not cover the scans as well as
    # the DFAs' most work.
    private def required_byte_missing?(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : Bool
      required = @required_bytes
      return false if required.empty? || @anchored_start || @prefilter.present?
      remaining = (bytes.size - byte_offset + 1).to_i64
      return false if meter.room < (required.size + 2) * remaining
      required.each do |byte|
        return true unless holds_byte?(bytes, byte_offset, byte, meter)
      end
      false
    end

    # True when *bytes* holds *byte* at or after *from*.
    private def holds_byte?(bytes : Bytes, from : Int32, byte : UInt8, meter : StaticMeter) : Bool
      at = from
      pointer = bytes.to_unsafe
      while at < bytes.size
        window = meter.readable(bytes.size - at, at)
        found = LibC.memchr(pointer + at, byte.to_i32, window)
        unless found.null?
          meter.charge((found.as(UInt8*) - (pointer + at)).to_i32 + 1, at)
          return true
        end
        meter.charge(window, at)
        at += window
      end
      false
    end

    # True when the search runs anchored at each prefilter candidate (see
    # `find_at_candidates`) or at each start byte (see
    # `find_at_start_bytes`): the pattern has a prefilter or a start scan,
    # is not anchored at its start, and the meter's allowance covers the
    # most work such a search can make, so it never raises `max_work` where
    # the DFAs alone would not.
    private def candidate_search?(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : Bool
      return false if @anchored_start
      return false unless @prefilter.present? || @start_scan != NO_START_SCAN
      most = CANDIDATE_WORK_PER_BYTE * (bytes.size - byte_offset + 1) + FAILED_TRY_SLACK + 2
      meter.room >= most
    end

    # Searches anchored at each position where the prefilter finds a
    # literal: every match starts with a prefix literal, so the first
    # candidate where an anchored match exists starts the leftmost match,
    # and its end is that match's end, with no reverse scan. When the
    # literals are the whole matches (`StaticPrefilter#exact?`), the
    # literal found is the match.
    #
    # Returns the match's start and end, `NO_MATCH` as the start, or
    # `RESUME` and the position from which the forward and reverse DFAs
    # take over (no match starts before it): once the failed tries have
    # read more bytes than the search covers (plus `FAILED_TRY_SLACK`), or
    # the prefilter proves ineffective. The work is then at most the
    # bytes again, and the call stays linear. That position is the start
    # of the character the candidate falls in (an unverified candidate, a
    # rare byte's position less its offset in the literal, can fall inside
    # one), as the DFAs start between characters.
    private def find_at_candidates(bytes : Bytes, byte_offset : Int32, earliest : Bool,
                                   meter : StaticMeter) : {Int32, Int32}
      return find_at_start_bytes(bytes, byte_offset, earliest, meter) unless @prefilter.present?
      prefilter = @prefilter
      scan = StaticPrefilterScan.new(prefilter, bytes)
      failed_cap = (bytes.size - byte_offset).to_i64 + FAILED_TRY_SLACK
      failed = 0_i64
      at = byte_offset
      while true
        candidate = scan.find(at, meter)
        return {NO_MATCH, NO_MATCH} if candidate < 0
        literal = scan.last_literal
        return {RESUME, character_start(bytes, candidate)} if literal < 0
        return {candidate, candidate + prefilter.literal_size(literal)} if prefilter.exact?
        before = meter.operations
        finish = find_end(bytes, candidate, true, earliest, meter, try_stop(candidate))
        return {candidate, finish} if finish >= 0
        return {RESUME, character_start(bytes, candidate)} if finish == UNDECIDED
        failed += meter.operations - before
        if failed > failed_cap || tries_fail_far?(failed, candidate - byte_offset) || scan.ineffective?
          return {RESUME, character_start(bytes, candidate)}
        end
        at = candidate + 1
      end
    end

    # The start of the character byte *at* falls in.
    private def character_start(bytes : Bytes, at : Int32) : Int32
      while 0 < at < bytes.size && bytes.unsafe_fetch(at) & 0xC0 == 0x80
        at -= 1
      end
      at
    end

    # Searches anchored at each byte a match can start with, found with
    # `StaticByteScan` and the pattern's `start_scan` code in windows the
    # meter allows, one operation per byte read. No match starts at any
    # other byte, so the first where an anchored match exists starts the
    # leftmost match, and the reverse DFA is not needed: a pattern such as
    # `,\s*` finds each match with one scan and one short anchored run.
    # Returns as `find_at_candidates` does, `RESUME` once the failed tries
    # have read more bytes than the search covers (plus
    # `FAILED_TRY_SLACK`).
    private def find_at_start_bytes(bytes : Bytes, byte_offset : Int32, earliest : Bool,
                                    meter : StaticMeter) : {Int32, Int32}
      code = @start_scan
      last = bytes.size - @minimum_bytes
      failed_cap = (bytes.size - byte_offset).to_i64 + FAILED_TRY_SLACK
      failed = 0_i64
      at = byte_offset
      while at <= last
        window = meter.readable(Math.min(last + 1 - at, CHUNK_BYTES), at)
        stop = at + window
        candidate = StaticByteScan.forward(bytes, at, stop, code)
        if candidate == stop
          meter.charge(window, at)
          at = stop
          next
        end
        meter.charge(candidate - at + 1, at)
        before = meter.operations
        finish = find_end(bytes, candidate, true, earliest, meter, try_stop(candidate))
        return {candidate, finish} if finish >= 0
        return {RESUME, candidate} if finish == UNDECIDED
        failed += meter.operations - before
        return {RESUME, candidate} if failed > failed_cap || tries_fail_far?(failed, candidate - byte_offset)
        at = candidate + 1
      end
      {NO_MATCH, NO_MATCH}
    end

    # Where a try at *candidate* stops undecided (see `TRY_REACH`).
    @[AlwaysInline]
    private def try_stop(candidate : Int32) : Int32
      candidate > Int32::MAX - TRY_REACH ? Int32::MAX : candidate + TRY_REACH
    end

    # True when the failed tries have read *failed* bytes, more than
    # twice the *covered* bytes the search moved past (plus
    # `FAILED_TRY_ROOM`).
    @[AlwaysInline]
    private def tries_fail_far?(failed : Int64, covered : Int32) : Bool
      failed > 2_i64 * covered + FAILED_TRY_ROOM
    end

    # Searches forward from *start* for the end of the leftmost-first
    # match (`LazyDFA#find_end` over a complete table). With *stop* before
    # the end of the text, a search that reads to *stop* undecided returns
    # `UNDECIDED`.
    private def find_end(bytes : Bytes, start : Int32, anchored : Bool, earliest : Bool, meter : StaticMeter,
                         stop : Int32 = Int32::MAX) : Int32
      size = bytes.size
      limit = @final_lf && size > start && bytes.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      text_limit = limit
      limit = stop if stop < limit
      direction = @forward
      shift = direction.shift
      table = direction.table.to_unsafe
      classes = direction.classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
      words = @unicode_words
      word_offset = direction.word_offset
      starts_at = if start == 0
                    @text_start_index
                  else
                    direction.start_index(symbol_flags(bytes, start - 1)) * 2
                  end
      current = direction.starts.unsafe_fetch(starts_at + (anchored ? 1 : 0)).to_i32
      last_end = NO_MATCH
      at = start
      wide_start = wide_end = 0
      wide_word = false
      # Where self-loop runs may start again (see `LazyDFA::RUN_BACKOFF`).
      runs_from = 0
      while at < limit
        chunk_end = at + meter.readable(Math.min(limit - at, CHUNK_BYTES), at)
        chunk_start = at
        while at < chunk_end
          byte = bytes.unsafe_fetch(at)
          symbol = classes[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(bytes, at) unless wide_start <= at < wide_end
            symbol &+= word_offset if wide_word
          end
          entry = table[current.unsafe_shl(shift) &+ symbol]
          at &+= 1
          if entry == current && at >= runs_from && !words &&
             (entry >= accel_limit || (!earliest && DEAD_LIMIT <= entry < special_limit))
            # A state that loops to itself (`.*`, `[^"]*`, the start state
            # between possible starts) keeps its row, so the loads of the
            # run no longer wait on each other (`LazyDFA#find_end` does the
            # same). In a match state each byte of the run ends a match, so
            # the last one read ends the latest. A short run pays more for
            # leaving this loop than it saves, so after one the search steps
            # byte by byte for `LazyDFA::RUN_BACKOFF` bytes.
            run_start = at
            row = current.unsafe_shl(shift)
            while at < chunk_end && table[row &+ classes[bytes.unsafe_fetch(at)]] == entry
              at &+= 1
            end
            runs_from = at + LazyDFA::RUN_BACKOFF if at - run_start < LazyDFA::SHORT_RUN
          elsif entry.to_i32 == current &+ 1 && entry >= accel_limit && !words
            # A chain of states numbered one after another (see
            # `Static::BuildTheTables#in_chains`), as `[0-9a-f]{8}` reads:
            # the next state is known before its load returns, so the
            # loads of the chain no longer wait on each other.
            chained = entry.to_i32
            while at < chunk_end && table[chained.unsafe_shl(shift) &+ classes[bytes.unsafe_fetch(at)]].to_i32 == chained &+ 1
              chained &+= 1
              at &+= 1
            end
            entry = F.new!(chained)
          end
          current = entry.to_i32
          next if current >= accel_limit
          if current >= special_limit
            at = StaticByteScan.forward(bytes, at, chunk_end, direction.accel_bytes.unsafe_fetch(current - special_limit))
            next
          end
          if current < DEAD_LIMIT
            last_end = at - 1 if current == DEAD_MATCH
            meter.charge(at - chunk_start, at)
            return last_end
          end
          last_end = at - 1
          if earliest
            meter.charge(at - chunk_start, at)
            return last_end
          end
        end
        meter.charge(at - chunk_start, at)
      end
      return UNDECIDED if limit < text_limit
      if at == size - 1 && limit == size - 1
        meter.charge(1, at)
        current = table[current.unsafe_shl(shift) &+ direction.edge_symbol &+ 1].to_i32
        at += 1
        if current < special_limit
          if current >= DEAD_LIMIT || current == DEAD_MATCH
            last_end = at - 1
            return last_end if earliest
          end
          return last_end if current < DEAD_LIMIT
        end
      end
      current = table[current.unsafe_shl(shift) &+ direction.edge_symbol].to_i32
      last_end = size if current < special_limit && current != DEAD
      last_end
    end

    # Searches backward from *finish* to no lower than *lower_bound* for
    # the leftmost start of a match ending at *finish*
    # (`LazyDFA#find_start` over a complete table).
    private def find_start(bytes : Bytes, finish : Int32, lower_bound : Int32, meter : StaticMeter) : Int32
      size = bytes.size
      direction = @reverse
      shift = direction.shift
      table = direction.table.to_unsafe
      classes = direction.classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
      words = @unicode_words
      word_offset = direction.word_offset
      flags = 0
      if finish == size
        flags = LazyDFA::TEXT_EDGE
      else
        byte = bytes.unsafe_fetch(finish)
        flags = symbol_flags(bytes, finish)
        flags |= LazyDFA::PREVIOUS_TAIL if byte & 0xC0 == 0x80
        flags |= LazyDFA::FINAL_LF_EDGE if finish == size - 1 && byte == Look::LINE_FEED
      end
      current = direction.starts.unsafe_fetch(direction.start_index(flags)).to_i32
      last_start = NO_MATCH
      at = finish
      wide_start = wide_end = 0
      wide_word = false
      # Where self-loop runs may start again, going down (see
      # `LazyDFA::RUN_BACKOFF`).
      runs_below = Int32::MAX
      while at > lower_bound
        chunk_end = at - meter.readable(Math.min(at - lower_bound, CHUNK_BYTES), at)
        chunk_start = at
        while at > chunk_end
          byte = bytes.unsafe_fetch(at - 1)
          symbol = classes[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(bytes, at - 1) unless wide_start <= at - 1 < wide_end
            symbol &+= word_offset if wide_word
          end
          entry = table[current.unsafe_shl(shift) &+ symbol]
          at &-= 1
          if entry == current && at <= runs_below && !words &&
             (entry >= accel_limit || DEAD_LIMIT <= entry < special_limit)
            # A self-loop run, as in `find_end`: in a match state each
            # byte of the run starts a match, and the last one read the
            # leftmost.
            run_start = at
            row = current.unsafe_shl(shift)
            while at > chunk_end && table[row &+ classes[bytes.unsafe_fetch(at - 1)]] == entry
              at &-= 1
            end
            runs_below = at - LazyDFA::RUN_BACKOFF if run_start - at < LazyDFA::SHORT_RUN
          elsif entry.to_i32 == current &+ 1 && entry >= accel_limit && !words
            # A chain of states numbered one after another, as in
            # `find_end`.
            chained = entry.to_i32
            while at > chunk_end && table[chained.unsafe_shl(shift) &+ classes[bytes.unsafe_fetch(at - 1)]].to_i32 == chained &+ 1
              chained &+= 1
              at &-= 1
            end
            entry = R.new!(chained)
          end
          current = entry.to_i32
          next if current >= accel_limit
          if current >= special_limit
            at = StaticByteScan.backward(bytes, at, chunk_end, direction.accel_bytes.unsafe_fetch(current - special_limit))
            next
          end
          last_start = at + 1 if current != DEAD
          if current < DEAD_LIMIT
            meter.charge(chunk_start - at, at)
            return last_start
          end
        end
        meter.charge(chunk_start - at, at)
      end
      symbol = lower_bound > 0 ? reverse_symbol_at(bytes, lower_bound - 1) : direction.edge_symbol
      current = table[current.unsafe_shl(shift) &+ symbol].to_i32
      last_start = lower_bound if current < special_limit && current != DEAD
      last_start
    end

    # The state flags reading byte *at* leaves for the next position (see
    # `LazyDFA`).
    private def symbol_flags(bytes : Bytes, at : Int32) : Int32
      byte = bytes.unsafe_fetch(at)
      flags = 0
      flags |= LazyDFA::PREVIOUS_LF if byte == Look::LINE_FEED
      if byte < 0x80
        flags |= LazyDFA::PREVIOUS_WORD | LazyDFA::PREVIOUS_UNICODE_WORD if Look.word_code_point?(byte.to_i32, true)
      else
        flags |= LazyDFA::PREVIOUS_WIDE
        flags |= LazyDFA::PREVIOUS_UNICODE_WORD if @unicode_words && LazyDFA.wide_char(bytes, at)[2]
      end
      flags
    end

    # The reverse table's column for the byte at *at*.
    private def reverse_symbol_at(bytes : Bytes, at : Int32) : Int32
      byte = bytes.unsafe_fetch(at)
      symbol = @reverse.classes.unsafe_fetch(byte).to_i32
      symbol += @reverse.word_offset if @unicode_words && byte >= 0x80 && LazyDFA.wide_char(bytes, at)[2]
      symbol
    end

    # Reads the groups of the match *start*...*finish* with a bounded
    # backtracker (RE2's BitState, as `BoundedBacktracker`): a depth-first
    # search over the span alone in leftmost-first priority order that
    # marks each (state, position) pair it visits in a bitset and never
    # visits one twice, so it makes at most states × (span + 1) visits.
    # Writes the groups to the first `slot_count` words before *scratch*
    # and returns true; returns false, having written nothing there, when
    # the bitset or the job stack (`StaticScratch`) is too small for the
    # span, and the Pike VM reads the groups instead. Each visit and each
    # slot undo is charged one operation, as on the runtime engine, all at
    # once when the pass ends: it runs only when the allowance left covers
    # its most work (a visit per pair and an undo per visit), and that is
    # at most `BACKTRACK_BITS` visits, so the deadline is read no later.
    #
    # The scratch: one slot vector, the bitset (`BACKTRACK_BITS` bits),
    # then the job stack, two words a job: a state and a position, or a
    # slot to restore (`-(slot + 1)`) and its value.
    private def backtrack_pass(bytes : Bytes, from : Int32, finish : Int32, search_start : Int32, meter : StaticMeter,
                               scratch : Pointer(Int32), anchored : Bool, exact_end : Bool) : Int32
      program = @program
      slots = @slot_count
      columns = finish - from + 1
      bits = program.size.to_i64 * columns
      return BACKTRACK_DECLINED if bits > StaticScratch::BACKTRACK_BITS || meter.room < 2 * bits + 2
      thread_slots = scratch
      visited = (scratch + slots).as(Pointer(UInt32))
      visited.clear(((bits + 31) // 32).to_i32)
      jobs = scratch + slots + StaticScratch::BACKTRACK_BITS // 32
      job_limit = 2 * StaticScratch::BACKTRACK_JOBS
      slots.times { |index| thread_slots[index] = -1 }
      kinds = program.kinds
      classes = @classes.to_unsafe
      # The visits and undos made, charged when the pass ends.
      work = 0
      # Unanchored, each character start from *from* on is tried in turn
      # with the same bitset (a pair that failed from one start fails from
      # every later one), and the first that matches is the match's start.
      origin = from
      while true
        jobs[0] = program.start_state
        jobs[1] = origin
        depth = 2
        while depth > 0
          depth -= 2
          current = jobs[depth]
          at = jobs[depth + 1]
          if current < 0
            thread_slots[-(current + 1)] = at
            next
          end
          if current >= BACKTRACK_STARTS
            # A job of starts (see the `Split` case): the last first, the
            # rest left on the stack.
            current -= BACKTRACK_STARTS
            first = from + (at & 0xFFFF)
            last = from + (at >> 16)
            if Program::StateKind.new(kinds.unsafe_fetch(current)).byte_range?
              # A byte state: the starts whose byte it does not take are
              # visited here, last first, as the general loop would visit
              # them, and the first it takes continues past its byte.
              low = program.lows.unsafe_fetch(current)
              high = program.highs.unsafe_fetch(current)
              taken = -1
              while last >= first
                position = last
                last -= 1
                next unless first_backtrack_visit?(visited, current, position - from, columns)
                work += 1
                next unless position < finish && low <= bytes.unsafe_fetch(position) <= high
                taken = position
                break
              end
              if last >= first
                jobs[depth] = current + BACKTRACK_STARTS
                jobs[depth + 1] = ((last - from) << 16) | (first - from)
                depth += 2
              end
              next if taken < 0
              current = program.next_states.unsafe_fetch(current).to_i32
              at = taken + 1
            else
              if last > first
                jobs[depth + 1] = ((last - 1 - from) << 16) | (first - from)
                depth += 2
              end
              at = last
            end
          end
          while true
            break unless first_backtrack_visit?(visited, current, at - from, columns)
            work += 1
            kind = Program::StateKind.new(kinds.unsafe_fetch(current))
            case kind
            when .byte_range?
              break unless at < finish
              byte = bytes.unsafe_fetch(at)
              break unless program.lows.unsafe_fetch(current) <= byte <= program.highs.unsafe_fetch(current)
              current = program.next_states.unsafe_fetch(current).to_i32
              at += 1
            when .sparse?
              break unless at < finish
              target = program.sparse_step(current, bytes.unsafe_fetch(at), classes)
              break if target < 0
              current = target
              at += 1
            when .split?
              if depth >= job_limit
                meter.charge(work, at)
                return BACKTRACK_DECLINED
              end
              alternate = program.alternates.unsafe_fetch(current).to_i32
              body = program.next_states.unsafe_fetch(current).to_i32
              body_kind = Program::StateKind.new(kinds.unsafe_fetch(body))
              unless body_kind.byte_range? || body_kind.sparse?
                jobs[depth] = alternate
                jobs[depth + 1] = at
                depth += 2
                current = body
                next
              end
              # A greedy loop over a byte state (`.*`, `\d+`): while the
              # byte read leads back to this split, step it here, marking
              # and counting the pairs the general loop would, and push the
              # alternate of every position passed as one job of starts.
              first = at
              target = -1
              while at < finish && first_backtrack_visit?(visited, body, at - from, columns)
                work += 1
                byte = bytes.unsafe_fetch(at)
                target = if body_kind.sparse?
                           program.sparse_step(body, byte, classes)
                         elsif program.lows.unsafe_fetch(body) <= byte <= program.highs.unsafe_fetch(body)
                           program.next_states.unsafe_fetch(body).to_i32
                         else
                           -1
                         end
                break unless target == current
                target = -1
                break unless first_backtrack_visit?(visited, current, at + 1 - from, columns)
                work += 1
                at += 1
              end
              jobs[depth] = alternate + BACKTRACK_STARTS
              jobs[depth + 1] = ((at - from) << 16) | (first - from)
              depth += 2
              break if target < 0
              current = target
              at += 1
            when .save?
              slot = program.arguments.unsafe_fetch(current).to_i32
              if slot < slots
                if depth >= job_limit
                  meter.charge(work, at)
                  return BACKTRACK_DECLINED
                end
                work += 1
                jobs[depth] = -(slot + 1)
                jobs[depth + 1] = thread_slots[slot]
                depth += 2
                thread_slots[slot] = at
              end
              current = program.next_states.unsafe_fetch(current).to_i32
            when .look?
              look = Program::LookKind.new(program.arguments.unsafe_fetch(current).to_i32)
              break unless Look.holds?(look, bytes, at, search_start)
              current = program.next_states.unsafe_fetch(current).to_i32
            when .match?
              # The first match in priority order ends at *finish* (the DFAs
              # found that end); anything else is left to the Pike VM, which
              # checks it.
              meter.charge(work, at)
              return BACKTRACK_DECLINED if exact_end && !(at == finish && thread_slots[0] == origin)
              (scratch - slots).copy_from(thread_slots, slots)
              return BACKTRACK_MATCHED
            else
              break
            end
          end
        end
        break if anchored
        origin += 1
        while origin < finish && bytes.unsafe_fetch(origin) & 0xC0 == 0x80
          origin += 1
        end
        break if origin > finish
      end
      meter.charge(work, finish)
      exact_end ? BACKTRACK_DECLINED : BACKTRACK_NO_MATCH
    end

    # `backtrack_pass`'s answers: the groups are written, nothing matches,
    # or the pass declined and wrote nothing.
    private BACKTRACK_MATCHED  =  1
    private BACKTRACK_NO_MATCH =  0
    private BACKTRACK_DECLINED = -1

    # Added to a state number in the backtracker's job stack, a job of
    # starts: explore that state at each position from the first to the
    # last, the last first, as the jobs one `Split` per position would be
    # taken. The job's position word holds the first position (from the
    # span's start) in its low 16 bits and the last in the bits above; a
    # span the bitset holds is under 2^14 bytes.
    private BACKTRACK_STARTS = 1 << 30

    # Marks the pair (*state*, *column*) visited and returns true, or
    # returns false when it was visited before.
    @[AlwaysInline]
    private def first_backtrack_visit?(visited : Pointer(UInt32), state : Int32, column : Int32, columns : Int32) : Bool
      bit = state &* columns &+ column
      word = visited + (bit >> 5)
      mask = 1_u32 << (bit & 31)
      return false if word.value & mask != 0
      word.value |= mask
      true
    end

    # Runs the Pike VM anchored at *start* over the span alone (bytes below
    # *finish*), as the runtime engine's capture pass does, and writes the
    # groups to the first `slot_count` words before *scratch*. The rest of
    # the scratch space: two slot tables (states × slots), two sparse sets
    # (dense and sparse, states each), the closure stack (two words per
    # frame) and one slot vector.
    private def capture_pass(bytes : Bytes, start : Int32, finish : Int32, search_start : Int32, meter : StaticMeter,
                             scratch : Pointer(Int32)) : Nil
      output = scratch - @slot_count
      program = @program
      states = program.size
      slots = @slot_count
      current_slots = scratch
      next_slots = scratch + states * slots
      sets = scratch + 2 * states * slots
      current_dense = sets
      current_sparse = sets + states
      next_dense = sets + 2 * states
      next_sparse = sets + 3 * states
      stack = sets + 4 * states
      thread_slots = stack + 2 * states
      current_size = 0
      next_size = 0
      matched = false
      at = start
      while true
        break if current_size == 0 && (matched || at > start)
        if !matched && at == start
          slots.times { |index| thread_slots[index] = -1 }
          current_size = closure(program.start_state, at, bytes, search_start, meter, current_dense, current_sparse,
            current_slots, current_size, stack, thread_slots)
        end
        index = 0
        while index < current_size
          state = current_dense[index]
          index += 1
          meter.charge(1, at)
          kind = Program::StateKind.new(program.kinds.unsafe_fetch(state))
          target = -1
          case kind
          when .match?
            (current_slots + state * slots).copy_to(output, slots)
            matched = true
            break
          when .byte_range?
            next if at >= finish
            byte = bytes.unsafe_fetch(at)
            next unless program.lows.unsafe_fetch(state) <= byte <= program.highs.unsafe_fetch(state)
            target = program.next_states.unsafe_fetch(state).to_i32
          when .sparse?
            next if at >= finish
            target = program.sparse_step(state, bytes.unsafe_fetch(at), @classes.to_unsafe)
          end
          next if target < 0
          meter.charge(slots, at)
          thread_slots.copy_from(current_slots + state * slots, slots)
          next_size = closure(target, at + 1, bytes, search_start, meter, next_dense, next_sparse, next_slots,
            next_size, stack, thread_slots)
        end
        break if at >= finish
        current_slots, next_slots = next_slots, current_slots
        current_dense, next_dense = next_dense, current_dense
        current_sparse, next_sparse = next_sparse, current_sparse
        current_size = next_size
        next_size = 0
        at += 1
      end
      unless matched && output[0] == start && output[1] == finish
        raise Mica::Error.new("internal error: the static capture pass did not find the span #{start}...#{finish}")
      end
    end

    # Adds the threads reachable from *state_index* at *at* to a list (its
    # dense and sparse sets and slot table) in priority order, as
    # `PikeVM#closure` does, and returns the list's new size.
    private def closure(state_index : Int32, at : Int32, bytes : Bytes, search_start : Int32, meter : StaticMeter,
                        dense : Pointer(Int32), sparse : Pointer(Int32), table : Pointer(Int32), size : Int32,
                        stack : Pointer(Int32), thread_slots : Pointer(Int32)) : Int32
      program = @program
      slots = @slot_count
      depth = 1
      stack[0] = state_index
      stack[1] = 0
      while depth > 0
        depth -= 1
        frame = stack[depth * 2]
        if frame < 0
          thread_slots[-(frame + 1)] = stack[depth * 2 + 1]
          next
        end
        current = frame
        while true
          member = sparse[current]
          break if 0 <= member < size && dense[member] == current
          sparse[current] = size
          dense[size] = current
          size += 1
          meter.charge(1, at)
          kind = Program::StateKind.new(program.kinds.unsafe_fetch(current))
          case kind
          when .byte_range?, .sparse?, .match?
            meter.charge(slots, at)
            (table + current * slots).copy_from(thread_slots, slots)
            break
          when .split?
            stack[depth * 2] = program.alternates.unsafe_fetch(current).to_i32
            depth += 1
            current = program.next_states.unsafe_fetch(current).to_i32
          when .save?
            slot = program.arguments.unsafe_fetch(current).to_i32
            if slot < slots
              stack[depth * 2] = -(slot + 1)
              stack[depth * 2 + 1] = thread_slots[slot]
              depth += 1
              thread_slots[slot] = at
            end
            current = program.next_states.unsafe_fetch(current).to_i32
          when .look?
            kind = Program::LookKind.new(program.arguments.unsafe_fetch(current).to_i32)
            break unless Look.holds?(kind, bytes, at, search_start)
            current = program.next_states.unsafe_fetch(current).to_i32
          else
            break
          end
        end
      end
      size
    end
  end
end
