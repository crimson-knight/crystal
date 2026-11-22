class YAML::Mica::YAML::Emitter
  # The kinds of event the emitter accepts, one per public method.
  private enum EventKind
    StreamStart
    StreamEnd
    DocumentStart
    DocumentEnd
    Alias
    Scalar
    SequenceStart
    SequenceEnd
    MappingStart
    MappingEnd

    # Returns true for the events that open a nesting level in the
    # look-ahead queue.
    def opens_level? : Bool
      stream_start? || document_start? || sequence_start? || mapping_start?
    end

    # Returns true for the events that close a nesting level in the
    # look-ahead queue.
    def closes_level? : Bool
      stream_end? || document_end? || sequence_end? || mapping_end?
    end
  end

  # One queued event. *implicit* is the document's, the collection's or the
  # scalar's plain implicit flag; *flow* asks for the flow style of a
  # collection.
  private record Event,
    kind : EventKind,
    anchor : Bytes? = nil,
    tag : Bytes? = nil,
    value : Bytes = Bytes.empty,
    implicit : Bool = false,
    quoted_implicit : Bool = false,
    flow : Bool = false,
    scalar_style : ScalarStyle = ScalarStyle::Any
end
