module Regex::Mica::Regex
  # :nodoc:
  # When a search call validates its haystack as UTF-8, then it reads the
  # haystack in windows the call's meter allows before each is read
  # (`SearchMeter#readable` or `StaticMeter#readable`), one operation per
  # byte, so the deadline and `max_work` stop a long validation as they
  # stop a scan; it raises `Mica::EncodingError` naming the first invalid
  # byte. `M` is the meter's type: the runtime engine's `SearchMeter` or a
  # static search's `StaticMeter`. Nothing is allocated.
  struct ValidateInWindows(M)
    def initialize(@bytes : Bytes, @meter : M)
    end

    def perform : Nil
      bytes = @bytes
      at = 0
      # A haystack the meter allows in one window (a line, a form field):
      # one pass, with no window to place.
      if bytes.size > 0 && @meter.readable(bytes.size, at) == bytes.size
        if offset = Core::UTF8.first_invalid_offset(bytes)
          raise Mica::EncodingError.new("The haystack is not valid UTF-8", Core::Position.new(offset.to_i64))
        end
        @meter.charge(bytes.size, at)
        return
      end
      while at < bytes.size
        stop = window_end_at_a_character(at, at + @meter.readable(bytes.size - at, at))
        if offset = Core::UTF8.first_invalid_offset(bytes[at, stop - at])
          raise Mica::EncodingError.new("The haystack is not valid UTF-8", Core::Position.new((at + offset).to_i64))
        end
        @meter.charge(stop - at, at)
        at = stop
      end
    end

    # Moves the end *stop* of a window that starts at *at* so no character
    # is split between two windows: back to the lead byte of the character
    # it would cut, or, when that empties the window, on past at most three
    # continuation bytes (an invalid run longer than a character is then
    # split, and the window still holds its first part).
    private def window_end_at_a_character(at : Int32, stop : Int32) : Int32
      bytes = @bytes
      boundary = stop
      while boundary > at && boundary < bytes.size && bytes.unsafe_fetch(boundary) & 0xC0 == 0x80
        boundary -= 1
      end
      return boundary if boundary > at
      boundary = at + 1
      while boundary < bytes.size && boundary - at < 4 && bytes.unsafe_fetch(boundary) & 0xC0 == 0x80
        boundary += 1
      end
      boundary
    end
  end
end
