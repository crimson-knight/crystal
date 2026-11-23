module Crystal::Mica::Encoding
  # Labels longer than this many bytes are refused before lookup. The
  # longest label either rule knows is under 20 bytes.
  MAX_LABEL_BYTES = 64

  # Returns the codec for a name whose iconv meaning `LabelRule::IconvCompatible`
  # keeps, given already trimmed and ASCII-lowercased, or nil. Names not
  # listed here fall through to the Encoding Standard's labels (minus
  # replacement's), which already cover `Shift_JIS`, `EUC-JP`, `GBK`,
  # `windows-1252`, `KOI8-R` and so on under their usual iconv spellings.
  def self.iconv_name(key : String) : Codec?
    case key
    when "utf-8", "utf8"                                                                                                                                  then Codec::UTF8
    when "utf-16", "utf16", "unicode"                                                                                                                     then Codec::UTF16
    when "utf-16be", "utf16be"                                                                                                                            then Codec::UTF16BE
    when "utf-16le", "utf16le"                                                                                                                            then Codec::UTF16LE
    when "utf-32", "utf32"                                                                                                                                then Codec::UTF32
    when "utf-32be", "utf32be", "ucs-4", "ucs4", "ucs-4be", "iso-10646-ucs-4"                                                                             then Codec::UTF32BE
    when "utf-32le", "utf32le", "ucs-4le"                                                                                                                 then Codec::UTF32LE
    when "ucs-2", "ucs2", "iso-10646-ucs-2", "csunicode"                                                                                                  then Codec::UCS2
    when "ucs-2be", "ucs2be", "unicodebig"                                                                                                                then Codec::UCS2BE
    when "ucs-2le", "ucs2le", "unicodelittle"                                                                                                             then Codec::UCS2LE
    when "ascii", "us-ascii", "ansi_x3.4-1968", "ansi_x3.4-1986", "iso646-us", "iso_646.irv:1991", "iso-ir-6", "us", "646", "csascii", "cp367", "ibm367"  then Codec::USASCII
    when "iso-8859-1", "iso8859-1", "iso_8859-1", "iso88591", "iso_8859-1:1987", "8859_1", "latin1", "l1", "cp819", "ibm819", "iso-ir-100", "csisolatin1" then Codec::ISO8859_1
    when "big5-hkscs", "big5hkscs"                                                                                                                        then Codec::Big5HKSCS
    when "cp936", "euc-cn", "euccn"                                                                                                                       then Codec::GBK
    when "cp949", "uhc", "euckr"                                                                                                                          then Codec::EUCKR
    when "cp950"                                                                                                                                          then Codec::Big5
    when "eucjp"                                                                                                                                          then Codec::EUCJP
    when "macroman"                                                                                                                                       then Codec::Macintosh
    end
  end

  # Returns the encoding *label* names under *rule*, or nil when the rule
  # does not know it. Leading and trailing ASCII whitespace is ignored and
  # ASCII letters match in either case, as the Encoding Standard's "get an
  # encoding" says. A label over `MAX_LABEL_BYTES` bytes returns nil
  # without being examined further.
  #
  # ```
  # Mica::Encoding.lookup(" Latin1 ")                           # => Mica::Encoding::Codec::Windows1252
  # Mica::Encoding.lookup("latin1", :iconv_compatible)          # => Mica::Encoding::Codec::ISO8859_1
  # Mica::Encoding.lookup("ISO-2022-CN-EXT")                    # => Mica::Encoding::Codec::Replacement
  # Mica::Encoding.lookup("ISO-2022-CN-EXT", :iconv_compatible) # => nil
  # ```
  def self.lookup(label : String, rule : LabelRule = LabelRule::Web) : Codec?
    return if label.bytesize > MAX_LABEL_BYTES
    key = normalize_label(label)
    if rule.web?
      Tables.web_label(key)
    elsif codec = iconv_name(key)
      codec
    elsif codec = Tables.web_label(key)
      codec unless codec.replacement?
    end
  end

  # Like `lookup`, but raises `UnknownEncodingError` for a label the rule
  # does not know.
  def self.lookup!(label : String, rule : LabelRule = LabelRule::Web) : Codec
    lookup(label, rule) || raise UnknownEncodingError.new(label)
  end

  # Trims ASCII whitespace (TAB, LF, FF, CR, SPACE) and lowercases ASCII
  # letters.
  private def self.normalize_label(label : String) : String
    bytes = label.to_slice
    start = 0
    finish = bytes.size
    while start < finish && ascii_whitespace?(bytes[start])
      start += 1
    end
    while finish > start && ascii_whitespace?(bytes[finish - 1])
      finish -= 1
    end
    String.new(finish - start) do |buffer|
      (start...finish).each_with_index do |source, target|
        byte = bytes[source]
        buffer[target] = byte >= 'A'.ord && byte <= 'Z'.ord ? byte + 32 : byte
      end
      {finish - start, 0}
    end
  end

  private def self.ascii_whitespace?(byte : UInt8) : Bool
    byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
  end
end
