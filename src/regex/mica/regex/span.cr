module Regex::Mica::Regex
  # The byte span of one match: the result of the allocation-free search
  # methods of `Expression`, `StaticPattern` and `StaticFallback`
  # (`search_span`, `each_span`). A plain value; it holds no reference to
  # the haystack.
  #
  # ```
  # limits = Mica::Regex::SearchLimits::REQUEST
  # slug = Mica::Regex.compile("[a-z]+", dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  # span = slug.search_span("-- post --", limits: limits)
  # span                 # => Mica::Regex::Span(@byte_begin=3, @byte_end=7)
  # span.try(&.bytesize) # => 4
  # ```
  record Span, byte_begin : Int32, byte_end : Int32 do
    # Returns the match's length in bytes.
    def bytesize : Int32
      byte_end - byte_begin
    end

    # Returns true for a match of no bytes.
    def empty? : Bool
      byte_end == byte_begin
    end

    # Returns the matched text of *haystack* (the one the search read). This
    # allocates the `String`.
    def text_in(haystack : String) : String
      haystack.byte_slice(byte_begin, bytesize)
    end
  end
end
