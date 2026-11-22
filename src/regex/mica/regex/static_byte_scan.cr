module Regex::Mica::Regex
  # :nodoc:
  # Skips runs of bytes that leave an accelerated DFA state where it is
  # (see `Static::BuildTheTables`). A state's code is one of:
  #
  # - `SKIP_ASCII`: every ASCII byte loops back, so the scan stops at the
  #   first non-ASCII byte (eight bytes at a time);
  # - a byte value 0 to 255: only that byte leaves, found with `memchr`
  #   going forward;
  # - `WORDWISE` with up to `MAX_SCAN_BYTES` ASCII bytes (and
  #   `STOPS_AT_NON_ASCII` when non-ASCII bytes leave too): a scan eight
  #   bytes at a time for any of them.
  #
  # Stopping early is always safe (the DFA reads the byte), so the scans
  # stop at a byte that might leave the state, never past one.
  module StaticByteScan
    SKIP_ASCII         = -1
    WORDWISE           = 1 << 30
    STOPS_AT_NON_ASCII = 1 << 26
    MAX_SCAN_BYTES     =                      3
    ONES               = 0x0101010101010101_u64
    HIGH_BITS          = 0x8080808080808080_u64
    LOW_SEVEN_BITS     = 0x7F7F7F7F7F7F7F7F_u64

    # The code of a word-at-a-time scan for *list_of_bytes* (ASCII).
    def self.encode(list_of_bytes : Array(Int32), stops_at_non_ascii : Bool) : Int32
      code = WORDWISE | (list_of_bytes.size << 24)
      code |= STOPS_AT_NON_ASCII if stops_at_non_ascii
      list_of_bytes.each_with_index { |byte, index| code |= byte << (8 * index) }
      code
    end

    # The first position in *at*...*stop* holding a byte that *code* stops
    # at, or *stop*.
    @[AlwaysInline]
    def self.forward(bytes : Bytes, at : Int32, stop : Int32, code : Int32) : Int32
      return Core::ByteScan.skip_ascii(bytes, at, stop) if code == SKIP_ASCII
      if code < 256
        found = bytes[at, stop - at].index(code.to_u8)
        return found ? at + found : stop
      end
      pointer = bytes.to_unsafe
      while at + 8 <= stop
        flags = stops_in((pointer + at).as(Pointer(UInt64)).value, code)
        return at + flags.trailing_zeros_count // 8 if flags != 0
        at += 8
      end
      while at < stop && !stops_at?(pointer[at], code)
        at += 1
      end
      at
    end

    # Going backward from *at* to no lower than *stop*: the position just
    # after the last byte before *at* that *code* stops at, or *stop*.
    @[AlwaysInline]
    def self.backward(bytes : Bytes, at : Int32, stop : Int32, code : Int32) : Int32
      pointer = bytes.to_unsafe
      while at - 8 >= stop
        flags = stops_in((pointer + at - 8).as(Pointer(UInt64)).value, code)
        return at - flags.leading_zeros_count // 8 if flags != 0
        at -= 8
      end
      while at > stop && !stops_at?(pointer[at - 1], code)
        at -= 1
      end
      at
    end

    # The high bit of each byte of *word* that *code* stops at (exact, so
    # either end of the flags can be read).
    @[AlwaysInline]
    private def self.stops_in(word : UInt64, code : Int32) : UInt64
      flags = code == SKIP_ASCII || code & STOPS_AT_NON_ASCII != 0 ? word & HIGH_BITS : 0_u64
      return flags if code == SKIP_ASCII
      count = code < 256 ? 1 : (code >> 24) & 3
      count.times do |index|
        byte = code < 256 ? code : (code >> (8 * index)) & 0xFF
        difference = word ^ (ONES &* byte.to_u64)
        # Exact zero-byte flags: high bit set where the byte is zero.
        flags |= ~(((difference & LOW_SEVEN_BITS) &+ LOW_SEVEN_BITS) | difference | LOW_SEVEN_BITS)
      end
      flags
    end

    @[AlwaysInline]
    private def self.stops_at?(byte : UInt8, code : Int32) : Bool
      return byte >= 0x80 if code == SKIP_ASCII
      return byte == code if code < 256
      return true if byte >= 0x80 && code & STOPS_AT_NON_ASCII != 0
      count = (code >> 24) & 3
      count.times { |index| return true if byte == (code >> (8 * index)) & 0xFF }
      false
    end
  end
end
