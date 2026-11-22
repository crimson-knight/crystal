module Regex::Mica::Regex
  # A pattern `Mica::Regex.static` could not hold in static tables. The
  # runtime compiler checked it while the application built (a pattern it
  # rejects is a compile error there), and the compiler printed a note
  # naming the limit it passed. It compiles on the runtime engine, under
  # `CompileLimits::TRUSTED_PATTERN`, when the constant holding it is
  # first read, and offers the same methods as `StaticPattern` on the
  # runtime engine's allocation-free API (`Expression#search_span`,
  # `Expression#search_groups`, `Expression#each_span`): once the
  # expression has adapted over its first searches, they allocate nothing
  # either.
  class StaticFallback
    # The pattern as written.
    getter source : String
    # The options it was compiled with.
    getter options : CompileOptions
    # Why the static path refused the pattern.
    getter reason : String
    # The runtime expression that runs the searches.
    getter expression : Expression

    def initialize(@source : String, @options : CompileOptions, @reason : String)
      @expression = Mica::Regex.compile(@source, dialect: :crystal, compile_limits: CompileLimits::TRUSTED_PATTERN,
        options: @options)
    end

    # Returns the number of capturing groups (group 0 not included).
    def capture_count : Int32
      @expression.capture_count
    end

    # Returns false: the pattern runs on the runtime engine.
    def static? : Bool
      false
    end

    # Returns true when *haystack* has a match at or after byte
    # *byte_offset* (see `StaticPattern#matches?`).
    def matches?(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                 deadline : Time::Span? = nil) : Bool
      @expression.matches_at_byte_index?(haystack, byte_offset, limits: limits, timeout: deadline)
    end

    # Returns the span of the leftmost-first match at or after byte
    # *byte_offset*, or nil (see `StaticPattern#search_span`).
    def search_span(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                    deadline : Time::Span? = nil) : Span?
      @expression.search_span(haystack, byte_offset, limits: limits, deadline: deadline)
    end

    # Yields the groups of the leftmost-first match at or after byte
    # *byte_offset* (see `StaticPattern#search_groups`).
    def search_groups(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                      deadline : Time::Span? = nil, & : Groups -> _)
      @expression.search_groups(haystack, byte_offset, limits: limits, deadline: deadline) { |groups| yield groups }
    end

    # Yields the span of each match of *haystack* in turn (see
    # `StaticPattern#each_span`).
    def each_span(haystack : String, *, limits : SearchLimits = SearchLimits::REQUEST, deadline : Time::Span? = nil,
                  & : Span ->) : Nil
      @expression.each_span(haystack, limits: limits, deadline: deadline) { |span| yield span }
    end

    # :nodoc:
    def search_span_unchecked(haystack : String, byte_offset : Int32, limits : SearchLimits,
                              deadline : Time::Span?) : Span?
      search_span(haystack, byte_offset, limits: limits, deadline: deadline)
    end

    # :nodoc:
    def search_groups_unchecked(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                                & : Groups -> _)
      search_groups(haystack, byte_offset, limits: limits, deadline: deadline) { |groups| yield groups }
    end
  end
end
