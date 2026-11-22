module Regex::Mica::Regex
  # A compiled regular expression, Mica's counterpart of Crystal's `Regex`.
  # Its method names and return types follow `Regex`, and its matches are
  # `Mica::Regex::MatchData` values that follow `Regex::MatchData`, so
  # moving code from stdlib `Regex` to Mica is mostly a type rename plus
  # the limits:
  #
  # - compiling takes a required `compile_limits:` (`CompileLimits`), and
  #   every search takes a required `limits:` (`SearchLimits`), with an
  #   optional wall-clock `timeout:`;
  # - the iteration methods Crystal puts on `String` (`scan`, `gsub`,
  #   `sub`, `split`) are methods of the expression that take the string;
  # - the native API does not set `$~` (and so `$1`); use the returned
  #   `MatchData`. The operators `=~` and `===` have no form that can take
  #   the required limits, so they are left out.
  #
  # Every search runs in time linear in the haystack (see `Searcher`,
  # `PikeVM` and `BoundedBacktracker` for the bounds) and fails with a
  # `SearchLimitError` instead of running past its limits. The haystack
  # must be valid UTF-8 (`Mica::EncodingError` otherwise; the
  # `MatchInvalidUtf` mode arrives in milestone R4).
  #
  # An expression is immutable and can be shared between fibers; each call
  # allocates its own workspace.
  #
  # ```
  # date = Mica::Regex::Expression.new("(?<year>\\d{4})-(?<month>\\d{2})",
  #   compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  # limits = Mica::Regex::SearchLimits::REQUEST
  # match = date.match("due 2026-11", limits: limits)
  # match.try(&.["year"])                                                    # => "2026"
  # date.gsub("2026-11 and 2027-01", "\\k<month>/\\k<year>", limits: limits) # => "11/2026 and 01/2027"
  # ```
  class Expression
    # The pattern as written.
    getter source : String
    # The options it was compiled with.
    getter options : CompileOptions
    # The dialect it was read in.
    getter dialect : Dialect
    # :nodoc:
    getter program : Program
    # Named groups in PCRE2 name-table order: sorted by name (byte order),
    # duplicates of a name in pattern order, one entry per name and number.
    getter list_of_name_entries : Array(Ast::GroupName)

    # Compiles *source* under *compile_limits*. Raises `SyntaxError` (or
    # `UnsupportedConstructError`) for a pattern the dialect rejects or
    # leaves out, and `CompileLimitError` when a limit trips.
    def initialize(@source : String, @options : CompileOptions = CompileOptions::None, *,
                   compile_limits : CompileLimits, @dialect : Dialect = Dialect::Crystal,
                   @cache_pool : CachePool = CachePool.default)
      if @options.match_invalid_utf?
        raise ArgumentError.new("CompileOptions::MatchInvalidUtf arrives in Mica::Regex milestone R4")
      end
      @program = Syntax.compile(@source, dialect: @dialect, compile_limits: compile_limits, options: @options)
      list_of_group_names = @program.list_of_group_names
      if list_of_group_names.empty?
        # Most patterns name no group: they share one empty table, read only.
        @list_of_name_entries = list_of_group_names
        @names_by_group = NO_GROUP_NAMES
      else
        @list_of_name_entries = Expression.name_entries(list_of_group_names)
        @names_by_group = {} of Int32 => String
        @list_of_name_entries.each { |entry| @names_by_group[entry.capture_index] = entry.group_name }
      end
    end

    # The group-name table of every pattern without named groups (never
    # changed: `name_table` hands out copies).
    Mica::Regex.static_constant(NO_GROUP_NAMES, Hash(Int32, String))

    # The name table entries of *list_of_group_names*, in PCRE2 order.
    protected def self.name_entries(list_of_group_names : Array(Ast::GroupName)) : Array(Ast::GroupName)
      seen = Set({String, Int32}).new
      unique = list_of_group_names.select { |entry| seen.add?({entry.group_name, entry.capture_index}) }
      unique.each_with_index.to_a.sort! do |(left, left_index), (right, right_index)|
        order = left.group_name.to_slice <=> right.group_name.to_slice
        order == 0 ? left_index <=> right_index : order
      end.map(&.[0])
    end

    # Returns the number of capturing groups.
    def capture_count : Int32
      @program.capture_count
    end

    # Returns a hash from group number to name for every named group (a
    # new hash each call, as `Regex#name_table` returns).
    def name_table : Hash(Int32, String)
      @names_by_group.dup
    end

    # :nodoc:
    # The name table without the copy, for `MatchData`.
    protected def names_by_group : Hash(Int32, String)
      @names_by_group
    end

    # Returns the first match in *string* at or after character index
    # *pos*, or nil (also when *pos* is negative or past the end).
    #
    # Character 0 is byte 0, so that call is `match_at_byte_index`. Any
    # other *pos* opens the searcher first, which reads the deadline and
    # validates the haystack, and the searcher finds the byte index of
    # *pos* under the call's meter (`Searcher#byte_index_of_char`).
    def match(string : String, pos : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
              limits : SearchLimits, timeout : Time::Span? = nil) : MatchData?
      return match_at_byte_index(string, 0, options, limits: limits, timeout: timeout) if pos == 0
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      byte_index = searcher.byte_index_of_char(pos)
      return nil unless byte_index
      find_match(searcher, string, byte_index, options, limits, timeout)
    ensure
      searcher.try(&.finish)
    end

    # Like `match`, but raises `MatchNotFoundError` when nothing matches.
    def match!(string : String, pos : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
               limits : SearchLimits, timeout : Time::Span? = nil) : MatchData
      match(string, pos, options, limits: limits, timeout: timeout) || raise MatchNotFoundError.new("Match not found")
    end

    # Returns the first match in *string* at or after byte *byte_index*, or
    # nil (also when *byte_index* is past the end). Raises `ArgumentError`
    # when *byte_index* is negative or inside a character.
    #
    # When the pattern's groups need more than the one-pass DFA to read
    # (see `SearchPlan#defers_groups?`), the match is found without them
    # and the groups are read the first time they are asked for: a capture
    # pass over the match alone, under *limits* and *timeout* again (see
    # `GroupReader`). A caller that only asks whether and where it
    # matched never pays for them.
    def match_at_byte_index(string : String, byte_index : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
                            limits : SearchLimits, timeout : Time::Span? = nil) : MatchData?
      if FirstSearch.applies?(@program, string, byte_index, limits)
        searcher = Searcher.first_search(@program, string, limits, timeout, @cache_pool)
        found = searcher.find(byte_index, options, true)
        return found ? MatchData.new(self, string, byte_index, found) : nil
      end
      # Slots and scratch on the stack for the short and candidate searches:
      # `ShortSearch::MAX_SLOTS` each (both decline a program with more).
      buffer = uninitialized StaticArray(Int64, 32)
      # The work a candidate search did before it declined.
      spent = 0_i64
      short = ShortSearch.new(@program, string, byte_index, options, limits, timeout)
      if short.applies?
        plan = @program.plan
        return nil if short.rejects?(plan)
        slot_count = Math.min(@program.slot_count, ShortSearch::MAX_SLOTS)
        slots = Slice.new(buffer.to_unsafe, slot_count)
        scratch = Slice.new(buffer.to_unsafe + ShortSearch::MAX_SLOTS, slot_count)
        finish = short.run(plan, slots, scratch)
        return nil if finish == LazyDFA::NO_MATCH
        return MatchData.new(self, string, byte_index, slots) unless finish == LazyDFA::GAVE_UP
      elsif timeout.nil?
        candidates = CandidateSearch.new(@program, @program.plan, string, byte_index, options, limits, timeout)
        if one_pass = candidates.one_pass
          slots = Slice.new(buffer.to_unsafe, @program.slot_count)
          scratch = Slice.new(buffer.to_unsafe + ShortSearch::MAX_SLOTS, @program.slot_count)
          finish = candidates.run(one_pass, slots, scratch)
          return nil if finish == LazyDFA::NO_MATCH
          return MatchData.new(self, string, byte_index, slots) unless finish == LazyDFA::GAVE_UP
          spent = candidates.spent
        end
      end
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      searcher.note_required_bytes_present(byte_index) if short.screened?
      # The work a candidate search did before it declined counts against
      # the call's allowance.
      searcher.meter.charge(spent, byte_index) if spent > 0
      find_match(searcher, string, byte_index, options, limits, timeout)
    ensure
      searcher.try(&.finish)
    end

    # The first match *searcher* finds in *string* from *byte_index*, with
    # its groups read now or left to `GroupReader`.
    private def find_match(searcher : Searcher, string : String, byte_index : Int32, options : MatchOptions,
                           limits : SearchLimits, timeout : Time::Span?) : MatchData?
      if searcher.defers_groups?
        found = searcher.find(byte_index, options, false)
        return nil unless found
        reader = GroupReader.new(limits, timeout, options)
        MatchData.new(self, string, byte_index, found[0].to_i32, found[1].to_i32, reader)
      else
        found = searcher.find(byte_index, options, true)
        found ? MatchData.new(self, string, byte_index, found) : nil
      end
    end

    # :nodoc:
    # The slots of the match *match_begin*...*match_end* that a search of
    # *string* from *byte_index* found, read by a capture pass over the
    # match alone (see `GroupReader`). *string* was validated by that
    # search, so it is not validated again.
    def read_groups(string : String, byte_index : Int32, match_begin : Int32, match_end : Int32,
                    options : MatchOptions, limits : SearchLimits, timeout : Time::Span?) : Slice(Int64)
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool, validated: true)
      searcher.read_groups(byte_index, match_begin, match_end, options)
    ensure
      searcher.try(&.finish)
    end

    # Returns the first match in *haystack* at or after byte *byte_offset*,
    # or nil: `match_at_byte_index` under the name the native API design
    # gives it (roadmap 6.2.6), with *deadline* as the timeout.
    def search(haystack : String, byte_offset : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
               limits : SearchLimits, deadline : Time::Span? = nil) : MatchData?
      match_at_byte_index(haystack, byte_offset, options, limits: limits, timeout: deadline)
    end

    # Returns the span of the first match in *haystack* at or after byte
    # *byte_offset*, or nil, without reading its groups. Once the expression
    # has adapted (its plan and caches are built over its first searches),
    # a call allocates nothing. Raises as `search` does.
    #
    # ```
    # number = Mica::Regex.compile("[0-9]+", dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
    # number.search_span("id 2026", limits: Mica::Regex::SearchLimits::REQUEST) # => Mica::Regex::Span(@byte_begin=3, @byte_end=7)
    # ```
    def search_span(haystack : String, byte_offset : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
                    limits : SearchLimits, deadline : Time::Span? = nil) : Span?
      span = nil
      find_slots(haystack, byte_offset, options, limits, deadline, false) do |slots|
        span = Span.new(slots[0].to_i32, slots[1].to_i32)
      end
      span
    end

    # Finds the first match in *haystack* at or after byte *byte_offset*
    # with its groups, yields them as `Groups`, and returns the block's
    # value, or nil when nothing matches. The groups are copied into
    # `Groups::STACK_SLOTS` slots in the caller's stack frame (a pattern with
    # more groups uses a heap buffer), so once the expression has adapted a
    # call allocates nothing beyond what the block does. Raises as `search`
    # does.
    #
    # ```
    # date = Mica::Regex.compile("(\\d{4})-(\\d{2})", dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
    # date.search_groups("due 2026-11", limits: Mica::Regex::SearchLimits::REQUEST) { |groups| groups.byte_begin(2) } # => 9
    # ```
    def search_groups(haystack : String, byte_offset : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
                      limits : SearchLimits, deadline : Time::Span? = nil, & : Groups -> _)
      storage = uninitialized StaticArray(Int32, Groups::STACK_SLOTS)
      slot_count = @program.slot_count
      slots = slot_count <= Groups::STACK_SLOTS ? Slice.new(storage.to_unsafe, slot_count) : Slice(Int32).new(slot_count)
      found = find_slots(haystack, byte_offset, options, limits, deadline, true) do |found_slots|
        slot_count.times { |index| slots[index] = found_slots[index].to_i32 }
      end
      return nil unless found
      yield Groups.new(haystack, slots)
    end

    # Yields the span of each successive match in *haystack*, as
    # `each_match` finds them (after an empty match the next search starts
    # one character later), without reading groups. All searches share one
    # work allowance and one deadline, and once the expression has adapted
    # the call allocates nothing.
    def each_span(haystack : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
                  deadline : Time::Span? = nil, & : Span ->) : Nil
      searcher = Searcher.open(@program, haystack, limits, deadline, @cache_pool)
      byte_offset = 0
      while found = searcher.find(byte_offset, options, false)
        span = Span.new(found[0].to_i32, found[1].to_i32)
        yield span
        byte_offset = span.byte_end
        byte_offset += char_bytesize_at(haystack, byte_offset) if span.empty?
      end
    ensure
      searcher.try(&.finish)
    end

    # Runs one search of *string* from *byte_index* on the fastest path the
    # call allows (as `match_at_byte_index` does, without deferring
    # groups), yields the found slots (group 0 only unless *captures*;
    # valid only inside the block, which must not search again), and
    # returns true; returns false when nothing matches.
    private def find_slots(string : String, byte_index : Int32, options : MatchOptions, limits : SearchLimits,
                           timeout : Time::Span?, captures : Bool, & : Slice(Int64) ->) : Bool
      if FirstSearch.applies?(@program, string, byte_index, limits)
        searcher = Searcher.first_search(@program, string, limits, timeout, @cache_pool)
        found = searcher.find(byte_index, options, captures)
        return false unless found
        yield found
        return true
      end
      # Slots and scratch on the stack for the short and candidate searches:
      # `ShortSearch::MAX_SLOTS` each (both decline a program with more).
      buffer = uninitialized StaticArray(Int64, 32)
      # The work a candidate search did before it declined.
      spent = 0_i64
      short = ShortSearch.new(@program, string, byte_index, options, limits, timeout)
      if short.applies?
        plan = @program.plan
        return false if short.rejects?(plan)
        slot_count = Math.min(@program.slot_count, ShortSearch::MAX_SLOTS)
        slots = Slice.new(buffer.to_unsafe, slot_count)
        scratch = Slice.new(buffer.to_unsafe + ShortSearch::MAX_SLOTS, slot_count)
        finish = short.run(plan, slots, scratch)
        return false if finish == LazyDFA::NO_MATCH
        unless finish == LazyDFA::GAVE_UP
          yield slots
          return true
        end
      elsif timeout.nil?
        candidates = CandidateSearch.new(@program, @program.plan, string, byte_index, options, limits, timeout)
        if one_pass = candidates.one_pass
          slots = Slice.new(buffer.to_unsafe, @program.slot_count)
          scratch = Slice.new(buffer.to_unsafe + ShortSearch::MAX_SLOTS, @program.slot_count)
          finish = candidates.run(one_pass, slots, scratch)
          return false if finish == LazyDFA::NO_MATCH
          unless finish == LazyDFA::GAVE_UP
            yield slots
            return true
          end
          spent = candidates.spent
        end
      end
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      # The work a candidate search did before it declined counts against
      # the call's allowance.
      searcher.meter.charge(spent, byte_index) if spent > 0
      found = searcher.find(byte_index, options, captures)
      return false unless found
      yield found
      true
    ensure
      searcher.try(&.finish)
    end

    # Returns true when *string* has a match at or after character index
    # *pos*. Stops at the first match it reaches. A *pos* other than 0 is
    # read as `match` reads it.
    def matches?(string : String, pos : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
                 limits : SearchLimits, timeout : Time::Span? = nil) : Bool
      return matches_at_byte_index?(string, 0, options, limits: limits, timeout: timeout) if pos == 0
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      byte_index = searcher.byte_index_of_char(pos)
      return false unless byte_index
      searcher.matches?(byte_index, options)
    ensure
      searcher.try(&.finish)
    end

    # Returns true when *string* has a match at or after byte *byte_index*.
    def matches_at_byte_index?(string : String, byte_index : Int32 = 0, options : MatchOptions = MatchOptions::None, *,
                               limits : SearchLimits, timeout : Time::Span? = nil) : Bool
      if FirstSearch.applies?(@program, string, byte_index, limits)
        searcher = Searcher.first_search(@program, string, limits, timeout, @cache_pool)
        return !searcher.find(byte_index, options, false).nil?
      end
      short = ShortSearch.new(@program, string, byte_index, options, limits, timeout)
      return false if short.applies? && short.rejects?(@program.plan)
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      searcher.matches?(byte_index, options)
    ensure
      searcher.try(&.finish)
    end

    # Yields each successive match in *string*, as `String#scan` finds
    # them: after an empty match the next search starts one character
    # later. All searches share the call's work allowance.
    def each_match(string : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
                   timeout : Time::Span? = nil, & : MatchData ->) : Nil
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      byte_offset = 0
      while found = searcher.find(byte_offset, options, true)
        match = MatchData.new(self, string, byte_offset, found)
        yield match
        index = match.byte_begin(0)
        match_bytesize = match.byte_end(0) - index
        match_bytesize += char_bytesize_at(string, index) if match_bytesize == 0
        byte_offset = index + match_bytesize
      end
    ensure
      searcher.try(&.finish)
    end

    # Yields each successive match in *string* (as `each_match`) and
    # returns *string*, like `String#scan(Regex, &)`.
    def scan(string : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
             timeout : Time::Span? = nil, & : MatchData ->) : String
      each_match(string, options, limits: limits, timeout: timeout) { |match| yield match }
      string
    end

    # Returns every successive match in *string*, like
    # `String#scan(Regex)`.
    def scan(string : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
             timeout : Time::Span? = nil) : Array(MatchData)
      list_of_matches = [] of MatchData
      each_match(string, options, limits: limits, timeout: timeout) { |match| list_of_matches << match }
      list_of_matches
    end

    # Replaces every match in *string* with the block's value (its
    # `to_s`), like `String#gsub(Regex, &)`. The block gets the matched
    # text and the match. Raises `SearchLimitError` naming
    # `max_output_bytes` when the result would pass it.
    def gsub(string : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
             timeout : Time::Span? = nil, & : String, MatchData -> _) : String
      replace(string, options, limits, timeout, true) do |matched, match, buffer, output|
        write_block_value(buffer, output, yield matched, match)
      end
    end

    # Replaces every match with *replacement*. With *backreferences*,
    # `\0`..`\9` insert a group, `\k<name>` a named group and `\\` a
    # backslash, as in `String#gsub(Regex, String)`.
    def gsub(string : String, replacement : String, backreferences : Bool = true,
             options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
             timeout : Time::Span? = nil) : String
      replace(string, options, limits, timeout, true) do |_, match, buffer, output|
        write_replacement(buffer, output, replacement, match, backreferences)
      end
    end

    # Replaces every match with the value *hash* has for the matched text
    # (nothing when it has none), like `String#gsub(Regex, Hash)`.
    def gsub(string : String, hash : Hash(String, _) | NamedTuple, options : MatchOptions = MatchOptions::None, *,
             limits : SearchLimits, timeout : Time::Span? = nil) : String
      gsub(string, options, limits: limits, timeout: timeout) { |matched| hash[matched]? }
    end

    # Replaces the first match with the block's value, like
    # `String#sub(Regex, &)`.
    def sub(string : String, options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
            timeout : Time::Span? = nil, & : String, MatchData -> _) : String
      replace(string, options, limits, timeout, false) do |matched, match, buffer, output|
        write_block_value(buffer, output, yield matched, match)
      end
    end

    # Replaces the first match with *replacement* (backreferences as in
    # `gsub`).
    def sub(string : String, replacement : String, backreferences : Bool = true,
            options : MatchOptions = MatchOptions::None, *, limits : SearchLimits,
            timeout : Time::Span? = nil) : String
      replace(string, options, limits, timeout, false) do |_, match, buffer, output|
        write_replacement(buffer, output, replacement, match, backreferences)
      end
    end

    # Replaces the first match with the value *hash* has for it.
    def sub(string : String, hash : Hash(String, _) | NamedTuple, options : MatchOptions = MatchOptions::None, *,
            limits : SearchLimits, timeout : Time::Span? = nil) : String
      sub(string, options, limits: limits, timeout: timeout) { |matched| hash[matched]? }
    end

    # Splits *string* at each match, like `String#split(Regex)`: captured
    # groups are included, at most *limit* pieces are made, and empty
    # pieces are dropped with *remove_empty*. Raises `SearchLimitError`
    # naming `max_output_bytes` when the pieces would pass it.
    def split(string : String, limit : Int32? = nil, *, remove_empty : Bool = false,
              options : MatchOptions = MatchOptions::None, limits : SearchLimits,
              timeout : Time::Span? = nil) : Array(String)
      list_of_pieces = [] of String
      split(string, limit, remove_empty: remove_empty, options: options, limits: limits, timeout: timeout) do |piece|
        list_of_pieces << piece
      end
      list_of_pieces
    end

    # Yields each piece of `split`.
    def split(string : String, limit : Int32? = nil, *, remove_empty : Bool = false,
              options : MatchOptions = MatchOptions::None, limits : SearchLimits,
              timeout : Time::Span? = nil, & : String ->) : Nil
      # The searcher validates and charges the haystack and reads the
      # deadline before any shortcut below.
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      output = OutputMeter.new(limits.max_output_bytes)
      if string.empty?
        yield "" unless remove_empty
        return
      end
      if limit && limit <= 1
        output.add(string.bytesize)
        yield string
        return
      end
      if @source.empty?
        split_by_character(string, limit, searcher.meter, output) { |piece| yield piece }
        return
      end
      count = 0
      match_offset = slice_offset = 0
      while found = searcher.find(match_offset, options, true)
        match = MatchData.new(self, string, match_offset, found)
        index = match.byte_begin(0)
        next_offset = match.byte_end(0)
        if next_offset == slice_offset
          match_offset = next_offset + char_bytesize_at(string, next_offset)
        else
          slice_size = index - slice_offset
          unless remove_empty && slice_size == 0
            output.add(slice_size)
            yield string.byte_slice(slice_offset, slice_size)
          end
          count += 1
          1.upto(match.size - 1) do |group|
            if piece = match[group]?
              output.add(piece.bytesize)
              yield piece
            end
          end
          slice_offset = match_offset = next_offset
        end
        break if limit && count + 1 == limit
        break if match_offset >= string.bytesize
      end
      unless remove_empty && slice_offset == string.bytesize
        output.add(string.bytesize - slice_offset)
        yield string.byte_slice(slice_offset)
      end
    ensure
      searcher.try(&.finish)
    end

    # Splits *string* into its characters (the empty pattern), charging one
    # operation per character to *meter* before its bytes are read. The
    # searcher validated *string*, so each character's length is read from
    # its lead byte.
    private def split_by_character(string : String, limit : Int32?, meter : SearchMeter, output : OutputMeter,
                                   & : String ->) : Nil
      bytes = string.to_slice
      yielded = 0
      byte_index = 0
      while byte_index < bytes.size
        if limit && yielded + 1 == limit
          output.add(bytes.size - byte_index)
          yield string.byte_slice(byte_index)
          return
        end
        meter.charge(1, byte_index)
        char_bytesize = Core::UTF8.sequence_length(bytes.unsafe_fetch(byte_index))
        output.add(char_bytesize)
        yield string.byte_slice(byte_index, char_bytesize)
        byte_index += char_bytesize
        yielded += 1
      end
    end

    # Copies *string* with its matches (every match, or the first)
    # replaced by what the block writes.
    private def replace(string : String, options : MatchOptions, limits : SearchLimits, timeout : Time::Span?,
                        every : Bool, & : String, MatchData, IO, OutputMeter ->) : String
      searcher = Searcher.open(@program, string, limits, timeout, @cache_pool)
      byte_offset = 0
      found = searcher.find(byte_offset, options, true)
      return string unless found
      output = OutputMeter.new(limits.max_output_bytes)
      last_byte_offset = 0
      # The buffer starts no larger than the output may grow.
      capacity = Math.min(string.bytesize.to_i64, limits.max_output_bytes).clamp(64_i64, Int32::MAX.to_i64).to_i32
      String.build(capacity) do |buffer|
        while found
          match = MatchData.new(self, string, byte_offset, found)
          index = match.byte_begin(0)
          output.add(index - last_byte_offset)
          buffer.write(string.to_slice[last_byte_offset, index - last_byte_offset])
          matched = match[0]
          yield matched, match, buffer, output
          if matched.bytesize == 0
            byte_offset = index + char_bytesize_at(string, index)
            last_byte_offset = index
          else
            byte_offset = index + matched.bytesize
            last_byte_offset = byte_offset
          end
          break unless every
          found = searcher.find(byte_offset, options, true)
        end
        if last_byte_offset < string.bytesize
          output.add(string.bytesize - last_byte_offset)
          buffer.write(string.to_slice[last_byte_offset..])
        end
      end
    ensure
      searcher.try(&.finish)
    end

    # Writes the `to_s` of a replacement block's *value*, charging its size
    # to *output* before it reaches *buffer*.
    private def write_block_value(buffer : IO, output : OutputMeter, value) : Nil
      text = value.to_s
      output.add(text.bytesize)
      buffer << text
    end

    # Writes *replacement* with its backreferences expanded, as
    # `String#scan_backreferences` does. Every literal run and every group is
    # charged to *output* before it reaches *buffer*, so a replacement that
    # multiplies the input stops at `max_output_bytes` instead of after the
    # result is built.
    private def write_replacement(buffer : IO, output : OutputMeter, replacement : String, match : MatchData,
                                  backreferences : Bool) : Nil
      bytes = replacement.to_slice
      unless backreferences
        write_charged(buffer, output, bytes)
        return
      end
      first_index = 0
      index = 0
      while backslash = bytes.index('\\'.ord.to_u8, index)
        index = backslash + 1
        break if index >= bytes.size
        char = bytes[index].unsafe_chr
        case char
        when '\\'
          write_charged(buffer, output, bytes[first_index, index - first_index])
          index += 1
          first_index = index
        when '0'..'9'
          write_charged(buffer, output, bytes[first_index, index - 1 - first_index])
          if group = match.group_bytes?(char - '0')
            write_charged(buffer, output, group)
          end
          index += 1
          first_index = index
        when 'k'
          index += 1
          next unless index < bytes.size && bytes[index] == '<'.ord
          write_charged(buffer, output, bytes[first_index, index - 2 - first_index])
          index += 1
          start_index = index
          end_index = bytes.index('>'.ord.to_u8, start_index)
          raise ArgumentError.new("Missing ending '>' for '\\\\k<...'") unless end_index
          name = bytes[start_index, end_index - start_index]
          capture = match.named_group_bytes?(name)
          unless capture
            raise IndexError.new("Undefined group name reference: #{String.new(name).inspect}")
          end
          write_charged(buffer, output, capture)
          index = end_index + 1
          first_index = index
        end
      end
      write_charged(buffer, output, bytes[first_index..]) if first_index < bytes.size
    end

    private def write_charged(buffer : IO, output : OutputMeter, piece : Bytes) : Nil
      output.add(piece.bytesize)
      buffer.write(piece)
    end

    private def char_bytesize_at(string : String, byte_index : Int32) : Int32
      return 1 if byte_index >= string.bytesize
      Core::UTF8.sequence_length(string.to_slice[byte_index])
    end

    def ==(other : Expression) : Bool
      @source == other.source && @options == other.options && @dialect == other.dialect
    end

    def hash(hasher)
      hasher = @source.hash(hasher)
      hasher = @options.hash(hasher)
      @dialect.hash(hasher)
    end

    # Writes the expression as an inline-option group that carries every
    # option with an inline form, setting the ones it has and clearing the
    # rest, so the text means the same inside any other pattern: `c` under
    # `IgnoreCase` is `(?i-mnrsxUa:c)`. Crystal's `Regex#to_s` writes only
    # `imsx`; Mica writes `n`, `r`, `U`, `xx` and PCRE2's `(?aD)`, `(?aS)`,
    # `(?aW)`, `(?aP)` and `(?aT)` too. Options with no inline form (see
    # `CompileOptions::INLINE`) are left out; `Mica::Regex.union_source`
    # refuses them.
    def to_s(io : IO) : Nil
      options = @options
      io << "(?"
      io << 'i' if options.ignore_case?
      io << 'm' if options.multiline?
      io << 'n' if options.no_auto_capture?
      io << 'r' if options.caseless_restrict?
      io << 's' if options.dot_all?
      io << (options.extended_more? ? "xx" : "x") if options.extended? || options.extended_more?
      io << 'U' if options.ungreedy?
      write_ascii_options(io, options)
      io << '-'
      io << 'i' unless options.ignore_case?
      io << 'm' unless options.multiline?
      io << 'n' unless options.no_auto_capture?
      io << 'r' unless options.caseless_restrict?
      io << 's' unless options.dot_all?
      io << 'x' unless options.extended? || options.extended_more?
      io << 'U' unless options.ungreedy?
      write_ascii_options(io, ~options & CompileOptions::ASCII_ALL)
      io << ':'
      # `aP` sets and clears `AsciiDigit` with `AsciiPosix`, so `AsciiDigit`
      # alone is cleared by `-aP` above and set again here.
      io << "(?aT)" if options.ascii_digit? && !options.ascii_posix?
      io << @source
      case @program.source_end
      when .in_comment? then io << '\n'
      when .in_quote?   then io << "\\E"
      end
      io << ')'
    end

    # Writes the `a` letters that name the ASCII options in *options*, for
    # the set half or the cleared half of an option group: `a` alone for
    # all five, else `aD`, `aS`, `aW`, then `aP` (which takes `AsciiDigit`
    # with it) or `aT`.
    private def write_ascii_options(io : IO, options : CompileOptions) : Nil
      ascii = options & CompileOptions::ASCII_ALL
      return if ascii.none?
      if ascii == CompileOptions::ASCII_ALL
        io << 'a'
        return
      end
      io << "aD" if ascii.ascii_backslash_d?
      io << "aS" if ascii.ascii_backslash_s?
      io << "aW" if ascii.ascii_backslash_w?
      if ascii.ascii_posix?
        io << "aP"
      elsif ascii.ascii_digit?
        io << "aT"
      end
    end

    def inspect(io : IO) : Nil
      io << "Mica::Regex::Expression(" << @source.inspect << ", " << @options << ')'
    end

    # The bytes `gsub`, `sub` and `split` produce, against
    # `SearchLimits#max_output_bytes`.
    private class OutputMeter
      def initialize(@limit : Int64)
        @bytes = 0_i64
      end

      def add(count : Int) : Nil
        @bytes += count
        return if @bytes <= @limit
        raise SearchLimitError.new("max_output_bytes", @limit, "An output of #{@bytes} bytes",
          Core::Position.new(0_i64))
      end
    end
  end

  # Compiles *pattern* in *dialect* under *compile_limits* (see
  # `Expression.new`).
  def self.compile(pattern : String, *, dialect : Dialect, compile_limits : CompileLimits,
                   options : CompileOptions = CompileOptions::None) : Expression
    Expression.new(pattern, options, compile_limits: compile_limits, dialect: dialect)
  end

  # The characters `escape` puts a backslash before (Crystal's
  # `Regex::SPECIAL_CHARACTERS`).
  SPECIAL_CHARACTERS = {' ', '.', '\\', '+', '*', '?', '[', '^', ']', '$', '(', ')', '{', '}', '=', '!', '<', '>',
                        '|', ':', '-'}

  # Returns *text* with every special character escaped, so it matches
  # itself as a pattern (Crystal's `Regex.escape`).
  def self.escape(text : String) : String
    String.build(text.bytesize) do |result|
      text.each_byte do |byte|
        result << '\\' if byte < 0x80 && SPECIAL_CHARACTERS.includes?(byte.unsafe_chr)
        result.write_byte(byte)
      end
    end
  end

  # Returns true when *text* contains a special character.
  def self.needs_escape?(text : String) : Bool
    text.each_char { |char| return true if SPECIAL_CHARACTERS.includes?(char) }
    false
  end

  # Returns the source of an expression that matches any of *patterns*:
  # strings are escaped, expressions keep their options as inline groups
  # (Crystal's `Regex.union`), so the result matches exactly what each
  # member matches. Compile it with the limits that fit.
  #
  # Raises `ArgumentError` for an expression whose options have no inline
  # form (`Anchored`, `FirstLine`, `DollarEndOnly`, `EndAnchored`,
  # `MatchInvalidUtf`): its text alone would match differently.
  def self.union_source(patterns : Enumerable(Expression | String)) : String
    patterns.join('|') do |pattern|
      if pattern.is_a?(String)
        escape(pattern)
      else
        outside = pattern.options & ~CompileOptions::INLINE
        unless outside.none?
          raise ArgumentError.new("#{pattern.inspect} has options with no inline form (#{outside}), so it cannot join a union")
        end
        pattern.to_s
      end
    end
  end
end
