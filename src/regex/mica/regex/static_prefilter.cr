module Regex::Mica::Regex
  # :nodoc:
  # A static pattern's literal prefilter: the runtime engine's `Prefilter`
  # for the pattern's prefix literals (`LiteralSet`), chosen while the
  # application built (see `Static::PrefilterTables`) and held in
  # read-only tables. The static path keeps three of its searchers, the
  # ones that check more than one byte of a literal per candidate: the
  # rare-byte search (with its pair and dense tests), the pair search and
  # the packed search. A pattern whose literals start with at most three
  # bytes (`Prefilter::Kind::FirstBytes`) needs none: its forward DFA's
  # start state already skips to them with `StaticByteScan`.
  #
  # Every candidate the scan returns is verified against the literals, so
  # a match can start there, and no match starts between the scan's
  # starting position and it (see `StaticPrefilterScan`).
  struct StaticPrefilter
    # The kind of a pattern without a prefilter.
    NONE = -1
    # The 64-bit words one pair test takes in `pair_tests`,
    # `narrow_tests` and `dense_tests`: its three offsets, then the fold
    # and lane words of its first, second and third bytes (see
    # `PairTest`).
    WORDS_PER_TEST = 9

    # `Prefilter::Kind#value`, or `NONE`.
    getter kind : Int32
    # True when the literals are the whole matches (`LiteralSet#exact?`):
    # the literal found is the match.
    getter? exact : Bool
    # The literals one after another, in priority order, and where each
    # ends.
    getter literal_bytes : Slice(UInt8)
    getter literal_ends : Slice(Int32)
    # For each byte value, the literals that start with it (a bit per
    # literal).
    getter starting_with : Slice(UInt64)
    # For each literal of at most eight bytes, its bytes as a little-endian
    # word and the mask of those bytes (0 for a longer literal).
    getter words : Slice(UInt64)
    getter word_masks : Slice(UInt64)
    # The rare-byte search's byte and where it sits in the literal.
    getter needle : Int32
    getter needle_offset : Int32
    # For the rare-byte search with a pair, how far the second byte sits
    # after the first (0 without a pair).
    getter pair_gap : Int32
    # For the packed search, how many leading bytes the masks cover, and
    # the masks (256 per covered position).
    getter mask_width : Int32
    getter masks : Slice(UInt64)
    # The shortest literal's length.
    getter minimum_length : Int32
    # `Prefilter#list_of_pair_tests`, `#list_of_narrow_tests` and
    # `#list_of_dense_tests`, `WORDS_PER_TEST` words each.
    getter pair_tests : Slice(UInt64)
    getter narrow_tests : Slice(UInt64)
    getter dense_tests : Slice(UInt64)

    def initialize(*, @kind : Int32, @exact : Bool, @literal_bytes : Slice(UInt8), @literal_ends : Slice(Int32),
                   @starting_with : Slice(UInt64), @words : Slice(UInt64), @word_masks : Slice(UInt64),
                   @needle : Int32, @needle_offset : Int32, @pair_gap : Int32, @mask_width : Int32,
                   @masks : Slice(UInt64), @minimum_length : Int32, @pair_tests : Slice(UInt64),
                   @narrow_tests : Slice(UInt64), @dense_tests : Slice(UInt64))
    end

    # The prefilter of a pattern that has none.
    def self.none : self
      new(kind: NONE, exact: false, literal_bytes: Slice(UInt8).empty, literal_ends: Slice(Int32).empty,
        starting_with: Slice(UInt64).empty, words: Slice(UInt64).empty, word_masks: Slice(UInt64).empty,
        needle: 0, needle_offset: 0, pair_gap: 0, mask_width: 0, masks: Slice(UInt64).empty, minimum_length: 0,
        pair_tests: Slice(UInt64).empty, narrow_tests: Slice(UInt64).empty, dense_tests: Slice(UInt64).empty)
    end

    # True when the pattern has a prefilter.
    def present? : Bool
      @kind != NONE
    end

    # The length of literal *index*.
    def literal_size(index : Int32) : Int32
      @literal_ends.unsafe_fetch(index) - literal_start(index)
    end

    private def literal_start(index : Int32) : Int32
      index == 0 ? 0 : @literal_ends.unsafe_fetch(index - 1)
    end

    # Returns the index of the highest-priority literal that occurs at
    # *at*, or -1, trying only the literals whose first byte is the byte at
    # *at* (and, for the packed search, only those in *candidates*), as
    # `Prefilter#literal_at` does. Charges the bytes compared.
    def literal_at(haystack : Bytes, at : Int32, meter : StaticMeter, candidates : UInt64 = UInt64::MAX) : Int32
      return -1 if at >= haystack.size
      bits = candidates & @starting_with.unsafe_fetch(haystack.unsafe_fetch(at))
      whole_word = at + 8 <= haystack.size
      word = whole_word ? PrefilterScan.word_at(haystack.to_unsafe + at) : 0_u64
      while bits != 0
        index = bits.trailing_zeros_count.to_i32
        bits &= bits - 1
        start = literal_start(index)
        size = @literal_ends.unsafe_fetch(index) - start
        meter.charge(size, at)
        mask = @word_masks.unsafe_fetch(index)
        if whole_word && mask != 0
          return index if word & mask == @words.unsafe_fetch(index)
        elsif Prefilter.literal_fits_at?(haystack, at, @literal_bytes[start, size])
          return index
        end
      end
      -1
    end
  end

  # :nodoc:
  # The forward-only state of a static prefilter over one haystack, owned
  # by one search call and kept in its stack frame (see `PrefilterScan`,
  # whose searchers it repeats over `StaticPrefilter`'s tables).
  #
  # **The guard.** As `PrefilterScan`'s: once `GUARD_CANDIDATES`
  # candidates have been verified and they came closer together than
  # `MINIMUM_SKIP` bytes on average, the scan is `ineffective?`; a scan
  # that is only an accelerator (the literals are not the whole matches)
  # then stops at the candidate it holds and returns it unverified
  # (`last_literal` is -1), which is safe, as no match starts before it.
  struct StaticPrefilterScan
    # How many candidates the scan has verified.
    getter candidates = 0
    # How many bytes the scan has moved past in all.
    getter skipped = 0_i64
    # The literal the last candidate returned starts, or -1 when the scan
    # stopped there unverified.
    getter last_literal = -1
    @guard_from = 0
    # True once a rare-byte scan switched to its dense tests.
    @dense_switched = false
    # True once the pair search switched to its narrow tests.
    @narrowed = false

    def initialize(@prefilter : StaticPrefilter, @haystack : Bytes)
    end

    # True when candidates have been too dense for the scan to pay off.
    def ineffective? : Bool
      @candidates >= PrefilterScan::GUARD_CANDIDATES && @skipped < @candidates.to_i64 * PrefilterScan::MINIMUM_SKIP
    end

    # Returns the first position at or after *from* where a literal
    # starts, or -1.
    def find(from : Int32, meter : StaticMeter) : Int32
      @guard_from = from
      case @prefilter.kind
      when Prefilter::Kind::RareByte.value then find_rare_byte(from, meter)
      when Prefilter::Kind::Packed.value   then find_packed(from, meter)
      else                                      find_pairs(from, meter, @prefilter.pair_tests)
      end
    end

    # Verifies *candidate*, counting it for the guard. Returns true when a
    # literal starts there, or when the scan should stop at it.
    private def accept?(candidate : Int32, meter : StaticMeter, bits : UInt64 = UInt64::MAX) : Bool
      @candidates += 1
      @skipped += candidate - @guard_from if candidate > @guard_from
      @guard_from = candidate + 1
      @last_literal = @prefilter.literal_at(@haystack, candidate, meter, bits)
      return true if @last_literal >= 0
      !@prefilter.exact? && ineffective?
    end

    # The rare-byte search (`PrefilterScan#find_rare_byte`): `memchr` for
    # the rare byte, in windows the meter allows, and the dense tests once
    # the byte proves dense in this haystack.
    private def find_rare_byte(from : Int32, meter : StaticMeter) : Int32
      return find_pairs(from, meter, @prefilter.pair_tests) if @prefilter.pair_gap > 0
      return find_pairs(from, meter, @prefilter.dense_tests) if @dense_switched
      offset = @prefilter.needle_offset
      needle = @prefilter.needle
      at = from
      while at < @haystack.size
        position = next_needle(needle, at + offset, meter)
        return -1 if position < 0
        candidate = position - offset
        if ineffective? && !@prefilter.dense_tests.empty?
          @dense_switched = true
          @candidates = 0
          @skipped = 0_i64
          @guard_from = candidate
          return find_pairs(candidate, meter, @prefilter.dense_tests)
        end
        return candidate if accept?(candidate, meter)
        at = candidate + 1
      end
      -1
    end

    # The first position at or after *from* holding *needle*, or -1,
    # charging each byte `memchr` reads, in windows of at most
    # `PrefilterScan::CHARGE_CHUNK` bytes the meter allows before each is
    # read.
    private def next_needle(needle : Int32, from : Int32, meter : StaticMeter) : Int32
      size = @haystack.size
      at = from
      bytes = @haystack.to_unsafe
      while at < size
        window = meter.readable(Math.min(PrefilterScan::CHARGE_CHUNK, size - at), at)
        found = LibC.memchr(bytes + at, needle, window)
        unless found.null?
          offset = (found.as(UInt8*) - (bytes + at)).to_i32
          meter.charge(offset + 1, at)
          return at + offset
        end
        meter.charge(window, at)
        at += window
      end
      meter.charge(1, size)
      -1
    end

    # The pair search over *tests* (`PrefilterScan#find_pairs`): eight
    # positions per step, one byte per lane of a word. The pair tests
    # switch to the narrow tests once candidates prove dense.
    private def find_pairs(from : Int32, meter : StaticMeter, tests : Slice(UInt64)) : Int32
      narrow = @prefilter.narrow_tests
      if tests.same?(@prefilter.pair_tests) && !narrow.empty?
        @narrowed ||= @candidates >= PrefilterScan::GUARD_CANDIDATES &&
                      @skipped < @candidates.to_i64 * PrefilterScan::NARROW_SKIP
        tests = narrow if @narrowed
      end
      if reads_third?(tests)
        find_pairs_reading_three(from, meter, tests)
      else
        find_pairs_reading_two(from, meter, tests)
      end
    end

    private def reads_third?(tests : Slice(UInt64)) : Bool
      index = 0
      while index < tests.size
        return true if tests.unsafe_fetch(index + 2) != tests.unsafe_fetch(index)
        index += StaticPrefilter::WORDS_PER_TEST
      end
      false
    end

    # The farthest byte past a candidate that *tests* read.
    private def reach_of(tests : Slice(UInt64)) : Int32
      reach = 0
      index = 0
      while index < tests.size
        reach = Math.max(reach, Math.max(tests.unsafe_fetch(index + 1), tests.unsafe_fetch(index + 2)).to_i32)
        index += StaticPrefilter::WORDS_PER_TEST
      end
      reach
    end

    # True when one of *tests* holds at *at*, reading no byte past the
    # haystack (`PairTest#holds_at?`).
    private def any_test_holds_at?(tests : Slice(UInt64), at : Int32) : Bool
      index = 0
      bytes = @haystack
      while index < tests.size
        test = tests.to_unsafe + index
        index += StaticPrefilter::WORDS_PER_TEST
        first = test[0].to_i32
        second = test[1].to_i32
        third = test[2].to_i32
        next if at + Math.max(second, third) >= bytes.size
        next unless bytes.unsafe_fetch(at + first) | test[3].to_u8! == test[4].to_u8!
        next unless bytes.unsafe_fetch(at + second) | test[5].to_u8! == test[6].to_u8!
        return true if bytes.unsafe_fetch(at + third) | test[7].to_u8! == test[8].to_u8!
      end
      false
    end

    {% for width, name in {2 => "two", 3 => "three"} %}
    private def find_pairs_reading_{{name.id}}(from : Int32, meter : StaticMeter, tests : Slice(UInt64)) : Int32
      last = @haystack.size - @prefilter.minimum_length
      word_last = @haystack.size - 8 - reach_of(tests)
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      list = tests.to_unsafe
      words = tests.size
      while at <= last
        stop = at + meter.readable(Math.min(PrefilterScan::CHARGE_CHUNK, last + 1 - at), at) - 1
        chunk_from = at
        found = -1
        word_stop = Math.min(stop - 7, word_last)
        while at <= word_stop
          lanes = 0_u64
          index = 0
          while index < words
            test = list + index
            test_lanes = PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test[0]) | test[3]) ^ test[4]) &
                         PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test[1]) | test[5]) ^ test[6])
            {% if width == 3 %}
              test_lanes &= PrefilterScan.zero_lanes((PrefilterScan.word_at(bytes + at + test[2]) | test[7]) ^ test[8])
            {% end %}
            lanes |= test_lanes
            index += StaticPrefilter::WORDS_PER_TEST
          end
          if lanes != 0
            while lanes != 0
              candidate = at + lanes.trailing_zeros_count // 8
              break if candidate > stop
              lanes &= lanes &- 1
              meter.charge(candidate - chunk_from + 1, candidate)
              return candidate if accept?(candidate, meter)
              chunk_from = candidate + 1
              stop = chunk_from + meter.readable(Math.min(PrefilterScan::CHARGE_CHUNK, last + 1 - chunk_from), chunk_from) - 1
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
            if any_test_holds_at?(tests, at)
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

    # The packed search (`PrefilterScan#find_packed`).
    private def find_packed(from : Int32, meter : StaticMeter) : Int32
      width = @prefilter.mask_width
      last = @haystack.size - width
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      table = @prefilter.masks.to_unsafe
      while at <= last
        stop = at + meter.readable(Math.min(PrefilterScan::CHARGE_CHUNK, last + 1 - at), at) - 1
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
