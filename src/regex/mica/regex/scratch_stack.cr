module Regex::Mica::Regex
  # :nodoc:
  # A stack of at most *capacity* values that lives for one call: in the
  # caller's own stack frame when *capacity* is at most `INLINE_CAPACITY`,
  # else in one array on the garbage-collected heap.
  #
  # The walks of a pattern's tree keep one entry per node at most, and most
  # patterns have a few dozen nodes, so their stacks ask the collector for
  # nothing. The values may be references: the collector scans a fiber's
  # stack as it scans an array.
  #
  # Make one with `Mica::Regex.scratch_stack`, in the method that uses it: the
  # stack is valid until that method returns.
  #
  # ```
  # stack = Mica::Regex.scratch_stack(Int32, 3)
  # stack << 7
  # stack.pop # => 7
  # ```
  struct ScratchStack(T)
    # The most values a stack keeps in its maker's stack frame.
    INLINE_CAPACITY = 64

    # The number of values on the stack.
    getter size : Int32 = 0

    # Wraps *buffer*, which has room for *capacity* values.
    def initialize(@buffer : Pointer(T), @capacity : Int32)
    end

    def empty? : Bool
      @size == 0
    end

    # Pushes *value*; raises `IndexError` when the stack is full.
    def <<(value : T) : Nil
      raise IndexError.new("ScratchStack is full") if @size == @capacity
      @buffer[@size] = value
      @size += 1
    end

    # Removes and returns the top value; raises `IndexError` when empty.
    def pop : T
      raise IndexError.new("ScratchStack is empty") if @size == 0
      @size -= 1
      @buffer[@size]
    end

    # Removes and returns the top value, or nil when empty.
    def pop? : T?
      return nil if @size == 0
      @size -= 1
      @buffer[@size]
    end

    # Returns the value at *index*, counted from the bottom.
    def [](index : Int32) : T
      raise IndexError.new unless 0 <= index < @size
      @buffer[index]
    end
  end

  # :nodoc:
  # Makes a `ScratchStack` of *type* with room for *capacity* values, in
  # the stack frame of the method that calls it.
  macro scratch_stack(type, capacity)
    %inline = uninitialized StaticArray({{type}}, ::Regex::Mica::Regex::ScratchStack::INLINE_CAPACITY)
    %capacity = {{capacity}}
    %buffer = if %capacity > ::Regex::Mica::Regex::ScratchStack::INLINE_CAPACITY
                Pointer({{type}}).malloc(%capacity)
              else
                %inline.to_unsafe
              end
    ::Regex::Mica::Regex::ScratchStack({{type}}).new(%buffer, %capacity)
  end
end
