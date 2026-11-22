module Regex::Mica::Regex
  # :nodoc:
  # One single search (`Expression#match_at_byte_index` or
  # `#matches_at_byte_index?`) of a short haystack, answered without a
  # lease, a searcher or a meter when it can be (see "Short searches" in
  # docs/regex.md):
  #
  # - `rejects?`: the program's `StartFilter` shows no match can start;
  # - `run`: the one-pass DFA, anchored at each position where the filter
  #   allows a match to start, finds the match (span and groups).
  #
  # Both answer only where the searcher would answer the same without
  # raising: any timeout is positive (one already passed must fail), the
  # offset is a character boundary inside the haystack, the haystack is
  # valid UTF-8, and the work they may do (validation, the start filter's
  # scans and, for `run`, at most `work_bound` steps) fits the call's
  # allowance. They check that before they read the haystack. Otherwise
  # they decline and the caller runs the searcher.
  #
  # A positive timeout counts from the start of the call, so it has not
  # passed before the call reads the haystack, and a short search under
  # one does less work than the meter does before its first clock read
  # (`Core::WorkMeter::CLOCK_INTERVAL`, checked in `fits?`): the searcher
  # would read the clock only as the call starts, where no time has
  # passed, and answer the same.
  struct ShortSearch
    # The longest haystack a short search reads.
    MAX_BYTES = 256
    # The most capture slots `run` keeps on the stack.
    MAX_SLOTS = 16
    # How many short searches of a program `run` waits for before it
    # builds the program's one-pass DFA, so a pattern searched once does
    # not pay for building it.
    BUILD_AFTER = 8
    # The most failed tries at a start `run` makes before it declines an
    # unanchored search; after `MAX_DECLINES` such declines it leaves the
    # program's unanchored searches to the searcher, whose DFA reads a
    # haystack with no match nearby faster than one try per position.
    MAX_TRIES    =  8
    MAX_DECLINES = 16

    # True once `rejects?` found the haystack valid and the filter's scans
    # inside the allowance without rejecting it, so `run` need not scan or
    # validate again.
    @screened = false

    # True once `rejects?` found the haystack valid and every required byte
    # (`StartFilter#list_of_required_bytes`) at or after the offset, so a
    # searcher that runs this call next need not look for them again (see
    # `Searcher#note_required_bytes_present`).
    getter? screened : Bool

    def initialize(@program : Program, @haystack : String, @byte_index : Int32, @options : MatchOptions,
                   @limits : SearchLimits, @timeout : Time::Span?)
      # The most work `fits?` allows: the ceiling, and under a timeout less
      # than the meter does before its first clock read.
      @work_cap = @timeout ? Math.min(@limits.work_ceiling, Core::WorkMeter::CLOCK_INTERVAL - 1) : @limits.work_ceiling
    end

    # True when the haystack is short and the offset one the searcher
    # would accept; no other method answers otherwise.
    def applies? : Bool
      bytes = @haystack.to_slice
      return false if bytes.size > MAX_BYTES || @byte_index < 0 || @byte_index > bytes.size
      if timeout = @timeout
        return false unless timeout.positive?
      end
      @byte_index == bytes.size || bytes.unsafe_fetch(@byte_index) & 0xC0 != 0x80
    end

    # True when no match can start (see `StartFilter#rejects?`) and the
    # searcher would say so without raising. Call `applies?` first, and
    # pass the program's *plan*.
    def rejects?(plan : SearchPlan) : Bool
      bytes = @haystack.to_slice
      filter = plan.start_filter
      return false unless fits?(filter.scan_work(bytes.size, @byte_index))
      unless filter.rejects?(bytes, @byte_index, anchored?(plan))
        @screened = valid?(plan)
        return false
      end
      valid?(plan)
    end

    # Runs the search on the one-pass DFA into *slots* (`slot_count`
    # entries) with *scratch* beside it. Returns the match end,
    # `LazyDFA::NO_MATCH`, or `LazyDFA::GAVE_UP` when this search declines.
    # Call `applies?` first, and pass the program's *plan*.
    def run(plan : SearchPlan, slots : Slice(Int64), scratch : Slice(Int64)) : Int32
      return LazyDFA::GAVE_UP if @program.slot_count > MAX_SLOTS
      return LazyDFA::GAVE_UP if @program.options.first_line? || @program.options.end_anchored?
      return LazyDFA::GAVE_UP if @options.end_anchored?
      one_pass = plan.short_search_one_pass || return LazyDFA::GAVE_UP
      bytes = @haystack.to_slice
      bound = work_bound(bytes.size)
      filter = plan.start_filter
      # The filter's scans, the start scan between tries (at most one
      # pass), and the tries themselves.
      steps = filter.scan_work(bytes.size, @byte_index) + (bytes.size - @byte_index) + bound
      return LazyDFA::GAVE_UP unless fits?(steps)
      unless @screened
        return LazyDFA::GAVE_UP unless valid?(plan)
        return LazyDFA::NO_MATCH if filter.rejects?(bytes, @byte_index, anchored?(plan))
      end
      if anchored?(plan)
        finish, _ = one_pass.search(bytes, @byte_index, @byte_index, slots, scratch, nil)
        return finish
      end
      return LazyDFA::GAVE_UP unless plan.short_tries_pay?
      spent = 0
      tries = 0
      start = @byte_index
      while (start = filter.next_start(bytes, start)) >= 0
        if start == bytes.size || bytes.unsafe_fetch(start) & 0xC0 != 0x80
          if tries == MAX_TRIES
            plan.note_short_decline
            return LazyDFA::GAVE_UP
          end
          finish, scanned = one_pass.search(bytes, start, @byte_index, slots, scratch, nil)
          return finish unless finish == LazyDFA::NO_MATCH
          spent += scanned + 1
          tries += 1
          # Tries that read past the bound decline as running out of tries
          # does, so a pattern whose failed tries read far (`\s+$` over a
          # run of spaces) stops trying after `MAX_DECLINES` such calls.
          if spent > bound
            plan.note_short_decline
            return LazyDFA::GAVE_UP
          end
        end
        start += 1
      end
      LazyDFA::NO_MATCH
    end

    # The most one-pass steps `run` takes before it declines: a few passes
    # over the haystack, so a pattern whose failed tries read far stays
    # cheap and linear.
    private def work_bound(size : Int32) : Int32
      4 * size + 64
    end

    # See `SearchPlan#anchored_at_offset?`, with the common answers first.
    private def anchored?(plan : SearchPlan) : Bool
      return true if @program.options.anchored? || @options.anchored? || plan.anchored_start?
      plan.empty_match_everywhere? && !(@program.options.end_anchored? || @options.end_anchored?)
    end

    # True when validating the haystack and *steps* more operations fit
    # the call's work allowance.
    #
    # It checks a sufficient condition that needs no multiplication:
    # the allowance is at least the smaller of `work_ceiling` and
    # `base_work`, or of `work_ceiling` and `work_per_byte` times a
    # haystack of at least one byte. Limits too tight for it decline.
    # Under a timeout the work must also end before the meter's first
    # clock read (see the type's comment).
    private def fits?(steps : Int32) : Bool
      needed = @haystack.bytesize.to_i64 + steps
      return false if @work_cap < needed
      @limits.base_work >= needed || (@haystack.bytesize > 0 && @limits.work_per_byte >= needed)
    end

    # True when the haystack is valid UTF-8. The plan remembers the last
    # `String` a short search validated (strings are immutable), so an
    # iteration of calls over one haystack validates it once.
    private def valid?(plan : SearchPlan) : Bool
      return true if plan.short_validated?(@haystack)
      return false if Core::UTF8.first_invalid_offset(@haystack.to_slice)
      plan.remember_short_validated(@haystack)
      true
    end
  end
end
