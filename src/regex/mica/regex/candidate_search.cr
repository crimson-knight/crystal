module Regex::Mica::Regex
  # :nodoc:
  # One single search (`Expression#match_at_byte_index`) of a haystack an
  # earlier call validated, answered without a lease, a searcher or a
  # meter when it can be (see "Candidate searches" in docs/regex.md): the
  # one-pass DFA runs anchored at each *candidate*, a position where a
  # match may start, and the first try that matches gives the leftmost
  # match, span and groups at once. Candidates come from the prefilter's
  # needle bytes when the pattern has prefix literals, else from the start
  # filter's start bytes.
  #
  # It answers only where the searcher would answer the same without
  # raising: no timeout is set, the offset is a character boundary inside
  # the haystack, the plan remembers the haystack as valid UTF-8, and its
  # most work fits the call's allowance, which it checks before it reads
  # the haystack (see `#fits?`). That work is bounded up front: the
  # candidate scan reads each byte from the offset at most once, the
  # failed tries read at most `#failed_bytes_cap` bytes (plus the overshoot
  # of the last), and the try that matches at most the remaining bytes. It
  # declines (`LazyDFA::GAVE_UP`) after `MAX_TRIES` failed tries, past that
  # cap, or when the one-pass DFA cannot decide; it then reports the work
  # it spent (`#spent`), and the caller charges it to the searcher that
  # takes over, so the call as a whole stays within its allowance.
  #
  # A program whose candidates rarely start a match (`MAX_DECLINES`
  # declines, with fewer than `MATCHES_PER_DECLINE` matches each) leaves
  # its searches to the searcher's lazy DFA, trying one search in
  # `RETRY_INTERVAL` to see whether that changed.
  struct CandidateSearch
    # The bytes a try may read at least before it stops undecided (see
    # `#failed_bytes_cap`).
    TRY_REACH = 64
    # The most failed tries one search makes before it declines.
    MAX_TRIES = 16
    # The declines for too many tries after which a program stops using
    # candidate searches.
    MAX_DECLINES = 16
    # The matches a program's candidate searches must find for each decline
    # to keep using them past `MAX_DECLINES`.
    MATCHES_PER_DECLINE = 32
    # A program whose candidate searches do not pay still tries one search
    # in this many.
    RETRY_INTERVAL = 256
    # The most capture slots the caller keeps on the stack.
    MAX_SLOTS = ShortSearch::MAX_SLOTS

    # The work this search did, for the searcher that takes over when it
    # declines.
    getter spent = 0_i64
    @failed_tries = 0
    @failed_bytes = 0_i64

    # *plan* is *program*'s plan, read once by the caller.
    def initialize(@program : Program, @plan : SearchPlan, @haystack : String, @byte_index : Int32,
                   @options : MatchOptions, @limits : SearchLimits, @timeout : Time::Span?)
    end

    # Returns the one-pass DFA when this search applies: no timeout, a
    # program and options it handles, an offset the searcher would accept,
    # a haystack the plan knows is valid, and work that fits. Reads no
    # byte of the haystack but the one at the offset.
    def one_pass : OnePassDFA?
      return nil if @timeout || @program.slot_count > MAX_SLOTS
      options = @program.options
      return nil if options.first_line? || options.end_anchored? || @options.end_anchored?
      bytes = @haystack.to_slice
      return nil if @byte_index < 0 || @byte_index > bytes.size
      return nil if @byte_index < bytes.size && bytes.unsafe_fetch(@byte_index) & 0xC0 == 0x80
      plan = @plan
      return nil unless plan.short_validated?(@haystack) && plan.candidate_searches_pay?
      return nil unless fits?(bytes.size - @byte_index)
      plan.built_one_pass || plan.short_search_one_pass
    end

    # Runs the search on *one_pass* (from `#one_pass`) into *slots*
    # (`slot_count` entries) with *scratch* beside it. Returns the match
    # end, `LazyDFA::NO_MATCH`, or `LazyDFA::GAVE_UP` when this search
    # declines (see `#spent`).
    def run(one_pass : OnePassDFA, slots : Slice(Int64), scratch : Slice(Int64)) : Int32
      plan = @plan
      bytes = @haystack.to_slice
      from = @byte_index
      # `one_pass` declined every end-anchored search.
      if @program.options.anchored? || @options.anchored? || plan.anchored_at_offset?(false)
        finish, scanned = one_pass.search(bytes, from, from, slots, scratch, nil)
        @spent = scanned.to_i64 + 1
        return finish
      end
      prefilter = plan.prefilter
      filter = plan.start_filter
      if prefilter && !plan.literal_search? && prefilter.kind.rare_byte?
        run_at_needles(one_pass, prefilter, bytes, slots, scratch)
      elsif prefilter.nil? && filter.minimum_bytes > 0
        run_at_start_bytes(one_pass, filter, bytes, slots, scratch, Int32::MAX)
      elsif prefilter && filter.minimum_bytes > 0 && prefilter.literal_set.list_of_literals.all?(&.size.== 1)
        # Literals of one byte each (`[ \t\n]+`) are the start filter\x27s
        # start bytes: a scan of the start table finds them as the
        # prefilter would, without the searcher\x27s set-up per call.
        run_at_start_bytes(one_pass, filter, bytes, slots, scratch, SPARSE_SCAN_BYTES)
      else
        LazyDFA::GAVE_UP
      end
    end

    # Tries each position where the prefilter's rare byte puts the start of
    # its one literal, found with `memchr`.
    private def run_at_needles(one_pass : OnePassDFA, prefilter : Prefilter, bytes : Bytes, slots : Slice(Int64),
                               scratch : Slice(Int64)) : Int32
      offset = prefilter.needle_offset
      needle = prefilter.list_of_needles.unsafe_fetch(0).to_i32
      pointer = bytes.to_unsafe
      at = @byte_index + offset
      while at < bytes.size
        found = LibC.memchr(pointer + at, needle, bytes.size - at)
        if found.null?
          @spent += bytes.size - at + 1
          return LazyDFA::NO_MATCH
        end
        position = (found.as(UInt8*) - pointer).to_i32
        @spent += position + 1 - at
        start = position - offset
        if bytes.unsafe_fetch(start) & 0xC0 != 0x80
          finish = try(one_pass, bytes, start, slots, scratch)
          return finish unless finish == LazyDFA::NO_MATCH
        end
        at = position + 1
      end
      @spent += 1
      LazyDFA::NO_MATCH
    end

    # The most bytes `run_at_start_bytes` reads past its last candidate
    # when the plan has a prefilter, whose scan skips a long stretch with
    # no candidate faster than a byte at a time.
    SPARSE_SCAN_BYTES = 256

    # Tries each position whose byte can start a match (`StartFilter`).
    # Past *sparse_bytes* bytes read since the offset or the last
    # candidate with no try, it declines (`LazyDFA::GAVE_UP`, counted as a
    # decline for `SearchPlan#candidate_searches_pay?`) and leaves the rest
    # to the searcher.
    private def run_at_start_bytes(one_pass : OnePassDFA, filter : StartFilter, bytes : Bytes, slots : Slice(Int64),
                                   scratch : Slice(Int64), sparse_bytes : Int32) : Int32
      filter.prepare_second_bytes(@program)
      last = bytes.size - filter.minimum_bytes
      at = @byte_index
      # The scan stops at `last` or where the stretch with no try runs out,
      # one bound, so the loop tests one condition per byte.
      scan_end = scan_end_after(at, last, sparse_bytes)
      while at <= scan_end
        byte = bytes.unsafe_fetch(at)
        # `last` leaves at least `minimum_bytes` bytes, so `at + 1` is in
        # the haystack whenever `second?` can be false.
        if filter.starts?(byte) && byte & 0xC0 != 0x80 && (at + 1 >= bytes.size || filter.second?(bytes.unsafe_fetch(at + 1)))
          finish = try(one_pass, bytes, at, slots, scratch)
          unless finish == LazyDFA::NO_MATCH
            @spent += at + 1 - @byte_index
            return finish
          end
          scan_end = scan_end_after(at + 1, last, sparse_bytes)
        end
        at += 1
      end
      if at <= last
        @spent += at - @byte_index
        @plan.note_candidate_decline
        return LazyDFA::GAVE_UP
      end
      @spent += Math.max(at - @byte_index, 0) + 1
      LazyDFA::NO_MATCH
    end

    # The last position `run_at_start_bytes` reads from *from* before it
    # declines (*sparse_bytes* bytes on), or *last* when that comes first.
    @[AlwaysInline]
    private def scan_end_after(from : Int32, last : Int32, sparse_bytes : Int32) : Int32
      return last if sparse_bytes == Int32::MAX
      Math.min(last.to_i64, from.to_i64 + sparse_bytes - 1).to_i32
    end

    # One anchored try at *start*: the match end, `LazyDFA::NO_MATCH`, or
    # `LazyDFA::GAVE_UP` when the search declines: `MAX_TRIES` failed
    # tries, failed tries that read more than `#failed_bytes_cap`, or a try
    # still undecided where it had to stop.
    @[AlwaysInline]
    private def try(one_pass : OnePassDFA, bytes : Bytes, start : Int32, slots : Slice(Int64),
                    scratch : Slice(Int64)) : Int32
      # A try may read what the failed tries before it left of the cap, and
      # at least `TRY_REACH`.
      reach = Math.max(TRY_REACH.to_i64, failed_bytes_cap(bytes.size - @byte_index) - @failed_bytes)
      stop = start + reach >= bytes.size ? Int32::MAX : (start + reach).to_i32
      finish, scanned = one_pass.search(bytes, start, @byte_index, slots, scratch, nil, stop)
      @spent += scanned + 1
      if finish >= 0
        @plan.note_candidate_match
        return finish
      end
      return finish if finish == LazyDFA::GAVE_UP
      @failed_tries += 1
      @failed_bytes += scanned + 1
      if @failed_tries >= MAX_TRIES
        @plan.note_candidate_decline
        return LazyDFA::GAVE_UP
      end
      return LazyDFA::GAVE_UP if @failed_bytes > failed_bytes_cap(bytes.size - @byte_index)
      LazyDFA::NO_MATCH
    end

    # The most bytes the failed tries of a search over *remaining* bytes may
    # read: the bytes themselves, and room for `MAX_TRIES` short tries
    # near the end of the haystack.
    @[AlwaysInline]
    private def failed_bytes_cap(remaining : Int32) : Int64
      remaining.to_i64 + MAX_TRIES * (TRY_REACH + 1)
    end

    # True when the most work this search can do over *remaining* bytes
    # fits the call's allowance: the candidate scan reads each of them
    # once (plus one), the failed tries read at most `#failed_bytes_cap`
    # plus the overshoot of the last one (`TRY_REACH + 1`), and the
    # try that matches at most the remaining bytes plus one, so at most
    # `3 * remaining + (MAX_TRIES + 1) * (TRY_REACH + 1) + 2`. A
    # sufficient condition that needs no multiplication: the allowance is
    # at least the smaller of `work_ceiling` and `base_work`, or of
    # `work_ceiling` and `base_work + work_per_byte` per haystack byte.
    private def fits?(remaining : Int32) : Bool
      overshoot = (MAX_TRIES + 1).to_i64 * (TRY_REACH + 1) + 2
      needed = 3_i64 * remaining + overshoot
      return false if @limits.work_ceiling < needed
      @limits.base_work >= needed || (@limits.work_per_byte >= 3 && @limits.base_work >= overshoot)
    end
  end
end
