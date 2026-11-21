module Regex::Mica::Regex
  # Compiles *pattern* while the application builds and returns a
  # `StaticPattern`: its DFA tables are read-only data in the binary, with
  # state ids at the narrowest width that holds them (`UInt8` or
  # `UInt16`), and its searches allocate nothing (the meter and the capture
  # pass's scratch live in a fixed-size `StaticArray` on the caller's
  # stack). Every search checks the work budget and the deadline as the
  # runtime engine does.
  #
  # *pattern* is a regex literal (its `i`, `m` and `x` flags apply, `m`
  # with Crystal's meaning, `Multiline | DotAll`) or a string literal (with
  # *ignore_case* for `i`; other flags go inline, `(?m)`). It must be known
  # when the application builds, and a pattern the runtime compiler
  # rejects is a compile error at the call.
  #
  # A pattern outside the static limits (a DFA over 4,096 states in either
  # direction, tables over 512 KiB, a capture pass over 64 KiB of stack, or
  # `\G`; see docs/regex.md, "Static patterns") becomes a `StaticFallback`
  # with the same methods, on the runtime engine, and the compiler prints a
  # note saying why. The call site stays the same either way.
  #
  # ```
  # ROUTE_ID = Mica::Regex.static(/\A[0-9]+\z/)
  # ROUTE_ID.matches?("2026") # => true
  # ```
  macro static(pattern, *, ignore_case = false)
    {% if pattern.is_a?(RegexLiteral) %}
      {% source = pattern.source %}
      {% if !source.is_a?(StringLiteral) %}
        {% pattern.raise "Mica::Regex.static needs a regex literal without interpolation" %}
      {% end %}
      {% options = 0 %}
      {% for flag in pattern.options %}
        {% if flag == :i %}{% options = options + 1 %}{% end %}
        {% if flag == :m %}{% options = options + 6 %}{% end %}
        {% if flag == :x %}{% options = options + 8 %}{% end %}
      {% end %}
    {% elsif pattern.is_a?(StringLiteral) %}
      {% source = pattern %}
      {% options = ignore_case ? 1 : 0 %}
    {% else %}
      {% pattern.raise "Mica::Regex.static needs a regex or string literal known when the application builds" %}
    {% end %}
    {% parts = run("./static/emit_static_pattern", source, options).stringify.split("\n%%\n") %}
    {% header = parts[0].split("\n") %}
    {% kind = header[0] %}
    {% note = header[1] || "" %}
    {% if kind == "error" %}{% pattern.raise note %}{% end %}
    {% if note != "" %}{% puts note %}{% end %}
    {{ parts[1].id }}
  end

  # A pattern compiled while the application built (see
  # `Mica::Regex.static`). `F` and `R` are the state-id types of its
  # forward and reverse DFA tables and `N` that of its capture program;
  # every pattern with the same three shares one `StaticMatcher`, so the
  # search code is in the binary once per width combination. `SCRATCH` is
  # the number of 32-bit words of stack `search_groups` takes for this
  # pattern's capture pass.
  #
  # Every method takes *limits* (default `SearchLimits::REQUEST`) and an
  # optional *deadline*, and raises as the runtime engine does:
  # `SearchLimitError` naming `max_work` when the work budget runs out,
  # `Mica::DeadlineExceededError` past the deadline, `Mica::EncodingError`
  # for a haystack that is not valid UTF-8, and `ArgumentError` for a
  # negative *byte_offset* or one inside a character.
  struct StaticPattern(F, R, N, SCRATCH)
    # :nodoc:
    def initialize(@matcher : StaticMatcher(F, R, N))
      if SCRATCH < @matcher.scratch_words
        raise ArgumentError.new("#{@matcher.source.inspect} needs #{@matcher.scratch_words} words of capture scratch")
      end
    end

    # Returns the pattern as written.
    def source : String
      @matcher.source
    end

    # Returns the options it was compiled with.
    def options : CompileOptions
      @matcher.options
    end

    # Returns the number of capturing groups (group 0 not included).
    def capture_count : Int32
      @matcher.capture_count
    end

    # Returns true: the static path holds this pattern (a `StaticFallback`
    # returns false).
    def static? : Bool
      true
    end

    # Returns true when *haystack* has a match at or after byte
    # *byte_offset*; stops at the first match end it reaches.
    def matches?(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                 deadline : Time::Span? = nil) : Bool
      @matcher.matches?(haystack, byte_offset, limits, deadline, true)
    end

    # Returns the span of the leftmost-first match at or after byte
    # *byte_offset*, or nil.
    def search_span(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                    deadline : Time::Span? = nil) : Span?
      @matcher.search_span(haystack, byte_offset, limits, deadline, true)
    end

    # Finds the leftmost-first match at or after byte *byte_offset* with its
    # groups, yields them (see `Groups`; valid only inside the block), and
    # returns the block's value, or nil when nothing matches.
    def search_groups(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                      deadline : Time::Span? = nil, & : Groups -> _)
      scratch = uninitialized StaticArray(Int32, SCRATCH)
      return nil unless @matcher.search_groups(haystack, byte_offset, limits, deadline, true, scratch.to_unsafe, SCRATCH)
      yield Groups.new(haystack, Slice.new(scratch.to_unsafe, @matcher.slot_count))
    end

    # Yields the span of each leftmost-first match of *haystack* in turn,
    # stepping over one character after an empty match as `String#scan`
    # does. One work budget and one deadline cover the whole call.
    def each_span(haystack : String, *, limits : SearchLimits = SearchLimits::REQUEST, deadline : Time::Span? = nil,
                  & : Span ->) : Nil
      @matcher.each_span(haystack, limits, deadline) { |span| yield span }
    end

    # :nodoc:
    # As `search_span`, for a *haystack* the caller has already validated
    # as UTF-8 (the benchmark adapter, after its first search of a
    # haystack).
    def search_span_unchecked(haystack : String, byte_offset : Int32, limits : SearchLimits,
                              deadline : Time::Span?) : Span?
      @matcher.search_span(haystack, byte_offset, limits, deadline, false)
    end

    # :nodoc:
    # As `search_groups`, for a *haystack* the caller has already validated.
    def search_groups_unchecked(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                                & : Groups -> _)
      scratch = uninitialized StaticArray(Int32, SCRATCH)
      return nil unless @matcher.search_groups(haystack, byte_offset, limits, deadline, false, scratch.to_unsafe, SCRATCH)
      yield Groups.new(haystack, Slice.new(scratch.to_unsafe, @matcher.slot_count))
    end
  end
end
