module Regex::Mica::Regex
  # Counts the work of one search call against its `SearchLimits`, on a
  # `Core::WorkMeter`. Created once per call, so an iteration call's
  # searches share one allowance.
  #
  # When the allowance runs out it raises `SearchLimitError` naming
  # `max_work`; when the call's timeout passes, `Mica::DeadlineExceededError`.
  #
  # WARNING: A meter belongs to one call and one fiber at a time (`restart`
  # begins the next call).
  class SearchMeter
    # The underlying meter (its `operations` are the work charged so far).
    getter work_meter : Core::WorkMeter

    # The limits and state count `@budget` was made for: a restart under
    # the same ones reuses it instead of building it again.
    @budget_limits : SearchLimits
    @budget_state_count : Int32
    @budget : Core::WorkBudget

    def initialize(limits : SearchLimits, state_count : Int32, haystack_bytes : Int32, timeout : Time::Span?)
      @budget_limits = limits
      @budget_state_count = state_count
      @budget = limits.work_budget(state_count, timeout)
      @work_meter = Core::WorkMeter.new(@budget)
      @work_meter.add_units(haystack_bytes)
    end

    # Starts the meter over for a new call (see `Core::WorkMeter#restart`).
    def restart(limits : SearchLimits, state_count : Int32, haystack_bytes : Int32, timeout : Time::Span?) : Nil
      unless limits == @budget_limits && state_count == @budget_state_count && timeout == @budget.timeout
        @budget_limits = limits
        @budget_state_count = state_count
        @budget = limits.work_budget(state_count, timeout)
      end
      @work_meter.restart(@budget)
      @work_meter.add_units(haystack_bytes)
    end

    # Returns the operations charged so far.
    def operations : Int64
      @work_meter.operations
    end

    # Charges *count* operations for work at haystack byte *at*.
    @[AlwaysInline]
    def charge(count : Int, at : Int32) : Nil
      exceeded(at) if @work_meter.charge(count)
    end

    # Returns how many of the next *wanted* haystack bytes from *at* a scan
    # may read now, one operation each, before it charges them: at least
    # one when *wanted* is positive, and never past the next checkpoint
    # (`Core::WorkMeter#headroom`). At a checkpoint it checks the budget
    # and the deadline first, and when the allowance is spent it charges
    # the first byte, which raises before the byte is read. A scan then
    # reads that many bytes and charges what it read.
    def readable(wanted : Int32, at : Int32) : Int32
      return 0 if wanted <= 0
      room = @work_meter.headroom
      if room == 0
        exceeded(at)
        room = @work_meter.headroom
        if room == 0
          charge(1, at)
          # Not reached: the allowance is spent, so the charge raised.
          raise Mica::Error.new("internal error: a charge past the allowance did not raise")
        end
      end
      room < wanted ? room.to_i32 : wanted
    end

    # Raises `Mica::DeadlineExceededError` when the timeout has passed,
    # reading the clock now (charges read it only at checkpoints).
    def enforce_deadline(at : Int32) : Nil
      @work_meter.enforce_deadline("while searching") { Core::Position.new(at.to_i64) }
    end

    # Raises `Mica::DeadlineExceededError` when the timeout passed before
    # the call began, as the call starts. The meter's clock started with
    # the call (`initialize`, `restart`), so a positive timeout has not
    # passed yet and the clock is not read again; a zero or negative one
    # has, whatever the clock reads.
    def enforce_start_deadline(at : Int32) : Nil
      timeout = @budget.timeout
      enforce_deadline(at) if timeout && !timeout.positive?
    end

    private def exceeded(at : Int32) : Nil
      verdict = @work_meter.verdict
      return if verdict.within?
      if verdict.budget_exceeded?
        raise SearchLimitError.new("max_work", @work_meter.allowance,
          "A search of #{@work_meter.operations} operations", Core::Position.new(at.to_i64))
      end
      @work_meter.raise_exceeded(verdict, Core::Position.new(at.to_i64), "while searching")
    end
  end
end
