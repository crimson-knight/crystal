module Regex::Mica::Regex
  # :nodoc:
  # The work budget and deadline of one static search call. Its counters
  # live in the caller's stack frame (`counters`, three `Int64`: the
  # operations so far, the next checkpoint and the allowance), so the meter
  # is a plain value that copies freely and allocates nothing.
  struct StaticMeter
    @timeout : Time::Span?
    @started : Time::Instant?

    def initialize(@counters : Pointer(Int64), limits : SearchLimits, state_count : Int32, haystack_bytes : Int32,
                   @timeout : Time::Span?)
      @started = @timeout ? Time.instant : nil
      @counters[0] = 0_i64
      @counters[2] = StaticMeter.allowance(limits, state_count, haystack_bytes)
      @counters[1] = next_checkpoint
    end

    # The operations charged so far.
    def operations : Int64
      @counters[0]
    end

    # `SearchLimits#max_work` for *state_count* states over
    # *haystack_bytes* bytes, saturating as it does, with 128-bit products
    # in place of its overflow divisions: every static search starts here.
    def self.allowance(limits : SearchLimits, state_count : Int32, haystack_bytes : Int32) : Int64
      most = Int64::MAX.to_u128
      base = limits.work_per_state.to_u128 * state_count.to_u128 + limits.base_work.to_u128
      scaled = limits.work_per_byte.to_u128 * haystack_bytes.to_u128
      total = Math.min(base + scaled, most).to_i64
      Math.min(total, limits.work_ceiling)
    end

    # The operations the allowance has left.
    def room : Int64
      @counters[2] - @counters[0]
    end

    # Raises `Mica::DeadlineExceededError` when the deadline has passed.
    def enforce_deadline(at : Int32) : Nil
      raise_deadline(at) if deadline_passed?
    end

    # Charges *count* operations; raises when the allowance or the deadline
    # is exceeded.
    @[AlwaysInline]
    def charge(count : Int32, at : Int32) : Nil
      operations = @counters[0] &+ count
      @counters[0] = operations
      exceeded(at) if operations > @counters[1]
    end

    # How many of the next *wanted* operations may be made before the
    # meter must be consulted again: at least one, or it raises. When the
    # allowance is spent exactly, it charges the next operation, which
    # raises `max_work` before the byte is read (as `SearchMeter#readable`
    # does).
    @[AlwaysInline]
    def readable(wanted : Int32, at : Int32) : Int32
      return 0 if wanted <= 0
      room = @counters[1] - @counters[0]
      if room <= 0
        exceeded(at)
        room = @counters[1] - @counters[0]
        if room <= 0
          charge(1, at)
          # Not reached: the allowance is spent, so the charge raised.
          raise Mica::Error.new("internal error: a charge past the allowance did not raise")
        end
      end
      room < wanted ? room.to_i32 : wanted
    end

    private def exceeded(at : Int32) : Nil
      allowance = @counters[2]
      if @counters[0] > allowance
        raise SearchLimitError.new("max_work", allowance, "A search of #{@counters[0]} operations",
          Core::Position.new(at.to_i64))
      end
      raise_deadline(at) if deadline_passed?
      @counters[1] = next_checkpoint
    end

    private def deadline_passed? : Bool
      timeout = @timeout
      started = @started
      return false unless timeout && started
      Time.instant - started >= timeout
    end

    private def raise_deadline(at : Int32) : NoReturn
      started = @started || Time.instant
      elapsed = Time.instant - started
      raise Mica::DeadlineExceededError.new("Deadline exceeded while searching", Core::Position.new(at.to_i64), elapsed)
    end

    private def next_checkpoint : Int64
      checkpoint = @counters[2]
      if @timeout
        clock = @counters[0] &+ Core::WorkMeter::CLOCK_INTERVAL
        checkpoint = clock if clock < checkpoint
      end
      checkpoint
    end
  end
end
