module Crystal::Mica::Encoding
  # What a decoder or encoder does when it meets a problem.
  enum ErrorMode
    # Stop: `convert` returns `Status::Error` with the problem and its
    # offset, and the one-shot methods raise `ConversionError`. The
    # converter then returns to its initial state, so a caller may go on
    # converting (WHATWG Encoding, 2026-11-20: a decoder resets after a
    # fatal error).
    Fatal
    # Decoders write U+FFFD for each maximal subpart of an ill-formed
    # sequence (Unicode chapter 3, "U+FFFD Substitution of Maximal
    # Subparts"; the Encoding Standard's decoders follow it). Encoders
    # write the Encoding Standard's "html" replacement, a decimal character
    # reference such as `&#20320;`, for a code point the encoding lacks,
    # and encode U+FFFD for ill-formed UTF-8 input.
    Replacement
    # Drop what fails and go on, as the standard library's
    # `invalid: :skip` does.
    Skip
  end

  # Which of two label tables `Encoding.lookup` reads.
  enum LabelRule
    # The Encoding Standard's labels, exactly (`iso-8859-1` and `ascii`
    # name windows-1252, `utf-16` names UTF-16LE). HTTP and HTML use it.
    Web
    # iconv's meanings for the names Crystal programs pass to
    # `String#encode` and `IO#set_encoding` (`ISO-8859-1` is exact Latin-1,
    # `UTF-16` reads a byte order mark, `UCS-2` and `UTF-32` exist), then
    # the web labels for every other name, minus the labels of the
    # replacement encoding.
    IconvCompatible
  end

  # The kind of problem a conversion met.
  enum Problem
    # Bytes that are not a valid sequence of the source encoding (for an
    # encoder: input that is not valid UTF-8).
    InvalidSequence
    # The input ended inside a sequence.
    IncompleteSequence
    # A code point the target encoding cannot represent (encoders only).
    Unmappable

    def describe : String
      case self
      in .invalid_sequence?    then "invalid byte sequence"
      in .incomplete_sequence? then "incomplete byte sequence at the end of the input"
      in .unmappable?          then "code point the encoding cannot represent"
      end
    end
  end

  # Why `convert` returned.
  enum Status
    # Every input byte was consumed.
    InputEmpty
    # The output buffer has too little room for the next step; call again
    # with more room. The input is consumed up to `Result#read`.
    OutputFull
    # A problem in `ErrorMode::Fatal`; see `Result#problem`.
    Error
  end

  # What one call to `Decoder#convert` or `Encoder#convert` did.
  record Result,
    # Why the call returned.
    status : Status,
    # Input bytes consumed by this call.
    read : Int32,
    # Output bytes written by this call.
    written : Int32,
    # The problem, when `status` is `Status::Error`.
    problem : Problem? = nil,
    # The 0-based offset, counted over the whole stream since the converter
    # was created, of the first byte of the sequence the problem is in;
    # -1 without a problem.
    offset : Int64 = -1_i64,
    # The code point an encoder could not represent; -1 otherwise.
    code_point : Int32 = -1 do
    def error? : Bool
      status.error?
    end

    def output_full? : Bool
      status.output_full?
    end
  end

  # Raised by the one-shot methods for a problem in `ErrorMode::Fatal`.
  class ConversionError < Mica::Error
    getter codec : Codec
    getter problem : Problem
    # Offset in the source of the first byte of the failing sequence.
    getter offset : Int64
    # The code point an encoder could not represent; -1 otherwise.
    getter code_point : Int32

    def initialize(@codec : Codec, @problem : Problem, @offset : Int64, @code_point : Int32 = -1)
      detail = @problem.unmappable? ? "U+#{@code_point.to_s(16, upcase: true).rjust(4, '0')}, a #{@problem.describe}" : @problem.describe
      super("#{@codec.name}: #{detail} at byte #{@offset}")
    end
  end

  # Raised by `Encoding.lookup!` for a label neither rule knows, or one
  # longer than `Encoding::MAX_LABEL_BYTES`.
  class UnknownEncodingError < Mica::Error
    getter label : String

    def initialize(label : String)
      @label = label.bytesize > MAX_LABEL_BYTES ? label.byte_slice(0, MAX_LABEL_BYTES) + "..." : label
      super("Unknown encoding: #{@label}")
    end
  end
end
