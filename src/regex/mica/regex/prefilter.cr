module Regex::Mica::Regex
  # A literal accelerator (roadmap 6.2.2): finds the next position at or
  # after a given one where one of a `LiteralSet`'s literals occurs, so the
  # lazy DFA can skip the bytes in between while it sits in its start
  # state. Four searchers, chosen when the expression is first searched:
  #
  # - **first bytes** (memchr style): the literals start with at most three
  #   distinct bytes, none of them common (`common_first_byte?`); each is
  #   found with `memchr`, which libc vectorizes;
  # - **rare byte**: one literal; its least common byte (by a fixed
  #   frequency rank) is found with `memchr` and the literal is checked
  #   around it. When even that byte is common in text (`COMMON_RANK`),
  #   the searcher looks for a pair instead, the two least common bytes
  #   at their distance in the literal, and a third, the least common of
  #   the rest, once the pair proves dense, eight positions per step; when the byte turns out dense
  #   in the haystack (`b{30}a` over a run of `b`), it switches to a pair
  #   (`list_of_dense_tests`);
  # - **packed pairs**: at most three distinct first bytes, one of them
  #   common (`t` for `(?i)the`, a Cyrillic lead byte), and literals that
  #   `MAX_PAIR_TESTS` pair tests cover (`PairTest`): each test is two
  #   bytes at fixed offsets compared up to one bit, so one test covers
  #   every case of a case-insensitive word, and eight positions are
  #   tested per step;
  # - **packed** (Teddy style): up to 64 literals; three 256-entry masks,
  #   one per leading byte position, say which literals can have that byte
  #   there, and a position is a candidate when the three masks share a bit.
  #
  # Every candidate is verified against the literals before it is returned,
  # so a returned position is where a literal really starts.
  #
  # **Progress.** A `PrefilterScan` belongs to one search call and only moves
  # forward: it remembers where each byte was last found, so a `memchr` never
  # rescans bytes, and every byte it reads, and every literal byte it
  # compares, is charged to the call's `SearchMeter`. Total work is O(n·k·l)
  # for k literals of at most l bytes (both bounded by `LiteralSet`).
  class Prefilter
    enum Kind
      FirstBytes
      RareByte
      Packed
      PackedPairs
    end

    getter kind : Kind
    getter literal_set : LiteralSet
    # The distinct first bytes (`FirstBytes`), or the rare byte or pair
    # (`RareByte`).
    getter list_of_needles : OffHeapList(UInt8)
    # The pair tests the pair search runs (`PackedPairs`, or `RareByte`
    # with a pair), else empty.
    getter list_of_pair_tests : OffHeapList(PairTest)
    # The same tests with a third byte where a test's pair is common
    # (`PairTest::COMMON_PAIR_WEIGHT`), which a scan switches to once the
    # pairs prove dense in its haystack (see `PrefilterScan#find_pairs`);
    # empty when no test has a third byte.
    getter list_of_narrow_tests : OffHeapList(PairTest)
    # For `RareByte` without a pair, the pair test a scan switches to when
    # the rare byte turns out dense in the haystack (see
    # `PrefilterScan#find_rare_byte`); empty when the literal has one
    # distinct byte.
    getter list_of_dense_tests : OffHeapList(PairTest)
    @masks : Slice(UInt64)
    @literals : Array(Bytes)
    # For each byte, the slot in `@starting_with` of the literals that start
    # with it (slot 0 holds none), and for each slot those literals as a bit
    # per literal: 256 bytes and a word per distinct first byte, rather
    # than a word for every byte value.
    @first_byte_slots : Slice(UInt8)
    @starting_with : Slice(UInt64)
    # For each literal of at most eight bytes, its bytes as a little-endian
    # word and the mask of those bytes (0 for a longer literal), so
    # `literal_at` compares it with one load (see `literal_fits_at?`).
    @list_of_words : Slice(UInt64)
    @list_of_word_masks : Slice(UInt64)
    # The other four-byte fields follow, together, so the prefilter has
    # no padding between its fields.
    # For `RareByte`, where the rare byte (or the first of the pair) sits
    # in the literal.
    getter needle_offset : Int32
    # For `RareByte` with a pair, how far the second byte of the pair sits
    # after the first (0 without a pair).
    getter pair_gap : Int32
    # For `Packed`, how many leading bytes the masks cover (1 to 3).
    getter mask_width : Int32
    # The shortest literal's length (`LiteralSet#minimum_length`).
    getter minimum_length : Int32

    # The most pair tests `PackedPairs` runs per step.
    MAX_PAIR_TESTS = 8

    # Every table and list sits outside the collector's heap (`OffHeap`,
    # `OffHeapList`) and goes back to libc with the prefilter, which its
    # plan holds for as long as any search reads it.
    def finalize
      OffHeap.free(@first_byte_slots)
      OffHeap.free(@starting_with)
      OffHeap.free(@list_of_words)
      OffHeap.free(@list_of_word_masks)
      OffHeap.free(@masks)
      @list_of_needles.free
      @list_of_pair_tests.free
      @list_of_narrow_tests.free
      @list_of_dense_tests.free
    end

    def initialize(@literal_set : LiteralSet)
      @literals = @literal_set.list_of_literals
      # Only a literal search reads which literal starts at a candidate.
      @literals = Prefilter.without_covered_literals(@literals) unless @literal_set.exact?
      @minimum_length = @literal_set.minimum_length
      @first_byte_slots = OffHeap.slice(UInt8, 256, 0_u8)
      slot_count = 1
      @literals.each do |literal|
        next unless @first_byte_slots[literal[0]] == 0
        @first_byte_slots[literal[0]] = slot_count.to_u8
        slot_count += 1
      end
      @starting_with = OffHeap.slice(UInt64, slot_count, 0_u64)
      @literals.each_with_index { |literal, index| @starting_with[@first_byte_slots[literal[0]]] |= 1_u64 << index }
      @list_of_words = OffHeap.slice(UInt64, @literals.size, 0_u64)
      @list_of_word_masks = OffHeap.slice(UInt64, @literals.size, 0_u64)
      @literals.each_with_index do |literal, index|
        next if literal.size > 8
        word = 0_u64
        literal.each_with_index { |byte, offset| word |= byte.to_u64 << (8 * offset) }
        @list_of_words[index] = word
        @list_of_word_masks[index] = literal.size == 8 ? UInt64::MAX : (1_u64 << (8 * literal.size)) &- 1
      end
      @needle_offset = 0
      @pair_gap = 0
      @mask_width = 0
      @masks = Slice(UInt64).empty
      @list_of_pair_tests = OffHeapList(PairTest).new
      @list_of_narrow_tests = OffHeapList(PairTest).new
      @list_of_dense_tests = OffHeapList(PairTest).new
      @list_of_needles = OffHeapList(UInt8).new
      # The distinct first bytes, in literal order (the slots above number
      # them in that order).
      first_bytes = OffHeapList(UInt8).new(slot_count - 1)
      @literals.each do |literal|
        first_bytes << literal[0] unless first_bytes.includes?(literal[0])
      end
      if @literals.size == 1
        first_bytes.free
        @kind = Kind::RareByte
        literal = @literals[0]
        @needle_offset = (0...literal.size).min_by { |index| Prefilter.rank(literal[index]) }
        @list_of_needles << literal[@needle_offset]
        if literal.size > 1
          # The second byte is the least common of the other offsets, a
          # different byte value first (a pair of two values is rarer).
          rare = literal[@needle_offset]
          other = (0...literal.size).reject(@needle_offset).min_by { |index| {literal[index] == rare ? 1 : 0, Prefilter.rank(literal[index])} }
          first, second = {@needle_offset, other}.minmax
          pair = PairTest.new(first, literal[first], 0_u8, second, literal[second], 0_u8)
          if Prefilter.rank(rare) >= COMMON_RANK
            @needle_offset = first
            @pair_gap = second - first
            @list_of_needles.clear
            @list_of_needles << literal[first]
            @list_of_needles << literal[second]
            @list_of_pair_tests << pair
            # Two common bytes (`t` and `h` of `the`) may take a third,
            # the least common of the rest.
            if third = (0...literal.size).reject { |index| index == first || index == second }.min_by? { |index| Prefilter.rank(literal[index]) }
              @list_of_narrow_tests << PairTest.new(first, literal[first], 0_u8, second, literal[second], 0_u8, third, literal[third], 0_u8)
            end
          elsif literal[other] != rare
            @list_of_dense_tests << pair
          end
        end
      elsif first_bytes.size <= 3
        # A common first byte stops `memchr` every few bytes; the pair
        # tests, when few enough cover the literals, skip on rarer bytes.
        if first_bytes.any? { |byte| Prefilter.common_first_byte?(byte) } && use_pair_tests
          first_bytes.free
          @kind = Kind::PackedPairs
        else
          @kind = Kind::FirstBytes
          @list_of_needles.free
          @list_of_needles = first_bytes
        end
      else
        first_bytes.free
        @kind = Kind::Packed
        @mask_width = Math.min(3, @literal_set.minimum_length)
        @masks = OffHeap.slice(UInt64, 256 * @mask_width, 0_u64)
        @literals.each_with_index do |literal, index|
          bit = 1_u64 << index
          @mask_width.times { |column| @masks[column * 256 + literal[column]] |= bit }
        end
      end
    end

    # :nodoc:
    # Returns *list_of_literals* without each literal that another of them
    # begins (`'ASIA` where `'` is in the set too), or *list_of_literals*
    # itself when none is covered. A candidate where the longer literal
    # starts is one where the shorter starts as well, so for a prefilter
    # that only finds where some literal starts the longer one is never
    # needed, and leaving it out spares `literal_at` its compare at every
    # candidate. Literals are compared only with those of the same first
    # byte (the set holds at most `LiteralSet::MAX_LITERALS`, one bit each).
    def self.without_covered_literals(list_of_literals : Array(Bytes)) : Array(Bytes)
      return list_of_literals if list_of_literals.size < 2
      by_first_byte = StaticArray(UInt64, 256).new(0_u64)
      list_of_literals.each_with_index { |literal, index| by_first_byte[literal[0]] |= 1_u64 << index }
      covered = 0_u64
      list_of_literals.each_with_index do |literal, index|
        others = by_first_byte[literal[0]] & ~(1_u64 << index)
        while others != 0
          other = list_of_literals.unsafe_fetch(others.trailing_zeros_count.to_i32)
          others &= others - 1
          if other.size < literal.size && literal[0, other.size] == other
            covered |= 1_u64 << index
            break
          end
        end
      end
      return list_of_literals if covered == 0
      list_of_kept = Array(Bytes).new(list_of_literals.size - covered.popcount)
      list_of_literals.each_with_index { |literal, index| list_of_kept << literal if covered.bit(index) == 0 }
      list_of_kept
    end

    # Sets the pair tests for `PackedPairs` (see `PairTest.cover`) and
    # returns true, or returns false when they would take more than
    # `MAX_PAIR_TESTS`.
    private def use_pair_tests : Bool
      list_of_tests = PairTest.cover(@literals, MAX_PAIR_TESTS) || return false
      list_of_tests.each { |test| @list_of_pair_tests << test.without_third }
      list_of_tests.each { |test| @list_of_narrow_tests << test } if list_of_tests.any?(&.reads_third?)
      true
    end

    # True when *byte* starting the literals makes `memchr` stop too often
    # for the first-bytes searcher to pay: the space or one of the most
    # common letters (`COMMON_RANK`), or a non-ASCII byte (a lead byte
    # starts most characters of a non-Latin text).
    def self.common_first_byte?(byte : UInt8) : Bool
      byte >= 0x80 || rank(byte) >= COMMON_RANK
    end

    # Returns the index of the highest-priority literal that occurs at
    # *at*, or -1, trying only the literals whose first byte is the byte at
    # *at* (and, for `Packed`, only those in *candidates*). Charges the
    # bytes compared.
    def literal_at(haystack : Bytes, at : Int32, meter : SearchMeter, candidates : UInt64 = UInt64::MAX) : Int32
      return -1 if at >= haystack.size
      bits = candidates & @starting_with.unsafe_fetch(@first_byte_slots.unsafe_fetch(haystack.unsafe_fetch(at)))
      # With eight bytes left, a literal of at most eight bytes is compared
      # as one masked word.
      whole_word = at + 8 <= haystack.size
      word = whole_word ? PrefilterScan.word_at(haystack.to_unsafe + at) : 0_u64
      while bits != 0
        index = bits.trailing_zeros_count.to_i32
        bits &= bits - 1
        literal = @literals.unsafe_fetch(index)
        meter.charge(literal.size, at)
        mask = @list_of_word_masks.unsafe_fetch(index)
        if whole_word && mask != 0
          return index if word & mask == @list_of_words.unsafe_fetch(index)
        elsif Prefilter.literal_fits_at?(haystack, at, literal)
          return index
        end
      end
      -1
    end

    # The longest literal `literal_fits_at?` compares with a byte loop.
    SHORT_LITERAL = 8

    # True when *literal* occurs in *haystack* at *at*. Up to
    # `SHORT_LITERAL` bytes a byte loop beats a `memcmp` call; the first
    # byte is already known to match, and a one-byte literal needs no
    # compare. A longer literal (at most `LiteralSet::MAX_LITERAL_BYTES`) is
    # compared eight bytes at a time, the last word overlapping the one
    # before it, which also beats the call.
    @[AlwaysInline]
    def self.literal_fits_at?(haystack : Bytes, at : Int32, literal : Bytes) : Bool
      size = literal.size
      return false if at + size > haystack.size
      if size > SHORT_LITERAL
        text = haystack.to_unsafe + at
        bytes = literal.to_unsafe
        offset = 0
        while offset < size - 8
          return false unless PrefilterScan.word_at(text + offset) == PrefilterScan.word_at(bytes + offset)
          offset += 8
        end
        return PrefilterScan.word_at(text + size - 8) == PrefilterScan.word_at(bytes + size - 8)
      end
      index = 1
      while index < size
        return false unless haystack.unsafe_fetch(at + index) == literal.unsafe_fetch(index)
        index += 1
      end
      true
    end

    # :nodoc:
    # The `Packed` masks: 256 entries per covered leading byte position.
    def masks : Slice(UInt64)
      @masks
    end

    # Returns the length of literal *index*.
    def literal_size(index : Int32) : Int32
      @literals[index].size
    end

    # A frequency rank for *byte* in typical text (higher is more common),
    # for choosing the rare byte. Letters and spaces rank high, control
    # bytes and non-ASCII lead bytes low.
    def self.rank(byte : UInt8) : Int32
      return 160 if byte >= 0xC0 # a lead byte: one per non-ASCII character
      return 96 if byte >= 0x80  # a continuation byte: spread over many values
      COMMON_BYTES.index(byte.unsafe_chr).try { |index| 255 - index } || 64
    end

    # About how often *byte* occurs in 1,024 bytes of typical text, for
    # choosing the bytes of a pair test (`PairTest.cover`), which weighs a
    # pair by the product of its two weights. Unlike `rank`, it puts a
    # non-ASCII lead byte above the letters: in a non-Latin text every
    # character starts with one of a few lead bytes, while its continuation
    # bytes spread over 64 values.
    def self.weight(byte : UInt8) : Int32
      return 256 if byte >= 0xC0
      return 16 if byte >= 0x80
      index = COMMON_BYTES.byte_index(byte) || return 1
      Math.max(1, (160 * 0.85 ** index).to_i)
    end

    # The rank from which a rare byte is too common for `memchr` to skip
    # far: the space and the eleven most common letters, each found every
    # few dozen bytes of text.
    COMMON_RANK = 243

    # Bytes in descending order of how often they occur in English text and
    # source code.
    COMMON_BYTES = " etaoinsrhldcumfpgwybvkxjqzETAOINSRHLDCUMFPGWYBVKXJQZ0123456789\n.,;:-_'\"()/=<>{}[]*#\t"
  end

  # :nodoc:
  # One test of the pair search (`Prefilter::Kind::PackedPairs`): a
  # position is a candidate when the byte *first_offset* past it is
  # *first_value* and the byte *second_offset* past it is *second_value*,
  # each compared up to one bit (*first_bit*, *second_bit*; 0 compares
  # exactly). Most case-insensitive literals differ from their other cases
  # in one bit per byte: 0x20 for an ASCII letter, and for a Cyrillic letter
  # 0x20 in the continuation byte and 0x01 in the lead byte, so one test
  # covers every case of a literal. A third byte (*third_offset*, compared
  # the same way) narrows a pair of common bytes (`t` and `h` of `the`);
  # without one it repeats the first. The lanes hold each value in all
  # eight bytes of a word, for the word-at-a-time step.
  struct PairTest
    getter first_offset : Int32
    getter second_offset : Int32
    getter third_offset : Int32
    getter first_fold : UInt64
    getter first_lanes : UInt64
    getter second_fold : UInt64
    getter second_lanes : UInt64
    getter third_fold : UInt64
    getter third_lanes : UInt64
    # The farthest byte past a candidate the test reads.
    getter reach : Int32

    def initialize(@first_offset : Int32, first_value : UInt8, first_bit : UInt8,
                   @second_offset : Int32, second_value : UInt8, second_bit : UInt8,
                   @third_offset : Int32 = first_offset, third_value : UInt8 = first_value, third_bit : UInt8 = first_bit)
      @first_fold = PrefilterScan::LANE_ONES &* first_bit
      @first_lanes = PrefilterScan::LANE_ONES &* (first_value | first_bit)
      @second_fold = PrefilterScan::LANE_ONES &* second_bit
      @second_lanes = PrefilterScan::LANE_ONES &* (second_value | second_bit)
      @third_fold = PrefilterScan::LANE_ONES &* third_bit
      @third_lanes = PrefilterScan::LANE_ONES &* (third_value | third_bit)
      @reach = Math.max(@second_offset, @third_offset)
    end

    # This test without its third byte.
    def without_third : PairTest
      copy = self
      copy.drop_third
      copy
    end

    protected def drop_third : Nil
      @third_offset = @first_offset
      @third_fold = @first_fold
      @third_lanes = @first_lanes
      @reach = @second_offset
    end

    # True when the test reads a third byte.
    def reads_third? : Bool
      @third_offset != @first_offset
    end

    # The farthest byte past a candidate that *list_of_tests* read.
    def self.reach(list_of_tests : Indexable(PairTest)) : Int32
      reach = 0
      list_of_tests.each { |test| reach = Math.max(reach, test.reach) }
      reach
    end

    # True when the test holds at *at* (reading no byte past *bytes*).
    @[AlwaysInline]
    def holds_at?(bytes : Bytes, at : Int32) : Bool
      return false if at + @reach >= bytes.size
      bytes.unsafe_fetch(at + @first_offset) | @first_fold.to_u8! == @first_lanes.to_u8! &&
        bytes.unsafe_fetch(at + @second_offset) | @second_fold.to_u8! == @second_lanes.to_u8! &&
        bytes.unsafe_fetch(at + @third_offset) | @third_fold.to_u8! == @third_lanes.to_u8!
    end

    # The weight product (see `Prefilter.weight`) from which a pair is
    # common enough to take a third byte: one candidate in 512 positions
    # if the two bytes were independent, which in text they are not (`th`
    # starts one position in 45 of English). A third byte costs a load per
    # step, so only such pairs pay for it.
    COMMON_PAIR_WEIGHT = 2_048

    # Returns at most *max_tests* tests such that every literal of
    # *list_of_literals* passes one of them where it starts, or nil.
    #
    # Each test is made from the first literal no test covers yet: at each
    # of its offsets, the literals whose byte there equals it or differs in
    # one bit (the first such bit seen at that offset) agree with it. The
    # test takes the two offsets with the most literals agreeing at both per
    # candidate expected (the product of the offsets' `Prefilter.weight`,
    # both bytes a bit allows counted), then the farthest apart, and
    # covers those literals. O(t·(k·l + l²)) for t tests and k literals of
    # at most l bytes (64 and 32, see `LiteralSet`).
    def self.cover(list_of_literals : Array(Bytes), max_tests : Int32) : Array(PairTest)?
      uncovered = list_of_literals.size == 64 ? UInt64::MAX : (1_u64 << list_of_literals.size) &- 1
      list_of_tests = [] of PairTest
      while uncovered != 0
        return nil if list_of_tests.size == max_tests
        lead = list_of_literals.unsafe_fetch(uncovered.trailing_zeros_count)
        return nil if lead.size < 2
        list_of_bits = Array(UInt8).new(lead.size, 0_u8)
        list_of_agreeing = Array(UInt64).new(lead.size, 0_u64)
        list_of_weights = Array(Int32).new(lead.size, 0)
        lead.size.times do |offset|
          bit = 0_u8
          agreeing = 0_u64
          bits = uncovered
          while bits != 0
            index = bits.trailing_zeros_count
            bits &= bits &- 1
            literal = list_of_literals.unsafe_fetch(index)
            next if literal.size <= offset
            difference = literal.unsafe_fetch(offset) ^ lead.unsafe_fetch(offset)
            if difference != 0
              next unless difference.popcount == 1
              bit = difference if bit == 0
              next unless difference == bit
            end
            agreeing |= 1_u64 << index
          end
          list_of_bits[offset] = bit
          list_of_agreeing[offset] = agreeing
          value = lead.unsafe_fetch(offset)
          list_of_weights[offset] = bit == 0 ? Prefilter.weight(value) : Prefilter.weight(value) + Prefilter.weight(value ^ bit)
        end
        # The best pair has the most literals covered per candidate
        # expected (covered / weight, compared crosswise in integers),
        # then the widest gap.
        best_first = best_second = 0
        best_covered = 0_i64
        best_weight = 1_i64
        (0...lead.size).each do |first|
          (first + 1...lead.size).each do |second|
            covered = (list_of_agreeing[first] & list_of_agreeing[second]).popcount.to_i64
            weight = list_of_weights[first].to_i64 * list_of_weights[second]
            better = covered * best_weight <=> best_covered * weight
            if better > 0 || (better == 0 && second - first > best_second - best_first)
              best_covered = covered
              best_weight = weight
              best_first = first
              best_second = second
            end
          end
        end
        covered = list_of_agreeing[best_first] & list_of_agreeing[best_second]
        # A common pair takes the least common third offset where every
        # literal it covers agrees too.
        best_third = best_first
        if best_weight >= COMMON_PAIR_WEIGHT
          third_weight = Int32::MAX
          lead.size.times do |third|
            next if third == best_first || third == best_second
            next unless list_of_agreeing[third] & covered == covered
            if list_of_weights[third] < third_weight
              third_weight = list_of_weights[third]
              best_third = third
            end
          end
        end
        list_of_tests << PairTest.new(best_first, lead[best_first], list_of_bits[best_first],
          best_second, lead[best_second], list_of_bits[best_second],
          best_third, lead[best_third], list_of_bits[best_third])
        uncovered &= ~covered
      end
      list_of_tests
    end
  end

  # :nodoc:
  # The forward-only state of a prefilter over one haystack, owned by one
  # search call (see `Prefilter`, "Progress").
  #
  # **The guard.** Every candidate verified counts, matching or not. Once
  # `GUARD_CANDIDATES` have been verified and they came closer together
  # than `MINIMUM_SKIP` bytes on average, the scan is `ineffective?`: a
  # scan that is only an accelerator (not the literal search itself) then
  # stops at the candidate it holds and returns it unverified, which is
  # safe (no match starts before it), and the caller stops using it.
  class PrefilterScan
    GUARD_CANDIDATES = 32
    MINIMUM_SKIP     =  8
    # The pair search takes its narrow tests (`Prefilter#list_of_narrow_tests`)
    # once `GUARD_CANDIDATES` candidates over a haystack came less than
    # this many bytes apart on average.
    NARROW_SKIP = 128
    # The bytes a scan reads between two charges to the meter.
    CHARGE_CHUNK = 4096
    # A byte in every lane of a word, and the high bit of every lane (the
    # pair search).
    LANE_ONES  = 0x0101010101010101_u64
    LANE_HIGHS = 0x8080808080808080_u64

    getter prefilter : Prefilter
    # How many candidates the scan has verified.
    getter candidates = 0
    # How many bytes the scan has moved past in all.
    getter skipped = 0_i64
    # The literal the last verified candidate starts (its index in the
    # set), or -1.
    getter last_literal = -1
    @guard_from = 0
    # The positions where each needle was last found (-1: not yet looked;
    # Int32::MAX: absent from there on).
    @found_at : StaticArray(Int32, 3)
    @scanned_from : StaticArray(Int32, 3)
    @packed_from = 0
    # True once a rare-byte scan switched to its pair (see
    # `find_rare_byte`).
    @dense_switched = false
    # True once a first-byte scan reads by words (see `first_bytes_dense?`).
    @first_bytes_dense = false
    # The candidates verified and the bytes moved past over this haystack,
    # across the calls that kept the scan's positions, and whether the pair
    # search switched to its narrow tests (see `find_pairs`).
    @haystack_candidates = 0
    @haystack_skipped = 0_i64
    @narrowed = false

    # With *verified_only* (the literal search), the scan never stops early:
    # every position it returns starts a literal.
    def initialize(@prefilter : Prefilter, @haystack : Bytes, @verified_only : Bool = false)
      @found_at = StaticArray(Int32, 3).new(-1)
      @scanned_from = StaticArray(Int32, 3).new(0)
    end

    # Starts the scan over on *haystack*, as a new scan would (a searcher
    # reuses its scan from one call to the next). With *keep_positions*
    # (the haystack is the one the last call scanned), where each needle
    # was found stays known.
    def reset(@haystack : Bytes, *, keep_positions : Bool = false) : Nil
      @candidates = 0
      @skipped = 0_i64
      @guard_from = 0
      @packed_from = 0
      return if keep_positions
      @dense_switched = false
      @first_bytes_dense = false
      @haystack_candidates = 0
      @haystack_skipped = 0_i64
      @narrowed = false
      @found_at = StaticArray(Int32, 3).new(-1)
      @scanned_from = StaticArray(Int32, 3).new(0)
    end

    # True when candidates have been too dense for the scan to pay off
    # (`GUARD_CANDIDATES`, `MINIMUM_SKIP`); the caller then stops using it
    # for the rest of the call.
    def ineffective? : Bool
      @candidates >= GUARD_CANDIDATES && @skipped < @candidates.to_i64 * MINIMUM_SKIP
    end

    # Returns the first position at or after *from* where a literal starts,
    # or -1.
    def find(from : Int32, meter : SearchMeter) : Int32
      @guard_from = from
      case @prefilter.kind
      in .first_bytes?  then find_first_bytes(from, meter)
      in .rare_byte?    then find_rare_byte(from, meter)
      in .packed?       then find_packed(from, meter)
      in .packed_pairs? then find_pairs(from, meter, @prefilter.list_of_pair_tests)
      end
    end

    # Verifies *candidate*, counting it for the guard. Returns true when a
    # literal starts there, or when the scan should stop at it (see the
    # class description).
    private def accept?(candidate : Int32, meter : SearchMeter, bits : UInt64 = UInt64::MAX) : Bool
      @candidates += 1
      @haystack_candidates += 1
      if candidate > @guard_from
        @skipped += candidate - @guard_from
        @haystack_skipped += candidate - @guard_from
      end
      @guard_from = candidate + 1
      @last_literal = @prefilter.literal_at(@haystack, candidate, meter, bits)
      return true if @last_literal >= 0
      !@verified_only && ineffective?
    end

    private def find_first_bytes(from : Int32, meter : SearchMeter) : Int32
      return find_first_bytes_in_words(from, meter) if @first_bytes_dense
      at = from
      while at < @haystack.size
        candidate = Int32::MAX
        @prefilter.list_of_needles.size.times do |needle|
          candidate = Math.min(candidate, next_needle(needle, @prefilter.list_of_needles[needle], at, meter))
        end
        return -1 if candidate == Int32::MAX
        accepted = accept?(candidate, meter)
        @first_bytes_dense = true if first_bytes_dense?
        return candidate if accepted
        at = candidate + 1
      end
      -1
    end

    # The average gap, in bytes, between the candidates of a first-byte
    # scan below which it reads the haystack a word at a time (see
    # `find_first_bytes_in_words`).
    DENSE_FIRST_BYTES_GAP = 256

    # True when this haystack has shown `GUARD_CANDIDATES` candidates for
    # two or three first bytes less than `DENSE_FIRST_BYTES_GAP` bytes
    # apart on average: a `memchr` per byte per candidate (a quote in
    # source code full of quotes) then costs more in calls than it saves.
    private def first_bytes_dense? : Bool
      @prefilter.list_of_needles.size > 1 && @haystack_candidates >= GUARD_CANDIDATES &&
        @haystack_skipped < @haystack_candidates.to_i64 * DENSE_FIRST_BYTES_GAP
    end

    # The first-byte search once its candidates proved dense: every first
    # byte is looked for in each eight-byte word at once (`zero_lanes`),
    # in windows of at most `CHARGE_CHUNK` bytes the meter allows before
    # they are read, each byte read charged once.
    private def find_first_bytes_in_words(from : Int32, meter : SearchMeter) : Int32
      needles = @prefilter.list_of_needles
      first = needles[0]
      second = needles[1]
      third = needles.size > 2 ? needles[2] : first
      first_lanes = LANE_ONES &* first
      second_lanes = LANE_ONES &* second
      third_lanes = LANE_ONES &* third
      bytes = @haystack.to_unsafe
      size = @haystack.size
      at = from
      while at < size
        window_start = at
        stop = at + meter.readable(Math.min(CHARGE_CHUNK, size - at), at)
        candidate = -1
        while at + 8 <= stop
          word = PrefilterScan.word_at(bytes + at)
          hits = PrefilterScan.zero_lanes(word ^ first_lanes) | PrefilterScan.zero_lanes(word ^ second_lanes) |
                 PrefilterScan.zero_lanes(word ^ third_lanes)
          if hits != 0
            # The lowest flagged lane is a true match (see `zero_lanes`).
            candidate = at + hits.trailing_zeros_count // 8
            break
          end
          at += 8
        end
        if candidate < 0
          while at < stop
            byte = bytes[at]
            if byte == first || byte == second || byte == third
              candidate = at
              break
            end
            at += 1
          end
        end
        if candidate < 0
          meter.charge(stop - window_start, window_start)
          at = stop
          next
        end
        meter.charge(candidate - window_start + 1, window_start)
        return candidate if accept?(candidate, meter)
        at = candidate + 1
      end
      -1
    end

    # The rare-byte search: `memchr` for the rare byte. A rare byte that
    # turns out dense in this haystack (`GUARD_CANDIDATES` candidates less
    # than `MINIMUM_SKIP` bytes apart on average, as a run of `b` makes
    # for `b{30}a`) switches the scan to the pair search with
    # `Prefilter#list_of_dense_tests` for the rest of the haystack (and
    # the later calls over it); the guard then
    # counts the pair search's candidates afresh.
    private def find_rare_byte(from : Int32, meter : SearchMeter) : Int32
      return find_pairs(from, meter, @prefilter.list_of_pair_tests) if @prefilter.pair_gap > 0
      return find_pairs(from, meter, @prefilter.list_of_dense_tests) if @dense_switched
      offset = @prefilter.needle_offset
      needle = @prefilter.list_of_needles[0]
      at = from
      while at < @haystack.size
        position = next_needle(0, needle, at + offset, meter)
        return -1 if position == Int32::MAX
        candidate = position - offset
        if ineffective? && !@prefilter.list_of_dense_tests.empty?
          @dense_switched = true
          @candidates = 0
          @skipped = 0_i64
          @guard_from = candidate
          return find_pairs(candidate, meter, @prefilter.list_of_dense_tests)
        end
        return candidate if accept?(candidate, meter)
        at = candidate + 1
      end
      -1
    end

    # The pair search over *list_of_tests* (see `PairTest`): a position is a
    # candidate when one of the tests holds there. Eight positions are
    # tested at once, one byte per lane of a 64-bit word: a lane holding the
    # wanted byte (after the test's fold bit is set) becomes zero after an
    # XOR, and the zero-lane test can also flag a lane above a real zero, so
    # the lowest flagged lane is a candidate that `accept?` verifies (a false
    # one is skipped like any candidate that fails). Near the end, where a
    # word would read past the haystack, each position is tested byte by
    # byte. The meter is charged as in `find_packed`.
    private def find_pairs(from : Int32, meter : SearchMeter, list_of_tests : OffHeapList(PairTest)) : Int32
      if list_of_tests.to_unsafe == @prefilter.list_of_pair_tests.to_unsafe && !@prefilter.list_of_narrow_tests.empty?
        @narrowed ||= @haystack_candidates >= GUARD_CANDIDATES &&
                      @haystack_skipped < @haystack_candidates.to_i64 * NARROW_SKIP
        list_of_tests = @prefilter.list_of_narrow_tests if @narrowed
      end
      if list_of_tests.any?(&.reads_third?)
        find_pairs_reading_three(from, meter, list_of_tests)
      else
        find_pairs_reading_two(from, meter, list_of_tests)
      end
    end

    # `find_pairs` made once for tests of two bytes and once for tests
    # of three, so a step of two-byte tests loads no third word.
    {% for width, name in {2 => "two", 3 => "three"} %}
    private def find_pairs_reading_{{name.id}}(from : Int32, meter : SearchMeter, list_of_tests : OffHeapList(PairTest)) : Int32
      last = @haystack.size - @prefilter.minimum_length
      # The last position whose words all lie inside the haystack.
      word_last = @haystack.size - 8 - PairTest.reach(list_of_tests)
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      tests = list_of_tests.to_unsafe
      test_count = list_of_tests.size
      while at <= last
        stop = at + meter.readable(Math.min(CHARGE_CHUNK, last + 1 - at), at) - 1
        chunk_from = at
        found = -1
        word_stop = Math.min(stop - 7, word_last)
        while at <= word_stop
          lanes = 0_u64
          index = 0
          while index < test_count
            test = tests[index]
            test_lanes = PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test.first_offset) | test.first_fold) ^ test.first_lanes) &
                         PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test.second_offset) | test.second_fold) ^ test.second_lanes)
            {% if width == 3 %}
              test_lanes &= PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test.third_offset) | test.third_fold) ^ test.third_lanes)
            {% end %}
            lanes |= test_lanes
            index += 1
          end
          if lanes != 0
            # Each flagged lane is a candidate, lowest first; one that
            # fails verification leaves the scan in this word. Verifying
            # charges the meter, so the chunk is allowed again after each,
            # and a shorter allowance hands the rest to the outer loop.
            while lanes != 0
              candidate = at + lanes.trailing_zeros_count // 8
              break if candidate > stop
              lanes &= lanes &- 1
              meter.charge(candidate - chunk_from + 1, candidate)
              return candidate if accept?(candidate, meter)
              chunk_from = candidate + 1
              stop = chunk_from + meter.readable(Math.min(CHARGE_CHUNK, last + 1 - chunk_from), chunk_from) - 1
            end
            if stop < at + 7
              at = chunk_from
              break
            end
            word_stop = Math.min(stop - 7, word_last)
          end
          at += 8
        end
        if found < 0
          while at <= stop
            if list_of_tests.any?(&.holds_at?(@haystack, at))
              found = at
              break
            end
            at += 1
          end
        end
        if found >= 0
          meter.charge(found - chunk_from + 1, found)
          return found if accept?(found, meter)
          at = found + 1
        elsif at > chunk_from
          meter.charge(at - chunk_from, chunk_from)
        end
      end
      meter.charge(@haystack.size - at, at) if at < @haystack.size
      -1
    end
    {% end %}

    # The eight bytes at *pointer* as one little-endian word (an unaligned
    # read).
    def self.word_at(pointer : UInt8*) : UInt64
      word = 0_u64
      pointerof(word).as(UInt8*).copy_from(pointer, 8)
      word
    end

    # The high bit of each lane of *word* that may be zero: every zero lane
    # is flagged, and a lane above a zero lane can be flagged too.
    def self.zero_lanes(word : UInt64) : UInt64
      (word &- LANE_ONES) & ~word & LANE_HIGHS
    end

    # Returns the first position at or after *from* holding *needle*
    # (`Int32::MAX` when none), reusing the last result while it is still
    # ahead, and charging each byte `memchr` reads once. The scan runs in
    # windows of at most `CHARGE_CHUNK` bytes that the meter allows before
    # each is read (`SearchMeter#readable`), so a search over budget stops
    # before the first byte it cannot pay for.
    private def next_needle(slot : Int32, needle : UInt8, from : Int32, meter : SearchMeter) : Int32
      found_at = @found_at.unsafe_fetch(slot)
      return found_at if from >= @scanned_from.unsafe_fetch(slot) && found_at >= from
      size = @haystack.size
      return Int32::MAX if from >= size
      index = Int32::MAX
      at = from
      bytes = @haystack.to_unsafe
      while at < size
        window = meter.readable(Math.min(CHARGE_CHUNK, size - at), at)
        found = LibC.memchr(bytes + at, needle.to_i32, window)
        unless found.null?
          offset = (found.as(UInt8*) - (bytes + at)).to_i32
          index = at + offset
          meter.charge(offset + 1, at)
          break
        end
        meter.charge(window, at)
        at += window
      end
      meter.charge(1, size) if index == Int32::MAX
      @scanned_from[slot] = from
      @found_at[slot] = index
    end

    # The packed search, charging each byte it reads once, at each
    # candidate and in windows of at most `CHARGE_CHUNK` positions that the
    # meter allows before each is read (`SearchMeter#readable`).
    private def find_packed(from : Int32, meter : SearchMeter) : Int32
      width = @prefilter.mask_width
      masks = @prefilter.masks
      last = @haystack.size - width
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      table = masks.to_unsafe
      while at <= last
        # A window ends at its first candidate: verifying it charges the
        # meter, so the next window is sized after that charge.
        stop = at + meter.readable(Math.min(CHARGE_CHUNK, last + 1 - at), at) - 1
        chunk_from = at
        bits = 0_u64
        while at <= stop
          bits = table[bytes[at]]
          if width > 1
            bits &= table[256 + bytes[at + 1]]
            bits &= table[512 + bytes[at + 2]] if width > 2
          end
          break if bits != 0
          at += 1
        end
        if at <= stop
          meter.charge(at - chunk_from + 1, at)
          return at if accept?(at, meter, bits)
          at += 1
        elsif at > chunk_from
          meter.charge(at - chunk_from, chunk_from)
        end
      end
      meter.charge(@haystack.size - at, at) if at < @haystack.size
      -1
    end
  end
end
