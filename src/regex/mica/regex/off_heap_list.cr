module Regex::Mica::Regex
  # Raised when libc's allocator cannot supply the memory an `OffHeapList`
  # asks for.
  class OutOfMemoryError < Mica::Error
  end

  # :nodoc:
  # A growable list of plain values (numbers, booleans, characters, enums,
  # and records and tuples of them) whose buffer comes from libc's `malloc`
  # instead of the garbage-collected heap, as PCRE2 keeps its tables and
  # match data.
  #
  # The engine's buffers hold no pointers, so the collector never needs to
  # scan them, and keeping them off its heap means a compile or a first
  # search asks the collector for a few small objects only: a process that
  # is about to collect does not start a collection inside a regex call for
  # a buffer of a new size. The element type is checked at compile time.
  #
  # The list is a struct, so it costs no allocation of its own, and it has
  # one owner: the object or method that made it frees it, exactly once,
  # with `free` (an object that keeps one past a call frees it in its
  # `finalize`). A copy of the struct shares the buffer, so a copy may read
  # and write elements, but only the owner's value may grow, shrink or free
  # the list.
  #
  # ```
  # list = Mica::Regex::OffHeapList(Int32).new(4)
  # list << 7
  # list << 8
  # list.sum # => 15
  # list.free
  # ```
  struct OffHeapList(T)
    include Indexable::Mutable(T)

    # The number of elements.
    getter size : Int32 = 0
    # The number of elements the buffer has room for.
    getter capacity : Int32 = 0
    @buffer : Pointer(T) = Pointer(T).null

    # Creates an empty list with room for *capacity* elements.
    def initialize(capacity : Int = 0)
      OffHeapList(T).check_plain
      reserve(capacity.to_i32) if capacity > 0
    end

    # Fails the build unless `T` holds no pointer.
    def self.check_plain : Nil
      {% begin %}
        {% element = T %}
        {% plain = [Number, Bool, Char, Enum].any? { |base| element <= base } %}
        {% if !plain && (element < Tuple || element < Struct) && !(element < Reference) %}
          {% fields = element < Tuple ? element.type_vars : element.instance_vars.map(&.type) %}
          {% plain = fields.all? { |field| [Number, Bool, Char, Enum].any? { |base| field <= base } } %}
        {% end %}
        {% raise "OffHeapList(#{element}) needs a type that holds no pointer: numbers, booleans, characters, enums, or records and tuples of them" unless plain %}
      {% end %}
    end

    # Creates a list of *size* copies of *value*.
    def self.new(size : Int, value : T) : self
      list = new(size)
      size.times { list << value }
      list
    end

    # Creates a list of *size* elements, each the block's value for its index.
    def self.new(size : Int, & : Int32 -> T) : self
      list = new(size)
      size.to_i32.times { |index| list << yield index }
      list
    end

    # Copies *values* into a new list.
    def self.copy_of(values : Indexable(T)) : self
      list = new(values.size)
      values.each { |value| list << value }
      list
    end

    # Copies *values* into a new list (one memory copy).
    def self.copy_of(values : OffHeapList(T)) : self
      list = new(values.size)
      list.concat(values)
      list
    end

    # Appends every element of *values* (one memory copy).
    def concat(values : OffHeapList(T)) : Nil
      # A list appended to itself: its buffer may move when it grows.
      appends_itself = values.to_unsafe == @buffer
      reserve(Math.max(@size + values.size, @capacity * 2)) if @size + values.size > @capacity
      (@buffer + @size).copy_from(appends_itself ? @buffer : values.to_unsafe, values.size)
      @size += values.size
    end

    # Sets the size to *count*, which must be within the capacity: the
    # caller has written the elements up to it through `to_unsafe`.
    def resize_within_capacity(count : Int32) : Nil
      raise IndexError.new("OffHeapList of capacity #{@capacity} cannot hold #{count} elements") unless 0 <= count <= @capacity
      @size = count
    end

    @[AlwaysInline]
    def unsafe_fetch(index : Int) : T
      @buffer[index]
    end

    @[AlwaysInline]
    def unsafe_put(index : Int, value : T) : T
      @buffer[index] = value
    end

    # Appends *value*, growing the buffer when it is full.
    @[AlwaysInline]
    def <<(value : T) : Nil
      reserve(@capacity == 0 ? 4 : @capacity * 2) if @size == @capacity
      @buffer[@size] = value
      @size += 1
    end

    # Appends every element of *values*.
    def concat(values : Indexable(T)) : Nil
      reserve(Math.max(@size + values.size, @capacity * 2)) if @size + values.size > @capacity
      values.each_with_index { |value, index| @buffer[@size + index] = value }
      @size += values.size
    end

    # Appends *value* (same as `<<`).
    def push(value : T) : Nil
      self << value
    end

    # Removes and returns the last element; raises `IndexError` when empty.
    def pop : T
      raise IndexError.new("OffHeapList is empty") if @size == 0
      @size -= 1
      @buffer[@size]
    end

    # Removes and returns the last element, or nil when empty.
    @[AlwaysInline]
    def pop? : T?
      return nil if @size == 0
      @size -= 1
      @buffer[@size]
    end

    # Removes every element, keeping the buffer.
    def clear : Nil
      @size = 0
    end

    # Keeps the first *count* elements (at most `size`).
    def truncate(count : Int32) : Nil
      @size = count.clamp(0, @size)
    end

    # Grows the buffer to room for at least *wanted* elements.
    def reserve(wanted : Int32) : Nil
      return if wanted <= @capacity
      reallocate(wanted)
    end

    # Appends *count* copies of *value*.
    def fill_to(count : Int32, value : T) : Nil
      reserve(count)
      while @size < count
        @buffer[@size] = value
        @size += 1
      end
    end

    # Shrinks the buffer to the elements it holds.
    def trim : Nil
      return if @size == @capacity
      if @size == 0
        free
      else
        reallocate(@size)
      end
    end

    # True when *other* holds the same elements in the same order.
    def ==(other : Indexable) : Bool
      equals?(other) { |left, right| left == right }
    end

    # Copies *count* elements from *start* into a new `Array` (for specs
    # and diagnostics).
    def [](start : Int, count : Int) : Array(T)
      to_slice[start, count].to_a
    end

    def to_s(io : IO) : Nil
      io << "OffHeapList"
      to_slice.to_s(io)
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    # The elements as a slice over the buffer; it is valid until the list
    # grows, shrinks or is freed.
    def to_slice : Slice(T)
      Slice.new(@buffer, @size)
    end

    def to_unsafe : Pointer(T)
      @buffer
    end

    # Bytes the buffer holds.
    def buffer_bytes : Int64
      @capacity.to_i64 * sizeof(T)
    end

    # Returns the buffer to libc and leaves the list empty. Freeing an
    # empty or already freed list does nothing.
    def free : Nil
      LibC.free(@buffer.as(Void*)) unless @buffer.null?
      @buffer = Pointer(T).null
      @size = 0
      @capacity = 0
    end

    private def reallocate(capacity : Int32) : Nil
      bytes = LibC::SizeT.new(capacity) * sizeof(T)
      grown = LibC.realloc(@buffer.as(Void*), bytes).as(Pointer(T))
      raise OutOfMemoryError.new("Out of memory: a list of #{capacity} elements (#{bytes} bytes)") if grown.null?
      OffHeap.count(bytes) if capacity > @capacity
      @buffer = grown
      @capacity = capacity
    end
  end
end

module Regex::Mica::Regex
  # :nodoc:
  # Fixed buffers of plain values (see `OffHeapList` for the types) from
  # libc's `malloc`, for engines that size a buffer once and keep it: the
  # caller frees each one exactly once, with `free`.
  module OffHeap
    # Bytes asked of libc so far, counted like `GC::Stats#total_bytes`:
    # every allocation, and the new size of every growth (shrinks and
    # frees count nothing). Specs add it to the collector's count to bound
    # what a compile or a search allocates in all.
    @@allocated_bytes = Atomic(Int64).new(0_i64)

    # The bytes asked of libc so far (see `@@allocated_bytes`).
    def self.allocated_bytes : Int64
      @@allocated_bytes.get(:relaxed)
    end

    # :nodoc:
    def self.count(bytes : Int) : Nil
      @@allocated_bytes.add(bytes.to_i64, :relaxed)
    end

    # A new slice of *size* copies of *value*.
    def self.slice(type : T.class, size : Int, value : T) : Slice(T) forall T
      return Slice(T).empty if size == 0
      buffer = pointer(T, size)
      size.times { |index| buffer[index] = value }
      Slice.new(buffer, size)
    end

    # A new buffer of *element_count* elements, not initialized.
    def self.pointer(type : T.class, element_count : Int) : Pointer(T) forall T
      OffHeapList(T).check_plain
      bytes = LibC::SizeT.new(element_count) * sizeof(T)
      buffer = LibC.malloc(bytes).as(Pointer(T))
      raise OutOfMemoryError.new("Out of memory: a buffer of #{element_count} elements (#{bytes} bytes)") if buffer.null?
      OffHeap.count(bytes)
      buffer
    end

    # Returns *slice*'s buffer to libc (nothing for an empty slice).
    def self.free(slice : Slice) : Nil
      free(slice.to_unsafe)
    end

    # Returns *buffer* to libc (nothing for a null pointer).
    def self.free(buffer : Pointer) : Nil
      LibC.free(buffer.as(Void*)) unless buffer.null?
    end
  end
end

module Regex::Mica::Regex
  # :nodoc:
  # Frees the buffers outside the collector's heap of an object that sits
  # in a cycle of references: a program refers to its plan, whose engines
  # and caches refer back to the program. The collector never finalizes
  # an object that can reach itself through others, so such an object
  # cannot free its buffers in its own `finalize`; it records them here
  # instead. The owner refers to nothing on the collector's heap, so it is
  # collected, and frees them, once the object is gone (the same reason
  # `CacheReservation` is a separate object).
  #
  # The object calls `track` for each buffer it takes, `retrack` when a
  # buffer moves (a list grew) and `untrack` when it frees one itself.
  class OffHeapOwner
    @list_of_addresses = OffHeapList(UInt64).new

    # Records *buffer* (a null pointer is ignored).
    def track(buffer : Pointer) : Nil
      @list_of_addresses << buffer.address unless buffer.null?
    end

    # Records that *before* moved to *after* (the result of a `realloc`).
    def retrack(before : Pointer, after : Pointer) : Nil
      return if before.address == after.address
      untrack(before)
      track(after)
    end

    # Forgets *buffer*, which its object has freed.
    def untrack(buffer : Pointer) : Nil
      return if buffer.null?
      index = @list_of_addresses.index(buffer.address) || return
      last = @list_of_addresses.size - 1
      @list_of_addresses[index] = @list_of_addresses[last]
      @list_of_addresses.truncate(last)
    end

    def finalize
      @list_of_addresses.each { |address| LibC.free(Pointer(Void).new(address)) }
      @list_of_addresses.free
    end
  end
end
