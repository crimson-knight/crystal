module Crystal::Mica::Encoding
  # Every character encoding Mica converts to and from UTF-8.
  #
  # The members up to `XUserDefined` are the encodings of the WHATWG
  # Encoding Standard, which the `LabelRule::Web` rule resolves labels to.
  # The members after it exist for the `LabelRule::IconvCompatible` rule:
  # names Crystal programs pass to `String#encode` and `IO#set_encoding`
  # whose iconv meaning differs from (or is absent from) the web's. See
  # docs/encoding.md for the table of differences.
  enum Codec
    UTF8
    IBM866
    ISO8859_2
    ISO8859_3
    ISO8859_4
    ISO8859_5
    ISO8859_6
    ISO8859_7
    ISO8859_8
    ISO8859_8_I
    ISO8859_10
    ISO8859_13
    ISO8859_14
    ISO8859_15
    ISO8859_16
    KOI8_R
    KOI8_U
    Macintosh
    Windows874
    Windows1250
    Windows1251
    Windows1252
    Windows1253
    Windows1254
    Windows1255
    Windows1256
    Windows1257
    Windows1258
    XMacCyrillic
    GBK
    GB18030
    Big5
    EUCJP
    ISO2022JP
    ShiftJIS
    EUCKR
    Replacement
    UTF16BE
    UTF16LE
    XUserDefined

    # Exact ISO-8859-1 (every byte is the code point of the same value).
    # The web's `iso-8859-1` label means windows-1252 instead.
    ISO8859_1
    # US-ASCII: bytes 0x80 to 0xFF are errors.
    USASCII
    # UTF-16 with a byte order mark: decoding reads one (big-endian when
    # absent), encoding writes FE FF and big-endian code units.
    UTF16
    # UTF-32 with a byte order mark, as `UTF16`.
    UTF32
    UTF32BE
    UTF32LE
    # UCS-2: UTF-16 code units without surrogate pairs (U+0000 to U+FFFF
    # minus the surrogates). `UCS2` is big-endian without a byte order mark.
    UCS2
    UCS2BE
    UCS2LE
    # Big5 with the Hong Kong Supplementary Character Set in both
    # directions: the web's Big5 decoder, and an encoder that also writes
    # HKSCS characters and the four composed pairs (`Ê̄` and so on).
    Big5HKSCS

    # Returns the encoding's name: the Encoding Standard's name for the web
    # encodings (`"UTF-8"`, `"Shift_JIS"`, `"gb18030"`), the usual iconv
    # name for the others (`"ISO-8859-1"`, `"UCS-2LE"`).
    def name : String
      case self
      in .utf8?           then "UTF-8"
      in .ibm866?         then "IBM866"
      in .iso8859_2?      then "ISO-8859-2"
      in .iso8859_3?      then "ISO-8859-3"
      in .iso8859_4?      then "ISO-8859-4"
      in .iso8859_5?      then "ISO-8859-5"
      in .iso8859_6?      then "ISO-8859-6"
      in .iso8859_7?      then "ISO-8859-7"
      in .iso8859_8?      then "ISO-8859-8"
      in .iso8859_8_i?    then "ISO-8859-8-I"
      in .iso8859_10?     then "ISO-8859-10"
      in .iso8859_13?     then "ISO-8859-13"
      in .iso8859_14?     then "ISO-8859-14"
      in .iso8859_15?     then "ISO-8859-15"
      in .iso8859_16?     then "ISO-8859-16"
      in .koi8_r?         then "KOI8-R"
      in .koi8_u?         then "KOI8-U"
      in .macintosh?      then "macintosh"
      in .windows874?     then "windows-874"
      in .windows1250?    then "windows-1250"
      in .windows1251?    then "windows-1251"
      in .windows1252?    then "windows-1252"
      in .windows1253?    then "windows-1253"
      in .windows1254?    then "windows-1254"
      in .windows1255?    then "windows-1255"
      in .windows1256?    then "windows-1256"
      in .windows1257?    then "windows-1257"
      in .windows1258?    then "windows-1258"
      in .x_mac_cyrillic? then "x-mac-cyrillic"
      in .gbk?            then "GBK"
      in .gb18030?        then "gb18030"
      in .big5?           then "Big5"
      in .eucjp?          then "EUC-JP"
      in .iso2022_jp?     then "ISO-2022-JP"
      in .shift_jis?      then "Shift_JIS"
      in .euckr?          then "EUC-KR"
      in .replacement?    then "replacement"
      in .utf16_be?       then "UTF-16BE"
      in .utf16_le?       then "UTF-16LE"
      in .x_user_defined? then "x-user-defined"
      in .iso8859_1?      then "ISO-8859-1"
      in .usascii?        then "US-ASCII"
      in .utf16?          then "UTF-16"
      in .utf32?          then "UTF-32"
      in .utf32_be?       then "UTF-32BE"
      in .utf32_le?       then "UTF-32LE"
      in .ucs2?           then "UCS-2"
      in .ucs2_be?        then "UCS-2BE"
      in .ucs2_le?        then "UCS-2LE"
      in .big5_hkscs?     then "BIG5-HKSCS"
      end
    end

    # Returns true for the encodings of the WHATWG Encoding Standard.
    def web? : Bool
      value <= XUserDefined.value
    end

    # Returns true for the encodings that share their single-byte decoder
    # and encoder (one byte is one code point or an error).
    def single_byte? : Bool
      (value >= IBM866.value && value <= XMacCyrillic.value) || x_user_defined? || iso8859_1? || usascii?
    end

    # Returns true when the encoding has an encoder. The Encoding Standard
    # defines none for replacement; UTF-16BE and UTF-16LE have one here
    # because the iconv-compatible names need it.
    def encodes? : Bool
      !replacement?
    end

    # Returns the encoding a web form or URL is encoded in for this
    # encoding (the Encoding Standard's "get an output encoding"):
    # replacement, UTF-16BE and UTF-16LE give UTF-8, the others themselves.
    def output_codec : Codec
      replacement? || utf16_be? || utf16_le? ? UTF8 : self
    end

    # Returns the largest number of UTF-8 bytes decoding *input_size*
    # bytes can produce, in any error mode and any chunking. Callers that
    # meter output can charge this before converting.
    def max_decoded_size(input_size : Int) : Int64
      size = input_size.to_i64
      case self
      when .utf16?, .utf16_be?, .utf16_le?, .ucs2?, .ucs2_be?, .ucs2_le?
        size // 2 * 3 + 3
      when .utf32?, .utf32_be?, .utf32_le?
        size + 3
      else
        # Every byte at most one U+FFFD (3 bytes); a two-byte sequence at
        # most two code points of 2 bytes each (Big5's composed pairs).
        size * 3 + 3
      end
    end

    # Returns the largest number of bytes encoding *input_size* bytes of
    # UTF-8 can produce. `ErrorMode::Replacement` writes a decimal
    # character reference (`&#65533;`, 8 bytes) for each byte that fails,
    # which dominates the bound for the legacy encodings.
    def max_encoded_size(input_size : Int, error_mode : ErrorMode = ErrorMode::Fatal) : Int64
      size = input_size.to_i64
      case self
      when .utf8?
        size * 3
      when .utf16?, .utf16_be?, .utf16_le?, .ucs2?, .ucs2_be?, .ucs2_le?
        size * 2 + 2
      when .utf32?, .utf32_be?, .utf32_le?
        size * 4 + 4
      else
        # ISO-2022-JP may need an escape (3 bytes) before every character
        # and one at the end; a character reference is at most 10 bytes
        # for 4 bytes of input, 8 bytes for 1.
        error_mode.replacement? ? size * 8 + 3 : size * 3 + 3
      end
    end
  end
end
