require "../mica/yaml"

# :nodoc:
module YAML::MicaEngine
  # The libyaml release whose events, marks and error messages the Mica
  # engine reproduces (its `LibYAML` dialect).
  LIBYAML_VERSION = {0, 2, 5}

  # :nodoc:
  def self.scalar_style(style : Mica::YAML::ScalarStyle) : ::YAML::ScalarStyle
    ::YAML::ScalarStyle.new(style.value)
  end
end

# A pull parser allows parsing a YAML document by events.
#
# When creating an instance, the parser is positioned in
# the first event. To get the event kind invoke `kind`.
# If the event is a scalar you can invoke `value` to get
# its **string** value. Other methods like `tag`, `anchor`
# and `scalar_style` let you inspect other information from events.
#
# Invoking `read_next` reads the next event.
#
# This is the default implementation: the events come from Mica's
# pure-Crystal parser in its libyaml dialect (see `doc/yaml_mica.md`). The
# public API, the events, their marks and the error messages are those of
# the libyaml implementation in `src/yaml/libyaml/pull_parser.cr`.
class YAML::PullParser
  protected getter content

  # :nodoc:
  #
  # Maximum structural depth (nested sequences and mappings) allowed.
  property max_nesting = 512

  # :nodoc:
  #
  # If true, evaluates the alias/anchor ratio to avoid excessive expansion of
  # aliases.
  property enforce_alias_anchor_ratio = true

  # :nodoc:
  #
  # Minimum number of aliases required before starting to evaluate the
  # alias/anchor ratio. This avoids affecting smaller documents.
  property alias_anchor_min_aliases = 100

  # :nodoc:
  #
  # The multiplier for the alias/anchor ratio evaluation. An error will be
  # raised when `aliases > multiplier * anchors` once `min_aliases` has been
  # reached.
  property alias_anchor_multiplier = 10

  @parser : Mica::YAML::PullParser?
  @failure : Mica::Error?

  def initialize(@content : String | IO)
    @closed = false
    @kind = EventKind::NONE

    @nesting = 0
    @anchors = 0
    @aliases = 0
    @anchor_scope = Hash(Int32, {String, Int32}).new
    @anchor_costs = Hash(String, Int32).new

    begin
      # Mica reads the stream start event when it is created.
      parser = Mica::YAML::PullParser.new(content, limits: Mica::YAML::ParseLimits::LIBYAML, timeout: nil,
        dialect: Mica::YAML::Dialect::LibYAML)
      @parser = parser
      @kind = EventKind.new(parser.kind.value)
    rescue error : Mica::Error
      @failure = error
      raise_failure(error)
    end
    raise "Expected STREAM_START" unless kind.stream_start?
  end

  # Creates a parser, yields it to the block, and closes
  # the parser at the end of it.
  def self.new(content, &)
    parser = new(content)
    yield parser ensure parser.close
  end

  # The current event kind.
  getter kind : EventKind

  # Returns the tag associated to the current event, or `nil`
  # if there's no tag.
  def tag : String?
    @parser.try(&.tag)
  end

  # Returns the scalar value, assuming the pull parser
  # is located at a scalar. Raises otherwise.
  def value : String
    expect_kind EventKind::SCALAR
    parser = @parser
    parser ? parser.value : ""
  end

  # Returns the anchor associated to the current event, or `nil`
  # if there's no anchor.
  getter anchor : String?

  # Returns the sequence style, assuming the pull parser is located
  # at a sequence begin event. Raises otherwise.
  def sequence_style : SequenceStyle
    expect_kind EventKind::SEQUENCE_START
    parser = @parser
    parser ? SequenceStyle.new(parser.sequence_style.value) : SequenceStyle::ANY
  end

  # Returns the mapping style, assuming the pull parser is located
  # at a mapping begin event. Raises otherwise.
  def mapping_style : MappingStyle
    expect_kind EventKind::MAPPING_START
    parser = @parser
    parser ? MappingStyle.new(parser.mapping_style.value) : MappingStyle::ANY
  end

  # Returns the scalar style, assuming the pull parser is located
  # at a scalar event. Raises otherwise.
  def scalar_style : ScalarStyle
    expect_kind EventKind::SCALAR
    parser = @parser
    parser ? MicaEngine.scalar_style(parser.scalar_style) : ScalarStyle::ANY
  end

  # Reads the next event.
  def read_next : EventKind
    # As with libyaml, a parser that failed keeps reporting its error.
    if failure = @failure
      raise_failure(failure)
    end
    parser = @parser
    return @kind unless parser

    begin
      @kind = EventKind.new(parser.read_next.value)
    rescue error : Mica::Error
      @failure = error
      @kind = EventKind::NONE
      raise_failure(error)
    end

    @anchor = parser.anchor
    @anchors += 1 if @anchor

    case kind
    when EventKind::SEQUENCE_START, EventKind::MAPPING_START
      increase_nesting
    when EventKind::SEQUENCE_END, EventKind::MAPPING_END
      decrease_nesting
    when EventKind::ALIAS
      increase_alias
    end

    kind
  end

  # Reads a "stream start" event, yields to the block,
  # and then reads a "stream end" event.
  def read_stream(&)
    read_stream_start
    value = yield
    read_stream_end
    value
  end

  # Reads a "document start" event, yields to the block,
  # and then reads a "document end" event.
  def read_document(&)
    read_document_start
    value = yield
    read_document_end
    value
  end

  # Reads a "sequence start" event, yields to the block,
  # and then reads a "sequence end" event.
  def read_sequence(&)
    read_sequence_start
    value = yield
    read_sequence_end
    value
  end

  # Reads a "mapping start" event, yields to the block,
  # and then reads a "mapping end" event.
  def read_mapping(&)
    read_mapping_start
    value = yield
    read_mapping_end
    value
  end

  # Reads an alias event, returning its anchor.
  def read_alias : String?
    expect_kind EventKind::ALIAS
    anchor = @anchor
    read_next
    anchor
  end

  # Reads a scalar, returning its value.
  def read_scalar : String
    expect_kind EventKind::SCALAR
    value = self.value
    read_next
    value
  end

  # Reads a "stream start" event.
  def read_stream_start
    read EventKind::STREAM_START
  end

  # Reads a "stream end" event.
  def read_stream_end
    read EventKind::STREAM_END
  end

  # Reads a "document start" event.
  def read_document_start
    read EventKind::DOCUMENT_START
  end

  # Reads a "document end" event.
  def read_document_end
    read EventKind::DOCUMENT_END
  end

  # Reads a "sequence start" event.
  def read_sequence_start
    read EventKind::SEQUENCE_START
  end

  # Reads a "sequence end" event.
  def read_sequence_end
    read EventKind::SEQUENCE_END
  end

  # Reads a "mapping start" event.
  def read_mapping_start
    read EventKind::MAPPING_START
  end

  # Reads a "mapping end" event.
  def read_mapping_end
    read EventKind::MAPPING_END
  end

  # Reads an expected event kind.
  def read(expected_kind : EventKind) : EventKind
    expect_kind expected_kind
    read_next
  end

  def skip : YAML::EventKind
    case kind
    when .scalar?
      read_next
    when .alias?
      read_next
    when .sequence_start?
      read_next
      until kind.sequence_end?
        skip
      end
      read_next
    when .mapping_start?
      read_next
      until kind.mapping_end?
        skip
        skip
      end
      read_next
    when .document_start?
      read_next
      until kind.document_end?
        skip
      end
      read_next
    when .stream_start?
      read_next
      until kind.stream_end?
        skip
      end
      read_next
    else
      read_next
    end
  end

  def location : {Int32, Int32}
    {start_line, start_column}
  end

  # After the stream end, and after an error, libyaml's event is empty and
  # its marks are zero: line 1, column 1.

  def start_line : Int32
    parser = @parser
    parser && !@kind.none? ? parser.start_line : 1
  end

  def start_column : Int32
    parser = @parser
    parser && !@kind.none? ? parser.start_column : 1
  end

  def end_line : Int32
    parser = @parser
    parser && !@kind.none? ? parser.end_line : 1
  end

  def end_column : Int32
    parser = @parser
    parser && !@kind.none? ? parser.end_column : 1
  end

  def close : Nil
    @closed = true
  end

  # Raises if the current kind is not the expected one.
  def expect_kind(kind : EventKind) : Nil
    raise "Expected #{kind} but was #{self.kind}" unless kind == self.kind
  end

  def raise(msg : String, line_number = self.start_line, column_number = self.start_column, context_info = nil) : NoReturn
    ::raise ParseException.new(msg, line_number, column_number, context_info)
  end

  # Raises the `ParseException` libyaml's error would have produced: the
  # problem with its mark, and the context with its mark when there is one.
  # An input error (invalid UTF-8, a control character) has no mark in
  # libyaml, so it reports line 1, column 1.
  private def raise_failure(error : Mica::Error) : NoReturn
    if error.is_a?(Mica::YAML::SyntaxError)
      context = error.context
      context_position = error.context_position
      if context && context_position
        context_info = {context, context_position.line, context_position.column}
      end
      raise error.detail, error.line_number, error.column_number, context_info
    elsif error.is_a?(Mica::ParseError)
      raise error.detail, 1, 1
    else
      raise error.message.to_s, 1, 1
    end
  end

  private def increase_nesting
    @nesting += 1

    if @nesting > @max_nesting
      raise "Nesting of #{@nesting} is too deep"
    end

    if anchor = @anchor
      @anchor_scope[@nesting] = {anchor, @aliases}
    end
  end

  private def decrease_nesting
    if scope = @anchor_scope.delete(@nesting)
      anchor, aliases = scope
      @anchor_costs[anchor] = @aliases - aliases
    end

    @nesting -= 1
  end

  private def increase_alias
    aliases = @anchor_costs[@anchor]? || 0
    @aliases += aliases + 1

    if @enforce_alias_anchor_ratio &&
       @aliases > @alias_anchor_min_aliases &&
       @aliases > @alias_anchor_multiplier * @anchors
      raise "Document contains excessive aliasing"
    end
  end
end
