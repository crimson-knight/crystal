require "./tables/labels"
require "./tables/single_byte"
require "./tables/jis0208"
require "./tables/jis0212"
require "./tables/iso_2022_jp_katakana"
require "./tables/euc_kr"
require "./tables/gb18030"
require "./tables/big5"

# Lookups over the generated index tables (scripts/generate_encoding_tables.rb).
# Every table is a read-only `Slice.literal`; nothing here allocates.
module Crystal::Mica::Encoding
  # A reverse index (code point to pointer), built from a forward index
  # the first time an encoder needs it. The Basic Multilingual Plane is a
  # page map (one entry per high byte: 0, or the 1-based number of a
  # 256-entry block whose entries are pointer + 1); code points above
  # U+FFFF go in a hash. Built once per process (constants initialize
  # lazily and under a lock) and read-only afterwards.
  class ReverseTable
    @pages = StaticArray(UInt16, 256).new(0_u16)
    @values = [] of UInt16
    @astral = {} of Int32 => Int32

    # Indexes every pointer of *forward* from *first_pointer* on, outside
    # *excluded*, keeping the first pointer for each code point.
    def initialize(forward : Slice, first_pointer : Int32 = 0, excluded : Range(Int32, Int32)? = nil)
      (first_pointer...forward.size).each do |pointer|
        next if excluded && excluded.includes?(pointer)
        code_point = forward.unsafe_fetch(pointer).to_i32
        add(code_point, pointer, replace: false) unless code_point == 0
      end
    end

    # Makes each of *code_points* map to its last pointer at or after
    # *first_pointer* in *forward*.
    def prefer_last(forward : Slice, code_points : Tuple, first_pointer : Int32) : self
      code_points.each do |target|
        last = (first_pointer...forward.size).reverse_each.find { |pointer| forward.unsafe_fetch(pointer).to_i32 == target }
        add(target, last, replace: true) if last
      end
      self
    end

    # Adds the first pointer of every code point of *forward* still missing.
    def fill_from(forward : Slice) : self
      forward.each_with_index do |code_point, pointer|
        add(code_point.to_i32, pointer, replace: false) unless code_point == 0
      end
      self
    end

    # Returns the pointer for *code_point*, or -1.
    @[AlwaysInline]
    def pointer_for(code_point : Int32) : Int32
      if code_point <= 0xFFFF
        page = @pages.unsafe_fetch(code_point >> 8).to_i32
        return -1 if page == 0
        @values.unsafe_fetch(((page - 1) << 8) | (code_point & 0xFF)).to_i32 - 1
      else
        @astral.fetch(code_point, -1)
      end
    end

    private def add(code_point : Int32, pointer : Int32, replace : Bool) : Nil
      if code_point > 0xFFFF
        @astral[code_point] = pointer if replace || !@astral.has_key?(code_point)
        return
      end
      page = @pages[code_point >> 8].to_i32
      if page == 0
        @values.concat(Array(UInt16).new(256, 0_u16))
        page = @values.size // 256
        @pages[code_point >> 8] = page.to_u16
      end
      slot = ((page - 1) << 8) | (code_point & 0xFF)
      @values[slot] = (pointer + 1).to_u16 if replace || @values[slot] == 0
    end
  end
end

module Crystal::Mica::Encoding::Tables
  # Returns the index code point for *pointer* in *index*, or -1 when the
  # pointer has none.
  @[AlwaysInline]
  def self.code_point(index : Slice, pointer : Int32) : Int32
    return -1 if pointer < 0 || pointer >= index.size
    code_point = index.unsafe_fetch(pointer).to_i32
    code_point == 0 ? -1 : code_point
  end

  # Reverse lookups, each built from its forward index on first use and
  # kept in a class variable (a constant would be built at program start).
  # Two fibers on different threads may both build one the first time; each
  # builds the same table, and the reference is published whole.
  {% for spec in [
                   {"jis0208", "ReverseTable.new(JIS0208)"},
                   {"shift_jis", "ReverseTable.new(JIS0208, excluded: 8272..8835)"},
                   {"euc_kr", "ReverseTable.new(EUC_KR)"},
                   {"gb18030", "ReverseTable.new(GB18030)"},
                   {"big5", "ReverseTable.new(BIG5, first_pointer: BIG5_FIRST_POINTER).prefer_last(BIG5, BIG5_LAST_POINTER_CODE_POINTS, BIG5_FIRST_POINTER)"},
                   {"big5_hkscs", "ReverseTable.new(BIG5, first_pointer: BIG5_FIRST_POINTER).prefer_last(BIG5, BIG5_LAST_POINTER_CODE_POINTS, BIG5_FIRST_POINTER).fill_from(BIG5)"},
                 ] %}
    @@{{ spec[0].id }}_reverse : ReverseTable? = nil

    # Returns the pointer for *code_point* (see the comments above), or -1.
    def self.{{ spec[0].id }}_encode(code_point : Int32) : Int32
      table = @@{{ spec[0].id }}_reverse ||= {{ spec[1].id }}
      table.pointer_for(code_point)
    end
  {% end %}

  # Index Big5 pointer: pointers below (0xA1 - 0x81) * 157 are excluded
  # (HKSCS is not written back), and six code points take their last
  # pointer. BIG5-HKSCS (iconv-compatible) falls back to the first pointer
  # anywhere in the index.
  BIG5_FIRST_POINTER            = (0xA1 - 0x81) * 157
  BIG5_LAST_POINTER_CODE_POINTS = {0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345}

  # Returns the code point for a four-byte gb18030 *pointer* (the
  # Encoding Standard's "index gb18030 ranges code point"), or -1.
  def self.gb18030_ranges_code_point(pointer : Int32) : Int32
    return -1 if (pointer > 39419 && pointer < 189000) || pointer > 1237575
    return 0xE7C7 if pointer == 7457
    found = GB18030_RANGE_POINTERS.bsearch_index { |offset| offset > pointer.to_u32 } || GB18030_RANGE_POINTERS.size
    index = found - 1
    GB18030_RANGE_CODE_POINTS.unsafe_fetch(index).to_i32 + pointer - GB18030_RANGE_POINTERS.unsafe_fetch(index).to_i32
  end

  # Returns the four-byte gb18030 pointer for *code_point* (the Encoding
  # Standard's "index gb18030 ranges pointer").
  def self.gb18030_ranges_pointer(code_point : Int32) : Int32
    return 7457 if code_point == 0xE7C7
    found = GB18030_RANGE_CODE_POINTS.bsearch_index { |offset| offset > code_point.to_u32 } || GB18030_RANGE_CODE_POINTS.size
    index = found - 1
    GB18030_RANGE_POINTERS.unsafe_fetch(index).to_i32 + code_point - GB18030_RANGE_CODE_POINTS.unsafe_fetch(index).to_i32
  end

  # Index single-byte for a legacy single-byte *codec*: 128 code points
  # for bytes 0x80 to 0xFF, 0 for none.
  def self.single_byte(codec : Codec) : Slice(UInt16)
    {% begin %}
      case codec
      {% for member in %w(IBM866 ISO8859_2 ISO8859_3 ISO8859_4 ISO8859_5 ISO8859_6 ISO8859_7 ISO8859_8 ISO8859_10 ISO8859_13 ISO8859_14 ISO8859_15 ISO8859_16 KOI8_R KOI8_U Macintosh Windows874 Windows1250 Windows1251 Windows1252 Windows1253 Windows1254 Windows1255 Windows1256 Windows1257 Windows1258 XMacCyrillic) %}
        when Codec::{{ member.id }} then {{ member.upcase.id }}
      {% end %}
      when Codec::ISO8859_8_I    then ISO8859_8
      when Codec::ISO8859_1      then LATIN1
      when Codec::XUserDefined   then X_USER_DEFINED
      when Codec::USASCII        then ASCII_ONLY
      else
        raise ArgumentError.new("#{codec.name} is not a single-byte encoding")
      end
    {% end %}
  end

  {% for member in %w(IBM866 ISO8859_2 ISO8859_3 ISO8859_4 ISO8859_5 ISO8859_6 ISO8859_7 ISO8859_8 ISO8859_10 ISO8859_13 ISO8859_14 ISO8859_15 ISO8859_16 KOI8_R KOI8_U Macintosh Windows874 Windows1250 Windows1251 Windows1252 Windows1253 Windows1254 Windows1255 Windows1256 Windows1257 Windows1258 XMacCyrillic) %}
    @@{{ member.downcase.id }}_reverse : ReverseTable? = nil
  {% end %}

  # The reverse lookup for a table-driven single-byte *codec* (a pointer is
  # the byte minus 0x80), or nil for the ones encoded by arithmetic (exact
  # ISO-8859-1, x-user-defined, US-ASCII).
  def self.single_byte_reverse(codec : Codec) : ReverseTable?
    {% begin %}
      case codec
      {% for member in %w(IBM866 ISO8859_2 ISO8859_3 ISO8859_4 ISO8859_5 ISO8859_6 ISO8859_7 ISO8859_8 ISO8859_10 ISO8859_13 ISO8859_14 ISO8859_15 ISO8859_16 KOI8_R KOI8_U Macintosh Windows874 Windows1250 Windows1251 Windows1252 Windows1253 Windows1254 Windows1255 Windows1256 Windows1257 Windows1258 XMacCyrillic) %}
        when Codec::{{ member.id }} then @@{{ member.downcase.id }}_reverse ||= ReverseTable.new({{ member.upcase.id }})
      {% end %}
      when Codec::ISO8859_8_I then @@iso8859_8_reverse ||= ReverseTable.new(ISO8859_8)
      else                         nil
      end
    {% end %}
  end

  # Exact ISO-8859-1: byte n is U+00nn.
  LATIN1 = {% begin %}Slice(UInt16).literal({{ (0x80..0xFF).to_a.map(&.id).join(", ").id }}){% end %}

  # x-user-defined: bytes 0x80 to 0xFF are U+F780 to U+F7FF.
  X_USER_DEFINED = {% begin %}Slice(UInt16).literal({{ (0xF780..0xF7FF).to_a.map(&.id).join(", ").id }}){% end %}

  # US-ASCII: no byte above 0x7F has a code point.
  ASCII_ONLY = {% begin %}Slice(UInt16).literal({{ (0...128).to_a.map { 0 }.join(", ").id }}){% end %}
end
