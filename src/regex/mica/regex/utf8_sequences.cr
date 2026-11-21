module Regex::Mica::Regex
  # Splits code point ranges into UTF-8 byte-range sequences, the way RE2
  # and Rust regex build their byte automata: a range is split at the
  # boundaries between encoding lengths, around the surrogate gap, and
  # wherever its first and last code point differ in more than the final
  # continuation bytes. Each resulting sequence is 1 to 4 byte ranges that
  # match exactly the UTF-8 encodings of its code points.
  #
  # The size preflight and the NFA compiler (R2) both call this routine, so
  # the preflight's count of byte transitions is exact, and it allocates
  # nothing: the split uses a fixed-size stack.
  #
  # ```
  # Mica::Regex::Utf8Sequences.count(0x00, 0x7F)     # => {1, 1}
  # Mica::Regex::Utf8Sequences.count(0x80, 0x10FFFF) # => {8, 26}
  # ```
  module Utf8Sequences
    # Pushes a range on the fixed split stack of `each`.
    private macro push_range(low, high)
      stack[depth] = {{low}}
      stack[depth + 1] = {{high}}
      depth += 2
    end

    # The highest code point encoded in 1, 2, 3 and 4 bytes.
    MAX_FOR_LENGTH = StaticArray[0x7F, 0x7FF, 0xFFFF, 0x10FFFF]

    # Calls the block once per sequence covering *first*..*last* (surrogates
    # skipped) with the sequence's byte length (1 to 4) and its first and
    # last code point.
    def self.each(first : Int32, last : Int32, & : Int32, Int32, Int32 ->) : Nil
      stack = StaticArray(Int32, 64).new(0)
      depth = 0
      push_range(first, last)
      while depth > 0
        depth -= 2
        low = stack[depth]
        high = stack[depth + 1]
        next if low > high
        if low <= 0xDFFF && high >= 0xD800
          if high > 0xDFFF
            push_range(0xE000, high)
          end
          if low < 0xD800
            push_range(low, 0xD7FF)
          end
          next
        end
        split = false
        MAX_FOR_LENGTH.each do |maximum|
          if low <= maximum && maximum < high
            push_range(maximum + 1, high)
            push_range(low, maximum)
            split = true
            break
          end
        end
        next if split
        length = encoded_length(low)
        (1...length).each do |index|
          mask = (1 << (6 * index)) - 1
          if (low & ~mask) != (high & ~mask)
            if (low & mask) != 0
              push_range((low | mask) + 1, high)
              push_range(low, low | mask)
              split = true
              break
            end
            if (high & mask) != mask
              push_range(high & ~mask, high)
              push_range(low, (high & ~mask) - 1)
              split = true
              break
            end
          end
        end
        next if split
        yield length, low, high
      end
    end

    # Returns `{sequences, byte ranges}` for *first*..*last*.
    def self.count(first : Int32, last : Int32) : {Int64, Int64}
      sequences = 0_i64
      byte_ranges = 0_i64
      each(first, last) do |length, _low, _high|
        sequences += 1
        byte_ranges += length
      end
      {sequences, byte_ranges}
    end

    # Returns the UTF-8 length of *code_point*.
    def self.encoded_length(code_point : Int32) : Int32
      return 1 if code_point <= 0x7F
      return 2 if code_point <= 0x7FF
      return 3 if code_point <= 0xFFFF
      4
    end
  end
end
