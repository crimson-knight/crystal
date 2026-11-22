module Regex::Mica::Regex
  # Upper bounds on what compiling one pattern may build. Every limit is
  # checked before the structure it guards exists, so a pattern built to
  # exhaust memory is refused with a `CompileLimitError` naming the limit
  # instead of being expanded.
  #
  # The native API takes the limits as a required argument (there is no
  # default and no global switch): use `UNTRUSTED_PATTERN` for patterns that
  # arrive at run time, `TRUSTED_PATTERN` for patterns written in source,
  # or `CompileLimits.custom` for anything else.
  #
  # ```
  # limits = Mica::Regex::CompileLimits.custom(max_pattern_bytes: 512)
  # limits.max_nest_depth # => 64 (from UNTRUSTED_PATTERN)
  # ```
  struct CompileLimits
    # Pattern length in bytes, checked before parsing.
    getter max_pattern_bytes : Int32
    # Nesting of groups, checked while parsing (the parser keeps an explicit
    # stack, so depth costs no machine stack).
    getter max_nest_depth : Int32
    # Capturing groups, checked while parsing.
    getter max_captures : Int32
    # Ranges in one class after case-fold closure, checked during class
    # lowering before the range array grows past it.
    getter max_class_ranges : Int32
    # Program states: the preflight's upper bound on the syntax tree (with
    # saturating arithmetic), checked before any `Hir` exists, and the
    # emitted count, checked by the compiler while it emits (R2).
    getter max_program_states : Int64
    # Pike VM workspace per search (16·m·c + 32·m bytes for m states and c
    # capture slots), checked when compilation finishes (R2).
    getter max_pike_bytes : Int64
    # Bytes the parser, the class lowering and the `Hir` may allocate,
    # charged to an `AllocationLedger` at every allocation.
    getter max_compile_bytes : Int64

    def initialize(@max_pattern_bytes : Int32, @max_nest_depth : Int32, @max_captures : Int32,
                   @max_class_ranges : Int32, @max_program_states : Int64, @max_pike_bytes : Int64,
                   @max_compile_bytes : Int64)
      check_positive("max_pattern_bytes", @max_pattern_bytes)
      check_positive("max_nest_depth", @max_nest_depth)
      check_positive("max_captures", @max_captures)
      check_positive("max_class_ranges", @max_class_ranges)
      check_positive("max_program_states", @max_program_states)
      check_positive("max_pike_bytes", @max_pike_bytes)
      check_positive("max_compile_bytes", @max_compile_bytes)
      # Group numbers are 16-bit in the Crystal dialect, as in PCRE2.
      raise ArgumentError.new("max_captures must be at most #{MAX_GROUP_NUMBER}") if @max_captures > MAX_GROUP_NUMBER
    end

    # Returns limits that start from `UNTRUSTED_PATTERN` and change only the
    # values given.
    def self.custom(*, max_pattern_bytes : Int32 = UNTRUSTED_PATTERN.max_pattern_bytes,
                    max_nest_depth : Int32 = UNTRUSTED_PATTERN.max_nest_depth,
                    max_captures : Int32 = UNTRUSTED_PATTERN.max_captures,
                    max_class_ranges : Int32 = UNTRUSTED_PATTERN.max_class_ranges,
                    max_program_states : Int64 = UNTRUSTED_PATTERN.max_program_states,
                    max_pike_bytes : Int64 = UNTRUSTED_PATTERN.max_pike_bytes,
                    max_compile_bytes : Int64 = UNTRUSTED_PATTERN.max_compile_bytes) : self
      new(max_pattern_bytes, max_nest_depth, max_captures, max_class_ranges, max_program_states,
        max_pike_bytes, max_compile_bytes)
    end

    private def check_positive(name : String, value : Int) : Nil
      raise ArgumentError.new("#{name} must be positive") if value <= 0
    end

    # The largest group number the Crystal dialect allows (PCRE2's
    # MAX_GROUP_NUMBER).
    MAX_GROUP_NUMBER = 65_535

    # For patterns that arrive at run time (`Regex.new(string)`, schema
    # `pattern` fields, rule packs).
    UNTRUSTED_PATTERN = new(
      max_pattern_bytes: 4 * 1024,
      max_nest_depth: 64,
      max_captures: 64,
      max_class_ranges: 4_096,
      max_program_states: 100_000_i64,
      max_pike_bytes: 4_i64 * 1024 * 1024,
      max_compile_bytes: 4_i64 * 1024 * 1024,
    )

    # For patterns written in program source (regex literals). The nesting
    # limit equals PCRE2's default parentheses limit.
    TRUSTED_PATTERN = new(
      max_pattern_bytes: 64 * 1024,
      max_nest_depth: 250,
      max_captures: 1_024,
      max_class_ranges: 65_536,
      max_program_states: 1_000_000_i64,
      max_pike_bytes: 64_i64 * 1024 * 1024,
      max_compile_bytes: 64_i64 * 1024 * 1024,
    )
  end
end
