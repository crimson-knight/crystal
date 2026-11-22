module Regex::Mica::Regex
  # :nodoc:
  # The engine for a program's first single searches
  # (`Expression#match_at_byte_index` and `#matches_at_byte_index?`): the
  # bounded backtracker over the haystack, with no `SearchPlan`, lease,
  # lazy-DFA cache or reverse NFA built (see "First searches" in
  # docs/regex.md).
  #
  # Building a plan costs more than a search of a small haystack does on
  # the backtracker (the start filter, the byte classes and the reverse
  # NFA of a pattern with `\w` come to tens of microseconds, the search to
  # well under one), so an expression compiled and searched once pays for
  # what that search uses and no more. Once a program has had `SEARCHES`
  # first searches, its later searches take the usual path and build the
  # plan, whose automata pay for themselves over many searches.
  #
  # A first search runs only where the backtracker's whole cost is known
  # to fit before the haystack is read: its bitset gate, or its hash set
  # of visited pairs for a large program (`BoundedBacktracker.fits_capped?`),
  # for the span from the offset to the end, and the call's work allowance
  # for validation plus every visit and slot write the backtracker can
  # make, so it never stops on `max_work` where it began. The deadline is
  # read before the haystack, as on every path. The search is
  # O(m·(L + 1) + c), at most `visit_limit` visits, and allocates the
  # backtracker's bitset (at most 32 KiB) or hash set (within the
  # backtracker allowance).
  module FirstSearch
    # How many single searches of a program run here before it builds its
    # plan.
    SEARCHES = 2
    # The longest span from the offset a first search reads: past it the
    # backtracker's visits cost more than the plan would.
    MAX_BYTES = 256
    # The same for a program whose matches start with a literal: its plan
    # is cheap, and its prefilter skips to the literals faster than the
    # backtracker tries each start.
    MAX_LITERAL_BYTES = 64

    # Visits a first search may make, as a fixed part and a part per state:
    # building a plan costs about as much as this many visits (a small
    # program's plan, about 4 us, over a thousand), so a
    # backtracker that has not decided by then hands the search to the
    # plan (see `Searcher.first_search`) having spent at most about what
    # the plan costs.
    VISITS_BASE      = 512_i64
    VISITS_PER_STATE =   8_i64

    # The fewest states of a *large* program, whose first searches may read
    # a span of up to `MAX_LARGE_BYTES` (`\p{L}{50}` compiles to about
    # 15,000 states). Its plan costs in proportion to its states, at least
    # about what `BoundedBacktracker::SPARSE_VISITS` visits cost, and over a
    # span too long for the bitset the backtracker marks visited pairs in a
    # hash set and stops after that many visits whatever the span. Past
    # `MAX_LARGE_BYTES` the search costs more than the plan, and a match
    # far from the offset would leave those visits wasted.
    LARGE_PROGRAM_STATES = BoundedBacktracker::SPARSE_VISITS // VISITS_PER_STATE
    MAX_LARGE_BYTES      = 65_536

    # The most visits a first search of *program* makes on the
    # backtracker.
    def self.visit_limit(program : Program) : Int64
      VISITS_BASE + VISITS_PER_STATE * program.state_count
    end

    # True when this search of *program* over *haystack* from *byte_index*
    # should run on the backtracker, counting it as one of the program's
    # first searches. Reads nothing of the haystack.
    def self.applies?(program : Program, haystack : String, byte_index : Int32, limits : SearchLimits) : Bool
      return false unless program.first_searches_left?
      return false if byte_index < 0 || byte_index > haystack.bytesize
      span = haystack.bytesize - byte_index
      return false unless span_fits?(program, span)
      return false unless fits_allowance?(program, haystack.bytesize, span, limits)
      program.count_first_search
    end

    # True when the backtracker may search a span of *span* bytes of
    # *program* with its visits capped: up to `MAX_BYTES` (`MAX_LITERAL_BYTES`
    # with prefix literals) within its bitset or its hash set, and up to
    # `MAX_LARGE_BYTES` of a large program without prefix literals
    # (`LARGE_PROGRAM_STATES`) in its hash set.
    def self.span_fits?(program : Program, span : Int32) : Bool
      return false unless BoundedBacktracker.fits_capped?(program, span)
      return true if span <= (program.literal_set ? MAX_LITERAL_BYTES : MAX_BYTES)
      return false if program.literal_set || span > MAX_LARGE_BYTES
      program.state_count >= LARGE_PROGRAM_STATES && !BoundedBacktracker.fits?(program, span)
    end

    # True when validating *haystack_bytes* bytes, finding the required
    # bytes (`Program#required_bytes_analysis_bound`) and scanning for them
    # (`Searcher#required_byte_missing?`, at most one pass each over *span*
    # bytes), and the most work the backtracker can do over the span (one
    # operation per visit, one per slot write, at most one of each per
    # (state, position) pair, and the run lookups of the state each visit
    # reads, `Program#run_reads_per_state`) fit the call's allowance.
    private def self.fits_allowance?(program : Program, haystack_bytes : Int32, span : Int32,
                                     limits : SearchLimits) : Bool
      visits = BoundedBacktracker.capped_visits(program, span)
      scans = StartFilter::MAX_REQUIRED_BYTES.to_i64 * span
      per_visit = 2_i64 + program.run_reads_per_state
      needed = haystack_bytes.to_i64 + program.required_bytes_analysis_bound(span) + scans + per_visit * visits
      needed <= limits.max_work(program.state_count, haystack_bytes.to_i64)
    end
  end
end
