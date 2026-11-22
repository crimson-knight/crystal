module Regex::Mica::Regex
  # Upper bounds on one search call: the matching work it may do and the
  # output it may build. Every search method of `Expression` takes them as a
  # required `limits:` argument (there is no default and no global switch):
  # use `REQUEST` for input that arrives with a request, `TRUSTED_INPUT`
  # for input the program itself produced, or `SearchLimits.custom`.
  #
  # The work allowance grows with the program and the haystack:
  #
  #     max_work = min(work_ceiling, work_per_state·m + base_work + work_per_byte·n)
  #
  # for a program of m states over n haystack bytes, so an empty haystack
  # still gets a nonzero budget. Work is counted in operations: one per
  # haystack byte validated, one per thread step and per state a closure
  # visits, c per capture slot vector copied, and one per backtracker visit
  # and undo entry. An iteration call (`scan`, `gsub`, `split`,
  # `each_match`) draws every search from one allowance, so a run of
  # matches cannot reset it.
  #
  # When a search needs more, it raises `SearchLimitError` naming
  # `max_work`; it never returns a partial or wrong result.
  #
  # ```
  # limits = Mica::Regex::SearchLimits.custom(work_ceiling: 1_000_000_i64)
  # limits.max_output_bytes # => 16_777_216 (from REQUEST)
  # ```
  struct SearchLimits
    # The absolute cap on work operations per call.
    getter work_ceiling : Int64
    # Operations allowed per haystack byte.
    getter work_per_byte : Int64
    # Operations allowed per program state.
    getter work_per_state : Int64
    # Operations allowed regardless of size.
    getter base_work : Int64
    # Bytes `gsub`, `sub` and `split` may produce per call (the text they
    # build, not the haystack).
    getter max_output_bytes : Int64

    def initialize(@work_ceiling : Int64, @work_per_byte : Int64, @work_per_state : Int64, @base_work : Int64,
                   @max_output_bytes : Int64)
      check_not_negative("work_ceiling", @work_ceiling)
      check_not_negative("work_per_byte", @work_per_byte)
      check_not_negative("work_per_state", @work_per_state)
      check_not_negative("base_work", @base_work)
      check_not_negative("max_output_bytes", @max_output_bytes)
    end

    # Returns limits that start from `REQUEST` and change only the values
    # given.
    def self.custom(*, work_ceiling : Int64 = REQUEST.work_ceiling, work_per_byte : Int64 = REQUEST.work_per_byte,
                    work_per_state : Int64 = REQUEST.work_per_state, base_work : Int64 = REQUEST.base_work,
                    max_output_bytes : Int64 = REQUEST.max_output_bytes) : self
      new(work_ceiling, work_per_byte, work_per_state, base_work, max_output_bytes)
    end

    # Returns the work budget for a program of *state_count* states over
    # *haystack_bytes* bytes, with an optional wall-clock *timeout*.
    def work_budget(state_count : Int32, timeout : Time::Span?) : Core::WorkBudget
      base = Preflight.add(Preflight.multiply(@work_per_state, state_count.to_i64), @base_work)
      Core::WorkBudget.new(operations_per_unit: @work_per_byte, base_operations: base, max_operations: @work_ceiling,
        timeout: timeout)
    end

    # Returns the work allowed for *state_count* states and *haystack_bytes*
    # bytes (the formula above).
    def max_work(state_count : Int32, haystack_bytes : Int64) : Int64
      work_budget(state_count, nil).allowance(haystack_bytes)
    end

    private def check_not_negative(name : String, value : Int64) : Nil
      raise ArgumentError.new("#{name} must not be negative") if value < 0
    end

    # For haystacks that arrive with a request (headers, bodies, form
    # fields): 10^8 operations at most, 16 MiB of output.
    REQUEST = new(
      work_ceiling: 100_000_000_i64,
      work_per_byte: 4_096_i64,
      work_per_state: 64_i64,
      base_work: 4_096_i64,
      max_output_bytes: 16_i64 * 1024 * 1024,
    )

    # For haystacks the program produced or read from its own files: 10^9
    # operations at most, 256 MiB of output.
    TRUSTED_INPUT = new(
      work_ceiling: 1_000_000_000_i64,
      work_per_byte: 4_096_i64,
      work_per_state: 64_i64,
      base_work: 4_096_i64,
      max_output_bytes: 256_i64 * 1024 * 1024,
    )
  end
end
