# The default engine behind `String#encode`, `String.new(bytes, encoding)`
# and `IO#set_encoding`: Mica's implementation of the WHATWG Encoding
# Standard, vendored in `src/crystal/mica/` (see `doc/encoding_mica.md`). It
# links no library. `-Duse_libiconv` (GNU libiconv) and `-Duse_iconv` (the
# platform's iconv) select iconv instead.
require "crystal/mica/encoding"

# :nodoc:
module Crystal::MicaEncoding
  alias Codec = Crystal::Mica::Encoding::Codec
  alias ErrorMode = Crystal::Mica::Encoding::ErrorMode

  # Returns the codec for an encoding name as iconv would read it, or
  # raises `ArgumentError` the way the iconv engine does.
  def self.codec(name : String, from : String, to : String) : Codec
    Crystal::Mica::Encoding.lookup(name, Crystal::Mica::Encoding::LabelRule::IconvCompatible) || raise invalid_encoding(from, to)
  end

  def self.error_mode(invalid : Symbol?) : ErrorMode
    invalid == :skip ? ErrorMode::Skip : ErrorMode::Fatal
  end

  # The iconv engine's message for an unknown name, naming the one that is
  # unknown, plus a pointer to the flag that brings iconv back.
  def self.invalid_encoding(from : String, to : String) : ArgumentError
    known_from = Crystal::Mica::Encoding.lookup(from, Crystal::Mica::Encoding::LabelRule::IconvCompatible)
    known_to = Crystal::Mica::Encoding.lookup(to, Crystal::Mica::Encoding::LabelRule::IconvCompatible)
    names = if known_from && !known_to
              to
            elsif known_to && !known_from
              from
            else
              "#{from} -> #{to}"
            end
    ArgumentError.new("Invalid encoding: #{names} (the built-in engine knows the WHATWG Encoding Standard's encodings plus UTF-16, UTF-32, UCS-2, ISO-8859-1, US-ASCII and BIG5-HKSCS; build with -Duse_libiconv or -Duse_iconv for others)")
  end

  # The iconv engine's message for a conversion problem.
  def self.conversion_error(problem : Crystal::Mica::Encoding::Problem?) : ArgumentError
    if problem.try(&.incomplete_sequence?)
      ArgumentError.new("Incomplete multibyte sequence")
    else
      ArgumentError.new("Invalid multibyte sequence")
    end
  end

  # `String.new(bytes, encoding, invalid)`.
  def self.decode(bytes : Bytes, encoding : String, invalid : Symbol?) : String
    IO::EncodingOptions.check_invalid(invalid)
    codec(encoding, encoding, "UTF-8").decoder(error_mode(invalid)).decode(bytes)
  rescue error : Crystal::Mica::Encoding::ConversionError
    raise conversion_error(error.problem)
  end

  # `String#encode(encoding, invalid)`.
  def self.encode(bytes : Bytes, encoding : String, invalid : Symbol?) : Bytes
    IO::EncodingOptions.check_invalid(invalid)
    codec(encoding, "UTF-8", encoding).encoder(error_mode(invalid)).encode(bytes)
  rescue error : Crystal::Mica::Encoding::ConversionError
    raise conversion_error(error.problem)
  end

  # `String.encode(slice, from, to, io, invalid)`: converts between any
  # two encodings, through UTF-8 when neither is UTF-8.
  def self.transcode(slice : Bytes, from : String, to : String, io : IO, invalid : Symbol?) : Nil
    IO::EncodingOptions.check_invalid(invalid)
    from_codec = codec(from, from, to)
    to_codec = codec(to, from, to)
    mode = error_mode(invalid)
    if from_codec.utf8?
      to_codec.encoder(mode).encode(slice, io)
    elsif to_codec.utf8?
      from_codec.decoder(mode).decode(slice, io)
    else
      to_codec.encoder(mode).encode(from_codec.decoder(mode).decode(slice).to_slice, io)
    end
  rescue error : Crystal::Mica::Encoding::ConversionError
    raise conversion_error(error.problem)
  end
end
