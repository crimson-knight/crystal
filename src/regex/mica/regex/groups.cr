module Regex::Mica::Regex
  # The groups of one match, yielded by `search_groups` (on `Expression`,
  # `StaticPattern` and `StaticFallback`). The offsets live in slots the
  # caller's stack frame owns, so the value is valid only inside the block
  # it is yielded to; keep a `Span` or a group's text, never the value.
  # Reading offsets allocates nothing; `[]?` allocates the `String` it
  # returns.
  #
  # ```
  # PLACEHOLDER = Mica::Regex.static(/\{\{\s*([a-z_]+)\s*\}\}/)
  # PLACEHOLDER.search_groups("Hello {{ first_name }}!") { |groups| groups[1]? } # => "first_name"
  # ```
  struct Groups
    # The slots `search_groups` keeps on the caller's stack: 31 groups and
    # group 0. A runtime pattern with more groups uses a heap buffer.
    STACK_SLOTS = 64

    # The haystack the search read.
    getter haystack : String

    # :nodoc:
    # *slots* holds a begin and an end byte offset per group, group 0 first,
    # negative for a group that did not take part.
    def initialize(@haystack : String, @slots : Slice(Int32))
    end

    # Returns the number of groups, group 0 (the whole match) included.
    def size : Int32
      @slots.size // 2
    end

    # Returns true when group *group* took part in the match.
    def matched?(group : Int32) : Bool
      0 <= group < size && @slots[group * 2] >= 0
    end

    # Returns the byte where group *group* begins, or -1 when it did not
    # take part. Raises `IndexError` for a group the pattern does not have.
    def byte_begin(group : Int32) : Int32
      check_group(group)
      @slots[group * 2]
    end

    # Returns the byte where group *group* ends, or -1 when it did not take
    # part. Raises `IndexError` for a group the pattern does not have.
    def byte_end(group : Int32) : Int32
      check_group(group)
      @slots[group * 2 + 1]
    end

    # Returns the span of group *group*, or nil when it did not take part.
    def span?(group : Int32) : Span?
      matched?(group) ? Span.new(@slots[group * 2], @slots[group * 2 + 1]) : nil
    end

    # Returns the text of group *group*, or nil when it did not take part
    # (or the pattern has no such group). Allocates the `String`.
    def []?(group : Int32) : String?
      return nil unless matched?(group)
      start = @slots[group * 2]
      @haystack.byte_slice(start, @slots[group * 2 + 1] - start)
    end

    private def check_group(group : Int32) : Nil
      raise IndexError.new("Invalid capture group index: #{group}") unless 0 <= group < size
    end
  end
end
