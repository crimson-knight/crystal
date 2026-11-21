module Regex::Mica::Regex
  # The engines a `Program` can run besides the Pike VM and the bounded
  # backtracker, chosen and built the first time the program is searched
  # (so compiling stays as cheap as R2 made it), and the caches its
  # searches lease.
  #
  # **Engine selection**, fastest correct path first:
  #
  # 1. **Literal search** when the pattern is a finite set of literals with
  #    no assertion (`LiteralSet#exact?`): the prefilter finds the match.
  # 2. **Lazy DFA**, forward for the end and reverse for the start, with
  #    the prefilter skipping ahead while the forward DFA is in its start
  #    state, for every program without `\G`. The reverse DFA is widened
  #    to read classes backward (`widen_reverse`) once its states grow
  #    wide. A program whose matches are short (`short_match`) finds the
  #    start with the forward DFA run anchored from each start while the
  #    reverse cache thrashes, and is searched that way while the forward
  #    cache thrashes.
  # 3. **Pike VM** (span layout) when neither applies, under
  #    `CompileOptions::FirstLine` or `EndAnchored`, and whenever a lazy DFA
  #    gives up (cache thrash, a full `CachePool`, a Unicode word assertion
  #    next to a non-ASCII byte).
  #
  # Captures, when asked for, come from the **one-pass DFA** when the
  # pattern is one-pass, else the bounded backtracker when the span fits
  # it, else the Pike VM.
  #
  # A plan is shared by every search of its program; its lazily built
  # parts are built under a mutex.
  class SearchPlan
    # `ends_at_text_end?`, worked out on first use: 0 not yet, 1 yes, 2 no.
    @ends_at_text_end = Atomic(Int32).new(0)
    getter program : Program
    getter byte_classes : ByteClasses
    # The forward lazy DFA, or nil when the program needs the Pike VM.
    getter forward : LazyDFA?
    # The prefilter, or nil.
    getter prefilter : Prefilter?
    # The lazily built parts are published through atomics, so a search
    # on another thread that sees one sees it fully built.
    @reverse = Atomic(LazyDFA?).new(nil)
    @reverse_with_reversed_classes = Atomic(LazyDFA?).new(nil)
    # See `list_of_required_bytes_past_literals`.
    @required_bytes_past_literals = Atomic(UInt64).new(RequiredBytes::NOT_FOUND)
    @one_pass = Atomic(OnePassDFA?).new(nil)
    # Bytes the tries of searches at starts read on the forward DFA before
    # the one-pass DFA was built (see `start_search_one_pass`).
    @start_try_bytes = Atomic(Int64).new(0_i64)
    # The last haystack a short search found to be valid UTF-8.
    @short_validated = Atomic(String?).new(nil)
    @short_match = Atomic(ShortMatch?).new(nil)
    @start_filter = Atomic(StartFilter?).new(nil)
    @mutex = Mutex.new
    @list_of_idle_leases = [] of SearchLease
    # The most recently returned lease, taken without the mutex.
    @hot_lease = Atomic(SearchLease?).new(nil)
    # The other four-byte fields and the flags follow, together, so the plan
    # has no padding between its fields.
    # True when the prefilter alone finds matches (see `LiteralSet#exact?`).
    getter? literal_search : Bool
    # True when every match starts at the start of the text (each path from
    # the start state passes `\A` before it reads a byte): a search is
    # then anchored at its offset, and the reverse DFA is not needed.
    getter? anchored_start : Bool
    # True when the program is anchored at its start and its one-pass DFA
    # is small (`OnePassDFA.small?`): its first search builds the one-pass
    # DFA and reads the groups with the match (see `defers_groups?`).
    getter? reads_groups_on_first_search : Bool
    # True when the empty string matches at every offset (a path from the
    # start state reaches a match through no byte and no assertion, as in
    # `.*` or `(a*)`): the leftmost match then starts at the search's
    # offset (see `anchored_at_offset?`).
    getter? empty_match_everywhere : Bool
    # Set once `widen_reverse` found the widened DFA too large.
    @widen_refused = Atomic(Int32).new(0)
    # Match starts found by the backtracker (see `backtrack_start?`).
    @backtracked_starts : Atomic(Int32)
    # Set (after @one_pass) once the one-pass build ran, as its result may
    # be nil.
    @one_pass_built = Atomic(Int32).new(0)
    # Short searches seen before the one-pass DFA was built (see
    # `short_search_one_pass`), counting from the first searches the
    # program ran without a plan (`FirstSearch`): a program searched that
    # often is searched again.
    @short_searches : Atomic(Int32)
    # Unanchored short searches that ran out of tries (see `ShortSearch`).
    @short_declines = Atomic(Int32).new(0)
    # Candidate searches that ran out of tries (see `CandidateSearch`).
    @candidate_declines = Atomic(Int32).new(0)
    # Candidate searches that found their match (counted without a
    # read-modify-write: a lost count only delays the verdict).
    @candidate_matches = Atomic(Int32).new(0)
    # Searches that skipped the candidate search (see
    # `candidate_searches_pay?`).
    @candidate_skips = Atomic(Int32).new(0)
    # 1 once a caller read groups that a search had left to read later.
    @groups_read = Atomic(Int32).new(0)
    @fixed_match_bytes = Atomic(Int32).new(FIXED_LENGTH_UNKNOWN)
    @short_match_built = Atomic(Int32).new(0)

    def initialize(@program : Program)
      # A program with class runs (`Program::ClassRun`) writes its states
      # out here, once, so the plan's engines read each state from one
      # array (`Program#state_at`); its first searches built nothing.
      @program.materialized_states
      @short_searches = Atomic(Int32).new(@program.first_search_count)
      @backtracked_starts = Atomic(Int32).new(@program.first_searches_ended? ? FirstSearch::SEARCHES : 0)
      @byte_classes = ByteClasses.new(@program)
      @forward = LazyDFA.supports?(@program) ? LazyDFA.new(@program, @byte_classes, false) : nil
      literal_set = @program.literal_set
      @prefilter = literal_set ? Prefilter.new(literal_set) : nil
      @literal_search = !!literal_set.try(&.exact?)
      @anchored_start = SearchPlan.anchored_start?(@program)
      @reads_groups_on_first_search = @anchored_start && OnePassDFA.small?(@program, @byte_classes)
      @empty_match_everywhere = SearchPlan.empty_match_everywhere?(@program)
    end

    # The required bytes (`Program#list_of_required_bytes`, rarest first)
    # that some prefix literal lacks (all of them without literals): a
    # prefilter candidate shows nothing of them, so a search with the
    # prefilter still checks they are present. Found on first use.
    def list_of_required_bytes_past_literals : RequiredBytes
      packed = @required_bytes_past_literals.get(:acquire)
      return RequiredBytes.new(packed) unless packed == RequiredBytes::NOT_FOUND
      list_of_bytes = @program.list_of_required_bytes
      if literal_set = @program.literal_set
        list_of_literals = literal_set.list_of_literals
        list_of_kept = RequiredBytes::NONE
        list_of_bytes.each do |byte|
          list_of_kept = list_of_kept.with(byte) unless list_of_literals.all?(&.includes?(byte))
        end
        list_of_bytes = list_of_kept
      end
      # Threads racing here find the same bytes, so each publishes the
      # same word.
      @required_bytes_past_literals.set(list_of_bytes.packed, :release)
      list_of_bytes
    end

    # True when a search from an offset may run anchored there, as the
    # leftmost match starts there if anywhere: every match starts at the
    # start of the text (`anchored_start?`), or the empty string matches
    # at every offset (`empty_match_everywhere?`) and the match need not
    # end at the end of the text (*end_anchored* false; under it the
    # empty match at the offset does not count).
    @[AlwaysInline]
    def anchored_at_offset?(end_anchored : Bool) : Bool
      @anchored_start || (@empty_match_everywhere && !end_anchored)
    end

    # The fewest bytes and the first bytes of a match (see `StartFilter`),
    # made on first use: only short searches read it, so a plan whose
    # haystacks are long never pays for it.
    @[AlwaysInline]
    def start_filter : StartFilter
      @start_filter.get(:acquire) || build_start_filter
    end

    private def build_start_filter : StartFilter
      @mutex.synchronize do
        built = @start_filter.get
        return built if built
        built = StartFilter.new(@program)
        @start_filter.set(built)
        built
      end
    end

    # True when every path from *program*'s start state reaches a
    # `StartOfText` assertion before it reads a byte or matches.
    def self.anchored_start?(program : Program) : Bool
      visited = VisitedStates.new(program.state_count)
      list_of_pending = OffHeapList(Int32).new(8)
      list_of_pending << program.start_state
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .split?
          list_of_pending << state.next_state
          list_of_pending << state.alternate
        when .save?
          list_of_pending << state.next_state
        when .look?
          next if Program::LookKind.new(state.argument).start_of_text?
          list_of_pending << state.next_state
        when .fail?
          next
        else
          return false
        end
      end
      true
    ensure
      list_of_pending.try(&.free)
      visited.try(&.free)
    end

    # The NFA states a walk from the start state has visited: bits on the
    # stack for a program of up to `SMALL_STATES` states (no allocation, as
    # the first search of most programs needs), and for a larger one in a
    # bitset outside the collector's heap, which `free` returns.
    private struct VisitedStates
      SMALL_STATES = 512

      @bits = StaticArray(UInt64, 8).new(0_u64)
      @large = OffHeapList(UInt64).new

      def initialize(state_count : Int32)
        @large.fill_to((state_count + 63) // 64, 0_u64) if state_count > SMALL_STATES
      end

      def free : Nil
        @large.free
      end

      # Marks *index* visited; false when it already was.
      def add?(index : Int32) : Bool
        word = index >> 6
        bit = 1_u64 << (index & 63)
        unless @large.empty?
          return false if @large.unsafe_fetch(word) & bit != 0
          @large.unsafe_put(word, @large.unsafe_fetch(word) | bit)
          return true
        end
        return false if @bits[word] & bit != 0
        @bits[word] |= bit
        true
      end
    end

    # True when every match ends at the end of the text, or before a line
    # feed that ends it: every path from the start state to a match state
    # passes `\z` (`EndOfText`) or `$` (`EndOfTextOrFinalNewline`), and
    # a path past one of those can read at most that final line feed.
    # Worked out on the first call (see `SearchPlan.ends_at_text_end?`).
    def ends_at_text_end? : Bool
      known = @ends_at_text_end.get(:relaxed)
      return known == 1 unless known == 0
      ends = SearchPlan.ends_at_text_end?(@program)
      @ends_at_text_end.set(ends ? 1 : 2, :relaxed)
      ends
    end

    # See the instance method. A program with no such assertion is
    # answered by one pass over its states; otherwise a walk from the start
    # state that stops at each of them must not reach a match state.
    def self.ends_at_text_end?(program : Program) : Bool
      ends_seen = false
      program.each_distinct_state do |state, _|
        ends_seen = true if state.kind.look? && SearchPlan.text_end_look?(state)
      end
      return false unless ends_seen
      visited = VisitedStates.new(program.state_count)
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .match?
          return false
        when .split?
          list_of_pending << state.next_state << state.alternate
        when .save?, .byte_range?
          list_of_pending << state.next_state
        when .look?
          list_of_pending << state.next_state unless SearchPlan.text_end_look?(state)
        when .sparse?
          state.alternate.times { |offset| list_of_pending << program.transition_at(index, state, offset).target }
        end
      end
      true
    end

    # True when *state* (a look state) asserts the end of the text, or the
    # end before a final line feed.
    protected def self.text_end_look?(state : Program::State) : Bool
      kind = Program::LookKind.new(state.argument)
      kind.end_of_text? || kind.end_of_text_or_final_newline?
    end

    # True when a path from *program*'s start state reaches a match state
    # through splits and group saves alone: no byte, and no assertion.
    def self.empty_match_everywhere?(program : Program) : Bool
      visited = VisitedStates.new(program.state_count)
      list_of_pending = OffHeapList(Int32).new(8)
      list_of_pending << program.start_state
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .match? then return true
        when .split?
          list_of_pending << state.next_state
          list_of_pending << state.alternate
        when .save? then list_of_pending << state.next_state
        end
      end
      false
    ensure
      list_of_pending.try(&.free)
      visited.try(&.free)
    end

    # The reverse lazy DFA (built on first use; replaced once by
    # `widen_reverse`), or nil.
    def reverse : LazyDFA?
      return nil unless @forward
      if built = @reverse.get
        return built
      end
      @mutex.synchronize do
        built = @reverse.get
        return built if built
        built = LazyDFA.new(@program, @byte_classes, true)
        @reverse.set(built)
        built
      end
    end

    # A reverse DFA state holding more NFA states than this is wide; a
    # reverse cache that has built `WIDE_STATES_TO_WIDEN` wide states makes
    # `widen_reverse` worth its one-time cost (a single short search does
    # not).
    WIDE_REVERSE_KEY     = 256
    WIDE_STATES_TO_WIDEN =  16

    # Replaces the reverse DFA with one that reads each class backward
    # through its `ReversedClass`, once: a search whose reverse cache has
    # built `WIDE_STATES_TO_WIDEN` states wider than `WIDE_REVERSE_KEY` NFA
    # states calls it (large Unicode classes next to non-ASCII text).
    # Reversing a class costs milliseconds the first time in a process, so
    # only programs that need it pay.
    #
    # The widened DFA reads more NFA nodes, so its cache's fixed part is
    # larger; when that part would take more than half of
    # *max_cache_bytes* (`\p{L}{256}` repeats one class 256 times), the
    # plan keeps its reverse DFA and does not try again.
    def widen_reverse(max_cache_bytes : Int64) : Nil
      return if @widen_refused.get == 1
      current = @reverse.get
      return if current && current.with_reversed_classes?
      return if @program.class_blocks.empty?
      # The widened DFA has at least the program's nodes; only when those fit
      # are the reversed classes counted.
      scratch_per_node = DFABuilder::BYTES_PER_STATE.to_i64 * 2
      node_limit = max_cache_bytes // scratch_per_node
      if @program.state_count > node_limit || ReverseNFA.widened_node_count(@program, node_limit) > node_limit
        @widen_refused.set(1)
        return
      end
      widened = reverse_with_reversed_classes || return
      @mutex.synchronize { @reverse.set(widened) }
    end

    # The reverse DFA that reads each class backward through its
    # `ReversedClass` (built on first use), or nil when the program needs
    # the Pike VM. `widen_reverse` makes it the reverse DFA;
    # `Engine::ReversedClasses` uses it from the start.
    def reverse_with_reversed_classes : LazyDFA?
      return nil unless @forward
      if built = @reverse_with_reversed_classes.get
        return built
      end
      @mutex.synchronize do
        built = @reverse_with_reversed_classes.get
        return built if built
        built = LazyDFA.new(@program, @byte_classes, true, with_reversed_classes: true)
        @reverse_with_reversed_classes.set(built)
        built
      end
    end

    # True while match starts should come from the bounded backtracker
    # rather than the reverse DFA (see `Searcher#backtracked_start`): the
    # reverse DFA is not built yet and the plan has found fewer than
    # `FirstSearch::SEARCHES` starts this way, so a program searched once
    # or twice never builds its reverse NFA. Counts the start.
    def backtrack_start? : Bool
      return false unless @reverse.get.nil?
      return false if @backtracked_starts.get(:relaxed) >= FirstSearch::SEARCHES
      @backtracked_starts.add(1, :relaxed) < FirstSearch::SEARCHES
    end

    # The one-pass DFA (built on first use), or nil when the program is not
    # one-pass.
    def one_pass : OnePassDFA?
      return @one_pass.get if @one_pass_built.get == 1
      @mutex.synchronize do
        if @one_pass_built.get == 0
          @one_pass.set(OnePassDFA.build(@program, @byte_classes))
          @one_pass_built.set(1)
        end
      end
      @one_pass.get
    end

    # True when a single search should leave the groups of its match to be
    # read on first use (`GroupReader`): the program has groups and the
    # one-pass DFA cannot read them, so reading them means the bounded
    # backtracker or the Pike VM. When the one-pass DFA can, its O(L) pass
    # costs less than a later call would, and the groups are read with the
    # match.
    #
    # Until a caller has read groups, this is also true while the one-pass
    # DFA is not built: a program's first searches find their match
    # without groups, so a caller that only asks whether and where it
    # matched never pays for a capture pass or for building the one-pass
    # DFA (the first capture pass, when a caller reads the groups, builds
    # it). The exception is a program anchored at its start whose one-pass
    # DFA is small (`reads_groups_on_first_search?`): it makes one attempt,
    # the one-pass DFA reads that attempt with its groups in one pass, and
    # building that DFA costs little, so its first search builds it. Once a
    # caller has read the groups of a match found without them
    # (`note_groups_read`), it is false for good: this program's callers
    # read groups, and reading them later costs more than reading them
    # with the match.
    def defers_groups? : Bool
      return false unless @program.slot_count > 2 && @groups_read.get(:relaxed) == 0
      return @one_pass.get.nil? if @one_pass_built.get == 1
      !@reads_groups_on_first_search
    end

    # True while unanchored short searches of this program usually find
    # their match within `ShortSearch::MAX_TRIES` tries.
    def short_tries_pay? : Bool
      @short_declines.get(:relaxed) < ShortSearch::MAX_DECLINES
    end

    def note_short_decline : Nil
      @short_declines.add(1, :relaxed)
    end

    # True while this program's candidate searches usually find their
    # match within `CandidateSearch::MAX_TRIES` tries: fewer than
    # `CandidateSearch::MAX_DECLINES` declines, or at least
    # `CandidateSearch::MATCHES_PER_DECLINE` matches for each.
    #
    # A program that fails this still tries one search in
    # `CandidateSearch::RETRY_INTERVAL`, so matches found later (the text
    # changed, or the declines came early) can bring it back.
    def candidate_searches_pay? : Bool
      declines = @candidate_declines.get(:relaxed)
      return true if declines < CandidateSearch::MAX_DECLINES
      return true if @candidate_matches.get(:relaxed) >= declines.to_i64 * CandidateSearch::MATCHES_PER_DECLINE
      skipped = @candidate_skips.get(:relaxed) &+ 1
      @candidate_skips.set(skipped, :relaxed)
      skipped % CandidateSearch::RETRY_INTERVAL == 0
    end

    def note_candidate_match : Nil
      matches = @candidate_matches.get(:relaxed)
      @candidate_matches.set(matches &+ 1, :relaxed) if matches < Int32::MAX
    end

    def note_candidate_decline : Nil
      @candidate_declines.add(1, :relaxed)
    end

    # True when *haystack* is the very `String` a short search validated
    # last (see `ShortSearch`).
    def short_validated?(haystack : String) : Bool
      @short_validated.get(:relaxed).same?(haystack)
    end

    def remember_short_validated(haystack : String) : Nil
      @short_validated.set(haystack, :relaxed)
    end

    # Records that a caller read the groups of a match found without them
    # (see `defers_groups?`).
    def note_groups_read : Nil
      @groups_read.set(1, :relaxed)
    end

    # The one-pass DFA for `ShortSearch#run`: built (see `one_pass`) once
    # the program has had `ShortSearch::BUILD_AFTER` short searches, or as
    # soon as another search built it; nil before, or when the program is
    # not one-pass.
    def short_search_one_pass : OnePassDFA?
      return @one_pass.get(:relaxed) if @one_pass_built.get(:acquire) == 1
      return nil if @short_searches.add(1, :relaxed) < ShortSearch::BUILD_AFTER
      one_pass
    end

    # The one-pass DFA for a search at starts (`Searcher#find_at_starts`),
    # or nil when its tries should run on the forward DFA: the program is
    # not one-pass, or its one-pass DFA is not built yet and building it
    # now would cost more than the tries have read.
    #
    # Building costs a pass over the table, `OnePassDFA.most_cells` cells
    # at most (about 6,000 for a Markdown autolink with a `{1,31}` class,
    # 38 us and 150 KB of allocation in a fresh process), where the lazy
    # DFA builds only the states a try reaches. So a table that is not
    # small is built once the tries on the forward DFA have read as many
    # bytes as it has cells (`note_start_try_bytes`): a program searched
    # once or twice never builds it, and one searched over and over pays
    # for it with at most that much reading. A small table is built at
    # once, and so is any table when the search *wants_groups*, which the
    # one-pass DFA reads with the match in one pass.
    def start_search_one_pass(wants_groups : Bool) : OnePassDFA?
      return @one_pass.get(:relaxed) if @one_pass_built.get(:acquire) == 1
      return one_pass if wants_groups || OnePassDFA.small?(@program, @byte_classes)
      return nil if @start_try_bytes.get(:relaxed) < OnePassDFA.most_cells(@program, @byte_classes)
      one_pass
    end

    # Counts *count* bytes a try of a search at starts read on the forward
    # DFA while the one-pass DFA was not built (see
    # `start_search_one_pass`).
    def note_start_try_bytes(count : Int64) : Nil
      @start_try_bytes.add(count, :relaxed)
    end

    # True once a search has built the one-pass DFA (see `one_pass`),
    # whether or not the program is one-pass.
    def one_pass_built? : Bool
      @one_pass_built.get == 1
    end

    # The one-pass DFA when a search has built it already (see `one_pass`),
    # or nil.
    def built_one_pass : OnePassDFA?
      @one_pass_built.get(:acquire) == 1 ? @one_pass.get(:relaxed) : nil
    end

    # The analysis of short matches (made on first use), or nil when a
    # match can be long (see `ShortMatch`).
    def short_match : ShortMatch?
      return @short_match.get if @short_match_built.get == 1
      @mutex.synchronize do
        if @short_match_built.get == 0
          @short_match.set(ShortMatch.analyze(@program))
          @short_match_built.set(1)
        end
      end
      @short_match.get
    end

    # The most states a program may have for `fixed_match_bytes` to
    # analyze it (one O(m) pass, made once).
    FIXED_LENGTH_STATES = 2_048

    # The length in bytes every match has, or -1 when matches can differ
    # in length (or the program has more than `FIXED_LENGTH_STATES`
    # states): the longest match (`ShortMatch.longest_match`) is as long as
    # the shortest (`StartFilter#minimum_bytes`). A match that ends at a
    # known position then starts this many bytes before it. Worked out on
    # first use and kept.
    def fixed_match_bytes : Int32
      length = @fixed_match_bytes.get(:relaxed)
      return length unless length == FIXED_LENGTH_UNKNOWN
      length = -1
      if @program.state_count <= FIXED_LENGTH_STATES && (longest = ShortMatch.longest_match(@program))
        length = longest if longest == start_filter.minimum_bytes
      end
      @fixed_match_bytes.set(length, :relaxed)
      length
    end

    # True once `fixed_match_bytes` has made its analysis.
    def fixed_match_bytes_known? : Bool
      @fixed_match_bytes.get(:relaxed) != FIXED_LENGTH_UNKNOWN
    end

    private FIXED_LENGTH_UNKNOWN = -2

    # Takes an idle lease (its caches warm from earlier searches) or makes
    # a new one for *pool*. Taking the lease out of the hot slot or the idle
    # list is what makes the caller its only holder (see `PoolMember`).
    def lease(pool : CachePool) : SearchLease
      lease = @hot_lease.swap(nil, :acquire) || @mutex.synchronize { @list_of_idle_leases.pop? }
      return lease if lease && lease.pool.same?(pool)
      SearchLease.new(self, pool)
    end

    # Returns *lease* for a later search to reuse. At most `MAX_IDLE_LEASES`
    # are kept per program.
    # The hot slot takes the lease as it is, workspaces and all; one that
    # goes to the idle list instead drops its workspaces first.
    def give_back(lease : SearchLease) : Nil
      lease.note_use(lease.pool.tick)
      return if @hot_lease.compare_and_set(nil, lease, :release, :relaxed)[1]
      lease.drop_workspaces
      kept = @mutex.synchronize do
        @list_of_idle_leases << lease if @list_of_idle_leases.size < MAX_IDLE_LEASES
      end
      # A lease no slot keeps can no longer be evicted, so it gives its
      # bytes back now.
      lease.evict unless kept
    end

    # :nodoc:
    # Evicts *lease* when it is idle here: taken out of the hot slot (and
    # put back after), or evicted where it waits in the idle list, under
    # the mutex every taker of the list holds. Returns false when a search
    # holds it.
    def evict_if_idle(lease : SearchLease) : Bool
      if @hot_lease.compare_and_set(lease, nil, :acquire, :relaxed)[1]
        lease.evict
        give_back(lease)
        return true
      end
      @mutex.synchronize do
        return false unless @list_of_idle_leases.any?(&.same?(lease))
        lease.evict
      end
      true
    end

    # Idle leases kept per program.
    MAX_IDLE_LEASES = 8
  end

  # :nodoc:
  # The caches one search call uses: the forward and reverse lazy-DFA
  # caches (made on first use), the Pike VM and backtracker workspaces of
  # the last call (kept only while the lease is the program's hot lease,
  # so a program retains at most one set), and the last haystack the lease
  # validated.
  #
  # The lease is the `CachePool` member: a search holds it from taking it
  # out of the plan's hot slot (one atomic exchange) to putting it back
  # (one compare-and-set), and the pool evicts an idle lease's caches and
  # kept Pike VM workspace together.
  class SearchLease < PoolMember
    getter pool : CachePool
    @forward_cache : DFACache?
    @reverse_cache : DFACache?
    @builder : DFABuilder?
    # The last haystack validated, held strongly: while it is held its
    # address cannot be reused by another string, so identity proves it is
    # the same (immutable) string. A searcher parked in the lease holds its
    # last haystack too, so this retains nothing more.
    @validated : String?
    @pike : PikeVM?
    @backtracker : BoundedBacktracker?
    @searcher : Searcher?

    # Takes the searcher a finished call parked here, if any.
    def take_searcher : Searcher?
      searcher = @searcher
      @searcher = nil
      searcher
    end

    # Takes the kept Pike VM workspace, if any.
    def take_pike : PikeVM?
      pike = @pike
      @pike = nil
      pike
    end

    # Takes the kept backtracker, if any.
    def take_backtracker : BoundedBacktracker?
      backtracker = @backtracker
      @backtracker = nil
      backtracker
    end

    # Keeps the workspaces (and the searcher) of the call that is ending,
    # for the next call.
    def keep(pike : PikeVM?, backtracker : BoundedBacktracker?, searcher : Searcher?) : Nil
      @pike = pike
      @backtracker = backtracker
      @searcher = searcher
    end

    # Drops the kept workspaces (a lease that goes to the idle list). The
    # caller holds the lease, so the pool cannot evict it meanwhile.
    def drop_workspaces : Nil
      if pike = @pike
        pike.release
      end
      @pike = nil
      @backtracker = nil
      @searcher = nil
    end

    def initialize(@plan : SearchPlan, @pool : CachePool)
      @pool.register(self)
    end

    # The forward cache, made on first use; nil when the pool cannot supply
    # a new cache (the search then runs on the Pike VM). The cache's bytes,
    # the builder's scratch space among them, are reserved before the
    # builder is made, so a refused cache leaves no builder behind.
    def forward_cache(dfa : LazyDFA) : DFACache?
      @forward_cache ||= reserve_cache(dfa)
    end

    # The reverse cache, as `forward_cache`.
    # A cache made for an earlier reverse DFA (see
    # `SearchPlan#widen_reverse`) is evicted and replaced.
    def reverse_cache(dfa : LazyDFA) : DFACache?
      cache = @reverse_cache
      if cache && !cache.dfa.same?(dfa)
        cache.evict
        cache = @reverse_cache = nil
      end
      cache || (@reverse_cache = reserve_cache(dfa))
    end

    # Reserves a new cache for *dfa* from the pool, then makes the builder
    # it shares (`builder`). When the pool refuses, no builder is made, and
    # one no remaining cache holds is dropped, so the lease keeps no
    # scratch space the pool does not account for.
    private def reserve_cache(dfa : LazyDFA) : DFACache?
      cache = DFACache.reserve?(dfa, @pool) { builder(dfa) }
      @builder = nil unless cache || @forward_cache || @reverse_cache
      cache
    end

    # The scratch space the caches build their states in: a search builds
    # in one cache at a time, so the forward and the reverse cache share
    # one, sized for the DFA with the most nodes (a reverse DFA that reads
    # classes backward has more nodes than the program has states). A
    # larger DFA gets a new builder; a cache made earlier keeps its own.
    private def builder(dfa : LazyDFA) : DFABuilder
      builder = @builder
      return builder if builder && builder.node_capacity >= dfa.node_count
      @builder = DFABuilder.new(dfa.node_count)
    end

    # True when *haystack* is the very `String` this lease validated last:
    # strings are immutable, so it is still valid UTF-8.
    def validated?(haystack : String) : Bool
      @validated.same?(haystack)
    end

    def remember_validated(haystack : String) : Nil
      @validated = haystack
    end

    def evict_if_idle : Bool
      @plan.evict_if_idle(self)
    end

    # Drops the caches (with their shared builder's scratch space) and the
    # kept Pike VM workspace, giving their bytes back to the pool. Runs only
    # while the evictor holds the lease; a cache is reserved afresh when the
    # lease is next used.
    def evict : Nil
      @forward_cache.try(&.evict)
      @forward_cache = nil
      @reverse_cache.try(&.evict)
      @reverse_cache = nil
      @builder = nil
      @pike.try(&.release)
    end
  end
end
