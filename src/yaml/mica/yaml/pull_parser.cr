# The event state machine in this file is a port of parser.c from libyaml 0.2.5,
# with the YAML 1.2 rules added; libyaml is distributed under the MIT
# license:
#
# Copyright (c) 2017-2020 Ingy döt Net
# Copyright (c) 2006-2016 Kirill Simonov
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

module YAML::Mica::YAML
  # The kind of event a `PullParser` is positioned at.
  enum EventKind
    None
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
  end

  # Reads YAML as a stream of events, one at a time.
  #
  # A new parser is positioned at the `StreamStart` event. `read_next`
  # moves to the next event and returns its kind; `kind`, `value`,
  # `anchor`, `tag` and the style getters describe the current one. After
  # `StreamEnd` the kind is `None`.
  #
  # ```
  # limits = Mica::YAML::ParseLimits::CONFIG_FILE
  # parser = Mica::YAML::PullParser.new("name: mica", limits: limits, timeout: 1.second)
  # parser.read_next # => DocumentStart
  # parser.read_next # => MappingStart
  # parser.read_next # => Scalar
  # parser.value     # => "name"
  # ```
  #
  # The input is held in memory: a `String` or `Bytes` is scanned in
  # place, an `IO` is read to its end first (up to `max_input_bytes`).
  # Every structural problem raises `SyntaxError`; a limit raises
  # `ParseLimitError`, `Mica::WorkBudgetExceededError` or
  # `Mica::DeadlineExceededError`.
  class PullParser
    private enum State : UInt8
      StreamStart
      ImplicitDocumentStart
      DocumentStart
      DocumentContent
      DocumentEnd
      BlockNode
      BlockNodeOrIndentlessSequence
      FlowNode
      BlockSequenceFirstEntry
      BlockSequenceEntry
      IndentlessSequenceEntry
      BlockMappingFirstKey
      BlockMappingKey
      BlockMappingValue
      FlowSequenceFirstEntry
      FlowSequenceEntry
      FlowSequenceEntryMappingKey
      FlowSequenceEntryMappingValue
      FlowSequenceEntryMappingEnd
      FlowMappingFirstKey
      FlowMappingKey
      FlowMappingValue
      FlowMappingEmptyValue
      End
    end

    private DEFAULT_TAG_DIRECTIVES = [{"!", "!"}, {"!!", "tag:yaml.org,2002:"}]

    # The kind of the current event.
    getter kind : EventKind = EventKind::None

    # The anchor of the current scalar, sequence start or mapping start,
    # or the anchor an alias event refers to; nil when there is none.
    getter anchor : String?

    # The tag of the current scalar, sequence start or mapping start, with
    # its handle resolved (`!!str` reads as `tag:yaml.org,2002:str`), or
    # nil when the node has none.
    getter tag : String?

    # The style of the current scalar (`Any` for other events).
    getter scalar_style : ScalarStyle = ScalarStyle::Any

    # The style of the current sequence start (`Any` for other events).
    getter sequence_style : SequenceStyle = SequenceStyle::Any

    # The style of the current mapping start (`Any` for other events).
    getter mapping_style : MappingStyle = MappingStyle::Any

    # True when the current document start has no `---`, the current
    # document end has no `...`, or the current sequence or mapping start
    # has no tag.
    getter? implicit : Bool = false

    # True when the current scalar's tag may be left out when it is
    # written in the plain style (it is plain and untagged, or tagged `!`).
    getter? plain_implicit : Bool = false

    # True when the current scalar's tag may be left out when it is
    # written in a quoted or block style (it is untagged and not plain).
    getter? quoted_implicit : Bool = false

    # The `%YAML` directive of the current document start as
    # `{major, minor}`, or nil.
    getter version_directive : {Int32, Int32}?

    # The `%TAG` directives of the current document start as
    # `{handle, prefix}` pairs.
    getter list_of_tag_directives : Array({String, String}) = [] of {String, String}

    # The work meter this parse runs under.
    getter meter : Core::WorkMeter

    @scanner : Scanner
    @value : String = ""
    @state : State = State::StreamStart
    @states : Array(State)
    @marks : Array(Mark)
    @document_tag_directives : Array({String, String})
    @start_mark : Mark = Mark.new(0, 0, 0)
    @end_mark : Mark = Mark.new(0, 0, 0)
    @depth : Int32 = 0
    @limits : ParseLimits
    @strict : Bool
    # True at the start of the stream and after a `...` marker: only then
    # may YAML 1.2 directives or a document without `---` follow.
    @document_ended_explicitly : Bool = true

    # Creates a parser over *source* and reads the `StreamStart` event.
    # *limits* bounds the parse and *timeout* its wall-clock time (nil for
    # none). Pass *meter* to share one work budget between several
    # parses.
    def initialize(source : String | Bytes | IO, *, limits : ParseLimits, timeout : Time::Span?,
                   dialect : Dialect = Dialect::YAML12, meter : Core::WorkMeter? = nil)
      @limits = limits
      @strict = dialect.yaml12?
      @meter = meter || Core::WorkMeter.new(limits.work_budget(timeout))
      bytes = Source.read(source, limits, @meter, dialect)
      @meter.add_units(bytes.size)
      @meter.enforce_deadline("while reading YAML") { Core::Position.new(0_i64, 1, 1) }
      @scanner = Scanner.new(bytes, dialect, limits, @meter)
      @states = Array(State).new(16)
      @marks = Array(Mark).new(16)
      @document_tag_directives = Array({String, String}).new(2)
      read_next
    end

    # Returns the current scalar's content. Raises `Mica::Error` when the
    # current event is not a scalar.
    def value : String
      raise Mica::Error.new("Expected a scalar event but was #{@kind}") unless @kind.scalar?
      @value
    end

    # Returns where the current event starts.
    def start_position : Core::Position
      @start_mark.position
    end

    # Returns where the current event ends (the position after its last
    # character).
    def end_position : Core::Position
      @end_mark.position
    end

    # Returns the 1-based line the current event starts on.
    def start_line : Int32
      @start_mark.line + 1
    end

    # Returns the 1-based column (in characters) the current event starts
    # at.
    def start_column : Int32
      @start_mark.column + 1
    end

    # Returns the 1-based line the current event ends on.
    def end_line : Int32
      @end_mark.line + 1
    end

    # Returns the 1-based column (in characters) after the current
    # event's last character.
    def end_column : Int32
      @end_mark.column + 1
    end

    # Moves to the next event and returns its kind. After the stream end
    # every call returns `EventKind::None`.
    def read_next : EventKind
      @anchor = nil
      @tag = nil
      if @scanner.stream_end_produced? || @state.end?
        @kind = EventKind::None
        return @kind
      end
      run_state
      @kind
    end

    # Reads events up to and including the end of the node the parser is
    # positioned at (a scalar, an alias, or a whole sequence or mapping),
    # and returns the kind of the event after it.
    def skip : EventKind
      nesting = 0
      loop do
        case @kind
        when .sequence_start?, .mapping_start?
          nesting += 1
        when .sequence_end?, .mapping_end?
          nesting -= 1
        when .none?
          return @kind
        else
          # scalars, aliases and stream or document events have no depth
        end
        read_next
        return @kind if nesting <= 0
      end
    end

    private def run_state : Nil
      case @state
      in .stream_start?                      then parse_stream_start
      in .implicit_document_start?           then parse_document_start(true)
      in .document_start?                    then parse_document_start(false)
      in .document_content?                  then parse_document_content
      in .document_end?                      then parse_document_end
      in .block_node?                        then parse_node(true, false)
      in .block_node_or_indentless_sequence? then parse_node(true, true)
      in .flow_node?                         then parse_node(false, false)
      in .block_sequence_first_entry?        then parse_block_sequence_entry(true)
      in .block_sequence_entry?              then parse_block_sequence_entry(false)
      in .indentless_sequence_entry?         then parse_indentless_sequence_entry
      in .block_mapping_first_key?           then parse_block_mapping_key(true)
      in .block_mapping_key?                 then parse_block_mapping_key(false)
      in .block_mapping_value?               then parse_block_mapping_value
      in .flow_sequence_first_entry?         then parse_flow_sequence_entry(true)
      in .flow_sequence_entry?               then parse_flow_sequence_entry(false)
      in .flow_sequence_entry_mapping_key?   then parse_flow_sequence_entry_mapping_key
      in .flow_sequence_entry_mapping_value? then parse_flow_sequence_entry_mapping_value
      in .flow_sequence_entry_mapping_end?   then parse_flow_sequence_entry_mapping_end
      in .flow_mapping_first_key?            then parse_flow_mapping_key(true)
      in .flow_mapping_key?                  then parse_flow_mapping_key(false)
      in .flow_mapping_value?                then parse_flow_mapping_value(false)
      in .flow_mapping_empty_value?          then parse_flow_mapping_value(true)
      in .end?                               then @kind = EventKind::None
      end
    end

    # --- Events -------------------------------------------------------------

    private def event(@kind : EventKind, @start_mark : Mark, @end_mark : Mark) : Nil
    end

    private def scalar_event(value : String, style : ScalarStyle, plain_implicit : Bool, quoted_implicit : Bool,
                             start_mark : Mark, end_mark : Mark) : Nil
      @value = value
      @scalar_style = style
      @plain_implicit = plain_implicit
      @quoted_implicit = quoted_implicit
      event(EventKind::Scalar, start_mark, end_mark)
    end

    private def empty_scalar(mark : Mark) : Nil
      scalar_event("", ScalarStyle::Plain, true, false, mark, mark)
    end

    private def sequence_start(implicit : Bool, style : SequenceStyle, start_mark : Mark, end_mark : Mark) : Nil
      enter_collection(start_mark)
      @implicit = implicit
      @sequence_style = style
      event(EventKind::SequenceStart, start_mark, end_mark)
    end

    private def mapping_start(implicit : Bool, style : MappingStyle, start_mark : Mark, end_mark : Mark) : Nil
      enter_collection(start_mark)
      @implicit = implicit
      @mapping_style = style
      event(EventKind::MappingStart, start_mark, end_mark)
    end

    private def collection_end(kind : EventKind, start_mark : Mark, end_mark : Mark) : Nil
      @depth -= 1
      event(kind, start_mark, end_mark)
    end

    private def enter_collection(mark : Mark) : Nil
      if @depth >= @limits.max_depth
        raise ParseLimitError.new("Collections nest deeper than max_depth (#{@limits.max_depth})", mark.position,
          "max_depth")
      end
      @depth += 1
    end

    private def parser_error(problem : String, problem_mark : Mark) : NoReturn
      raise SyntaxError.new(problem, problem_mark.position)
    end

    private def parser_error(context : String, context_mark : Mark, problem : String, problem_mark : Mark) : NoReturn
      raise SyntaxError.new(problem, problem_mark.position, context, context_mark.position)
    end

    # --- States -------------------------------------------------------------

    private def parse_stream_start : Nil
      token = @scanner.peek
      unless token.kind.stream_start?
        parser_error("did not find expected <stream-start>", token.start_mark)
      end
      @state = State::ImplicitDocumentStart
      event(EventKind::StreamStart, token.start_mark, token.start_mark)
      @scanner.skip
    end

    private def parse_document_start(implicit : Bool) : Nil
      token = @scanner.peek
      if !implicit || @strict
        while token.kind.document_end?
          @scanner.skip
          token = @scanner.peek
          @document_ended_explicitly = true
        end
      end
      kind = token.kind
      implicit = true if @strict && @document_ended_explicitly
      if @strict && !@document_ended_explicitly && (kind.version_directive? || kind.tag_directive?)
        parser_error("did not find expected <document start>", token.start_mark)
      end
      if implicit && !kind.version_directive? && !kind.tag_directive? && !kind.document_start? && !kind.stream_end?
        process_directives
        @version_directive = nil
        @list_of_tag_directives = [] of {String, String}
        @states << State::DocumentEnd
        @state = State::BlockNode
        @implicit = true
        event(EventKind::DocumentStart, token.start_mark, token.start_mark)
      elsif !kind.stream_end?
        start_mark = token.start_mark
        @version_directive, @list_of_tag_directives = process_directives
        token = @scanner.peek
        unless token.kind.document_start?
          parser_error("did not find expected <document start>", token.start_mark)
        end
        @states << State::DocumentEnd
        @state = State::DocumentContent
        @implicit = false
        event(EventKind::DocumentStart, start_mark, token.end_mark)
        @scanner.skip
      else
        @state = State::End
        event(EventKind::StreamEnd, token.start_mark, token.end_mark)
        @scanner.skip
      end
    end

    private def parse_document_content : Nil
      token = @scanner.peek
      kind = token.kind
      if kind.version_directive? || kind.tag_directive? || kind.document_start? || kind.document_end? ||
         kind.stream_end?
        @state = @states.pop
        empty_scalar(token.start_mark)
      else
        parse_node(true, false)
      end
    end

    private def parse_document_end : Nil
      token = @scanner.peek
      start_mark = token.start_mark
      end_mark = start_mark
      implicit = true
      if token.kind.document_end?
        end_mark = token.end_mark
        @scanner.skip
        implicit = false
      end
      @document_tag_directives.clear
      @document_ended_explicitly = !implicit
      @state = State::DocumentStart
      @implicit = implicit
      event(EventKind::DocumentEnd, start_mark, end_mark)
    end

    private def parse_node(block : Bool, indentless_sequence : Bool) : Nil
      token = @scanner.peek
      if token.kind.alias?
        @state = @states.pop
        @anchor = token.value
        event(EventKind::Alias, token.start_mark, token.end_mark)
        @scanner.skip
        return
      end

      start_mark = token.start_mark
      end_mark = start_mark
      tag_mark = start_mark
      anchor = nil
      tag_handle = nil
      tag_suffix = nil
      if token.kind.anchor?
        anchor = token.value
        end_mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        if token.kind.tag?
          tag_handle = token.handle
          tag_suffix = token.value
          tag_mark = token.start_mark
          end_mark = token.end_mark
          @scanner.skip
          token = @scanner.peek
        end
      elsif token.kind.tag?
        tag_handle = token.handle
        tag_suffix = token.value
        end_mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        if token.kind.anchor?
          anchor = token.value
          end_mark = token.end_mark
          @scanner.skip
          token = @scanner.peek
        end
      end

      tag = nil
      if tag_handle && tag_suffix
        tag = resolve_tag(tag_handle, c_string(tag_suffix), start_mark, tag_mark)
      end
      implicit = tag.nil? || tag.empty?
      @anchor = anchor
      @tag = tag

      kind = token.kind
      if indentless_sequence && kind.block_entry?
        @state = State::IndentlessSequenceEntry
        sequence_start(implicit, SequenceStyle::Block, start_mark, token.end_mark)
      elsif kind.scalar?
        plain_implicit = false
        quoted_implicit = false
        if (token.style.plain? && tag.nil?) || tag == "!"
          plain_implicit = true
        elsif tag.nil?
          quoted_implicit = true
        end
        @state = @states.pop
        scalar_event(token.value, token.style, plain_implicit, quoted_implicit, start_mark, token.end_mark)
        @scanner.skip
      elsif kind.flow_sequence_start?
        @state = State::FlowSequenceFirstEntry
        sequence_start(implicit, SequenceStyle::Flow, start_mark, token.end_mark)
      elsif kind.flow_mapping_start?
        @state = State::FlowMappingFirstKey
        mapping_start(implicit, MappingStyle::Flow, start_mark, token.end_mark)
      elsif block && kind.block_sequence_start?
        @state = State::BlockSequenceFirstEntry
        sequence_start(implicit, SequenceStyle::Block, start_mark, token.end_mark)
      elsif block && kind.block_mapping_start?
        @state = State::BlockMappingFirstKey
        mapping_start(implicit, MappingStyle::Block, start_mark, token.end_mark)
      elsif anchor || tag
        @state = @states.pop
        scalar_event("", ScalarStyle::Plain, implicit, false, start_mark, end_mark)
      else
        parser_error(block ? "while parsing a block node" : "while parsing a flow node", start_mark,
          "did not find expected node content", token.start_mark)
      end
    end

    # A tag prefix or suffix as libyaml's users see it. libyaml keeps both
    # as C strings, so a `%00` escape ends the text there; YAML 1.2 keeps
    # the NUL character and what follows it.
    private def c_string(value : String) : String
      return value if @strict
      terminator = value.to_slice.index(0_u8)
      terminator ? value.byte_slice(0, terminator) : value
    end

    private def resolve_tag(handle : String, suffix : String, start_mark : Mark, tag_mark : Mark) : String
      return suffix if handle.empty?
      @document_tag_directives.each do |directive|
        return directive[1] + suffix if directive[0] == handle
      end
      parser_error("while parsing a node", start_mark, "found undefined tag handle", tag_mark)
    end

    private def parse_block_sequence_entry(first : Bool) : Nil
      if first
        token = @scanner.peek
        @marks << token.start_mark
        @scanner.skip
      end
      token = @scanner.peek
      if token.kind.block_entry?
        mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        if !token.kind.block_entry? && !token.kind.block_end?
          @states << State::BlockSequenceEntry
          parse_node(true, false)
        else
          @state = State::BlockSequenceEntry
          empty_scalar(mark)
        end
      elsif token.kind.block_end?
        @state = @states.pop
        @marks.pop
        collection_end(EventKind::SequenceEnd, token.start_mark, token.end_mark)
        @scanner.skip
      else
        parser_error("while parsing a block collection", @marks.pop, "did not find expected '-' indicator",
          token.start_mark)
      end
    end

    private def parse_indentless_sequence_entry : Nil
      token = @scanner.peek
      if token.kind.block_entry?
        mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        kind = token.kind
        if !kind.block_entry? && !kind.key? && !kind.value? && !kind.block_end?
          @states << State::IndentlessSequenceEntry
          parse_node(true, false)
        else
          @state = State::IndentlessSequenceEntry
          empty_scalar(mark)
        end
      else
        @state = @states.pop
        collection_end(EventKind::SequenceEnd, token.start_mark, token.start_mark)
      end
    end

    private def parse_block_mapping_key(first : Bool) : Nil
      if first
        token = @scanner.peek
        @marks << token.start_mark
        @scanner.skip
      end
      token = @scanner.peek
      if token.kind.key?
        mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        kind = token.kind
        if !kind.key? && !kind.value? && !kind.block_end?
          @states << State::BlockMappingValue
          parse_node(true, true)
        else
          @state = State::BlockMappingValue
          empty_scalar(mark)
        end
      elsif token.kind.block_end?
        @state = @states.pop
        @marks.pop
        collection_end(EventKind::MappingEnd, token.start_mark, token.end_mark)
        @scanner.skip
      elsif @strict && token.kind.value?
        # YAML 1.2: a value indicator with no key before it has an empty key.
        @state = State::BlockMappingValue
        empty_scalar(token.start_mark)
      else
        parser_error("while parsing a block mapping", @marks.pop, "did not find expected key", token.start_mark)
      end
    end

    private def parse_block_mapping_value : Nil
      token = @scanner.peek
      if token.kind.value?
        mark = token.end_mark
        @scanner.skip
        token = @scanner.peek
        kind = token.kind
        if !kind.key? && !kind.value? && !kind.block_end?
          @states << State::BlockMappingKey
          parse_node(true, true)
        else
          @state = State::BlockMappingKey
          empty_scalar(mark)
        end
      else
        @state = State::BlockMappingKey
        empty_scalar(token.start_mark)
      end
    end

    private def parse_flow_sequence_entry(first : Bool) : Nil
      if first
        token = @scanner.peek
        @marks << token.start_mark
        @scanner.skip
      end
      token = @scanner.peek
      unless token.kind.flow_sequence_end?
        unless first
          if token.kind.flow_entry?
            @scanner.skip
            token = @scanner.peek
          else
            parser_error("while parsing a flow sequence", @marks.pop, "did not find expected ',' or ']'",
              token.start_mark)
          end
        end
        if token.kind.key?
          @state = State::FlowSequenceEntryMappingKey
          mapping_start(true, MappingStyle::Flow, token.start_mark, token.end_mark)
          @scanner.skip
          return
        elsif @strict && token.kind.value?
          @state = State::FlowSequenceEntryMappingKey
          mapping_start(true, MappingStyle::Flow, token.start_mark, token.start_mark)
          return
        elsif !token.kind.flow_sequence_end?
          @states << State::FlowSequenceEntry
          parse_node(false, false)
          return
        end
      end
      @state = @states.pop
      @marks.pop
      collection_end(EventKind::SequenceEnd, token.start_mark, token.end_mark)
      @scanner.skip
    end

    private def parse_flow_sequence_entry_mapping_key : Nil
      token = @scanner.peek
      kind = token.kind
      if !kind.value? && !kind.flow_entry? && !kind.flow_sequence_end?
        @states << State::FlowSequenceEntryMappingValue
        parse_node(false, false)
      elsif @strict
        @state = State::FlowSequenceEntryMappingValue
        empty_scalar(token.start_mark)
      else
        mark = token.end_mark
        @scanner.skip
        @state = State::FlowSequenceEntryMappingValue
        empty_scalar(mark)
      end
    end

    private def parse_flow_sequence_entry_mapping_value : Nil
      token = @scanner.peek
      if token.kind.value?
        @scanner.skip
        token = @scanner.peek
        if !token.kind.flow_entry? && !token.kind.flow_sequence_end?
          @states << State::FlowSequenceEntryMappingEnd
          parse_node(false, false)
          return
        end
      end
      @state = State::FlowSequenceEntryMappingEnd
      empty_scalar(token.start_mark)
    end

    private def parse_flow_sequence_entry_mapping_end : Nil
      token = @scanner.peek
      @state = State::FlowSequenceEntry
      collection_end(EventKind::MappingEnd, token.start_mark, token.start_mark)
    end

    private def parse_flow_mapping_key(first : Bool) : Nil
      if first
        token = @scanner.peek
        @marks << token.start_mark
        @scanner.skip
      end
      token = @scanner.peek
      unless token.kind.flow_mapping_end?
        unless first
          if token.kind.flow_entry?
            @scanner.skip
            token = @scanner.peek
          else
            parser_error("while parsing a flow mapping", @marks.pop, "did not find expected ',' or '}'",
              token.start_mark)
          end
        end
        if token.kind.key?
          @scanner.skip
          token = @scanner.peek
          kind = token.kind
          if !kind.value? && !kind.flow_entry? && !kind.flow_mapping_end?
            @states << State::FlowMappingValue
            parse_node(false, false)
          else
            @state = State::FlowMappingValue
            empty_scalar(token.start_mark)
          end
          return
        elsif @strict && token.kind.value?
          @state = State::FlowMappingValue
          empty_scalar(token.start_mark)
          return
        elsif !token.kind.flow_mapping_end?
          @states << State::FlowMappingEmptyValue
          parse_node(false, false)
          return
        end
      end
      @state = @states.pop
      @marks.pop
      collection_end(EventKind::MappingEnd, token.start_mark, token.end_mark)
      @scanner.skip
    end

    private def parse_flow_mapping_value(empty : Bool) : Nil
      token = @scanner.peek
      if empty
        @state = State::FlowMappingKey
        empty_scalar(token.start_mark)
        return
      end
      if token.kind.value?
        @scanner.skip
        token = @scanner.peek
        if !token.kind.flow_entry? && !token.kind.flow_mapping_end?
          @states << State::FlowMappingKey
          parse_node(false, false)
          return
        end
      end
      @state = State::FlowMappingKey
      empty_scalar(token.start_mark)
    end

    # Reads the directives before a document and sets the tag handles the
    # document may use. Returns the `%YAML` version and the `%TAG` pairs.
    private def process_directives : { {Int32, Int32}?, Array({String, String}) }
      version = nil
      directives = [] of {String, String}
      token = @scanner.peek
      while token.kind.version_directive? || token.kind.tag_directive?
        if token.kind.version_directive?
          parser_error("found duplicate %YAML directive", token.start_mark) if version
          if token.major != 1 || (!@strict && token.minor != 1 && token.minor != 2)
            parser_error("found incompatible YAML document", token.start_mark)
          end
          version = {token.major, token.minor}
        else
          pair = {token.handle, c_string(token.value)}
          if @document_tag_directives.any? { |directive| directive[0] == pair[0] }
            parser_error("found duplicate %TAG directive", token.start_mark)
          end
          @document_tag_directives << pair
          directives << pair
        end
        @scanner.skip
        token = @scanner.peek
      end
      DEFAULT_TAG_DIRECTIVES.each do |pair|
        @document_tag_directives << pair unless @document_tag_directives.any? { |directive| directive[0] == pair[0] }
      end
      {version, directives}
    end
  end
end
