# The event state machine, the event analysis and the output routines in
# this file and in emitter/analysis.cr and emitter/writer.cr are a port of
# emitter.c, writer.c and the event initializers of api.c from libyaml
# 0.2.5, which is distributed under the MIT license:
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
require "../core"
require "./styles"
require "./emit_error"

# Writes a stream of YAML events as text, byte for byte the way libyaml
# 0.2.5 writes them with the settings Crystal's standard library uses:
# UTF-8 output, unescaped Unicode, an indent of 2, a preferred width of 80
# columns, LF line breaks and no `%YAML` or `%TAG` directives.
#
# Each method stands for one libyaml event. Events must arrive in a valid
# order (a stream holds documents, a document holds one node, a mapping
# holds keys and values in turn); an event out of order raises `EmitError`
# with libyaml's wording.
#
# ```
# io = IO::Memory.new
# emitter = Mica::YAML::Emitter.new(io)
# emitter.stream_start
# emitter.document_start
# emitter.mapping_start
# emitter.scalar("name")
# emitter.scalar("Mica")
# emitter.scalar("formats")
# emitter.sequence_start(style: Mica::YAML::SequenceStyle::Flow)
# emitter.scalar("xml")
# emitter.scalar("yaml")
# emitter.sequence_end
# emitter.mapping_end
# emitter.document_end
# emitter.stream_end
# io.to_s # => "---\nname: Mica\nformats: [xml, yaml]\n"
# ```
#
# Like libyaml, the emitter holds back up to three events before it writes
# (it has to see whether a collection is empty and whether a key fits on one
# line), so an error in one event can surface on a later call. Output
# gathers in a 16 KiB buffer that is written to the `IO` when it fills, at
# the end of each document, at the end of the stream and on `flush`.
class YAML::Mica::YAML::Emitter
  # The size of the output buffer in bytes.
  BUFFER_SIZE = 16_384

  # The buffer starts this small and doubles up to `BUFFER_SIZE`, so a
  # short document costs a short buffer. What reaches the `IO`, and in
  # which pieces, does not depend on it.
  private INITIAL_BUFFER_SIZE = 512

  # The number of columns each nesting level is indented by.
  BEST_INDENT = 2

  # The column after which the emitter looks for a place to break a line.
  BEST_WIDTH = 80

  # The longest key, in bytes of anchor, tag and value, written as
  # `key: value` rather than as `? key`.
  MAX_SIMPLE_KEY_LENGTH = 128

  private enum State
    StreamStart
    FirstDocumentStart
    DocumentStart
    DocumentContent
    DocumentEnd
    FlowSequenceFirstItem
    FlowSequenceItem
    FlowMappingFirstKey
    FlowMappingKey
    FlowMappingSimpleValue
    FlowMappingValue
    BlockSequenceFirstItem
    BlockSequenceItem
    BlockMappingFirstKey
    BlockMappingKey
    BlockMappingSimpleValue
    BlockMappingValue
    End
  end

  @io : IO
  @buffer : Bytes
  @buffered : Int32 = 0

  @state : State = State::StreamStart
  @states : Array(State)
  @events : Deque(Event)
  @indents : Array(Int32)
  @has_tag_directives : Bool = false

  @indent : Int32 = -1
  @flow_level : Int32 = 0
  @mapping_context : Bool = false
  @simple_key_context : Bool = false
  @column : Int32 = 0
  @whitespace : Bool = true
  @indention : Bool = true
  @open_ended : Int32 = 0

  # What `analyze_event` found in the event at the head of the queue.
  @anchor : Bytes? = nil
  @anchor_is_alias : Bool = false
  @tag_handle : Bytes? = nil
  @tag_suffix : Bytes? = nil
  @scalar_value : Bytes = Bytes.empty
  @scalar_multiline : Bool = false
  @flow_plain_allowed : Bool = false
  @block_plain_allowed : Bool = false
  @single_quoted_allowed : Bool = false
  @block_allowed : Bool = false
  @scalar_style : ScalarStyle = ScalarStyle::Plain

  # Creates an emitter that writes to *io*.
  def initialize(@io : IO)
    @buffer = Bytes.new(INITIAL_BUFFER_SIZE)
    @states = [] of State
    @events = Deque(Event).new
    @indents = [] of Int32
  end

  # Starts the stream. This is the first event of every stream.
  def stream_start : Nil
    emit Event.new(EventKind::StreamStart)
  end

  # Ends the stream and writes everything still buffered to the `IO`.
  def stream_end : Nil
    emit Event.new(EventKind::StreamEnd)
  end

  # Starts a document. With *implicit* true the `---` line is left out for
  # the first document of the stream; later documents always get one.
  def document_start(implicit : Bool = false) : Nil
    emit Event.new(EventKind::DocumentStart, implicit: implicit)
  end

  # Ends the document. With *implicit* false a `...` line is written.
  def document_end(implicit : Bool = true) : Nil
    emit Event.new(EventKind::DocumentEnd, implicit: implicit)
  end

  # Writes the scalar *value*.
  #
  # *style* is a request: the emitter falls back to a quoted style when the
  # value cannot be written in the requested one (a plain scalar cannot
  # start with `- `, a block scalar cannot sit inside a flow collection, and
  # so on). `ScalarStyle::Any` asks for plain.
  #
  # *tag* is written only when *plain_implicit* and *quoted_implicit* are
  # both false. *plain_implicit* says the tag may be left out when the
  # scalar is written plain, *quoted_implicit* when it is written in any
  # other style; a scalar with neither a tag nor an implicit flag raises
  # `EmitError`.
  #
  # Raises `EmitError` when *value*, *anchor* or *tag* is not UTF-8.
  def scalar(value : String, anchor : String? = nil, tag : String? = nil,
             plain_implicit : Bool = true, quoted_implicit : Bool = true,
             style : ScalarStyle = ScalarStyle::Any) : Nil
    anchor_bytes = checked_name(anchor, "anchor")
    tag_bytes = checked_name(tag, "tag")
    value_bytes = value.to_slice
    raise EmitError.new("scalar value is not valid UTF-8") unless valid_utf8?(value_bytes)
    emit Event.new(EventKind::Scalar, anchor: anchor_bytes, tag: tag_bytes, value: value_bytes,
      implicit: plain_implicit, quoted_implicit: quoted_implicit, scalar_style: style)
  end

  # Starts a sequence. *tag* is written only when *implicit* is false. An
  # empty sequence and a sequence inside a flow collection are written in
  # the flow style whatever *style* asks for.
  #
  # Raises `EmitError` when *anchor* or *tag* is not UTF-8.
  def sequence_start(anchor : String? = nil, tag : String? = nil, implicit : Bool = true,
                     style : SequenceStyle = SequenceStyle::Any) : Nil
    anchor_bytes = checked_name(anchor, "anchor")
    tag_bytes = checked_name(tag, "tag")
    emit Event.new(EventKind::SequenceStart, anchor: anchor_bytes, tag: tag_bytes,
      implicit: implicit, flow: style.flow?)
  end

  # Ends the innermost open sequence.
  def sequence_end : Nil
    emit Event.new(EventKind::SequenceEnd)
  end

  # Starts a mapping; the nodes that follow are its keys and values in
  # turn. *tag* is written only when *implicit* is false. An empty mapping
  # and a mapping inside a flow collection are written in the flow style
  # whatever *style* asks for.
  #
  # Raises `EmitError` when *anchor* or *tag* is not UTF-8.
  def mapping_start(anchor : String? = nil, tag : String? = nil, implicit : Bool = true,
                    style : MappingStyle = MappingStyle::Any) : Nil
    anchor_bytes = checked_name(anchor, "anchor")
    tag_bytes = checked_name(tag, "tag")
    emit Event.new(EventKind::MappingStart, anchor: anchor_bytes, tag: tag_bytes,
      implicit: implicit, flow: style.flow?)
  end

  # Ends the innermost open mapping.
  def mapping_end : Nil
    emit Event.new(EventKind::MappingEnd)
  end

  # Writes an alias (`*anchor`) to the node that carries *anchor*.
  #
  # Raises `EmitError` when *anchor* is not UTF-8.
  def alias(anchor : String) : Nil
    emit Event.new(EventKind::Alias, anchor: checked_name(anchor, "anchor"))
  end

  # Writes the buffered bytes to the `IO`. Events the emitter still holds
  # back for look-ahead stay queued, and flushing the `IO` itself is left
  # to the caller.
  def flush : Nil
    flush_buffer
  end

  # Returns the bytes of *name* the way libyaml reads a C string (up to the
  # first NUL byte), after the UTF-8 check its event initializers make.
  private def checked_name(name : String?, label : String) : Bytes?
    return nil unless name
    bytes = name.to_slice
    terminator = bytes.index(0_u8)
    bytes = bytes[0, terminator] if terminator
    raise EmitError.new("#{label} is not valid UTF-8") unless valid_utf8?(bytes)
    bytes
  end

  # Queues *event*, then writes every queued event whose look-ahead is
  # complete.
  private def emit(event : Event) : Nil
    @events.push(event)
    until need_more_events?
      head = @events[0]
      analyze_event(head)
      run_state(head)
      @events.shift
    end
  end

  # Returns true while the event at the head of the queue has to wait: a
  # DOCUMENT-START for 1 more event, a SEQUENCE-START for 2 and a
  # MAPPING-START for 3, unless the queue already holds the whole node.
  private def need_more_events? : Bool
    return true if @events.empty?
    kind = @events[0].kind
    accumulate =
      if kind.document_start?
        1
      elsif kind.sequence_start?
        2
      elsif kind.mapping_start?
        3
      else
        return false
      end
    return false if @events.size > accumulate

    level = 0
    @events.each do |event|
      if event.kind.opens_level?
        level += 1
      elsif event.kind.closes_level?
        level -= 1
      end
      return false if level == 0
    end
    true
  end

  private def fail(problem : String) : NoReturn
    raise EmitError.new(problem)
  end

  private def increase_indent(flow : Bool, indentless : Bool) : Nil
    @indents.push(@indent)
    if @indent < 0
      @indent = flow ? BEST_INDENT : 0
    elsif !indentless
      @indent += BEST_INDENT
    end
  end

  private def run_state(event : Event) : Nil
    case @state
    in .stream_start?               then emit_stream_start(event)
    in .first_document_start?       then emit_document_start(event, true)
    in .document_start?             then emit_document_start(event, false)
    in .document_content?           then emit_document_content(event)
    in .document_end?               then emit_document_end(event)
    in .flow_sequence_first_item?   then emit_flow_sequence_item(event, true)
    in .flow_sequence_item?         then emit_flow_sequence_item(event, false)
    in .flow_mapping_first_key?     then emit_flow_mapping_key(event, true)
    in .flow_mapping_key?           then emit_flow_mapping_key(event, false)
    in .flow_mapping_simple_value?  then emit_flow_mapping_value(event, true)
    in .flow_mapping_value?         then emit_flow_mapping_value(event, false)
    in .block_sequence_first_item?  then emit_block_sequence_item(event, true)
    in .block_sequence_item?        then emit_block_sequence_item(event, false)
    in .block_mapping_first_key?    then emit_block_mapping_key(event, true)
    in .block_mapping_key?          then emit_block_mapping_key(event, false)
    in .block_mapping_simple_value? then emit_block_mapping_value(event, true)
    in .block_mapping_value?        then emit_block_mapping_value(event, false)
    in .end?                        then fail("expected nothing after STREAM-END")
    end
  end

  private def emit_stream_start(event : Event) : Nil
    @open_ended = 0
    fail("expected STREAM-START") unless event.kind.stream_start?
    @indent = -1
    @column = 0
    @whitespace = true
    @indention = true
    @state = State::FirstDocumentStart
  end

  private def emit_document_start(event : Event, first : Bool) : Nil
    if event.kind.document_start?
      @has_tag_directives = true
      implicit = event.implicit && first
      @open_ended = 0
      implicit = false if empty_document?
      unless implicit
        write_indent
        write_indicator(DOCUMENT_START_INDICATOR, true, false, false)
      end
      @state = State::DocumentContent
      @open_ended = 0
    elsif event.kind.stream_end?
      # A block scalar that keeps its trailing line breaks ended the last
      # document.
      if @open_ended == 2
        write_indicator(DOCUMENT_END_INDICATOR, true, false, false)
        @open_ended = 0
        write_indent
      end
      flush_buffer
      @state = State::End
    else
      fail("expected DOCUMENT-START or STREAM-END")
    end
  end

  private def emit_document_content(event : Event) : Nil
    @states.push(State::DocumentEnd)
    emit_node(event, false, false)
  end

  private def emit_document_end(event : Event) : Nil
    fail("expected DOCUMENT-END") unless event.kind.document_end?
    write_indent
    if !event.implicit
      write_indicator(DOCUMENT_END_INDICATOR, true, false, false)
      @open_ended = 0
      write_indent
    elsif @open_ended == 0
      @open_ended = 1
    end
    flush_buffer
    @state = State::DocumentStart
    @has_tag_directives = false
  end

  private def emit_flow_sequence_item(event : Event, first : Bool) : Nil
    if first
      write_indicator(FLOW_SEQUENCE_START_INDICATOR, true, true, false)
      increase_indent(true, false)
      @flow_level += 1
    end

    if event.kind.sequence_end?
      @flow_level -= 1
      @indent = @indents.pop
      write_indicator(FLOW_SEQUENCE_END_INDICATOR, false, false, false)
      @state = @states.pop
      return
    end

    write_indicator(FLOW_ENTRY_INDICATOR, false, false, false) unless first
    write_indent if @column > BEST_WIDTH
    @states.push(State::FlowSequenceItem)
    emit_node(event, false, false)
  end

  private def emit_flow_mapping_key(event : Event, first : Bool) : Nil
    if first
      write_indicator(FLOW_MAPPING_START_INDICATOR, true, true, false)
      increase_indent(true, false)
      @flow_level += 1
    end

    if event.kind.mapping_end?
      @flow_level -= 1
      @indent = @indents.pop
      write_indicator(FLOW_MAPPING_END_INDICATOR, false, false, false)
      @state = @states.pop
      return
    end

    write_indicator(FLOW_ENTRY_INDICATOR, false, false, false) unless first
    write_indent if @column > BEST_WIDTH

    if simple_key?
      @states.push(State::FlowMappingSimpleValue)
      emit_node(event, true, true)
    else
      write_indicator(KEY_INDICATOR, true, false, false)
      @states.push(State::FlowMappingValue)
      emit_node(event, true, false)
    end
  end

  private def emit_flow_mapping_value(event : Event, simple : Bool) : Nil
    if simple
      write_indicator(VALUE_INDICATOR, false, false, false)
    else
      write_indent if @column > BEST_WIDTH
      write_indicator(VALUE_INDICATOR, true, false, false)
    end
    @states.push(State::FlowMappingKey)
    emit_node(event, true, false)
  end

  private def emit_block_sequence_item(event : Event, first : Bool) : Nil
    increase_indent(false, @mapping_context && !@indention) if first

    if event.kind.sequence_end?
      @indent = @indents.pop
      @state = @states.pop
      return
    end

    write_indent
    write_indicator(BLOCK_ENTRY_INDICATOR, true, false, true)
    @states.push(State::BlockSequenceItem)
    emit_node(event, false, false)
  end

  private def emit_block_mapping_key(event : Event, first : Bool) : Nil
    increase_indent(false, false) if first

    if event.kind.mapping_end?
      @indent = @indents.pop
      @state = @states.pop
      return
    end

    write_indent

    if simple_key?
      @states.push(State::BlockMappingSimpleValue)
      emit_node(event, true, true)
    else
      write_indicator(KEY_INDICATOR, true, false, true)
      @states.push(State::BlockMappingValue)
      emit_node(event, true, false)
    end
  end

  private def emit_block_mapping_value(event : Event, simple : Bool) : Nil
    if simple
      write_indicator(VALUE_INDICATOR, false, false, false)
    else
      write_indent
      write_indicator(VALUE_INDICATOR, true, false, true)
    end
    @states.push(State::BlockMappingKey)
    emit_node(event, true, false)
  end

  private def emit_node(event : Event, mapping : Bool, simple_key : Bool) : Nil
    @mapping_context = mapping
    @simple_key_context = simple_key

    kind = event.kind
    if kind.alias?
      emit_alias
    elsif kind.scalar?
      emit_scalar(event)
    elsif kind.sequence_start?
      emit_sequence_start(event)
    elsif kind.mapping_start?
      emit_mapping_start(event)
    else
      fail("expected SCALAR, SEQUENCE-START, MAPPING-START, or ALIAS")
    end
  end

  private def emit_alias : Nil
    process_anchor
    put(0x20_u8) if @simple_key_context
    @state = @states.pop
  end

  private def emit_scalar(event : Event) : Nil
    select_scalar_style(event)
    process_anchor
    process_tag
    increase_indent(true, false)
    process_scalar
    @indent = @indents.pop
    @state = @states.pop
  end

  private def emit_sequence_start(event : Event) : Nil
    process_anchor
    process_tag
    @state =
      if @flow_level > 0 || event.flow || empty_sequence?
        State::FlowSequenceFirstItem
      else
        State::BlockSequenceFirstItem
      end
  end

  private def emit_mapping_start(event : Event) : Nil
    process_anchor
    process_tag
    @state =
      if @flow_level > 0 || event.flow || empty_mapping?
        State::FlowMappingFirstKey
      else
        State::BlockMappingFirstKey
      end
  end

  # libyaml's `yaml_emitter_check_empty_document` always answers no.
  private def empty_document? : Bool
    false
  end

  private def empty_sequence? : Bool
    return false if @events.size < 2
    @events[0].kind.sequence_start? && @events[1].kind.sequence_end?
  end

  private def empty_mapping? : Bool
    return false if @events.size < 2
    @events[0].kind.mapping_start? && @events[1].kind.mapping_end?
  end

  # Returns true when the node at the head of the queue can be written as
  # a `key:` on one line.
  private def simple_key? : Bool
    kind = @events[0].kind
    length = anchor_length
    if kind.alias?
      # The anchor alone.
    elsif kind.scalar?
      return false if @scalar_multiline
      length += tag_length + @scalar_value.size
    elsif kind.sequence_start?
      return false unless empty_sequence?
      length += tag_length
    elsif kind.mapping_start?
      return false unless empty_mapping?
      length += tag_length
    else
      return false
    end
    length <= MAX_SIMPLE_KEY_LENGTH
  end

  private def anchor_length : Int32
    anchor = @anchor
    anchor ? anchor.size : 0
  end

  private def tag_length : Int32
    handle = @tag_handle
    suffix = @tag_suffix
    (handle ? handle.size : 0) + (suffix ? suffix.size : 0)
  end

  private def select_scalar_style(event : Event) : Nil
    style = event.scalar_style
    no_tag = @tag_handle.nil? && @tag_suffix.nil?

    if no_tag && !event.implicit && !event.quoted_implicit
      fail("neither tag nor implicit flags are specified")
    end

    style = ScalarStyle::Plain if style.any?
    style = ScalarStyle::DoubleQuoted if @simple_key_context && @scalar_multiline

    if style.plain?
      if (@flow_level > 0 && !@flow_plain_allowed) || (@flow_level == 0 && !@block_plain_allowed)
        style = ScalarStyle::SingleQuoted
      end
      if @scalar_value.empty? && (@flow_level > 0 || @simple_key_context)
        style = ScalarStyle::SingleQuoted
      end
      style = ScalarStyle::SingleQuoted if no_tag && !event.implicit
    end

    if style.single_quoted?
      style = ScalarStyle::DoubleQuoted unless @single_quoted_allowed
    end

    if style.literal? || style.folded?
      if !@block_allowed || @flow_level > 0 || @simple_key_context
        style = ScalarStyle::DoubleQuoted
      end
    end

    if no_tag && !event.quoted_implicit && !style.plain?
      @tag_handle = PRIMARY_TAG_HANDLE
    end

    @scalar_style = style
  end

  private def process_anchor : Nil
    anchor = @anchor
    return unless anchor
    write_indicator(@anchor_is_alias ? ALIAS_INDICATOR : ANCHOR_INDICATOR, true, false, false)
    write_anchor(anchor)
  end

  private def process_tag : Nil
    handle = @tag_handle
    suffix = @tag_suffix
    if handle
      write_tag_handle(handle)
      write_tag_content(suffix, false) if suffix
    elsif suffix
      write_indicator(VERBATIM_TAG_START_INDICATOR, true, false, false)
      write_tag_content(suffix, false)
      write_indicator(VERBATIM_TAG_END_INDICATOR, false, false, false)
    end
  end

  private def process_scalar : Nil
    value = @scalar_value
    case @scalar_style
    in .plain?, .any?  then write_plain_scalar(value, !@simple_key_context)
    in .single_quoted? then write_single_quoted_scalar(value, !@simple_key_context)
    in .double_quoted? then write_double_quoted_scalar(value, !@simple_key_context)
    in .literal?       then write_literal_scalar(value)
    in .folded?        then write_folded_scalar(value)
    end
  end
end

require "./emitter/event"
require "./emitter/analysis"
require "./emitter/writer"
