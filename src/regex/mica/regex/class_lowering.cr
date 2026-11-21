module Regex::Mica::Regex
  # Lowers syntax-tree classes and case-folded literals to `CodePointSet`s,
  # with case folding chosen per dialect:
  #
  # - **Crystal (PCRE2):** under `IgnoreCase`, only literal characters and
  #   ranges are closed over their simple case folding orbits; `\d`, `\w`,
  #   `\s`, `\p{...}` and POSIX classes are not folded (PCRE2 turns `Lu`,
  #   `Ll` and `Lt` into `L&` instead, at parse time). `CaselessRestrict`
  #   keeps ASCII and non-ASCII characters apart. Negation applies after
  #   folding.
  # - **ECMA-262 (`u` mode):** every member of the class is closed over the
  #   orbits (`Canonicalize` is simple case folding), escapes included, so
  #   `/[\w]/iu` gains U+017F and U+212A. Negation applies after folding.
  # - **XSD:** no case-insensitive mode exists; nothing is folded.
  #
  # Sets are merged in one pass over all members (a heap of sorted range
  # streams, one per distinct member, so repeating `\p{L}` costs no more
  # merge work than writing it once), and the result is refused with
  # `CompileLimitError` naming `max_class_ranges` as soon as it would grow
  # past the limit. Every allocation is charged to the `AllocationLedger`
  # before it is made, and every heap step to the work meter with the
  # heap's depth.
  module ClassLowering
    # Lowers *char_class* for *dialect*.
    #
    # A class of one escape or property (`\w`, `\p{L}`, `[^\d]`) that
    # case folding leaves alone lowers to a set shared by the process:
    # it is lowered once and the same set object comes back afterward, so
    # the class costs no merge and its compiled automaton (`ClassMemo`) is
    # found by the set's digest. A shared set larger than the caller's
    # `max_class_ranges` is lowered again, so the refusal is the same.
    def self.lower(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits, ledger : AllocationLedger,
                   meter : Core::WorkMeter) : CodePointSet
      items = char_class.list_of_items
      item = items.first?
      unless items.size == 1 && item && !item.item_kind.range? && !(char_class.options.ignore_case? && dialect.ecma262?)
        return lower_written_class(char_class, dialect, limits, ledger, meter)
      end
      key = {item, char_class.negated?}
      shared = @@shared_mutex.synchronize { @@shared_sets[key]? }
      return shared if shared && shared.range_count <= limits.max_class_ranges
      set = lower_items(char_class, dialect, limits, ledger, meter)
      @@shared_mutex.synchronize { @@shared_sets[key] ||= set }
    end

    # The shared sets of single-item classes, by item and negation. There
    # are at most two per escape and property, so the table stays small.
    # The lock and the tables are static objects, so a program that never
    # compiles a class pays nothing for them.
    Mica::Regex.static_object(shared_mutex, Mutex)
    Mica::Regex.static_object(shared_sets, Hash({Ast::ClassItem, Bool}, CodePointSet))

    # The most items a class may have for its lowering to be kept in
    # `@@written_sets`, and the most classes kept there.
    WRITTEN_CLASS_ITEMS =  32
    WRITTEN_CLASSES     = 512

    # What a written class lowers from: its items, negation, whether it is
    # folded and restricted, and the dialect.
    private alias WrittenClassKey = {Array(Ast::ClassItem), Bool, Bool, Bool, Dialect}

    # Lowers a class of several items or of ranges (`[0-9a-f]`,
    # `[\w.-]`). Under `IgnoreCase` its ranges are closed over their fold
    # orbits, which reads the fold table member by member, and a pattern
    # often writes the same class many times (`[0-9a-f]{8}-[0-9a-f]{4}`),
    # so the sets of classes up to `WRITTEN_CLASS_ITEMS` items are kept
    # for the process (up to `WRITTEN_CLASSES` of them; a full table is
    # emptied and filled again, so the classes a process keeps compiling
    # stay in it). The same set object comes back for
    # the same class, so `ClassMemo` finds its automaton by identity. A
    # kept set larger than the caller's `max_class_ranges` is lowered
    # again, so the refusal is the same.
    private def self.lower_written_class(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits,
                                         ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet
      items = char_class.list_of_items
      return lower_items(char_class, dialect, limits, ledger, meter) if items.size > WRITTEN_CLASS_ITEMS
      options = char_class.options
      folding = options.ignore_case? && !dialect.xsd?
      restricted = folding && options.caseless_restrict? && dialect.crystal?
      key = {items, char_class.negated?, folding, restricted, dialect}
      written = @@shared_mutex.synchronize { @@written_sets[key]? }
      return written if written && written.range_count <= limits.max_class_ranges
      set = lower_items(char_class, dialect, limits, ledger, meter)
      @@shared_mutex.synchronize do
        kept = @@written_sets[key]?
        return kept if kept && kept.range_count <= limits.max_class_ranges
        @@written_sets.clear if @@written_sets.size >= WRITTEN_CLASSES
        @@written_sets[key] = set
      end
      set
    end

    Mica::Regex.static_object(written_sets, Hash(WrittenClassKey, CodePointSet))

    # The ranges, the bounds merged from them and the fold partners are
    # scratch outside the collector's heap, freed when the set is made;
    # the context lives in this call's stack frame.
    private def self.lower_items(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits,
                                 ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet
      ledger.charge_object(instance_sizeof(Context), "a class lowering", char_class.offset)
      context = Mica::Regex.stack_object(Context, char_class.offset, limits, ledger, meter)
      options = char_class.options
      folding = options.ignore_case? && !dialect.xsd?
      restricted = options.caseless_restrict? && dialect.crystal?
      context.charge_array(0, 8)
      list_of_ranges = OffHeapList({Int32, Int32}).new
      context.charge_array(0, 8)
      list_of_streams = [] of RangeStream
      context.charge_hash
      # The members seen so far: the first one alone, then a set once a
      # second arrives (most classes have one).
      first_item = nil
      seen_items = nil
      char_class.list_of_items.each do |item|
        context.charge_work(1)
        if item.item_kind.range?
          context.charge_append(sizeof({Int32, Int32}))
          list_of_ranges << {item.first, item.last}
        else
          if seen_items
            next if seen_items.includes?(item)
            seen_items << item
          elsif first_item
            next if first_item == item
            seen_items = Set{first_item, item}
          else
            first_item = item
          end
          context.charge_hash_entry(sizeof(Ast::ClassItem))
          context.charge_stream
          list_of_streams << RangeStream.for_item(item)
        end
      end
      unless list_of_ranges.empty?
        literal_bounds = merge_ranges(list_of_ranges, context)
        context.charge_stream
        list_of_streams << RangeStream.new(literal_bounds.to_slice, false)
        if folding && dialect.crystal?
          partners = fold_partners(literal_bounds.to_slice, restricted, context)
          context.charge_stream
          list_of_streams << RangeStream.new(partners.to_slice, false)
        end
      end
      set = union(list_of_streams, context)
      if folding && dialect.ecma262?
        partners.try(&.free)
        partners = fold_partners(set.list_of_bounds, false, context)
        context.charge_array(2, 8)
        context.charge_stream
        context.charge_stream
        set = union([RangeStream.new(set.list_of_bounds, false), RangeStream.new(partners.to_slice, false)], context)
      end
      set = complement(set, context) if char_class.negated?
      context.check_final(set.range_count)
      set
    ensure
      list_of_ranges.try(&.free)
      literal_bounds.try(&.free)
      partners.try(&.free)
    end

    # Returns the set *literal* stands for when case folding gives it fold
    # partners in *dialect* (the code point closed over its simple case
    # folding orbit, kept within ASCII or non-ASCII under
    # `CaselessRestrict` in the Crystal dialect), or nil when it matches
    # only itself. The set is held to `max_class_ranges` like any class.
    def self.fold_literal(literal : Ast::Literal, dialect : Dialect, limits : CompileLimits,
                          ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet?
      options = literal.options
      return nil unless options.ignore_case? && !dialect.xsd?
      code_point = literal.code_point
      restricted = options.caseless_restrict? && dialect.crystal?
      return shared_ascii_fold(literal, restricted, limits, meter) if code_point < 0x80
      members = StaticArray(Int32, 8).new(0)
      count = 1
      members[0] = code_point
      Unicode.each_fold_partner(code_point) do |partner|
        next if restricted && (partner < 0x80) != (code_point < 0x80)
        raise SyntaxError.new("internal error: a case folding orbit longer than 8", Core::Position.new(literal.offset.to_i64)) if count == members.size
        members[count] = partner
        count += 1
      end
      return nil if count == 1
      offset = literal.offset
      meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(count)
      sorted = members.to_slice[0, count].sort!
      range_count = 1
      (1...count).each { |index| range_count += 1 if sorted[index] > sorted[index - 1] + 1 }
      if range_count > limits.max_class_ranges
        raise CompileLimitError.new("max_class_ranges", limits.max_class_ranges.to_i64,
          "A class of #{range_count} ranges", Core::Position.new(offset.to_i64))
      end
      ledger.charge_object(instance_sizeof(CodePointSet), "a folded literal", offset)
      ledger.charge_array(range_count * 2, sizeof(Int32), "a folded literal", offset)
      bounds = Array(Int32).new(range_count * 2)
      sorted.each do |member|
        if bounds.size > 0 && member == bounds[-1] + 1
          bounds[-1] = member
        else
          bounds << member << member
        end
      end
      CodePointSet.from_bounds(bounds)
    end

    # The folded set of an ASCII literal, shared by the process (see
    # `ascii_fold_set?`): a case-insensitive pattern folds most of its
    # characters, and each would otherwise make a set of its own. The set
    # is held to `max_class_ranges` and charged to *meter* as one made for
    # the literal would be; nothing is allocated, so the ledger is not
    # charged.
    private def self.shared_ascii_fold(literal : Ast::Literal, restricted : Bool, limits : CompileLimits,
                                       meter : Core::WorkMeter) : CodePointSet?
      set = ascii_fold_set?(literal.code_point, restricted)
      return nil unless set
      offset = literal.offset
      meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(set.size.to_i32)
      if set.range_count > limits.max_class_ranges
        raise CompileLimitError.new("max_class_ranges", limits.max_class_ranges.to_i64,
          "A class of #{set.range_count} ranges", Core::Position.new(offset.to_i64))
      end
      set
    end

    # The bounds of the fold set of each ASCII letter, six entries per
    # letter in alphabet order: the capital, the small letter and the one
    # partner outside ASCII (the Kelvin sign for `k`, the long s for `s`),
    # each as a range of one. A letter without an outside partner has two
    # zeros there, which no set reads. A spec checks these against the
    # Unicode fold table.
    {% begin %}
      private ASCII_FOLD_BOUNDS = Slice(Int32).literal(
        {% for letter in 0...26 %}
          {% outside = letter == 10 ? 0x212A : (letter == 18 ? 0x17F : 0) %}
          {{0x41 + letter}}, {{0x41 + letter}}, {{0x61 + letter}}, {{0x61 + letter}}, {{outside}}, {{outside}},
        {% end %}
      )
    {% end %}

    # The fold sets of the ASCII letters, two per letter in alphabet order:
    # unrestricted, then restricted (`CaselessRestrict`, which drops the
    # partner outside ASCII). They are static objects over static bounds,
    # so they cost a program nothing in the collector's heap, at start or
    # at their first use; a capital and its small letter share their sets.
    @@ascii_fold_storage = uninitialized StaticArray(ReferenceStorage(CodePointSet), 52)
    @@ascii_folds : Pointer(ReferenceStorage(CodePointSet)) = begin
      storage = @@ascii_fold_storage.to_unsafe
      26.times do |letter|
        bounds = ASCII_FOLD_BOUNDS[letter * 6, 6]
        inside_ascii = bounds[0, 4]
        CodePointSet.unsafe_construct(storage + letter * 2, bounds[5] == 0 ? inside_ascii : bounds)
        CodePointSet.unsafe_construct(storage + letter * 2 + 1, inside_ascii)
      end
      storage
    end

    # The fold set of ASCII *code_point*, restricted to ASCII or not, or
    # nil for a code point that matches only itself (every one but the
    # letters).
    private def self.ascii_fold_set?(code_point : Int32, restricted : Bool) : CodePointSet?
      letter = (code_point | 0x20) - 0x61
      return nil unless 0 <= letter < 26
      (@@ascii_folds + (letter * 2 + (restricted ? 1 : 0))).as(CodePointSet)
    end

    # Returns the union of *list_of_sets*, charged to *ledger* and *meter*
    # as a class lowering at *offset* would be. The caller keeps the total
    # of their ranges within *limits*' `max_class_ranges`, so the union
    # never passes it.
    def self.union_of(list_of_sets : Array(CodePointSet), limits : CompileLimits, ledger : AllocationLedger,
                      meter : Core::WorkMeter, offset : Int32) : CodePointSet
      ledger.charge_object(instance_sizeof(Context), "a class union", offset)
      context = Mica::Regex.stack_object(Context, offset, limits, ledger, meter)
      context.charge_array(list_of_sets.size, sizeof(RangeStream))
      list_of_streams = list_of_sets.map do |set|
        context.charge_stream
        RangeStream.new(set.list_of_bounds, false)
      end
      union(list_of_streams, context)
    end

    # Returns `.` (*matches_newline* false: everything but LF) or `\N`.
    # The two sets are shared by the process (sets are never changed after
    # they are made), so every `.` is the same set and finds its automaton
    # in `ClassMemo` by identity.
    def self.any_character(matches_newline : Bool) : CodePointSet
      matches_newline ? @@any_character : @@any_character_but_newline
    end

    Mica::Regex.static_object(any_character, CodePointSet, Slice(Int32).literal(0, 0x10FFFF))
    Mica::Regex.static_object(any_character_but_newline, CodePointSet,
      Slice(Int32).literal(0, 0x09, 0x0B, 0x10FFFF))

    # Sorts *list_of_ranges* in place and merges overlapping and adjacent
    # ranges into bounds.
    # The caller frees the list it returns.
    private def self.merge_ranges(list_of_ranges : OffHeapList({Int32, Int32}), context : Context) : OffHeapList(Int32)
      context.charge_work(list_of_ranges.size * 2)
      list_of_ranges.to_slice.unstable_sort!
      context.charge_array(0, sizeof(Int32))
      bounds = OffHeapList(Int32).new
      list_of_ranges.each do |first, last|
        if bounds.size > 0 && first <= bounds[-1] + 1
          bounds[-1] = last if last > bounds[-1]
        else
          context.charge_range
          bounds << first
          bounds << last
        end
      end
      bounds
    end

    # The fold partners of every member of the ranges in *bounds*, as
    # merged single-point bounds (they may overlap *bounds*). The caller
    # frees the list it returns.
    private def self.fold_partners(bounds : Slice(Int32), restricted : Bool, context : Context) : OffHeapList(Int32)
      context.charge_array(0, sizeof(Int32))
      list_of_points = OffHeapList(Int32).new
      partner_bounds = OffHeapList(Int32).new
      begin
        (bounds.size // 2).times do |index|
          first = bounds[index * 2]
          last = bounds[index * 2 + 1]
          visited = 0
          # The members within ASCII fold by `ASCII_FOLD_BOUNDS`, which
          # holds what the Unicode table holds for them: a class of ASCII
          # ranges then never reads that table.
          if first < 0x80
            Math.max(first, 0x41).upto(Math.min(last, 0x7A)) do |code_point|
              letter = (code_point | 0x20) - 0x61
              next unless 0 <= letter < 26
              visited += 1
              context.charge_append(sizeof(Int32))
              list_of_points << (code_point ^ 0x20)
              outside = ASCII_FOLD_BOUNDS[letter * 6 + 4]
              next if restricted || outside == 0
              context.charge_append(sizeof(Int32))
              list_of_points << outside
            end
            first = 0x80
          end
          if first <= last
            visited += Unicode.each_folding_code_point(first, last) do |code_point|
              Unicode.each_fold_partner(code_point) do |partner|
                next if restricted && partner < 0x80
                context.charge_append(sizeof(Int32))
                list_of_points << partner
              end
            end
          end
          context.charge_work(visited + 1)
        end
        context.charge_work(list_of_points.size)
        list_of_points.to_slice.unstable_sort!
        context.charge_array(0, sizeof(Int32))
        list_of_points.each do |code_point|
          if partner_bounds.size > 0 && code_point <= partner_bounds[-1] + 1
            partner_bounds[-1] = code_point if code_point > partner_bounds[-1]
          else
            context.charge_range
            partner_bounds << code_point
            partner_bounds << code_point
          end
        end
      rescue error
        partner_bounds.free
        raise error
      ensure
        list_of_points.free
      end
      partner_bounds
    end

    # Merges sorted range streams into one set with a binary heap keyed on
    # each stream's current range start: O(R log k) for R ranges from k
    # streams, charged as 1 + the heap's depth per range.
    private def self.union(list_of_streams : Array(RangeStream), context : Context) : CodePointSet
      context.charge_array(list_of_streams.size, sizeof(Int32))
      # The heap and the bounds are scratch outside the collector's heap;
      # the set gets the bounds in one array of their exact size.
      heap = OffHeapList(Int32).new(list_of_streams.size)
      list_of_streams.each_with_index do |stream, index|
        next if stream.done?
        heap << index
        sift_up(heap, list_of_streams, heap.size - 1)
      end
      context.charge_work(list_of_streams.size * (heap.size.bit_length + 1))
      context.charge_array(0, sizeof(Int32))
      bounds = OffHeapList(Int32).new(8)
      until heap.empty?
        stream = list_of_streams[heap[0]]
        first = stream.current_first
        last = stream.current_last
        context.charge_work(1 + heap.size.bit_length)
        if bounds.size > 0 && first <= bounds[-1] + 1
          bounds[-1] = last if last > bounds[-1]
        else
          context.check_growth(bounds.size // 2 + 1)
          context.charge_range
          bounds << first
          bounds << last
        end
        stream.advance
        if stream.done?
          heap[0] = heap[-1]
          heap.pop
        end
        sift_down(heap, list_of_streams, 0) unless heap.empty?
        # One stream is left: its ranges go in whole when they can. A union
        # of one stream reads it to the end instead, so a static set comes
        # through unmerged and is read in place below.
        next unless heap.size == 1 && list_of_streams.size > 1
        if with_rest = bounds_with_rest(list_of_streams[heap[0]], bounds, context)
          context.charge_set
          return CodePointSet.from_bounds(with_rest)
        end
      end
      context.charge_set
      # One stream of static data that came through unmerged is the set's
      # bounds already (`\d`, `[[:alpha:]]`): the set reads them in place.
      static_bounds = list_of_streams.size == 1 ? list_of_streams[0].static_bounds? : nil
      if static_bounds && static_bounds.size == bounds.size
        CodePointSet.from_bounds(static_bounds)
      else
        CodePointSet.from_bounds(Slice(Int32).new(bounds.size) { |index| bounds.unsafe_fetch(index) })
      end
    ensure
      heap.try(&.free)
      bounds.try(&.free)
    end

    # Returns *bounds* followed by every range *stream* has left, when it
    # is the last stream of a union and the pass can be charged whole: the
    # ranges of `\w` past the few literals of `[\w+\-.]` are then copied
    # straight into the set's array, where the heap would take each of the
    # 900 in turn. Returns nil, leaving the union to its loop, for a
    # complemented stream or when the ledger, the meter or
    # `max_class_ranges` might stop the pass part way, so a refusal comes
    # from the same range as before. The charges are those of the loop:
    # two operations per range read (a heap of one) and one appended range
    # per range kept. The buffer has room for every range left, so it is a
    # range longer than the set where the first one left joins the last of
    # *bounds*.
    private def self.bounds_with_rest(stream : RangeStream, bounds : OffHeapList(Int32), context : Context) : Slice(Int32)?
      rest = stream.rest || return nil
      range_count = rest.size // 2
      return nil unless context.fits_whole?(bounds.size // 2 + range_count, range_count)
      appended = 0
      buffer = Pointer(Int32).malloc(bounds.size + rest.size)
      buffer.copy_from(bounds.to_unsafe, bounds.size)
      size = bounds.size
      range_count.times do |index|
        first = rest.unsafe_fetch(index * 2)
        last = rest.unsafe_fetch(index * 2 + 1)
        if size > 0 && first <= buffer[size - 1] + 1
          buffer[size - 1] = last if last > buffer[size - 1]
        else
          buffer[size] = first
          buffer[size + 1] = last
          size += 2
          appended += 1
        end
      end
      with_rest = Slice.new(buffer, size)
      context.charge_work(range_count * 2)
      context.charge_ranges(appended)
      with_rest
    end

    private def self.sift_up(heap : OffHeapList(Int32), list_of_streams : Array(RangeStream), position : Int32) : Nil
      index = position
      while index > 0
        parent = (index - 1) // 2
        break unless list_of_streams[heap[index]].current_first < list_of_streams[heap[parent]].current_first
        heap.swap(index, parent)
        index = parent
      end
    end

    private def self.sift_down(heap : OffHeapList(Int32), list_of_streams : Array(RangeStream), position : Int32) : Nil
      index = position
      loop do
        left = index * 2 + 1
        break if left >= heap.size
        smallest = left
        right = left + 1
        if right < heap.size && list_of_streams[heap[right]].current_first < list_of_streams[heap[left]].current_first
          smallest = right
        end
        break unless list_of_streams[heap[smallest]].current_first < list_of_streams[heap[index]].current_first
        heap.swap(index, smallest)
        index = smallest
      end
    end

    private def self.complement(set : CodePointSet, context : Context) : CodePointSet
      context.charge_array(0, sizeof(Int32))
      bounds = [] of Int32
      next_first = 0
      set.each_range do |first, last|
        if first > next_first
          context.check_growth(bounds.size // 2 + 1)
          context.charge_range
          bounds << next_first << first - 1
        end
        next_first = last + 1
      end
      if next_first <= CodePointSet::MAX_CODE_POINT
        context.check_growth(bounds.size // 2 + 1)
        context.charge_range
        bounds << next_first << CodePointSet::MAX_CODE_POINT
      end
      context.charge_work(set.range_count + 1)
      context.charge_set
      CodePointSet.from_bounds(bounds)
    end

    # The limits, ledger and meter of one class lowering.
    private class Context
      def initialize(@offset : Int32, @limits : CompileLimits, @ledger : AllocationLedger, @meter : Core::WorkMeter)
      end

      def charge_work(count : Int32) : Nil
        offset = @offset
        @meter.enforce { Core::Position.new(offset.to_i64) } if @meter.charge(count)
      end

      # An array created with *capacity* elements of *element_bytes*.
      def charge_array(capacity : Int32, element_bytes : Int32) : Nil
        @ledger.charge_array(capacity, element_bytes, "a class lowering list", @offset)
      end

      # One element of *element_bytes* appended to a growing array.
      def charge_append(element_bytes : Int32) : Nil
        @ledger.charge_append(element_bytes, "a class member", @offset)
      end

      # One range (two bounds) appended to a growing bounds array.
      def charge_range : Nil
        @ledger.charge_append(2 * sizeof(Int32), "a class range", @offset)
      end

      # *count* ranges appended to a growing bounds array.
      def charge_ranges(count : Int32) : Nil
        @ledger.charge_appends(count, 2 * sizeof(Int32), "a class range", @offset)
      end

      # True when a union now at most *total_ranges* long can take
      # *range_count* more ranges in one pass with nothing to stop it: the
      # ledger has room for every range, the meter reaches no checkpoint,
      # and `check_growth` would pass each one.
      def fits_whole?(total_ranges : Int32, range_count : Int32) : Bool
        return false if total_ranges.to_i64 > @limits.max_class_ranges.to_i64 + 1
        return false if @meter.headroom <= range_count.to_i64 * 2
        @ledger.room_for?(range_count.to_i64 * 2 * sizeof(Int32) * AllocationLedger::GROWTH_FACTOR)
      end

      # A range stream object and its entry in the stream list.
      def charge_stream : Nil
        @ledger.charge_object(instance_sizeof(RangeStream), "a class member", @offset)
        @ledger.charge_append(sizeof(RangeStream), "a class member", @offset)
      end

      # A `CodePointSet` object (its bounds are charged as they grow).
      def charge_set : Nil
        @ledger.charge_object(instance_sizeof(CodePointSet), "a class", @offset)
      end

      # An empty `Set` with its first block of entries.
      def charge_hash : Nil
        @ledger.charge_object(instance_sizeof(Hash(Ast::ClassItem, Nil)), "a class member set", @offset)
        @ledger.charge_array(8, sizeof(Ast::ClassItem) + 8, "a class member set", @offset)
      end

      # One member added to the set of distinct members.
      def charge_hash_entry(key_bytes : Int32) : Nil
        @ledger.charge_hash_entry(key_bytes, "a class member set", @offset)
      end

      # Refuses a union that would have more ranges than the limit allows;
      # negation changes the count by at most one, so one spare range is
      # allowed until `check_final`.
      def check_growth(count : Int32) : Nil
        refuse(count) if count.to_i64 > @limits.max_class_ranges.to_i64 + 1
      end

      def check_final(count : Int32) : Nil
        refuse(count) if count > @limits.max_class_ranges
      end

      private def refuse(count : Int32) : NoReturn
        raise CompileLimitError.new("max_class_ranges", @limits.max_class_ranges.to_i64,
          "A class of #{count} ranges", Core::Position.new(@offset.to_i64))
      end
    end

    # A sorted range source for the union: a Unicode table set or an array
    # of bounds, read directly or as its complement. It only reads the
    # bounds it is given.
    private class RangeStream
      # The bounds as `first, last` pairs (an ASCII set's array, or the
      # decoded table of a Unicode set).
      @bounds : Slice(Int32)
      @count : Int32
      @index : Int32
      getter current_first : Int32 = 0
      getter current_last : Int32 = 0
      getter? done : Bool = false

      # True when the bounds are static data in the binary.
      @static = false

      def self.for_item(item : Ast::ClassItem) : self
        if item.item_kind.unicode_set?
          new(item.first, item.negated)
        else
          new(Ast::AsciiSet.new(item.first).bounds, item.negated, static: true)
        end
      end

      # The bounds when they are static data read as they are (not as
      # their complement), else nil.
      def static_bounds? : Slice(Int32)?
        @static && !@negated ? @bounds : nil
      end

      def initialize(@bounds : Slice(Int32), @negated : Bool, @static : Bool = false)
        @count = @bounds.size // 2
        @index = 0
        load
      end

      def initialize(set_id : Int32, @negated : Bool)
        @bounds = Unicode.decoded_ranges(set_id)
        @static = true
        @count = Unicode.range_count(set_id)
        @index = 0
        load
      end

      def advance : Nil
        @index += 1
        load
      end

      # The bounds from the current range on, or nil for a complemented
      # stream (its ranges are the gaps, worked out one at a time) or one
      # that is done.
      def rest : Slice(Int32)?
        return nil if @negated || @done
        @bounds[@index * 2, (@count - @index) * 2]
      end

      # Loads the range at @index (a gap between ranges when negated),
      # skipping empty gaps.
      private def load : Nil
        unless @negated
          if @index >= @count
            @done = true
            return
          end
          @current_first, @current_last = range_at(@index)
          return
        end
        while @index <= @count
          first = @index == 0 ? 0 : range_at(@index - 1)[1] + 1
          last = @index == @count ? CodePointSet::MAX_CODE_POINT : range_at(@index)[0] - 1
          if first <= last
            @current_first = first
            @current_last = last
            return
          end
          @index += 1
        end
        @done = true
      end

      private def range_at(index : Int32) : {Int32, Int32}
        {@bounds[index * 2], @bounds[index * 2 + 1]}
      end
    end
  end
end
