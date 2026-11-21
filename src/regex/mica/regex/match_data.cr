module Regex::Mica::Regex
  # One match of an `Expression`, Mica's counterpart of Crystal's
  # `Regex::MatchData`, with the same methods and the same rules:
  #
  # - group 0 is the whole match; `size` counts it, `group_size` does not;
  # - `[]?(n)` is nil for a group that did not take part and `""` for one
  #   that matched empty, and `[](n)` raises `IndexError` for either an
  #   invalid index or a group that did not take part;
  # - `begin` and `end` count characters, `byte_begin` and `byte_end`
  #   bytes;
  # - with duplicate names, `self["name"]` is the participating group of
  #   that name with the latest start, ties going to the first in
  #   name-table order (`Expression#list_of_name_entries`), as stdlib's
  #   PCRE2 binding chooses.
  #
  # ```
  # limits = Mica::Regex::SearchLimits::REQUEST
  # expression = Mica::Regex::Expression.new("(a)(?<b>x)?", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  # match = expression.match!("ab", limits: limits)
  # match[1]    # => "a"
  # match["b"]? # => nil
  # ```
  struct MatchData
    # The expression that matched.
    getter regex : Expression
    # The haystack.
    getter string : String
    # Capturing groups (group 0 not included).
    getter group_size : Int32
    # The byte index the search started from.
    getter byte_index : Int32

    # Group 0, held in the value itself, so a match of a pattern without
    # groups allocates nothing.
    @match_begin : Int32
    @match_end : Int32
    # Groups 1 to `group_size` as begin and end byte offsets (negative for
    # a group that did not take part). A match read with its groups keeps
    # up to `INLINE_GROUP_SLOTS` offsets in the value itself (`@inline_groups`),
    # so a match of up to four groups allocates nothing; more go in
    # `@groups`. A match whose groups are read on first use keeps its
    # `GroupReader` and its offsets in one buffer every copy of the match
    # shares (`@deferred`, null otherwise): each offset is `GROUP_UNREAD`
    # until then. Only the buffer's address is in the value, so the value
    # stays small to copy.
    @inline_groups : StaticArray(Int32, INLINE_GROUP_SLOTS)
    @groups : Slice(Int32)
    @deferred : Pointer(GroupReader)

    # :nodoc:
    # The group offsets a match keeps in the value itself.
    INLINE_GROUP_SLOTS = 8

    # Copies the first `2 * (group_size + 1)` entries of *slots* (byte
    # offsets, negative for a group that did not take part; a span-only
    # search fills only group 0).
    def initialize(@regex : Expression, @string : String, @byte_index : Int32, slots : Slice(Int64))
      @group_size = @regex.capture_count
      @match_begin = slots[0].to_i32
      @match_end = slots[1].to_i32
      @inline_groups = uninitialized StaticArray(Int32, INLINE_GROUP_SLOTS)
      @deferred = Pointer(GroupReader).null
      count = @group_size * 2
      if count <= INLINE_GROUP_SLOTS
        @groups = Slice(Int32).empty
        available = Math.min(count, slots.size - 2)
        count.times do |index|
          @inline_groups[index] = index < available ? slots.unsafe_fetch(index + 2).to_i32 : -1
        end
      else
        @groups = MatchData.copy_groups(slots, @group_size)
      end
    end

    # :nodoc:
    # A match found without its groups; *reader* reads them when they are
    # first asked for.
    def initialize(@regex : Expression, @string : String, @byte_index : Int32, @match_begin : Int32,
                   @match_end : Int32, reader : GroupReader)
      @group_size = @regex.capture_count
      @inline_groups = uninitialized StaticArray(Int32, INLINE_GROUP_SLOTS)
      @groups = Slice(Int32).empty
      @deferred = MatchData.deferred_buffer(reader, @group_size * 2)
    end

    # A buffer that holds *reader* and then *offset_count* offsets, each
    # `GROUP_UNREAD`. A `GroupReader` holds no references (limits, a
    # timeout and options are plain values), so the buffer is allocated
    # pointer-free, as a `Slice(Int32)` of groups was.
    protected def self.deferred_buffer(reader : GroupReader, offset_count : Int32) : Pointer(GroupReader)
      buffer = GC.malloc_atomic(sizeof(GroupReader) + offset_count * sizeof(Int32)).as(GroupReader*)
      buffer.value = reader
      offsets = (buffer + 1).as(Int32*)
      offset_count.times { |index| offsets[index] = GROUP_UNREAD }
      buffer
    end

    # :nodoc:
    # Marks a group offset not read yet.
    GROUP_UNREAD = Int32::MIN

    # :nodoc:
    # Groups 1 to *group_size* of *slots* (`Slice(Int32).empty` when there
    # are none, which allocates nothing).
    def self.copy_groups(slots : Slice(Int64), group_size : Int32) : Slice(Int32)
      return Slice(Int32).empty if group_size == 0
      count = group_size * 2
      available = Math.min(count, slots.size - 2)
      copied = Slice(Int32).new(count) do |index|
        index < available ? slots.unsafe_fetch(index + 2).to_i32 : -1
      end
      copied
    end

    # Returns the number of groups, group 0 included.
    def size : Int32
      @group_size + 1
    end

    # Returns the character index where group *n* starts.
    def begin(n : Int32 = 0) : Int32
      character_index(byte_begin(n))
    end

    # Returns the character index where group *n* ends.
    def end(n : Int32 = 0) : Int32
      character_index(byte_end(n))
    end

    # Returns the byte index where group *n* starts.
    def byte_begin(n : Int32 = 0) : Int32
      check_index_out_of_bounds(n)
      byte_range(n) { |normalized| raise_capture_group_was_not_matched(normalized) }.begin
    end

    # Returns the byte index where group *n* ends.
    def byte_end(n : Int32 = 0) : Int32
      check_index_out_of_bounds(n)
      byte_range(n) { |normalized| raise_capture_group_was_not_matched(normalized) }.end
    end

    # Returns group *n*, or nil when it did not take part or *n* is not a
    # group.
    def []?(n : Int) : String?
      return unless valid_group?(n)
      range = byte_range(n) { return nil }
      @string.byte_slice(range.begin, range.end - range.begin)
    end

    # Returns group *n*; raises `IndexError` when it did not take part or
    # *n* is not a group.
    def [](n : Int) : String
      check_index_out_of_bounds(n)
      range = byte_range(n) { |normalized| raise_capture_group_was_not_matched(normalized) }
      @string.byte_slice(range.begin, range.end - range.begin)
    end

    # Returns the named group *group_name*, or nil when no group of that
    # name took part or the name does not exist.
    def []?(group_name : String) : String?
      fetch_named(group_name) { nil }
    end

    # Returns the named group *group_name*; raises `KeyError` when no group
    # of that name took part or the name does not exist.
    def [](group_name : String) : String
      fetch_named(group_name) do |exists|
        if exists
          raise KeyError.new("Capture group '#{group_name}' was not matched")
        else
          raise KeyError.new("Capture group '#{group_name}' does not exist")
        end
      end
    end

    # Returns the groups in *range*; raises `IndexError` when the range is
    # outside the groups or one of them did not take part.
    def [](range : Range) : Array(String)
      self[*Indexable.range_to_index_and_count(range, size) || raise IndexError.new]
    end

    # Returns the groups in *range*, or nil when it is outside the groups.
    def []?(range : Range) : Array(String)?
      self[*Indexable.range_to_index_and_count(range, size) || return nil]?
    end

    # Returns *count* groups from *start*.
    def [](start : Int, count : Int) : Array(String)
      self[start, count]? || raise IndexError.new
    end

    # Returns *count* groups from *start*, or nil when out of range.
    def []?(start : Int, count : Int) : Array(String)?
      start, count = Indexable.normalize_start_and_count(start, count, size) { return nil }
      Array(String).new(count) { |offset| self[start + offset] }
    end

    # Returns the haystack before the match.
    def pre_match : String
      @string.byte_slice(0, byte_begin(0))
    end

    # Returns the haystack after the match.
    def post_match : String
      @string.byte_slice(byte_end(0))
    end

    # Returns the unnamed groups (group 0 excluded).
    def captures : Array(String?)
      names = @regex.names_by_group
      list_of_captures = [] of String?
      (1...size).each do |group|
        list_of_captures << self[group]? unless names.has_key?(group)
      end
      list_of_captures
    end

    # Returns the named groups by name.
    def named_captures : Hash(String, String?)
      names = @regex.names_by_group
      captures_by_name = {} of String => String?
      (1...size).each do |group|
        if (name = names[group]?) && !captures_by_name.has_key?(name)
          captures_by_name[name] = self[name]?
        end
      end
      captures_by_name
    end

    # Returns every group, group 0 first.
    def to_a : Array(String?)
      (0...size).map { |group| self[group]? }
    end

    # Returns every group by name, or by number when unnamed.
    def to_h : Hash(Int32 | String, String?)
      names = @regex.names_by_group
      groups = {} of (String | Int32) => String?
      (0...size).each do |group|
        if name = names[group]?
          groups[name] = self[name]? unless groups.has_key?(name)
        else
          groups[group] = self[group]?
        end
      end
      groups
    end

    def inspect(io : IO) : Nil
      names = @regex.names_by_group
      io << "Mica::Regex::MatchData("
      size.times do |group|
        io << ' ' << names.fetch(group, group) << ':' if group > 0
        self[group]?.inspect(io)
      end
      io << ')'
    end

    # Returns the whole match.
    def to_s : String
      self[0]
    end

    def to_s(io : IO) : Nil
      io << to_s
    end

    def ==(other : MatchData) : Bool
      size == other.size && @regex == other.regex && @string == other.string &&
        @match_begin == other.match_begin && @match_end == other.match_end && same_groups?(other)
    end

    private def same_groups?(other : MatchData) : Bool
      (@group_size * 2).times { |index| return false unless group_offset(index) == other.group_offset(index) }
      true
    end

    def hash(hasher)
      hasher = @regex.hash(hasher)
      hasher = @string.hash(hasher)
      hasher = @match_begin.hash(hasher)
      hasher = @match_end.hash(hasher)
      (@group_size * 2).times { |index| hasher = group_offset(index).hash(hasher) }
      hasher
    end

    # :nodoc:
    protected def match_begin : Int32
      @match_begin
    end

    # :nodoc:
    protected def match_end : Int32
      @match_end
    end

    # :nodoc:
    # Entry *index* of groups 1 to `group_size` (begin and end pairs), read
    # now if it is still pending.
    @[AlwaysInline]
    protected def group_offset(index : Int32) : Int32
      deferred = @deferred
      unless deferred.null?
        offsets = (deferred + 1).as(Int32*)
        offset = offsets[index]
        return offset unless offset == GROUP_UNREAD
        read_groups(deferred.value, offsets)
        return offsets[index]
      end
      groups = @groups
      groups.empty? ? @inline_groups.unsafe_fetch(index) : groups[index]
    end

    # Reads the groups into the shared *offsets* (`2 * group_size` of
    # them). Every entry is one aligned 32-bit store of the same value
    # whichever fiber stores it, so a reader that sees an entry other than
    # `GROUP_UNREAD` sees its final value, and one that sees `GROUP_UNREAD`
    # reads the groups itself.
    private def read_groups(reader : GroupReader, offsets : Pointer(Int32)) : Nil
      @regex.program.plan.note_groups_read
      found = @regex.read_groups(@string, @byte_index, @match_begin, @match_end, reader.options, reader.limits,
        reader.timeout)
      (@group_size * 2).times { |index| offsets[index] = found[index + 2].to_i32 }
    end

    private def character_index(byte_index : Int32) : Int32
      @string.byte_index_to_char_index(byte_index) ||
        raise IndexError.new("Byte index #{byte_index} is not at a character boundary")
    end

    private def byte_range(n : Int, &)
      n += size if n < 0
      if n == 0
        first = @match_begin
        last = @match_end
      else
        first = group_offset(n * 2 - 2)
        last = group_offset(n * 2 - 1)
      end
      if first < 0 || last < 0
        yield n
      else
        first...last
      end
    end

    # :nodoc:
    # Group *n*'s bytes in the haystack, without a copy, or nil (as `#[]?`).
    def group_bytes?(n : Int) : Bytes?
      return unless valid_group?(n)
      range = byte_range(n) { return nil }
      @string.to_slice[range.begin, range.end - range.begin]
    end

    # :nodoc:
    # The bytes of the named group whose name is *group_name* (UTF-8), in
    # the haystack, without a copy, or nil (as `#[]?(String)`).
    def named_group_bytes?(group_name : Bytes) : Bytes?
      range = named_byte_range(group_name) { return nil }
      @string.to_slice[range.begin, range.end - range.begin]
    end

    private def fetch_named(group_name : String, &)
      range = named_byte_range(group_name) { |exists| return yield exists }
      @string.byte_slice(range.begin, range.end - range.begin)
    end

    # The byte range of the named group *group_name* that took part (the
    # last of duplicates, as PCRE2 selects); yields whether the name exists
    # when none did.
    private def named_byte_range(group_name : String | Bytes, &)
      selected = nil
      exists = false
      @regex.list_of_name_entries.each do |entry|
        next unless entry.group_name.to_slice == group_name.to_slice
        exists = true
        range = byte_range(entry.capture_index) { nil }
        if range && (selected.nil? || range.begin > selected.begin)
          selected = range
        end
      end
      selected || yield exists
    end

    private def check_index_out_of_bounds(index : Int) : Nil
      raise IndexError.new("Invalid capture group index: #{index}") unless valid_group?(index)
    end

    private def valid_group?(index : Int) : Bool
      -size <= index < size
    end

    private def raise_capture_group_was_not_matched(index : Int) : NoReturn
      raise IndexError.new("Capture group #{index} was not matched")
    end
  end
end

module Regex::Mica::Regex
  # :nodoc:
  # What reading the groups of a match found without them takes (see
  # `Expression#match_at_byte_index`): the limits, timeout and options of
  # the call that found it. Reading them is a capture pass over the match
  # alone, anchored at its start and cut at its end, under those limits (a
  # fresh allowance and, with a timeout, a fresh deadline): O(L + c) on the
  # one-pass DFA, O(m·(L + 1) + c) on the backtracker, O(m·c·(L + 1)) on the
  # Pike VM, for a match of L bytes.
  record GroupReader, limits : SearchLimits, timeout : Time::Span?, options : MatchOptions
end
