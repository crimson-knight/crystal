require "../mica/yaml"

# A YAML builder generates valid YAML.
#
# A `YAML::Error` is raised if attempting to generate
# an invalid YAML (for example, if invoking `end_sequence`
# without a matching `start_sequence`)
#
# ```
# require "yaml"
#
# string = YAML.build do |yaml|
#   yaml.mapping do
#     yaml.scalar "foo"
#     yaml.sequence do
#       yaml.scalar 1
#       yaml.scalar 2
#     end
#     yaml.scalar "bar"
#     yaml.mapping do
#       yaml.scalar "baz"
#       yaml.scalar "qux"
#     end
#   end
# end
# string # => "---\nfoo:\n- 1\n- 2\nbar:\n  baz: qux\n"
# ```
#
# This is the default implementation: the output comes from Mica's
# pure-Crystal emitter, which writes the same bytes as libyaml (see
# `doc/yaml_mica.md`).
class YAML::Builder
  # By default the maximum nesting of sequences/mappings is 99. Nesting more
  # than this will result in a YAML::Error. Changing the value of this property
  # allows more/less nesting.
  property max_nesting = 99

  # Passes the emitter's output to the target as text, so an `IO` with an
  # encoding set receives it transcoded, as with the libyaml engine.
  private class TextOutput < IO
    def initialize(@target : IO)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("Can't read from YAML::Builder output")
    end

    def write(slice : Bytes) : Nil
      @target.write_string(slice)
    end
  end

  # Creates a `YAML::Builder` that will write to the given `IO`.
  def initialize(@io : IO)
    @emitter = Mica::YAML::Emitter.new(TextOutput.new(@io))
    @closed = false
    @nesting = 0
  end

  # Creates a `YAML::Builder` that writes to *io* and yields it to the block.
  #
  # After returning from the block the builder is closed.
  def self.build(io : IO, & : self ->) : Nil
    builder = new(io)
    yield builder ensure builder.close
  end

  # Starts a YAML stream.
  def start_stream
    emit("stream_start") { @emitter.stream_start }
  end

  # Ends a YAML stream.
  def end_stream : Nil
    emit("stream_end") { @emitter.stream_end }
    flush
  end

  # Starts a YAML stream, invokes the block, and ends it.
  def stream(&)
    start_stream
    yield.tap { end_stream }
  end

  # Starts a document.
  #
  # If *implicit_start_indicator* is true, skips printing the document start
  # indicator (`---`) if this is the first document in the stream.
  def start_document(*, implicit_start_indicator : Bool = false)
    emit("document_start") { @emitter.document_start(implicit: implicit_start_indicator) }
  end

  # Ends a document.
  def end_document
    emit("document_end") { @emitter.document_end(implicit: true) }
  end

  # Starts a document, invokes the block, and then ends it.
  #
  # If *implicit_start_indicator* is true, skips printing the document start
  # indicator (`---`) if this is the first document in the stream.
  def document(*, implicit_start_indicator : Bool = false, &)
    start_document(implicit_start_indicator: implicit_start_indicator)
    yield.tap { end_document }
  end

  # Emits a scalar value.
  def scalar(value, anchor : String? = nil, tag : String? = nil, style : YAML::ScalarStyle = YAML::ScalarStyle::ANY)
    string = value.to_s
    implicit = tag.nil?
    emit("scalar") do
      @emitter.scalar(string, anchor, tag, implicit, implicit, Mica::YAML::ScalarStyle.new(style.value))
    end
  end

  # Starts a sequence.
  def start_sequence(anchor : String? = nil, tag : String? = nil, style : YAML::SequenceStyle = YAML::SequenceStyle::ANY) : Nil
    emit("sequence_start") do
      @emitter.sequence_start(anchor, tag, tag.nil?, Mica::YAML::SequenceStyle.new(style.value))
    end
    increase_nesting
  end

  # Ends a sequence.
  def end_sequence : Nil
    emit("sequence_end") { @emitter.sequence_end }
    decrease_nesting
  end

  # Starts a sequence, invokes the block, and the ends it.
  def sequence(anchor : String? = nil, tag : String? = nil, style : YAML::SequenceStyle = YAML::SequenceStyle::ANY, &)
    start_sequence(anchor, tag, style)
    yield.tap { end_sequence }
  end

  # Starts a mapping.
  def start_mapping(anchor : String? = nil, tag : String? = nil, style : YAML::MappingStyle = YAML::MappingStyle::ANY) : Nil
    emit("mapping_start") do
      @emitter.mapping_start(anchor, tag, tag.nil?, Mica::YAML::MappingStyle.new(style.value))
    end
    increase_nesting
  end

  # Ends a mapping.
  def end_mapping : Nil
    emit("mapping_end") { @emitter.mapping_end }
    decrease_nesting
  end

  # Starts a mapping, invokes the block, and then ends it.
  def mapping(anchor : String? = nil, tag : String? = nil, style : YAML::MappingStyle = YAML::MappingStyle::ANY, &)
    start_mapping(anchor, tag, style)
    yield.tap { end_mapping }
  end

  # Emits an alias to the given *anchor*.
  #
  # ```
  # require "yaml"
  #
  # yaml = YAML.build do |builder|
  #   builder.mapping do
  #     builder.scalar "key"
  #     builder.alias "example"
  #   end
  # end
  #
  # yaml # => "---\nkey: *example\n"
  # ```
  def alias(anchor : String) : Nil
    emit("alias") { @emitter.alias(anchor) }
  end

  # Emits the scalar `"<<"` followed by an alias to the given *anchor*.
  #
  # See [YAML Merge](https://yaml.org/type/merge.html).
  #
  # ```
  # require "yaml"
  #
  # yaml = YAML.build do |builder|
  #   builder.mapping do
  #     builder.merge "development"
  #   end
  # end
  #
  # yaml # => "---\n<<: *development\n"
  # ```
  def merge(anchor : String) : Nil
    self.scalar "<<"
    self.alias anchor
  end

  # Flushes any pending data to the underlying `IO`.
  def flush
    @emitter.flush

    @io.flush
  end

  # Closes the builder, freeing up resources.
  def close : Nil
    @closed = true
  end

  private def emit(event_name : String, &) : Nil
    yield
  rescue error : Mica::YAML::EmitError
    raise YAML::Error.new("Error emitting #{event_name}: #{error.message}")
  end

  private def increase_nesting
    @nesting += 1
    if @nesting > @max_nesting
      raise YAML::Error.new("Nesting of #{@nesting} is too deep")
    end
  end

  private def decrease_nesting
    @nesting -= 1
  end
end
