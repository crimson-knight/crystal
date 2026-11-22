module Regex::Mica::Regex
  # :nodoc:
  # Which engines a `Searcher` may run. `Auto` is what the public API uses;
  # the others let specs, the fuzzers and the benchmarks force one path.
  enum Engine
    # Every engine (see `SearchPlan`): literal search and the prefilter,
    # the lazy DFAs, the one-pass DFA, with the R2 engines as fallbacks.
    Auto
    # As `Auto` with the literal accelerators off: the lazy DFAs and the
    # one-pass DFA, with the R2 engines as fallbacks.
    NoAccelerators
    # Milestone R2's two phases: a capture-free Pike VM pass finds the
    # span; when captures are wanted, the bounded backtracker (when the
    # span fits its bitset) or a Pike VM with every slot runs again over
    # the span alone.
    TwoPhase
    # One Pike VM pass with every capture slot.
    PikeVM
    # One bounded backtracker pass over the whole haystack (it must fit).
    Backtracker
    # As `NoAccelerators`, with every unanchored search of a program whose
    # matches are short (`SearchPlan#short_match`) made from each start
    # (`LazyDFA#find_from_each_start`), as `Auto` does once its forward
    # cache thrashes. For the differential fuzzers.
    EachStart
    # As `NoAccelerators`, with every match start found by the reverse DFA
    # reading each class backward through its `ReversedClass`, the reverse
    # DFA `Auto` widens to when its states grow wide. For the differential
    # fuzzers and the conformance replay.
    ReversedClasses
    # As `NoAccelerators`, with every match start the forward DFA leads to
    # found by the bounded backtracker over the span up to the match end
    # whenever it fits (see `Searcher#backtracked_start`), as `Auto` does
    # for a plan's first starts. For the differential fuzzers and the
    # conformance replay.
    BacktrackedStarts

    # True when the engine may use the lazy DFAs and the one-pass DFA.
    def automata? : Bool
      auto? || no_accelerators? || each_start? || reversed_classes? || backtracked_starts?
    end
  end

  # :nodoc:
  # Runs the searches of one call over one haystack: it validates the
  # haystack once, holds the call's `SearchMeter`, leases the program's
  # lazy-DFA caches for the call, and keeps its engine workspaces for the
  # searches that follow (as `scan` and `gsub` make).
  #
  # **Phase 1** finds the leftmost-first span `[s, e)` on the fastest path
  # `SearchPlan` allows: a literal search, or the forward lazy DFA (with
  # the prefilter skipping ahead in its start state) for `e` and the
  # reverse lazy DFA for `s` (widened to read classes backward once its
  # states grow wide, see `ReversedClass`; for a program whose matches are
  # short, the forward DFA run anchored from each start, see `ShortMatch`,
  # takes over while either cache thrashes); or, when the DFAs do not apply
  # or give up, a
  # Pike VM tracking only group 0, in O(m·(n + 1)). Once a DFA gives up in
  # a call, the call's later searches go straight to the Pike VM, so a
  # thrashing cache costs its bounded work once. Once the prefilter has
  # proved ineffective (`PrefilterScan#ineffective?`), the call stops
  # using it.
  #
  # **Phase 2** runs only when captures are asked for, anchored at s and
  # reading no byte at or after e: the highest-priority match that starts
  # at s still ends at e when bytes past e are cut off, because cutting
  # bytes only removes matches. The one-pass DFA reads it in O(L + c) when
  # the pattern is one-pass; otherwise the backtracker costs
  # O(m·(L + 1) + c) and the Pike VM O(m·c·(L + 1)), for L = e − s.
  #
  # **First line.** Under `CompileOptions::FirstLine` an unanchored search
  # starts no match after the first line feed at or after its offset. The
  # searcher scans for that line feed once and reuses it while the offsets
  # of later searches stay at or before it, so an iteration call scans each
  # byte at most once; every byte scanned is charged one operation.
  #
  # **One workspace.** The searcher holds at most one `PikeVM` workspace:
  # the span layout while only spans are asked for, the capture layout
  # (which also runs span searches) once captures are, releasing the span
  # workspace first. Beside it lives at most one `BoundedBacktracker`, sized
  # within `Program#backtracker_allowance`, so everything a search holds
  # stays within `CompileLimits#max_pike_bytes`. The lazy-DFA caches are
  # bounded by their `CachePool`.
  #
  # Call `finish` when the call is done, so the next call reuses the warm
  # caches and workspaces; a searcher that is never finished only loses
  # that reuse.
  #
  # WARNING: A searcher belongs to one call and one fiber.
  class Searcher
    # The call's meter.
    getter meter : SearchMeter
    # True once a lazy DFA gave up in this call (for specs).
    getter? dfa_gave_up = false
    # Which path found the last span (for specs and the benchmarks).
    getter last_path : Path = Path::None

    # The phase-1 paths.
    enum Path
      None
      Literal
      LazyDFA
      OnePass
      PikeVM
      Backtracker
    end

    @pike : PikeVM? = nil
    @backtracker : BoundedBacktracker? = nil
    # The span slots and the capture slots share one buffer: the first two
    # entries, then the program's slots.
    @span_slots : Slice(Int64)
    @capture_slots : Slice(Int64)
    # The last first-line scan: it started at @line_scan_start and found
    # the line feed (or the haystack end) at @line_feed_at.
    @line_scan_start = -1
    @line_feed_at = -1
    @plan : SearchPlan?
    @lease : SearchLease?
    @scan : PrefilterScan?
    @prefilter_off = false
    # The one-pass search's scratch slots, and the bytes the search at
    # starts read that no match kept in this call (see `find_at_starts`).
    @one_pass_scratch : Slice(Int64)?
    @start_search_waste = 0_i64
    @start_search_off = false
    # Where the search at starts handed the call to the span search (see
    # `hand_over_dense_misses?`), or -1.
    @handed_over_at = -1
    # True once a capped capture pass on the backtracker gave up in this
    # call (see `capped_capture_pass`).
    @capped_captures_off = false
    # Searches started in this call (see `check_resumed_deadline`).
    @searches_started = 0
    # The forward cache's counters when this search retried the unanchored
    # DFA (see `from_each_start?`).
    @retry_from : {Int64, Int64}? = nil
    # The same for the reverse cache (see `reverse_thrashing?`).
    @reverse_retry_from : {Int64, Int64}? = nil
    # True when the span pass read the groups too (see `groups_with_span?`).
    @groups_with_span = false
    # Where this call found each required byte (see
    # `required_byte_missing?`), or -1.
    @required_at = StaticArray(Int32, StartFilter::MAX_REQUIRED_BYTES).new(-1)
    # True for a program's first search (see `Searcher.first_search`).
    @first_search = false

    def initialize(@program : Program, @haystack : String, limits : SearchLimits, timeout : Time::Span?,
                   @engine : Engine = Engine::Auto, @cache_pool : CachePool = CachePool.default,
                   lease : SearchLease? = nil)
      @meter = SearchMeter.new(limits, @program.state_count, @haystack.bytesize, timeout)
      slots = Slice(Int64).new(2 + @program.slot_count, PikeVM::UNSET)
      @span_slots = slots[0, 2]
      @capture_slots = slots[2, @program.slot_count]
      if @engine.automata?
        plan = @plan = @program.plan
        attach(lease || plan.lease(@cache_pool))
      end
      begin_call_or_finish
    end

    # Returns a searcher for one call of the default path over *haystack*:
    # the one the program's lease kept from an earlier call, started over,
    # or a new one. Pair it with `finish`.
    # With *validated*, *haystack* is one an earlier call of the program
    # validated (`Expression#read_groups`), and is not validated again.
    def self.open(program : Program, haystack : String, limits : SearchLimits, timeout : Time::Span?,
                  cache_pool : CachePool, *, validated : Bool = false) : Searcher
      lease = program.plan.lease(cache_pool)
      lease.remember_validated(haystack) if validated
      if searcher = lease.take_searcher
        searcher.resume(lease, haystack, limits, timeout)
        searcher
      else
        new(program, haystack, limits, timeout, Engine::Auto, cache_pool, lease)
      end
    end

    # Returns a searcher for a program's first search (see `FirstSearch`):
    # the bounded backtracker with no plan and no lease. It checks first
    # that the haystack holds the bytes every match contains, and it makes
    # at most `FirstSearch.visit_limit` visits: a search the backtracker
    # has not decided by then (a pattern that backtracks hard over this
    # haystack) goes on, in the same call and under the same meter, on the
    # plan's engines (`Auto`), so it costs at most about twice what the
    # plan would have.
    def self.first_search(program : Program, haystack : String, limits : SearchLimits, timeout : Time::Span?,
                          cache_pool : CachePool) : Searcher
      searcher = new(program, haystack, limits, timeout, Engine::Backtracker, cache_pool)
      searcher.first_search = true
      searcher
    end

    protected setter first_search : Bool

    # True when this call should find matches without their groups and
    # leave the groups to be read on first use (see
    # `SearchPlan#defers_groups?`).
    def defers_groups? : Bool
      @engine.auto? && !!@plan.try(&.defers_groups?)
    end

    # Starts this (finished) searcher over for a new call on *lease*.
    #
    # When the call searches the very `String` the last one did (an
    # iteration of separate calls, as `String#scan` makes), the positions
    # the last call found its prefilter needles and required bytes at stay
    # valid (strings are immutable, and the parked searcher held it, so its
    # address was not reused): they are kept, so a needle or byte that is
    # rare, or absent, is not looked for again past where it was found.
    # Those bytes were read and charged once, in the call that found them.
    protected def resume(lease : SearchLease, haystack : String, limits : SearchLimits, timeout : Time::Span?) : Nil
      same_haystack = @haystack.same?(haystack)
      @haystack = haystack
      @meter.restart(limits, @program.state_count, @haystack.bytesize, timeout)
      @line_scan_start = -1
      @line_feed_at = -1
      @scan.try(&.reset(@haystack.to_slice, keep_positions: same_haystack))
      @prefilter_off = false
      @start_search_waste = 0_i64
      @start_search_off = false
      @capped_captures_off = false
      @searches_started = 0
      @required_at.fill(-1) unless same_haystack
      @dfa_gave_up = false
      @last_path = Path::None
      @cache_pool = lease.pool
      attach(lease)
      begin_call_or_finish
    end

    # Moves a first search the backtracker gave up on (see `first_search`)
    # to the plan's engines: the call keeps its meter, and the lease
    # remembers that the haystack was validated.
    private def take_the_plan : Nil
      @first_search = false
      @engine = Engine::Auto
      plan = @plan = @program.plan
      lease = plan.lease(@cache_pool)
      lease.remember_validated(@haystack)
      if backtracker = @backtracker
        @backtracker = nil
        @cache_pool.keep_spare_backtracker(backtracker)
      end
      attach(lease)
    end

    private def attach(lease : SearchLease) : Nil
      @lease = lease
      @pike = lease.take_pike
      @backtracker = lease.take_backtracker
    end

    # Starts the call; when that raises (an invalid haystack, a deadline
    # already passed, a validation charge over the budget), gives the lease
    # back first, so its caches return to the pool idle and evictable.
    private def begin_call_or_finish : Nil
      begin_call
    rescue error
      finish
      raise error
    end

    # Reads the deadline, then validates the haystack (unless the lease
    # validated this very string).
    private def begin_call : Nil
      # The deadline is checked at the start of every call, before the
      # haystack is read, so a timeout that has already passed fails even a
      # search too short to reach a clock checkpoint. The meter read the
      # clock as the call began.
      @meter.enforce_start_deadline(0)
      lease = @lease
      plan = @plan
      # A lease remembers the last `String` it validated (strings are
      # immutable), so an iteration of separate calls over one haystack
      # validates it once; the plan is told too, for candidate searches.
      if lease && lease.validated?(@haystack)
        plan.remember_short_validated(@haystack) if plan && !plan.short_validated?(@haystack)
      else
        # Validation reads every byte once: one operation per byte. A
        # haystack a short search of this plan found valid (the very same
        # `String`) is charged the same but not read again.
        bytes = @haystack.to_slice
        if plan && plan.short_validated?(@haystack)
          @meter.charge(bytes.size, 0)
        else
          validate_in_windows(bytes)
        end
        lease.try(&.remember_validated(@haystack))
        @plan.try(&.remember_short_validated(@haystack))
      end
    end

    # Validates *bytes* as UTF-8 in windows the meter allows before each
    # is read (`SearchMeter#readable`), one operation per byte, so the
    # deadline and `max_work` stop a long validation as they stop a scan.
    # Raises `Mica::EncodingError` at the first invalid byte.
    private def validate_in_windows(bytes : Bytes) : Nil
      ValidateInWindows.new(bytes, @meter).perform
    end

    # Returns the byte index of character *pos* of the haystack (its
    # bytesize when *pos* is its character count), or nil when *pos* is
    # negative or past the end, as `String#char_index_to_byte_index`
    # does. The haystack was validated when the call began, so every byte
    # that is not a continuation byte starts a character. It reads the
    # haystack in windows of at most `PrefilterScan::CHARGE_CHUNK` bytes
    # that the meter allows before each is read (`SearchMeter#readable`),
    # one operation per byte, so the deadline and `max_work` stop it.
    def byte_index_of_char(pos : Int32) : Int32?
      bytes = @haystack.to_slice
      # A string has no more characters than bytes.
      return nil if pos < 0 || pos > bytes.size
      characters = 0
      at = 0
      while at < bytes.size
        window_start = at
        stop = at + @meter.readable(Math.min(bytes.size - at, PrefilterScan::CHARGE_CHUNK), at)
        while at < stop
          if bytes.unsafe_fetch(at) & 0xC0 != 0x80
            if characters == pos
              @meter.charge(at + 1 - window_start, at)
              return at
            end
            characters += 1
          end
          at += 1
        end
        @meter.charge(stop - window_start, stop)
      end
      characters == pos ? bytes.size : nil
    end

    # True once the prefilter proved ineffective in this call (for specs).
    def prefilter_off? : Bool
      @prefilter_off || !!@scan.try(&.ineffective?)
    end

    # Hands the leased caches back to the program for later calls. Without
    # a lease (an engine other than `Auto` or `NoAccelerators`), releases
    # the Pike VM workspace, so its charge goes back to the pool now, and
    # gives the backtracker to the pool as its spare (see
    # `CachePool#take_spare_backtracker`).
    def finish : Nil
      if (lease = @lease) && (plan = @plan)
        @lease = nil
        lease.keep(@pike, @backtracker, @engine.auto? ? self : nil)
        @pike = nil
        @backtracker = nil
        plan.give_back(lease)
      else
        if pike = @pike
          @pike = nil
          pike.release
        end
        if backtracker = @backtracker
          @backtracker = nil
          @cache_pool.keep_spare_backtracker(backtracker)
        end
      end
    end

    # Returns the slots of the leftmost-first match at or after
    # *byte_index* (group 0 only unless *captures*), or nil. Raises
    # `ArgumentError` when *byte_index* is negative or inside a character.
    def find(byte_index : Int32, options : MatchOptions, captures : Bool) : Slice(Int64)?
      check_resumed_deadline(byte_index)
      bytes = @haystack.to_slice
      return nil if byte_index > bytes.size
      check_start(bytes, byte_index)
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      anchored = @program.options.anchored? || options.anchored? || anchored_at_offset?(end_anchored)
      return nil if required_byte_missing?(bytes, byte_index, from_text_end?(anchored, end_anchored))
      case @engine
      in .pike_vm?
        slots = @capture_slots
        want_captures = @program.slot_count > 2
        @last_path = Path::PikeVM
        found = pike(want_captures).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false,
          @meter, slots, first_line_end(bytes, byte_index, anchored), want_captures)
        found ? slots : nil
      in .backtracker?
        slots = @capture_slots
        @last_path = Path::Backtracker
        workspace = backtracker
        workspace.visit_limit = FirstSearch.visit_limit(@program) if @first_search
        found = workspace.search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, @meter, slots,
          first_line_end(bytes, byte_index, anchored))
        if @first_search && workspace.gave_up?
          take_the_plan
          return find(byte_index, options, captures)
        end
        found ? slots : nil
      in .auto?, .no_accelerators?, .two_phase?, .each_start?, .reversed_classes?, .backtracked_starts?
        find_in_two_phases(bytes, byte_index, anchored, end_anchored, captures)
      end
    end

    # Returns true when anything matches at or after *byte_index*; stops at
    # the first match it reaches.
    def matches?(byte_index : Int32, options : MatchOptions) : Bool
      check_resumed_deadline(byte_index)
      bytes = @haystack.to_slice
      return false if byte_index > bytes.size
      check_start(bytes, byte_index)
      return false if required_byte_missing?(bytes, byte_index, false)
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      anchored = @program.options.anchored? || options.anchored? || anchored_at_offset?(end_anchored)
      if dfa = automaton(end_anchored)
        if literal_search?(anchored)
          return literal_span(bytes, byte_index)
        end
        lease = @lease || raise Mica::Error.new("internal error: no lease")
        if cache = lease.forward_cache(dfa)
          unless from_each_start?(cache, anchored)
            found = find_end_or_hand_over(dfa, cache, bytes, byte_index, anchored, true)
            judge_retry(cache)
            return found >= 0 unless found == LazyDFA::GAVE_UP
          end
          if !anchored && (short_match = @plan.try(&.short_match))
            start, _ = dfa.find_from_each_start(cache, bytes, byte_index, true, short_match, @meter)
            return start >= 0 unless start == LazyDFA::GAVE_UP
          end
        end
        @dfa_gave_up = true
      end
      pike(false).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, true, @meter, @span_slots,
        first_line_end(bytes, byte_index, anchored), false)
    end

    private def find_in_two_phases(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                                   captures : Bool) : Slice(Int64)?
      span = @span_slots
      want_captures = captures && @program.slot_count > 2
      # Where the span search starts: past the candidates the search at
      # starts has already ruled out, when it handed over (see
      # `hand_over_dense_misses?`).
      span_from = byte_index
      unless (from_end = find_from_text_end(bytes, byte_index, anchored, end_anchored)).nil?
        return nil unless from_end
        return span unless want_captures
        return capture_pass(bytes, byte_index, span[0].to_i32, span[1].to_i32, end_anchored)
      end
      if start_search?(anchored, end_anchored, want_captures, bytes.size - byte_index)
        @handed_over_at = -1
        found = find_at_starts(bytes, byte_index, anchored, want_captures)
        span_from = @handed_over_at if found.nil? && @handed_over_at > byte_index
        unless found.nil?
          return nil unless found
          return @capture_slots if @last_path.one_pass?
          return span unless want_captures
          return capture_pass(bytes, byte_index, span[0].to_i32, span[1].to_i32, end_anchored)
        end
      end
      @groups_with_span = false
      return nil unless find_span(bytes, span_from, anchored, end_anchored, span, want_captures)
      return span unless want_captures
      return @capture_slots if @groups_with_span
      capture_pass(bytes, byte_index, span[0].to_i32, span[1].to_i32, end_anchored)
    end

    # Finds the match of a program whose every match ends at the end of
    # the text, or before a line feed that ends it
    # (`SearchPlan#ends_at_text_end?`, as `[ -~]*XYZ$` does), from that end:
    # the reverse DFA finds the leftmost start of a match ending at each of
    # those two places, the lower of them starts the leftmost match, and
    # the forward DFA anchored there finds its end. It reads the match and
    # a few bytes, where a forward search reads the whole haystack first.
    # Writes the span to the span slots and returns true, returns false
    # when nothing matches, or nil when the search should take the other
    # paths (it does not apply, or a DFA gave up).
    private def find_from_text_end(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool) : Bool?
      return nil unless from_text_end?(anchored, end_anchored)
      plan = @plan || return nil
      forward = plan.forward || return nil
      reverse = plan.reverse || return nil
      lease = @lease || return nil
      reverse_cache = lease.reverse_cache(reverse) || return nil
      size = bytes.size
      start = LazyDFA::NO_MATCH
      {size, size - 1}.each do |finish|
        next if finish < byte_index
        next if finish < size && bytes.unsafe_fetch(finish) != Look::LINE_FEED
        found = reverse.find_start(reverse_cache, bytes, finish, byte_index, @meter)
        return nil if found == LazyDFA::GAVE_UP
        start = found if found >= 0 && (start < 0 || found < start)
      end
      return false if start < 0
      forward_cache = lease.forward_cache(forward) || return nil
      finish = forward.find_end(forward_cache, bytes, start, true, false, nil, @meter)
      return nil if finish < 0
      @span_slots[0] = start.to_i64
      @span_slots[1] = finish.to_i64
      @last_path = Path::LazyDFA
      true
    end

    # True when `find_from_text_end` applies to a search with these anchors:
    # an unanchored `Auto` search of a program whose every match ends at the
    # end of the text.
    private def from_text_end?(anchored : Bool, end_anchored : Bool) : Bool
      return false if anchored || end_anchored || !@engine.auto? || @dfa_gave_up || @program.options.first_line?
      plan = @plan
      !!plan && plan.ends_at_text_end?
    end

    # True when this search should run anchored at the positions where a
    # match must start (`find_at_starts`) rather than unanchored with a
    # reverse DFA for the start: at each prefilter candidate when the
    # pattern has prefix literals, or at the search's offset when it is
    # anchored, the pattern is one-pass and groups are wanted (without
    # groups the forward lazy DFA alone is cheaper per byte than the
    # one-pass DFA). An anchored search uses the one-pass DFA once an
    # earlier capture pass has built it; before that, one whose *remaining*
    # bytes pass its probe (`one_pass_probe_bytes`) reads them on the
    # forward DFA first (see `find_anchored`), so a search that never
    # matches, or ends early, never builds it.
    private def start_search?(anchored : Bool, end_anchored : Bool, want_captures : Bool, remaining : Int32) : Bool
      return false unless @engine.auto? && !@start_search_off && !end_anchored && !@dfa_gave_up
      plan = @plan || return false
      return false if @program.options.first_line? || plan.literal_search? || !plan.forward
      return !!plan.prefilter unless anchored
      return false unless want_captures
      return !plan.built_one_pass.nil? if plan.one_pass_built?
      remaining.to_i64 > one_pass_probe_bytes
    end

    # The most bytes an anchored search with groups reads on the forward
    # DFA before it builds the one-pass DFA (see `find_anchored`): at
    # least `ONE_PASS_BYTES_PER_STATE` per program state, so the build
    # (O(m) per DFA state, at most m of them) costs no more than the
    # probe's reading did.
    private def one_pass_probe_bytes : Int64
      Math.max(ONE_PASS_PROBE_BYTES, ONE_PASS_BYTES_PER_STATE * @program.state_count)
    end

    # See `one_pass_probe_bytes`.
    ONE_PASS_PROBE_BYTES     = 4_096_i64
    ONE_PASS_BYTES_PER_STATE =    64_i64

    # Searches anchored at each position where a match must start (see
    # `start_search?`): on the one-pass DFA, which gives the span and the
    # groups at once (into the capture slots, path `OnePass`), or else on
    # the forward lazy DFA, which gives the end (into the span slots, path
    # `LazyDFA`). Returns true or false when it decided whether there is a
    # match, nil when the call should take the other paths instead (the
    # search starts again from *byte_index* there): the one-pass DFA could
    # not decide (see `OnePassDFA#search`), the lazy DFA gave up, a try
    # read `MAX_TRY_BYTES` undecided, or the call turned this search off.
    # Each of the first three turns it off for the rest of the call.
    #
    # Unanchored, it tries each prefilter candidate in turn: every match
    # starts with a prefix literal, so the first candidate where an
    # anchored match exists starts the leftmost match. The bytes a try reads
    # that no match keeps (all of a failed try, and those a successful one
    # reads past its match end looking for a longer match) may be read
    # again by a later try or search, so the call counts them, and once
    # they add up to more than the haystack (or the prefilter proves
    # ineffective) it stops searching this way: the extra work is then at
    # most n plus one per try, and the call stays linear.
    #
    # The tries of a program whose one-pass DFA is not built yet run on the
    # forward lazy DFA until they have read enough to pay for building it
    # (see `SearchPlan#start_search_one_pass`), unless the search wants
    # groups (*want_captures*).
    private def find_at_starts(bytes : Bytes, byte_index : Int32, anchored : Bool, want_captures : Bool) : Bool?
      plan = @plan || return nil
      return find_anchored(plan, bytes, byte_index) if anchored
      one_pass = plan.start_search_one_pass(want_captures)
      forward = nil
      cache = nil
      unless one_pass
        forward = plan.forward || return nil
        lease = @lease || return nil
        cache = lease.forward_cache(forward) || return nil
      end
      scan = prefilter_scan(bytes, false) || return nil
      at = byte_index
      misses = 0
      while true
        candidate = scan.find(at, @meter)
        return false if candidate < 0
        found = try_start(one_pass, forward, cache, bytes, candidate, byte_index)
        return found unless found == false
        return nil if @start_search_off || scan.ineffective?
        misses += 1
        return nil if misses == MISSED_TRIES && hand_over_dense_misses?(bytes, candidate, byte_index)
        at = candidate + 1
      end
    end

    # The failed tries in a row after which a search at starts whose
    # candidates come close together (see `hand_over_dense_misses?`) goes
    # to the unanchored forward DFA instead.
    MISSED_TRIES = 64
    # The most bytes per failed try, on average, for which the tries count
    # as close together.
    DENSE_MISS_BYTES = 512

    # True, and the tries turn off for the rest of the call, when
    # `MISSED_TRIES` failed tries from *byte_index* to the one at
    # *candidate* came less than `DENSE_MISS_BYTES` apart on average. Each
    # try restarts the anchored DFA at its candidate, which costs more than
    # the unanchored forward DFA pays to step past a candidate that starts
    # no match (it keeps its state, and takes the prefilter skip from its
    # start state), so a haystack full of candidates and short of matches
    # (a quote before a key, in source code full of quotes) is searched
    # faster that way. Every match starts at a candidate, and none starts
    # at those tried, so the span search goes on from the character after
    # *candidate* (`@handed_over_at`) and reads no byte twice.
    private def hand_over_dense_misses?(bytes : Bytes, candidate : Int32, byte_index : Int32) : Bool
      return false if candidate - byte_index >= MISSED_TRIES * DENSE_MISS_BYTES
      # Without a forward DFA (a program with `\G`) the span search runs the
      # Pike VM, whose search start must stay the call's.
      return false unless @plan.try(&.forward)
      @handed_over_at = Math.min(candidate + Core::UTF8.sequence_length(bytes.unsafe_fetch(candidate)), bytes.size)
      @start_search_off = true
    end

    # The anchored search with groups (see `start_search?`), on the
    # one-pass DFA once it is built. Before that, the forward DFA reads up
    # to `one_pass_probe_bytes`: a search it decides there takes its span
    # (path `LazyDFA`; the capture pass follows), and one still undecided,
    # a long match such as `(?s)^(.*)$` over a large haystack, builds the
    # one-pass DFA and reads the match once on it. A decisive one-pass DFA
    # never gives up once it has read to the end, so that try reads as far
    # as the match needs: one pass in place of the span search and then the
    # capture pass. The probe's bytes are read at most twice.
    private def find_anchored(plan : SearchPlan, bytes : Bytes, byte_index : Int32) : Bool?
      unless plan.one_pass_built?
        forward = plan.forward || return nil
        lease = @lease || return nil
        cache = lease.forward_cache(forward) || return nil
        stop = Math.min(byte_index.to_i64 + one_pass_probe_bytes, Int32::MAX.to_i64).to_i32
        finish = forward.find_end(cache, bytes, byte_index, true, false, nil, @meter, stop)
        unless finish == LazyDFA::GAVE_UP
          return false if finish < 0
          @span_slots[0] = byte_index.to_i64
          @span_slots[1] = finish.to_i64
          @last_path = Path::LazyDFA
          return true
        end
      end
      one_pass = plan.one_pass || return nil
      try_start(one_pass, nil, nil, bytes, byte_index, byte_index, !one_pass.decisive?)
    end

    # The most bytes one try at a start reads before it gives up: a try
    # still undecided there (a long match, or a long failure such as `a+b`
    # over a run of a's) turns the search at starts off for the call, so
    # it costs the call at most this much.
    MAX_TRY_BYTES = 64

    # One anchored try at *start* (see `find_at_starts`), on *one_pass*
    # when there is one, else on *forward* with *cache*; it reads at most
    # `MAX_TRY_BYTES` while *bounded*.
    private def try_start(one_pass : OnePassDFA?, forward : LazyDFA?, cache : DFACache?, bytes : Bytes, start : Int32,
                          byte_index : Int32, bounded : Bool = true) : Bool?
      stop = !bounded || start.to_i64 + MAX_TRY_BYTES > bytes.size ? Int32::MAX : start + MAX_TRY_BYTES
      if one_pass
        scratch = @one_pass_scratch ||= Slice(Int64).new(@program.slot_count, PikeVM::UNSET)
        finish, scanned = one_pass.search(bytes, start, byte_index, @capture_slots, scratch, @meter, stop)
        path = Path::OnePass
      elsif forward && cache
        before = @meter.operations
        finish = forward.find_end(cache, bytes, start, true, false, nil, @meter, stop)
        scanned = @meter.operations - before
        plan = @plan
        plan.note_start_try_bytes(scanned.to_i64 + 1) if plan && !plan.one_pass_built?
        @span_slots[0] = start.to_i64
        @span_slots[1] = finish.to_i64
        path = Path::LazyDFA
      else
        return nil
      end
      if finish == LazyDFA::GAVE_UP
        @start_search_off = true
        return nil
      end
      count_start_search_waste(bytes, scanned.to_i64, finish >= 0 ? (finish - start).to_i64 : -1_i64)
      return false if finish < 0
      @last_path = path
      true
    end

    # Counts the bytes a try read beyond the *kept* bytes of its match (-1:
    # no match, so every byte read and one more for the try), and turns
    # the search at starts off for the call when they pass the haystack's
    # size.
    private def count_start_search_waste(bytes : Bytes, scanned : Int64, kept : Int64) : Nil
      @start_search_waste += kept < 0 ? scanned + 1 : Math.max(scanned - kept, 0_i64)
      @start_search_off = true if @start_search_waste > bytes.size
    end

    # Returns the slots of the match *start*...*finish* that a search from
    # *byte_index* found (see `GroupReader`): the capture pass alone.
    def read_groups(byte_index : Int32, start : Int32, finish : Int32, options : MatchOptions) : Slice(Int64)
      bytes = @haystack.to_slice
      end_anchored = @program.options.end_anchored? || options.end_anchored?
      capture_pass(bytes, byte_index, start, finish, end_anchored)
    end

    # Runs phase 2 over the span *start*...*finish* (see the type comment)
    # and returns the capture slots.
    private def capture_pass(bytes : Bytes, byte_index : Int32, start : Int32, finish : Int32,
                             end_anchored : Bool) : Slice(Int64)
      slots = @capture_slots
      found = false
      if @engine.automata? && (one_pass = @program.plan.one_pass)
        found = one_pass.captures(bytes, start, finish, byte_index, slots, @meter)
      end
      unless found
        found = if BoundedBacktracker.fits?(@program, finish - start)
                  workspace = backtracker
                  # The pass must end at *finish*: an alternative too long
                  # for the span fails before it reads.
                  workspace.list_of_min_bytes = @program.list_of_min_bytes
                  found_here = workspace.search(bytes, start, finish, byte_index, true, end_anchored, @meter, slots, Int32::MAX)
                  workspace.list_of_min_bytes = nil
                  found_here
                else
                  capped_capture_pass(bytes, byte_index, start, finish, end_anchored, slots) ||
                    pike(true).search(bytes, start, finish, byte_index, true, end_anchored, false, @meter, slots,
                      Int32::MAX, true)
                end
      end
      unless found && slots[0] == start && slots[1] == finish
        raise Mica::Error.new("internal error: the capture pass did not find the span #{start}...#{finish}")
      end
      slots
    end

    # The capture pass over a span too long for the backtracker's bitset
    # (a program of thousands of states, as alternatives of `\p{L}{14}`
    # compile to): the backtracker marking visited pairs in a hash set and
    # stopping after `BoundedBacktracker::SPARSE_VISITS` visits (see
    # "Capped searches" there). It visits the same pairs as with the
    # bitset, so it finds the same groups, and over the short spans words
    # and fields make it reads a few states per byte where the Pike VM
    # steps every live thread through its closure. Returns true when it
    # filled *slots*; false when it does not apply or gave up, and the
    # Pike VM runs instead. Its visits are charged, so a pass that gives
    # up costs at most `SPARSE_VISITS` more operations, and after one does
    # the call stops trying it: the extra work is at most that once per
    # call.
    private def capped_capture_pass(bytes : Bytes, byte_index : Int32, start : Int32, finish : Int32,
                                    end_anchored : Bool, slots : Slice(Int64)) : Bool
      return false if @capped_captures_off || !@engine.automata?
      span = finish - start
      return false unless span <= FirstSearch::MAX_BYTES && BoundedBacktracker.fits_capped?(@program, span)
      return false if 2_i64 * BoundedBacktracker::SPARSE_VISITS > @meter.work_meter.allowance - @meter.operations
      workspace = backtracker
      workspace.visit_limit = BoundedBacktracker::SPARSE_VISITS
      found = workspace.search(bytes, start, finish, byte_index, true, end_anchored, @meter, slots, Int32::MAX)
      workspace.visit_limit = Int64::MAX
      if workspace.gave_up?
        @capped_captures_off = true
        return false
      end
      found
    end

    # Finds the span of the leftmost-first match into *span*; returns
    # false when there is none.
    # A Pike VM span pass runs in the capture layout when *capture_layout*
    # (the capture pass will need it), so only one workspace is ever made.
    private def find_span(bytes : Bytes, byte_index : Int32, anchored : Bool, end_anchored : Bool,
                          span : Slice(Int64), capture_layout : Bool) : Bool
      if dfa = automaton(end_anchored)
        if literal_search?(anchored)
          @last_path = Path::Literal
          return literal_span(bytes, byte_index)
        end
        lease = @lease || raise Mica::Error.new("internal error: no lease")
        cache = lease.forward_cache(dfa)
        finish = if cache.nil? || from_each_start?(cache, anchored)
                   LazyDFA::GAVE_UP
                 else
                   find_end_or_hand_over(dfa, cache, bytes, byte_index, anchored, false)
                 end
        judge_retry(cache) if cache
        return false if finish == LazyDFA::NO_MATCH
        if finish >= 0 && !anchored && capture_layout && groups_with_span?(bytes, byte_index, finish, end_anchored)
          @last_path = Path::LazyDFA
          span[0] = @capture_slots[0]
          span[1] = finish.to_i64
          return true
        end
        if finish >= 0
          start = anchored ? byte_index : match_start(lease, dfa, cache, bytes, finish, byte_index)
          if start >= 0
            @last_path = Path::LazyDFA
            span[0] = start.to_i64
            span[1] = finish.to_i64
            return true
          end
        elsif cache && !anchored && (short_match = @plan.try(&.short_match))
          start, finish = dfa.find_from_each_start(cache, bytes, byte_index, false, short_match, @meter)
          return false if start == LazyDFA::NO_MATCH
          if start >= 0
            @last_path = Path::LazyDFA
            span[0] = start.to_i64
            span[1] = finish.to_i64
            return true
          end
        end
        @dfa_gave_up = true
      end
      @last_path = Path::PikeVM
      pike(capture_layout).search(bytes, byte_index, bytes.size, byte_index, anchored, end_anchored, false, @meter, span,
        first_line_end(bytes, byte_index, anchored), false)
    end

    # The start of the leftmost-first match that ends at *finish*, no lower
    # than *lower_bound*. When every match has one length
    # (`SearchPlan#fixed_match_bytes`) it is that many bytes before
    # *finish*. When every match is short (`SearchPlan#short_match`)
    # it is the first start, from `ShortMatch#longest` bytes before
    # *finish*, where the forward DFA run anchored finds any match: no
    # earlier start has one, as the match is leftmost. Otherwise the
    # reverse DFA finds it.
    private def match_start(lease : SearchLease, dfa : LazyDFA, cache : DFACache?, bytes : Bytes, finish : Int32,
                            lower_bound : Int32) : Int32
      backtracked = false
      if @engine.auto?
        plan = @program.plan
        # The analysis that tells whether every match has one length is made
        # once per program (`SearchPlan#fixed_match_bytes`), and costs more
        # than the backtracker's pass over a short span, so until it is made
        # the backtracker finds the start where it may (`backtracked_start`):
        # a program searched once or twice never makes the analysis.
        unless plan.fixed_match_bytes_known?
          backtracked = true
          if start = backtracked_start(bytes, finish, lower_bound)
            return start
          end
        end
        # Every match has the same length: the start is that far back.
        length = plan.fixed_match_bytes
        return finish - length if length >= 0 && finish - length >= lower_bound
      end
      if !backtracked && (@engine.auto? || @engine.backtracked_starts?) &&
         (start = backtracked_start(bytes, finish, lower_bound))
        return start
      end
      # The match bound is analyzed only when a start may come from it.
      if cache && !@engine.reversed_classes? && (@engine.each_start? || reverse_thrashing?(lease))
        if (short_match = @program.plan.short_match) && (@engine.each_start? || !reverse_retry?(lease))
          return start_from_each_start(dfa, cache, short_match, bytes, finish, lower_bound)
        end
      end
      start = reverse_start(lease, bytes, finish, lower_bound)
      if start == LazyDFA::GAVE_UP && cache && !@engine.reversed_classes? && (short_match = @program.plan.short_match)
        return start_from_each_start(dfa, cache, short_match, bytes, finish, lower_bound)
      end
      start
    end

    # The most bytes from the offset to a match end over which
    # `groups_with_span?` runs the backtracker.
    GROUPS_WITH_SPAN_BYTES = 64

    # True when the bounded backtracker, run anchored at *byte_index* over
    # *byte_index*...*finish* (the end the forward DFA found), found the
    # match there and read its groups into the capture slots, in place of
    # the reverse DFA and a capture pass. A match that starts at the offset
    # is the leftmost one, so this pass is the capture pass itself; when
    # none starts there, the search goes on with the reverse DFA. It runs only
    # where the capture pass would run the backtracker anyway (the program
    # is not one-pass, as a capture pass found), over at most
    # `GROUPS_WITH_SPAN_BYTES` bytes within the bitset gate, with the
    # visits it can make inside the call's remaining allowance, and it
    # stops after `FirstSearch.visit_limit` visits (the search then goes on
    # with the reverse DFA). As in `backtracked_start`, the leftmost-first
    # match of the span from the offset is the match the forward DFA
    # found: it ends at *finish*, and its groups are the ones a capture
    # pass reads.
    private def groups_with_span?(bytes : Bytes, byte_index : Int32, finish : Int32, end_anchored : Bool) : Bool
      return false unless @engine.auto? && !@program.options.first_line?
      plan = @plan || return false
      return false unless plan.one_pass_built? && plan.built_one_pass.nil?
      span = finish - byte_index
      return false unless span <= GROUPS_WITH_SPAN_BYTES && BoundedBacktracker.fits?(@program, span)
      visits = BoundedBacktracker.capped_visits(@program, span)
      return false if 2_i64 * visits > @meter.work_meter.allowance - @meter.operations
      slots = @capture_slots
      workspace = backtracker
      workspace.visit_limit = FirstSearch.visit_limit(@program)
      workspace.list_of_min_bytes = @program.list_of_min_bytes
      found = workspace.search(bytes, byte_index, finish, byte_index, true, end_anchored, @meter, slots, Int32::MAX)
      workspace.visit_limit = Int64::MAX
      workspace.list_of_min_bytes = nil
      return false if workspace.gave_up? || !found
      unless slots[1] == finish
        raise Mica::Error.new("internal error: the backtracker found no match ending at #{finish}")
      end
      @groups_with_span = true
    end

    # The start of the match ending at *finish*, found by the bounded
    # backtracker over *lower_bound*...*finish* while the plan has not built
    # its reverse DFA and is still finding its first starts
    # (`SearchPlan#backtrack_start?`), or nil (the reverse DFA finds it).
    #
    # The leftmost-first match of the span ends at *finish*: its start is
    # the match's, as no match starts earlier, and the match from there
    # that the forward DFA found ranks first among those that end by
    # *finish*. The span must be at most `FirstSearch::MAX_BYTES` long and
    # fit the backtracker's bitset or its capped hash set, and its most
    # work (a visit and a slot write per (state, position) pair) the
    # call's remaining allowance, so a reverse DFA built for one search is
    # not built at all, and the search stays within O(m·(L + 1)). A
    # backtracker still undecided after `FirstSearch.visit_limit` visits
    # leaves the start to the reverse DFA.
    private def backtracked_start(bytes : Bytes, finish : Int32, lower_bound : Int32) : Int32?
      plan = @plan || return nil
      span = finish - lower_bound
      return nil unless span <= FirstSearch::MAX_BYTES && BoundedBacktracker.fits_capped?(@program, span)
      visits = BoundedBacktracker.capped_visits(@program, span)
      return nil if 2_i64 * visits > @meter.work_meter.allowance - @meter.operations
      return nil unless @engine.backtracked_starts? || plan.backtrack_start?
      slots = @capture_slots
      workspace = backtracker
      workspace.visit_limit = FirstSearch.visit_limit(@program)
      found = workspace.search(bytes, lower_bound, finish, lower_bound, false, false, @meter, slots, Int32::MAX)
      workspace.visit_limit = Int64::MAX
      return nil if workspace.gave_up?
      unless found && slots[1] == finish
        raise Mica::Error.new("internal error: the backtracker found no match ending at #{finish}")
      end
      slots[0].to_i32
    end

    # The start of the match ending at *finish*: the first position, from
    # `ShortMatch#longest` bytes before it, where the forward DFA run
    # anchored reaches a match.
    private def start_from_each_start(dfa : LazyDFA, cache : DFACache, short_match : ShortMatch, bytes : Bytes,
                                      finish : Int32, lower_bound : Int32) : Int32
      from = Math.max(lower_bound, finish - short_match.longest)
      start, _ = dfa.find_from_each_start(cache, bytes, from, true, short_match, @meter)
      return start unless start == LazyDFA::NO_MATCH
      raise Mica::Error.new("internal error: no start found for the match ending at #{finish}")
    end

    # True when the reverse cache thrashes (`DFACache#thrashing?`).
    private def reverse_thrashing?(lease : SearchLease) : Bool
      reverse = @program.plan.reverse || return false
      cache = lease.reverse_cache(reverse) || return false
      cache.thrashing?
    end

    # True when this search is one of the thrashing reverse cache's
    # periodic retries (see `DFACache#retry?`), whose outcome
    # `reverse_start` reports.
    private def reverse_retry?(lease : SearchLease) : Bool
      reverse = @program.plan.reverse || return false
      cache = lease.reverse_cache(reverse) || return false
      return false unless cache.retry?
      @reverse_retry_from = {cache.states_built, cache.bytes_read}
      true
    end

    private def reverse_start(lease : SearchLease, bytes : Bytes, finish : Int32, lower_bound : Int32) : Int32
      plan = @program.plan
      reverse = (@engine.reversed_classes? ? plan.reverse_with_reversed_classes : plan.reverse) || return LazyDFA::GAVE_UP
      cache = lease.reverse_cache(reverse) || return LazyDFA::GAVE_UP
      start = reverse.find_start(cache, bytes, finish, lower_bound, @meter)
      if retry_from = @reverse_retry_from
        @reverse_retry_from = nil
        cache.judge_retry(*retry_from)
      end
      if cache.wide_states >= SearchPlan::WIDE_STATES_TO_WIDEN && !reverse.with_reversed_classes?
        plan.widen_reverse(@cache_pool.max_cache_bytes)
      end
      if start == LazyDFA::NO_MATCH
        raise Mica::Error.new("internal error: the reverse DFA found no start for the match ending at #{finish}")
      end
      start
    end

    # True when an unanchored search should skip the unanchored forward DFA
    # and run `LazyDFA#find_from_each_start`: its cache thrashes on this
    # program (`DFACache#thrashing?`), every match is short enough
    # (`SearchPlan#short_match`), and this is not a periodic retry.
    private def from_each_start?(cache : DFACache, anchored : Bool) : Bool
      return false if anchored
      return false unless @engine.each_start? || cache.thrashing?
      plan = @plan
      return false unless plan && plan.short_match
      return true if @engine.each_start?
      return true unless cache.retry?
      @retry_from = {cache.states_built, cache.bytes_read}
      false
    end

    # Runs the forward DFA from *byte_index* (`LazyDFA#find_end`). When the
    # search can go on from each start instead (unanchored, every match
    # short), the DFA gives up at the first cache clear that finds it
    # thrashing, rather than building `LazyDFA::MAX_CLEARS` caches' worth
    # of states first: a program's first search over a long haystack then
    # pays for one cache, not four.
    private def find_end_or_hand_over(dfa : LazyDFA, cache : DFACache, bytes : Bytes, byte_index : Int32,
                                      anchored : Bool, earliest : Bool) : Int32
      cache.hands_over_to = anchored ? nil : @plan
      dfa.find_end(cache, bytes, byte_index, anchored, earliest, prefilter_scan(bytes, anchored), @meter)
    ensure
      cache.hands_over_to = nil
    end

    # Reports a retry of the unanchored DFA (see `from_each_start?`) to
    # *cache*.
    private def judge_retry(cache : DFACache) : Nil
      if retry_from = @retry_from
        @retry_from = nil
        cache.judge_retry(*retry_from)
      end
    end

    # True when the plan proved every match starts at the start of the text,
    # so an unanchored search finds only what an anchored one at its offset
    # finds (nothing past offset 0).
    private def anchored_at_offset?(end_anchored : Bool) : Bool
      return false unless @engine.automata?
      plan = @plan
      !!plan && plan.anchored_at_offset?(end_anchored)
    end

    # The forward lazy DFA when this search may use it, or nil.
    private def automaton(end_anchored : Bool) : LazyDFA?
      return nil unless @engine.automata?
      return nil if @dfa_gave_up || end_anchored || @program.options.first_line?
      @plan.try(&.forward)
    end

    private def literal_search?(anchored : Bool) : Bool
      return false unless @engine.auto? && !anchored
      plan = @plan
      !!plan && plan.literal_search?
    end

    # The literal search: the prefilter's next candidate is the match, and
    # the first literal (in priority order) found there is its text.
    private def literal_span(bytes : Bytes, byte_index : Int32) : Bool
      prefilter = @plan.try(&.prefilter) || raise Mica::Error.new("internal error: no prefilter")
      scan = @scan ||= PrefilterScan.new(prefilter, bytes, verified_only: true)
      start = scan.find(byte_index, @meter)
      return false if start < 0
      # The scan verified the candidate, so it knows the literal.
      literal = scan.last_literal
      @span_slots[0] = start.to_i64
      @span_slots[1] = (start + prefilter.literal_size(literal)).to_i64
      true
    end

    # The prefilter scan for this call, or nil when the engine, the search
    # or the call's experience so far rules it out.
    private def prefilter_scan(bytes : Bytes, anchored : Bool) : PrefilterScan?
      return nil if anchored || @prefilter_off || !@engine.auto?
      prefilter = @plan.try(&.prefilter)
      return nil unless prefilter
      scan = @scan ||= PrefilterScan.new(prefilter, bytes)
      if scan.ineffective?
        @prefilter_off = true
        return nil
      end
      scan
    end

    # True when the bytes from *byte_index* lack one of the ASCII bytes
    # every match contains (`Program#list_of_required_bytes`), so nothing
    # matches there: `Auto` and first searches (when the analysis is cheap,
    # see `Program#required_bytes_for_first_search`) check this before any
    # engine runs (`(a|aa)*b` over a run of a's never starts one).
    #
    # Each byte is found with `memchr`, reading in the windows the meter
    # allows and charging one operation per byte read. The call remembers
    # where it found each byte, and a later search of the call starting at
    # or before that position does not scan again; a later search starts
    # after the end of the match before it, which contains the byte, so an
    # iteration call reads each byte at most once per required byte.
    #
    # A search that runs from the end of the text (*from_text_end*, see
    # `find_from_text_end`) skips the check: it reads less than a `memchr`
    # for a byte that only the last line holds. An anchored search of such a
    # program (`^...$`) keeps it, as it reads forward from its start.
    private def required_byte_missing?(bytes : Bytes, byte_index : Int32, from_text_end : Bool) : Bool
      if @engine.auto? && (plan = @plan)
        return false if from_text_end
        # Auto checks the rarest required byte at every search, as a
        # haystack may lack it past an earlier match. It looks for the
        # others (at most `StartFilter::MAX_REQUIRED_BYTES` in all) once per
        # haystack, when its first search starts: the rarest byte by
        # English text is not always the absent one (`x` ranks rarer than
        # `y` in `(x+x+)+y` over a run of x's), and `memchr` reads many
        # bytes per cycle where a DFA reads about one, while an iteration
        # whose searches each looked again would pay a call per match. With
        # a literal prefilter, which already skips to where a literal
        # starts, it looks once per haystack for the bytes some literal
        # lacks (`y` past the literal `xx`) and for no other.
        if plan.prefilter
          list_of_bytes = plan.list_of_required_bytes_past_literals
          every_search = 0
        else
          list_of_bytes = @program.list_of_required_bytes
          every_search = 1
        end
        checked = list_of_bytes.size
      elsif @first_search
        list_of_bytes = @program.required_bytes_for_first_search(bytes.size - byte_index, @meter, byte_index) || return false
        checked = every_search = list_of_bytes.size
      else
        return false
      end
      checked.times do |index|
        found_at = @required_at[index]
        next if found_at >= byte_index
        # The others once per haystack, and only past a short span, where a
        # scan costs about what the engine would.
        next if index >= every_search && (found_at >= 0 || bytes.size - byte_index <= ShortSearch::MAX_BYTES)
        found = find_byte(bytes, list_of_bytes.unsafe_fetch(index), byte_index)
        return true if found < 0
        @required_at[index] = found
      end
      false
    end

    # Records that every required byte (`StartFilter#list_of_required_bytes`,
    # of which the bytes `required_byte_missing?` looks for are a part)
    # occurs at or after *byte_index*, as a short search of this call found
    # (`ShortSearch#screened?`), so a search from *byte_index* does not
    # scan for them again. Each is recorded as found at *byte_index*, the
    # earliest it can be, so a later search from past it scans as before.
    def note_required_bytes_present(byte_index : Int32) : Nil
      @required_at.fill(byte_index)
    end

    # The first position of *byte* at or after *from*, or -1, charging the
    # bytes read.
    private def find_byte(bytes : Bytes, byte : UInt8, from : Int32) : Int32
      at = from
      while at < bytes.size
        window = @meter.readable(bytes.size - at, at)
        if found = bytes[at, window].index(byte)
          @meter.charge(found + 1, at)
          return at + found
        end
        @meter.charge(window, at)
        at += window
      end
      -1
    end

    # Returns the last position where an unanchored search from *start*
    # may begin a match: the first line feed at or after *start* under
    # `CompileOptions::FirstLine`, or `Int32::MAX`. A scan already made
    # from at or before *start* answers when its line feed is at or after
    # *start* (no line feed lies between); otherwise the bytes from
    # *start* are scanned, each charged one operation, in windows the
    # meter allows before each is read (`SearchMeter#readable`).
    private def first_line_end(bytes : Bytes, start : Int32, anchored : Bool) : Int32
      return Int32::MAX if anchored || !@program.options.first_line?
      return @line_feed_at if @line_scan_start >= 0 && @line_scan_start <= start <= @line_feed_at
      line_feed_at = bytes.size
      at = start
      while at < bytes.size
        window = @meter.readable(bytes.size - at, at)
        if found = bytes[at, window].index(Look::LINE_FEED)
          @meter.charge(found + 1, at)
          line_feed_at = at + found
          break
        end
        @meter.charge(window, at)
        at += window
      end
      # The end of the haystack, when no line feed was found.
      @meter.charge(1, bytes.size) if line_feed_at == bytes.size
      @line_scan_start = start
      @line_feed_at = line_feed_at
    end

    # Reads the deadline again when a later search of the call starts: the
    # caller's block (an `each_match` or `gsub` block) runs between searches,
    # and its time counts against the call's timeout. The first search was
    # checked when the call started.
    private def check_resumed_deadline(byte_index : Int32) : Nil
      @meter.enforce_deadline(byte_index) if @searches_started > 0
      @searches_started += 1
    end

    private def check_start(bytes : Bytes, byte_index : Int32) : Nil
      raise ArgumentError.new("Negative byte index: #{byte_index}") if byte_index < 0
      if byte_index < bytes.size && bytes.unsafe_fetch(byte_index) & 0xC0 == 0x80
        raise ArgumentError.new("Byte index #{byte_index} is inside a UTF-8 character")
      end
    end

    # Returns the workspace, in the capture layout when *captures*, leased
    # from the call's `CachePool` (`SearchLimitError` naming
    # `cache_pool_max_bytes` when the pool cannot supply it). A span
    # workspace is released before a capture one replaces it.
    private def pike(captures : Bool) : PikeVM
      if workspace = @pike
        if workspace.captures? || !captures
          workspace.prepare
          return workspace
        end
        @pike = nil
        workspace.release
      end
      @pike = PikeVM.new(@program, captures, @cache_pool)
    end

    # The backtracker: the lease's, or for a call without one (a first
    # search) the pool's spare, which `finish` gives back.
    private def backtracker : BoundedBacktracker
      if backtracker = @backtracker
        return backtracker
      end
      spare = @cache_pool.take_spare_backtracker(@program) unless @lease
      @backtracker = spare || BoundedBacktracker.new(@program, @program.slot_count)
    end
  end
end
