module YAML::Mica::YAML
  # A place in the input as the scanner counts it: 0-based byte offset,
  # 0-based line and 0-based column in characters.
  #
  # :nodoc:
  record Mark, offset : Int32, line : Int32, column : Int32 do
    # Returns the mark as a `Core::Position` (1-based line and column).
    def position : Core::Position
      Core::Position.new(@offset.to_i64, @line + 1, @column + 1)
    end
  end

  # One lexical token. *value* holds a scalar's content, an anchor or alias
  # name, a tag's suffix or a tag directive's prefix; *handle* a tag's or
  # tag directive's handle; *major* and *minor* a version directive.
  #
  # :nodoc:
  struct Token
    enum Kind : UInt8
      StreamStart
      StreamEnd
      VersionDirective
      TagDirective
      DocumentStart
      DocumentEnd
      BlockSequenceStart
      BlockMappingStart
      BlockEnd
      FlowSequenceStart
      FlowSequenceEnd
      FlowMappingStart
      FlowMappingEnd
      BlockEntry
      FlowEntry
      Key
      Value
      Alias
      Anchor
      Tag
      Scalar
    end

    getter kind : Kind
    getter style : ScalarStyle
    getter start_mark : Mark
    getter end_mark : Mark
    getter value : String
    getter handle : String
    getter major : Int32
    getter minor : Int32

    def initialize(@kind : Kind, @start_mark : Mark, @end_mark : Mark, @value : String = "",
                   @handle : String = "", @style : ScalarStyle = ScalarStyle::Any,
                   @major : Int32 = 0, @minor : Int32 = 0)
    end
  end

  # A growable byte buffer the scanner reuses for scalar content.
  #
  # :nodoc:
  class ByteBuffer
    getter size : Int32 = 0

    def initialize(capacity : Int32 = 256)
      @bytes = Bytes.new(capacity)
    end

    def clear : Nil
      @size = 0
    end

    def empty? : Bool
      @size == 0
    end

    def <<(byte : UInt8) : Nil
      grow(1) if @size == @bytes.size
      @bytes[@size] = byte
      @size += 1
    end

    def write(source : Bytes) : Nil
      return if source.empty?
      grow(source.size) if @bytes.size - @size < source.size
      Core::ByteScan.copy_into(@bytes, @size, source)
      @size += source.size
    end

    def write(other : ByteBuffer) : Nil
      write(other.to_slice)
    end

    def to_slice : Bytes
      @bytes[0, @size]
    end

    def first_byte : UInt8
      @size > 0 ? @bytes[0] : 0_u8
    end

    private def grow(needed : Int32) : Nil
      capacity = @bytes.size
      while capacity - @size < needed
        raise ArgumentError.new("Scalar larger than 1 GiB") if capacity > Int32::MAX // 2
        capacity *= 2
      end
      bytes = Bytes.new(capacity)
      Core::ByteScan.copy_into(bytes, 0, @bytes[0, @size])
      @bytes = bytes
    end
  end
end
