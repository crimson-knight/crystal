module Regex::Mica::Regex
  # Groups the 256 byte values into classes that no part of a program can
  # tell apart: every byte range of every state starts and ends on a class
  # boundary, and so do the bytes the assertions look at (the line feed,
  # the ASCII word characters, UTF-8 continuation bytes and non-ASCII
  # bytes). The lazy DFA and the one-pass DFA keep one transition per class
  # instead of one per byte, and use a class's first byte (its
  # representative) wherever a byte is needed.
  class ByteClasses
    # The number of classes (1 to 256).
    getter class_count : Int32
    # The class of each byte, then (from byte 256) the first byte of each
    # class, in order (the first `class_count`): one 512-byte table from
    # libc (`OffHeap`), so the object on the collector's heap is small;
    # `finalize` frees it.
    @class_of : Pointer(UInt8)
    @list_of_representatives : Pointer(UInt8)

    def initialize(program : Program)
      boundaries = StaticArray(Bool, 257).new(false)
      program.each_distinct_state do |state, _|
        ByteClasses.mark(pointerof(boundaries), state.low.to_i32, state.high.to_i32) if state.kind.byte_range?
      end
      program.each_transition_range { |low, high| ByteClasses.mark(pointerof(boundaries), low.to_i32, high.to_i32) }
      {% for range in [{0x0A, 0x0A}, {0x30, 0x39}, {0x41, 0x5A}, {0x5F, 0x5F}, {0x61, 0x7A}, {0x80, 0xBF}] %}
        ByteClasses.mark(pointerof(boundaries), {{range[0]}}, {{range[1]}})
      {% end %}
      @class_of = OffHeap.pointer(UInt8, 512)
      @class_of.clear(512)
      @list_of_representatives = @class_of + 256
      current = 0
      (1..255).each do |byte|
        if boundaries[byte]
          current += 1
          @list_of_representatives[current] = byte.to_u8
        end
        @class_of[byte] = current.to_u8
      end
      @class_count = current + 1
    end

    def finalize
      OffHeap.free(@class_of)
    end

    # Marks the class boundaries *low* and *high* + 1 in *boundaries*.
    protected def self.mark(boundaries : StaticArray(Bool, 257)*, low : Int32, high : Int32) : Nil
      boundaries.value[low] = true
      boundaries.value[high + 1] = true
    end

    # Returns the class of *byte*.
    @[AlwaysInline]
    def class_of(byte : UInt8) : Int32
      @class_of[byte].to_i32
    end

    # Returns the first byte of class *class_index*.
    def representative(class_index : Int32) : UInt8
      @list_of_representatives[class_index]
    end

    # Returns the number of byte values in class *class_index* (a class is
    # a run of consecutive bytes, from its representative to the next
    # class's).
    def class_size(class_index : Int32) : Int32
      next_start = class_index + 1 < @class_count ? @list_of_representatives[class_index + 1].to_i32 : 256
      next_start - @list_of_representatives[class_index].to_i32
    end

    # :nodoc:
    # The byte-to-class table, for the search loops.
    def table : Pointer(UInt8)
      @class_of
    end
  end
end
