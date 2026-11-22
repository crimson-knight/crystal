module YAML::Mica::YAML
  # Brings a parse's input into memory as UTF-8.
  #
  # :nodoc:
  module Source
    private READ_CHUNK = 65_536

    # Returns *source* as UTF-8 bytes: a `String` or `Bytes` in place, an
    # `IO` read to its end. UTF-16 and UTF-32 input (detected as the YAML
    # specification describes: by its byte order mark or by the zero bytes
    # around its first character) is converted. Raises `ParseLimitError`
    # when the input is larger than `max_input_bytes`.
    def self.read(source : String | Bytes | IO, limits : ParseLimits, meter : Core::WorkMeter,
                  dialect : Dialect) : Bytes
      bytes = if source.is_a?(String)
                source.to_slice
              elsif source.is_a?(Bytes)
                source
              else
                read_io(source, limits, meter)
              end
      check_size(bytes.size.to_i64, limits)
      transcode(bytes, meter, dialect)
    end

    private def self.check_size(size : Int64, limits : ParseLimits) : Nil
      return if size <= limits.max_input_bytes
      raise ParseLimitError.new("Input is larger than max_input_bytes (#{limits.max_input_bytes})",
        Core::Position.new(limits.max_input_bytes, 0, 0), "max_input_bytes")
    end

    private def self.read_io(io : IO, limits : ParseLimits, meter : Core::WorkMeter) : Bytes
      buffer = Bytes.new(READ_CHUNK)
      size = 0
      loop do
        if size == buffer.size
          larger = Bytes.new(buffer.size * 2)
          Core::ByteScan.copy_into(larger, 0, buffer)
          buffer = larger
        end
        count = io.read(buffer[size, buffer.size - size])
        break if count == 0
        size += count
        check_size(size.to_i64, limits)
        meter.enforce_deadline("while reading YAML") { Core::Position.new(size.to_i64, 0, 0) }
      end
      buffer[0, size]
    end

    # Returns the width in bytes of a code unit, whether it is big-endian
    # and the size of the byte order mark when *bytes* is UTF-16 or UTF-32,
    # or nil for UTF-8. libyaml knows UTF-16 behind a byte order mark only.
    private def self.wide_encoding(bytes : Bytes, dialect : Dialect) : {Int32, Bool, Int32}?
      if dialect.lib_yaml?
        return nil unless bytes.size >= 2
        return {2, true, 2} if bytes[0] == 0xFE && bytes[1] == 0xFF
        return {2, false, 2} if bytes[0] == 0xFF && bytes[1] == 0xFE
        return nil
      end
      first = bytes.size > 0 ? bytes[0] : 0xAA_u8
      second = bytes.size > 1 ? bytes[1] : 0xAA_u8
      third = bytes.size > 2 ? bytes[2] : 0xAA_u8
      fourth = bytes.size > 3 ? bytes[3] : 0xAA_u8
      if bytes.size >= 4 && first == 0 && second == 0 && third == 0xFE && fourth == 0xFF
        {4, true, 4}
      elsif bytes.size >= 4 && first == 0 && second == 0 && third == 0
        {4, true, 0}
      elsif bytes.size >= 4 && first == 0xFF && second == 0xFE && third == 0 && fourth == 0
        {4, false, 4}
      elsif bytes.size >= 4 && second == 0 && third == 0 && fourth == 0
        {4, false, 0}
      elsif bytes.size >= 2 && first == 0xFE && second == 0xFF
        {2, true, 2}
      elsif bytes.size >= 2 && first == 0 && second != 0
        {2, true, 0}
      elsif bytes.size >= 2 && first == 0xFF && second == 0xFE
        {2, false, 2}
      elsif bytes.size >= 2 && second == 0 && first != 0
        {2, false, 0}
      else
        nil
      end
    end

    private def self.transcode(bytes : Bytes, meter : Core::WorkMeter, dialect : Dialect) : Bytes
      encoding = wide_encoding(bytes, dialect)
      unless encoding
        # A UTF-8 byte order mark at the very start is not content.
        return bytes[3, bytes.size - 3] if bytes.size >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        return bytes
      end
      width, big_endian, start = encoding
      output = ByteBuffer.new(bytes.size)
      encoded = uninitialized UInt8[4]
      index = start
      while index + width <= bytes.size
        unit = read_unit(bytes, index, width, big_endian)
        offset = index
        index += width
        if width == 2 && unit >= 0xD800 && unit <= 0xDBFF && index + 2 <= bytes.size
          low = read_unit(bytes, index, 2, big_endian)
          if low >= 0xDC00 && low <= 0xDFFF
            unit = 0x10000_u32 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            index += 2
          end
        end
        if (unit >= 0xD800 && unit <= 0xDFFF) || unit > 0x10FFFF
          raise InvalidCharacterError.new("invalid UTF-#{width * 8} code unit", Core::Position.new(offset.to_i64, 0, 0))
        end
        size = Core::UTF8.encode(unit.to_i32, encoded.to_slice)
        output.write(encoded.to_slice[0, size])
        if meter.charge(width)
          meter.enforce("while reading YAML") { Core::Position.new(offset.to_i64, 0, 0) }
        end
      end
      if index != bytes.size
        raise InvalidCharacterError.new("incomplete UTF-#{width * 8} code unit", Core::Position.new(index.to_i64, 0, 0))
      end
      output.to_slice
    end

    private def self.read_unit(bytes : Bytes, index : Int32, width : Int32, big_endian : Bool) : UInt32
      unit = 0_u32
      width.times do |step|
        byte = bytes[big_endian ? index + step : index + width - 1 - step]
        unit = (unit << 8) | byte
      end
      unit
    end
  end
end
