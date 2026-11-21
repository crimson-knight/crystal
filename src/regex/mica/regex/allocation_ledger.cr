module Regex::Mica::Regex
  # Counts the bytes one compilation allocates and refuses the allocation
  # that would pass `CompileLimits#max_compile_bytes`.
  #
  # Every structure the compiler builds is charged here *before* it is
  # allocated, with an upper bound on what the garbage collector really
  # hands out for it, so the ledger total is never below the process's
  # allocation and a refused pattern has allocated at most one charge past
  # its limit:
  #
  # - an object is charged `instance_sizeof` plus the collector's extra
  #   byte, rounded up to its 16-byte granule (`charge_object`);
  # - an array of known size is charged its object and its buffer
  #   (`charge_array`);
  # - an array that grows one element at a time is charged
  #   `GROWTH_FACTOR` times the element size per element (`charge_append`),
  #   which covers every buffer its geometric growth allocates and frees
  #   along the way;
  # - a string is charged its header, bytes and terminator (`charge_string`).
  #
  # `spec/regex/compile_complexity_spec.cr` checks the bound against
  # `GC.stats` for the worst accepted pattern families.
  #
  # WARNING: A ledger belongs to one compilation and one fiber.
  class AllocationLedger
    # The collector's allocation granule.
    GRANULE = 16
    # What the collector allocates to register one finalizer (its
    # finalization record), beside the object itself: measured as 32 bytes
    # with bdwgc 8.2 on 64-bit targets, checked by the Pike VM charge spec.
    FINALIZER_BYTES = 32

    # Bytes a growing `Array` allocates per element, as a multiple of the
    # element size: stdlib arrays double up to 256 elements and then grow
    # by about 1.25, so the buffers allocated for n elements sum to at most
    # 6.24 n elements, granule rounding included (the worst case is near
    # 1.8 million elements).
    GROWTH_FACTOR = 7

    # Bytes charged so far.
    getter bytes : Int64 = 0_i64

    # The limit enforced.
    getter limit : Int64

    def initialize(@limit : Int64)
    end

    # The `ClassMemo::Block`s this compilation built and the memo did not
    # keep, whose lists sit outside the collector's heap: the compilation
    # hands them to its program (`take_owned_blocks`), which frees them with
    # itself, or frees them when it stops early (`free_owned_blocks`).
    @list_of_owned_blocks : Array(ClassMemo::Block)? = nil

    # Records *block* as this compilation's.
    def own(block : ClassMemo::Block) : Nil
      (@list_of_owned_blocks ||= [] of ClassMemo::Block) << block
    end

    # Hands the owned blocks over (nil when there are none); the ledger no
    # longer owns them.
    def take_owned_blocks : Array(ClassMemo::Block)?
      owned = @list_of_owned_blocks
      @list_of_owned_blocks = nil
      owned
    end

    # Frees the blocks the ledger still owns.
    def free_owned_blocks : Nil
      take_owned_blocks.try(&.each(&.free))
    end

    # Returns the bytes the collector takes for a request of *count*
    # bytes: it adds one byte (so a pointer just past the end still keeps
    # the object alive) and rounds up to its granule.
    def self.granules(count : Int) : Int64
      (count.to_i64 + GRANULE) // GRANULE * GRANULE
    end

    # Charges *count* bytes for *what*, an allocation about to happen at
    # *offset* in the pattern. Raises `CompileLimitError` naming
    # `max_compile_bytes` when the total would pass the limit.
    def charge(count : Int, what : String, offset : Int32) : Nil
      raise ArgumentError.new("Negative allocation charge: #{count}") if count < 0
      total = @bytes &+ count
      if total > @limit || total < @bytes
        raise CompileLimitError.new("max_compile_bytes", @limit, "Allocating #{what} (#{count} bytes after #{@bytes})",
          Core::Position.new(offset.to_i64))
      end
      @bytes = total
    end

    # True when *count* more bytes fit under the limit, so charges that
    # sum to *count* raise nothing.
    def room_for?(count : Int64) : Bool
      count >= 0 && count <= @limit - @bytes
    end

    # Charges one object of *instance_bytes* (its `instance_sizeof`).
    def charge_object(instance_bytes : Int, what : String, offset : Int32) : Nil
      charge(AllocationLedger.granules(instance_bytes), what, offset)
    end

    # Charges an array allocated with exactly *capacity* elements of
    # *element_bytes* each: the array object and its buffer.
    def charge_array(capacity : Int, element_bytes : Int, what : String, offset : Int32) : Nil
      raise ArgumentError.new("Negative capacity: #{capacity}") if capacity < 0
      buffer = capacity > 0 ? AllocationLedger.granules(capacity.to_i64 * element_bytes) : 0_i64
      charge(AllocationLedger.granules(instance_sizeof(Array(Int32))) + buffer, what, offset)
    end

    # Charges one element of *element_bytes* appended to a growing array
    # (the array object itself is charged when it is created).
    def charge_append(element_bytes : Int, what : String, offset : Int32) : Nil
      charge(element_bytes.to_i64 * GROWTH_FACTOR, what, offset)
    end

    # Charges *count* elements of *element_bytes* appended to a growing
    # array, as *count* calls of `charge_append` would.
    def charge_appends(count : Int, element_bytes : Int, what : String, offset : Int32) : Nil
      raise ArgumentError.new("Negative count: #{count}") if count < 0
      charge(element_bytes.to_i64 * GROWTH_FACTOR * count, what, offset)
    end

    # Charges one entry added to a `Hash` or `Set` whose key and value take
    # *entry_bytes*: the entry, its hash and its index slot, with the
    # growth of both tables (the hash object is charged when it is
    # created).
    def charge_hash_entry(entry_bytes : Int, what : String, offset : Int32) : Nil
      charge_append(entry_bytes + 16, what, offset)
    end

    # Charges a string of *bytesize* bytes.
    def charge_string(bytesize : Int, what : String, offset : Int32) : Nil
      charge(AllocationLedger.granules(sizeof(Int32) * 3 + bytesize.to_i64 + 1), what, offset)
    end
  end
end
