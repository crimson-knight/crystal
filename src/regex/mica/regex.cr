require "./core"

# A regular expression engine in pure Crystal whose searches run in time
# linear in the haystack (the RE2 and Rust regex family): no backtracking
# into exponential time, no C library, no PCRE2.
#
# Milestone R1 provides the compile front half: the Crystal dialect parser
# (the PCRE2 subset Crystal programs use), compile limits checked before the
# structures they guard are built, an allocation ledger, the size preflight,
# the high-level intermediate representation (`Hir`) with Unicode classes
# and per-dialect case folding, and `Syntax.check`, which validates a
# pattern without compiling it to a program. R2 adds the Pike VM, the
# bounded backtracker and `Expression`; R3 the lazy DFAs, the one-pass DFA,
# literal prefilters and the `CachePool` (see `SearchPlan`). See
# docs/regex.md for the dialect, the excluded constructs and their
# rewrites.
#
# ```
# limits = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
# report = Mica::Regex::Syntax.check("(?<year>\\d{4})-\\d{2}", dialect: :crystal, compile_limits: limits)
# report.capture_count # => 1
# ```
module Regex::Mica::Regex
  # Raised when a pattern is not valid in its dialect. `byte_offset` is the
  # 0-based byte in the pattern where the problem was found.
  class SyntaxError < Mica::ParseError
  end

  # Raised for a construct the dialect recognizes but Mica::Regex leaves
  # out because it does not fit the linear-time engines (backreferences,
  # lookaround, atomic groups and possessive quantifiers, recursion,
  # conditionals, `\K`, backtracking verbs, callouts, `\C` and, until
  # milestone R9, `\X`). `construct` names it; docs/regex.md lists a
  # rewrite for each.
  class UnsupportedConstructError < SyntaxError
    # The excluded construct, for example "lookahead".
    getter construct : String

    def initialize(@construct : String, position : Core::Position)
      super("#{@construct} is outside the Mica::Regex dialect (see docs/regex.md, \"Excluded constructs\")", position)
    end
  end

  # Raised when a pattern needs more than one of its `CompileLimits` allow.
  # The limit is checked before the structure it guards is built.
  class CompileLimitError < Mica::LimitExceededError
    # The name of the limit, for example "max_program_states".
    getter limit_name : String

    # The limit's configured value.
    getter limit_value : Int64

    def initialize(@limit_name : String, @limit_value : Int64, detail : String, position : Core::Position)
      super("#{detail} exceeds #{@limit_name} (#{@limit_value})", position)
    end
  end

  # Raised when a search needs more than its `SearchLimits` allow (work or
  # output); `limit_name` and `limit_value` name the limit.
  class SearchLimitError < Mica::LimitExceededError
    # The name of the limit, for example "max_work".
    getter limit_name : String

    # The limit's value for this call.
    getter limit_value : Int64

    def initialize(@limit_name : String, @limit_value : Int64, detail : String, position : Core::Position)
      super("#{detail} exceeds #{@limit_name} (#{@limit_value})", position)
    end
  end

  # Raised by `Expression#match!` when nothing matches.
  class MatchNotFoundError < Mica::Error
  end
end

require "./regex/dialect"
require "./regex/compile_options"
require "./regex/compile_limits"
require "./regex/allocation_ledger"
require "./regex/off_heap_list"
require "./regex/static_object"
require "./regex/scratch_stack"
require "./regex/unicode"
require "./regex/code_point_set"
require "./regex/utf8_sequences"
require "./regex/ast"
require "./regex/parser"
require "./regex/hir"
require "./regex/class_lowering"
require "./regex/class_trie"
require "./regex/class_memo"
require "./regex/class_memo_prebuilt"
require "./regex/class_memo_prebuilt_folded"
require "./regex/preflight"
require "./regex/translator"
require "./regex/syntax"
require "./regex/literal_set"
require "./regex/program"
require "./regex/look"
require "./regex/compiler"
require "./regex/match_options"
require "./regex/search_limits"
require "./regex/search_meter"
require "./regex/validate_in_windows"
require "./regex/cache_pool"
require "./regex/pike_vm"
require "./regex/bounded_backtracker"
require "./regex/prefilter"
require "./regex/byte_classes"
require "./regex/reversed_class"
require "./regex/reverse_nfa"
require "./regex/lazy_dfa"
require "./regex/dfa_cache"
require "./regex/one_pass_dfa"
require "./regex/start_filter"
require "./regex/short_match"
require "./regex/search_plan"
require "./regex/searcher"
require "./regex/short_search"
require "./regex/candidate_search"
require "./regex/first_search"
require "./regex/span"
require "./regex/groups"
require "./regex/expression"
require "./regex/match_data"
require "./regex/static_meter"
require "./regex/static_byte_scan"
require "./regex/static_prefilter"
require "./regex/static_tables"
require "./regex/static_matcher"
require "./regex/static_pattern"
require "./regex/static_fallback"
