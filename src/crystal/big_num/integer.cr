module Crystal::BigNum
  # :nodoc:
  #
  # An arbitrary-precision integer: sign and magnitude, immutable and
  # normalized (no high zero limb; zero has no limbs). Values up to two limbs
  # (128 bits) live inline, so they are built, added and compared with no
  # allocation; larger magnitudes live in limbs from `GC.malloc_atomic`, which
  # the collector never scans. Copies share their limbs, and every operation
  # writes its result into a fresh buffer.
  #
  # Operators and methods have `BigInt`'s names and GMP's semantics: bitwise
  # operators and `>>` present the two's complement of the value.
  struct Integer
    include Comparable(Integer)

    # The signed limb count: the sign of the value, and the count of limbs in
    # use. Zero is 0.
    @size : Int32
    # Limb 0 when the value has at most two limbs.
    @low : Limb
    # Limb 1 when the value has at most two limbs.
    @high : Limb
    # The limbs, least significant first, when the value has more than two.
    @limbs : Pointer(Limb)

    protected def initialize(@size : Int32, @low : Limb, @high : Limb, @limbs : Pointer(Limb))
    end

    # Zero.
    def self.zero : Integer
      new(0, Limb.zero, Limb.zero, Pointer(Limb).null)
    end

    # The value of the primitive integer *value*.
    def self.new(value : ::Int::Primitive) : Integer
      if value.is_a?(::Int::Signed)
        negative = value < 0
        magnitude = negative ? 0_u128 &- value.to_i128.to_u128! : value.to_u128
        from_magnitude(magnitude, negative)
      else
        from_magnitude(value.to_u128, false)
      end
    end

    # The value with the 128-bit *magnitude* and the sign *negative*.
    protected def self.from_magnitude(magnitude : UInt128, negative : Bool) : Integer
      low = magnitude.to_u64!
      high = (magnitude >> 64).to_u64!
      size = high != 0 ? 2 : (low != 0 ? 1 : 0)
      new(negative ? -size : size, low, high, Pointer(Limb).null)
    end

    # The value whose magnitude is *limbs* (least significant first) and
    # whose sign is *negative*. The limbs are copied; high zero limbs are
    # dropped, and a zero magnitude gives zero whatever *negative* says.
    def self.from_limbs(limbs : Slice(Limb), negative : Bool) : Integer
      count = Limbs.normalize(limbs.to_unsafe, limbs.size)
      build(count, negative) do |pointer|
        Limbs.copy(pointer, limbs.to_unsafe, count)
        count
      end
    end

    # Builds a value in a fresh buffer of *capacity* limbs: the block writes
    # the magnitude there and returns how many limbs it wrote. The result is
    # normalized, and moved inline when it fits in two limbs. The buffer is
    # only valid inside the block.
    def self.build(capacity : Int32, negative : Bool, & : Pointer(Limb) -> Int32) : Integer
      if capacity <= 2
        buffer = uninitialized StaticArray(Limb, 2)
        used = yield buffer.to_unsafe
        from_buffer(buffer.to_unsafe, used, negative, false)
      else
        pointer = Limbs.allocate(capacity)
        used = yield pointer
        from_buffer(pointer, used, negative, true)
      end
    end

    # Normalizes the *used* limbs at *pointer* and wraps them; with
    # *owned_heap* the pointer itself becomes the value's limbs.
    protected def self.from_buffer(pointer : Pointer(Limb), used : Int32, negative : Bool, owned_heap : Bool) : Integer
      count = Limbs.normalize(pointer, used)
      if count <= 2
        low = count > 0 ? pointer[0] : Limb.zero
        high = count > 1 ? pointer[1] : Limb.zero
        new(negative ? -count : count, low, high, Pointer(Limb).null)
      elsif owned_heap
        new(negative ? -count : count, Limb.zero, Limb.zero, pointer)
      else
        heap = Limbs.allocate(count)
        Limbs.copy(heap, pointer, count)
        new(negative ? -count : count, Limb.zero, Limb.zero, heap)
      end
    end

    # The read-only magnitude, least significant limb first, with no high zero
    # limb. An inline value gives a copy of its limbs.
    def limbs : Slice(Limb)
      count = size
      if count <= 2
        copy = Slice(Limb).new(count) { |index| index == 0 ? @low : @high }
        Slice.new(copy.to_unsafe, count, read_only: true)
      else
        Slice.new(@limbs, count, read_only: true)
      end
    end

    # Whether the value is below zero.
    def negative? : Bool
      @size < 0
    end

    # Whether the value is zero.
    def zero? : Bool
      @size == 0
    end

    # The count of limbs in the magnitude.
    def size : Int32
      @size.abs
    end

    # The signed limb count (see `@size`).
    protected def signed_size : Int32
      @size
    end

    # Whether the magnitude is held inline.
    protected def inline? : Bool
      @size.abs <= 2
    end

    # The magnitude of an inline value.
    protected def magnitude128 : UInt128
      (@high.to_u128! << 64) | @low
    end

    # Limb *index* of the magnitude (which must be below `size`).
    protected def limb_at(index : Int) : Limb
      if inline?
        index == 0 ? @low : @high
      else
        @limbs[index]
      end
    end

    # A pointer to the magnitude. For an inline value it points into this
    # value's own storage, so it is valid only while that storage is: use it
    # on locals and parameters within one method, never keep it.
    protected def limb_pointer : Pointer(Limb)
      inline? ? pointerof(@low) : @limbs
    end

    # -1, 0 or 1 as the value is negative, zero or positive.
    def sign : Int32
      @size <=> 0
    end

    # ---- Addition and subtraction ----

    def +(other : Integer) : Integer
      if inline? && other.inline?
        a = magnitude128
        b = other.magnitude128
        if negative? == other.negative?
          sum = a &+ b
          return Integer.from_magnitude(sum, negative?) if sum >= a
          heap = Limbs.allocate(3)
          heap[0] = sum.to_u64!
          heap[1] = (sum >> 64).to_u64!
          heap[2] = Limb.new(1)
          return Integer.new(negative? ? -3 : 3, Limb.zero, Limb.zero, heap)
        elsif a >= b
          return Integer.from_magnitude(a &- b, negative?)
        else
          return Integer.from_magnitude(b &- a, other.negative?)
        end
      end
      Integer.add_signed(limb_pointer, @size, other.limb_pointer, other.signed_size)
    end

    def +(other : ::Int::Primitive) : Integer
      self + Integer.new(other)
    end

    def -(other : Integer) : Integer
      self + (-other)
    end

    def -(other : ::Int::Primitive) : Integer
      self + (-Integer.new(other))
    end

    # The sum of the signed magnitudes at *ap* and *bp* (signed limb counts
    # *a_size* and *b_size*).
    protected def self.add_signed(ap : Pointer(Limb), a_size : Int32, bp : Pointer(Limb), b_size : Int32) : Integer
      a_count = a_size.abs
      b_count = b_size.abs
      if (a_size < 0) == (b_size < 0)
        negative = a_size < 0
        if a_count < b_count
          ap, bp = bp, ap
          a_count, b_count = b_count, a_count
        end
        build(a_count + 1, negative) do |rp|
          rp[a_count] = Limbs.add(rp, ap, a_count, bp, b_count)
          a_count + 1
        end
      else
        order = a_count != b_count ? (a_count > b_count ? 1 : -1) : Limbs.cmp(ap, bp, a_count)
        return zero if order == 0
        if order > 0
          build(a_count, a_size < 0) do |rp|
            Limbs.sub(rp, ap, a_count, bp, b_count)
            a_count
          end
        else
          build(b_count, b_size < 0) do |rp|
            Limbs.sub(rp, bp, b_count, ap, a_count)
            b_count
          end
        end
      end
    end

    def - : Integer
      Integer.new(-@size, @low, @high, @limbs)
    end

    def abs : Integer
      Integer.new(@size.abs, @low, @high, @limbs)
    end

    # ---- Comparison ----

    def <=>(other : Integer) : Int32
      a_size = @size
      b_size = other.signed_size
      return a_size > b_size ? 1 : -1 if a_size != b_size
      count = a_size.abs
      order = if count <= 2
                a = magnitude128
                b = other.magnitude128
                a == b ? 0 : (a > b ? 1 : -1)
              else
                Limbs.cmp(@limbs, other.limb_pointer, count)
              end
      a_size < 0 ? -order : order
    end

    def <=>(other : ::Int::Primitive) : Int32
      self <=> Integer.new(other)
    end

    def ==(other : Integer) : Bool
      return false if @size != other.signed_size
      return magnitude128 == other.magnitude128 if inline?
      Limbs.cmp(@limbs, other.limb_pointer, size) == 0
    end

    def ==(other : ::Int::Primitive) : Bool
      self == Integer.new(other)
    end

    # ---- Hash ----

    # The value reduced the way `Crystal::Hasher.reduce_num` reduces an
    # integer: the magnitude modulo the Mersenne prime 2**61 - 1, negated
    # (wrapping) for a negative value. Equal to what `BigInt` gives today.
    def hash_reduce : UInt64
      residue = magnitude_modulo_hash_prime
      negative? ? 0_u64 &- residue : residue
    end

    # Feeds the value to *hasher* exactly as `BigInt#hash(hasher)` does for an
    # equal `BigInt`, so equal numbers hash alike across types.
    def hash(hasher)
      residue = magnitude_modulo_hash_prime.to_i64
      hasher.number(negative? ? -residue : residue)
    end

    private HASH_PRIME = (1_u64 << 61) - 1

    # The magnitude modulo 2**61 - 1. Since 2**61 = 1 (mod 2**61 - 1), the
    # magnitude cut into 61-bit pieces, least significant first, has the
    # same residue as the sum of the pieces; the pieces are independent, so
    # the sum runs at the processor's full width instead of one long chain.
    private def magnitude_modulo_hash_prime : UInt64
      count = size
      return Integer.fold_hash_prime(magnitude128) if count <= 2
      pointer = @limbs
      sum = 0_u128
      position = 0
      # Pieces whose window may reach into the limb above their first.
      last_full = (count &- 1) &* LIMB_BITS
      while position < last_full
        index = position >> 6
        window = ((pointer[index &+ 1].to_u128! << 64) | pointer[index]) >> (position & 63)
        sum &+= window.to_u64! & HASH_PRIME
        position &+= 61
      end
      top = pointer[count &- 1]
      while position < count &* LIMB_BITS
        sum &+= (top >> (position & 63)) & HASH_PRIME
        position &+= 61
      end
      Integer.fold_hash_prime(sum)
    end

    # *value* (below 2**126) folded modulo 2**61 - 1 to below 2**62 (and
    # fully reduced when *value* is below 2**122).
    protected def self.fold_hash_prime(value : UInt128) : UInt64
      folded = (value & HASH_PRIME) &+ ((value >> 61) & HASH_PRIME) &+ (value >> 122)
      folded = (folded & HASH_PRIME) &+ (folded >> 61)
      residue = folded.to_u64!
      residue >= HASH_PRIME ? residue &- HASH_PRIME : residue
    end

    # ---- Bit operations (two's complement view, as GMP) ----

    def ~ : Integer
      -(self + Integer.new(1))
    end

    def &(other : Integer) : Integer
      if !negative? && !other.negative? && inline? && other.inline?
        return Integer.from_magnitude(magnitude128 & other.magnitude128, false)
      end
      Integer.bitwise_and(limb_pointer, @size, other.limb_pointer, other.signed_size)
    end

    def &(other : ::Int::Primitive) : Integer
      self & Integer.new(other)
    end

    def |(other : Integer) : Integer
      if !negative? && !other.negative? && inline? && other.inline?
        return Integer.from_magnitude(magnitude128 | other.magnitude128, false)
      end
      Integer.bitwise_or(limb_pointer, @size, other.limb_pointer, other.signed_size)
    end

    def |(other : ::Int::Primitive) : Integer
      self | Integer.new(other)
    end

    def ^(other : Integer) : Integer
      if !negative? && !other.negative? && inline? && other.inline?
        return Integer.from_magnitude(magnitude128 ^ other.magnitude128, false)
      end
      Integer.bitwise_xor(limb_pointer, @size, other.limb_pointer, other.signed_size)
    end

    def ^(other : ::Int::Primitive) : Integer
      self ^ Integer.new(other)
    end

    # A fresh copy of the *count* limbs at *pointer* less one (the magnitude
    # is at least 1): the two's complement of a negative value is the
    # complement of this.
    protected def self.magnitude_less_one(pointer : Pointer(Limb), count : Int32) : Pointer(Limb)
      copy = Limbs.allocate(count)
      Limbs.sub_1(copy, pointer, count, Limb.new(1))
      copy
    end

    # Adds one to the *count* limbs at *rp* and stores the carry at
    # `rp[count]`; returns `count + 1`.
    protected def self.increment_into(rp : Pointer(Limb), count : Int32) : Int32
      rp[count] = Limbs.add_1(rp, rp, count, Limb.new(1))
      count + 1
    end

    protected def self.bitwise_and(ap : Pointer(Limb), a_size : Int32, bp : Pointer(Limb), b_size : Int32) : Integer
      if a_size < 0 && b_size >= 0
        ap, bp = bp, ap
        a_size, b_size = b_size, a_size
      end
      a_count = a_size.abs
      b_count = b_size.abs
      if b_size >= 0
        # x & y = x & y.
        count = Math.min(a_count, b_count)
        build(count, false) do |rp|
          Limbs.and_n(rp, ap, bp, count)
          count
        end
      elsif a_size >= 0
        # x & -y = x & ~(y - 1); the complement is all ones above y.
        b_less = magnitude_less_one(bp, b_count)
        build(a_count, false) do |rp|
          common = Math.min(a_count, b_count)
          Limbs.andn_n(rp, ap, b_less, common)
          Limbs.copy(rp + common, ap + common, a_count - common)
          a_count
        end
      else
        # -x & -y = -(((x - 1) | (y - 1)) + 1).
        if a_count < b_count
          ap, bp = bp, ap
          a_count, b_count = b_count, a_count
        end
        a_less = magnitude_less_one(ap, a_count)
        b_less = magnitude_less_one(bp, b_count)
        build(a_count + 1, true) do |rp|
          Limbs.ior_n(rp, a_less, b_less, b_count)
          Limbs.copy(rp + b_count, a_less + b_count, a_count - b_count)
          increment_into(rp, a_count)
        end
      end
    end

    protected def self.bitwise_or(ap : Pointer(Limb), a_size : Int32, bp : Pointer(Limb), b_size : Int32) : Integer
      if a_size < 0 && b_size >= 0
        ap, bp = bp, ap
        a_size, b_size = b_size, a_size
      end
      a_count = a_size.abs
      b_count = b_size.abs
      if b_size >= 0
        # x | y = x | y.
        if a_count < b_count
          ap, bp = bp, ap
          a_count, b_count = b_count, a_count
        end
        build(a_count, false) do |rp|
          Limbs.ior_n(rp, ap, bp, b_count)
          Limbs.copy(rp + b_count, ap + b_count, a_count - b_count)
          a_count
        end
      elsif a_size >= 0
        # x | -y = -(((y - 1) & ~x) + 1); only y's limbs count.
        b_less = magnitude_less_one(bp, b_count)
        build(b_count + 1, true) do |rp|
          common = Math.min(a_count, b_count)
          Limbs.andn_n(rp, b_less, ap, common)
          Limbs.copy(rp + common, b_less + common, b_count - common)
          increment_into(rp, b_count)
        end
      else
        # -x | -y = -(((x - 1) & (y - 1)) + 1).
        count = Math.min(a_count, b_count)
        a_less = magnitude_less_one(ap, a_count)
        b_less = magnitude_less_one(bp, b_count)
        build(count + 1, true) do |rp|
          Limbs.and_n(rp, a_less, b_less, count)
          increment_into(rp, count)
        end
      end
    end

    protected def self.bitwise_xor(ap : Pointer(Limb), a_size : Int32, bp : Pointer(Limb), b_size : Int32) : Integer
      if a_size < 0 && b_size >= 0
        ap, bp = bp, ap
        a_size, b_size = b_size, a_size
      end
      a_count = a_size.abs
      b_count = b_size.abs
      negative = (a_size < 0) != (b_size < 0)
      ap = magnitude_less_one(ap, a_count) if a_size < 0
      bp = magnitude_less_one(bp, b_count) if b_size < 0
      if a_count < b_count
        ap, bp = bp, ap
        a_count, b_count = b_count, a_count
      end
      # x ^ y = x ^ y; x ^ -y = -((x ^ (y - 1)) + 1); -x ^ -y = (x - 1) ^ (y - 1).
      build(a_count + 1, negative) do |rp|
        Limbs.xor_n(rp, ap, bp, b_count)
        Limbs.copy(rp + b_count, ap + b_count, a_count - b_count)
        negative ? increment_into(rp, a_count) : a_count
      end
    end

    # Bit *index* of the two's complement of the value.
    def bit(index : Int) : Int32
      return 0 if index < 0
      count = size
      limb_index = index // LIMB_BITS
      return negative? ? 1 : 0 if limb_index >= count
      bit = ((limb_at(limb_index) >> (index % LIMB_BITS)) & 1).to_i32
      return bit unless negative?
      lowest_one = Limbs.trailing_zeros(limb_pointer, count)
      if index < lowest_one
        0
      elsif index == lowest_one
        1
      else
        1 - bit
      end
    end

    # The count of one bits; for a negative value the two's complement has
    # infinitely many, and the result is `UInt64::MAX`, as GMP gives.
    def popcount : UInt64
      return UInt64::MAX if negative?
      return magnitude128.popcount.to_u64 if inline?
      Limbs.popcount(@limbs, size)
    end

    # The index of the lowest one bit (the same for the value and its two's
    # complement); `UInt64::MAX` for zero, as GMP gives.
    def trailing_zeros_count : UInt64
      return UInt64::MAX if zero?
      return magnitude128.trailing_zeros_count.to_u64 if inline?
      Limbs.trailing_zeros(@limbs, size)
    end

    # The count of bits in the magnitude; 1 for zero, as GMP's
    # `mpz_sizeinbase(x, 2)` gives.
    def bit_length : Int32
      count = size
      return 1 if count == 0
      count * LIMB_BITS - limb_at(count - 1).leading_zeros_count.to_i32
    end

    # ---- Shifts ----

    # The value times 2 ** *count*. A negative *count* shifts right, as
    # `Int#<<` does; a negative *count* at or past the bit length (down to
    # `Int64::MIN`) shifts every bit out and gives 0, or -1 for a negative
    # value (`>>` rounds toward minus infinity).
    def <<(count : Int) : Integer
      if count < 0
        return all_bits_shifted_out if count <= -(size.to_i64 * LIMB_BITS)
        return self >> -count.to_i64
      end
      return self if count == 0 || zero?
      if inline? && count < 128
        magnitude = magnitude128
        if magnitude.leading_zeros_count >= count
          return Integer.from_magnitude(magnitude << count, negative?)
        end
      end
      shift = count.to_i32
      limb_shift = shift // LIMB_BITS
      bit_shift = shift % LIMB_BITS
      count_in = size
      capacity = count_in + limb_shift + 1
      ap = limb_pointer
      Integer.build(capacity, negative?) do |rp|
        Limbs.zero(rp, limb_shift)
        if bit_shift == 0
          Limbs.copy(rp + limb_shift, ap, count_in)
          rp[capacity - 1] = Limb.zero
        else
          rp[capacity - 1] = Limbs.lshift(rp + limb_shift, ap, count_in, bit_shift)
        end
        capacity
      end
    end

    # The value divided by 2 ** *count*, rounded toward minus infinity (GMP's
    # `fdiv_q_2exp`). A negative *count* shifts left, as `Int#>>` does; a left
    # shift too large for memory raises `OverflowError`.
    def >>(count : Int) : Integer
      return self << -count.to_i64 if count < 0
      return self if count == 0 || zero?
      count_in = size
      return all_bits_shifted_out if count >= count_in.to_i64 * LIMB_BITS
      if inline?
        magnitude = magnitude128
        quotient = magnitude >> count
        quotient &+= 1 if negative? && (quotient << count) != magnitude
        return Integer.from_magnitude(quotient, negative?)
      end
      shift = count.to_i32
      limb_shift = shift // LIMB_BITS
      bit_shift = shift % LIMB_BITS
      count_out = count_in - limb_shift
      ap = limb_pointer
      Integer.build(count_out + 1, negative?) do |rp|
        lost = !Limbs.zero?(ap, limb_shift)
        if bit_shift == 0
          Limbs.copy(rp, ap + limb_shift, count_out)
        else
          lost |= Limbs.rshift(rp, ap + limb_shift, count_out, bit_shift) != 0
        end
        if negative? && lost
          Integer.increment_into(rp, count_out)
        else
          count_out
        end
      end
    end

    # :nodoc:
    def unsafe_shr(count : Int) : Integer
      self >> count
    end

    # A right shift by at least the bit length: 0, or -1 for a negative value.
    private def all_bits_shifted_out : Integer
      negative? ? Integer.new(-1) : Integer.zero
    end

    # ---- Conversions ----

    # The value as an `Int64`, or `nil` when it does not fit.
    def to_i64? : Int64?
      return 0_i64 if zero?
      return nil if size > 1
      if negative?
        @low <= (1_u64 << 63) ? (0_u64 &- @low).to_i64! : nil
      else
        @low <= Int64::MAX.to_u64 ? @low.to_i64 : nil
      end
    end

    # The value as a `UInt64`, or `nil` when it does not fit.
    def to_u64? : UInt64?
      return 0_u64 if zero?
      return nil if negative? || size > 1
      @low
    end

    # The value as an `Int128`, or `nil` when it does not fit.
    def to_i128? : Int128?
      return nil unless inline?
      magnitude = magnitude128
      if negative?
        magnitude <= (1_u128 << 127) ? (0_u128 &- magnitude).to_i128! : nil
      else
        magnitude <= Int128::MAX.to_u128 ? magnitude.to_i128 : nil
      end
    end

    # The value as a `UInt128`, or `nil` when it does not fit.
    def to_u128? : UInt128?
      return nil if negative? || !inline?
      magnitude128
    end

    # The low 64 bits of the two's complement of the value.
    def to_u64! : UInt64
      return 0_u64 if zero?
      low = limb_at(0)
      negative? ? 0_u64 &- low : low
    end

    # The low 64 bits of the two's complement of the value, as signed.
    def to_i64! : Int64
      to_u64!.to_i64!
    end

    # The low 128 bits of the two's complement of the value.
    def to_u128! : UInt128
      count = size
      return 0_u128 if count == 0
      magnitude = limb_at(0).to_u128!
      magnitude |= limb_at(1).to_u128! << 64 if count > 1
      negative? ? 0_u128 &- magnitude : magnitude
    end

    # The low 128 bits of the two's complement of the value, as signed.
    def to_i128! : Int128
      to_u128!.to_i128!
    end

    # The sign and the limbs in hexadecimal, most significant first; for
    # spec failures and reproducers.
    def inspect(io : IO) : Nil
      io << "Integer("
      io << '-' if negative?
      io << "0x"
      count = size
      if count == 0
        io << '0'
      else
        (count - 1).downto(0) do |index|
          limb_at(index).to_s(io, 16, precision: index == count - 1 ? 1 : LIMB_BITS // 4)
        end
      end
      io << ')'
    end

    # ---- Multiplication ----

    # The product, as `mpz_mul`. Operands of up to two limbs multiply in
    # registers; when both operands hold the same magnitude the product is
    # a square.
    def *(other : Integer) : Integer
      a_count = size
      b_count = other.size
      negative = negative? != other.negative?
      if a_count <= 2 && b_count <= 2
        return Integer.multiply_inline(@low, @high, other.@low, other.@high, negative)
      end
      return Integer.zero if a_count == 0 || b_count == 0
      # One operand has more than two limbs; a one-limb operand is a factor.
      return multiply_by_limb(other.@low, negative) if b_count == 1
      return other.multiply_by_limb(@low, negative) if a_count == 1
      return Integer.square_magnitude(@limbs, a_count, negative) if same_magnitude?(other)
      if a_count >= b_count
        Integer.multiply_magnitudes(limb_pointer, a_count, other.limb_pointer, b_count, negative)
      else
        Integer.multiply_magnitudes(other.limb_pointer, b_count, limb_pointer, a_count, negative)
      end
    end

    # The product with a primitive integer, as `mpz_mul_si` and `mpz_mul_ui`:
    # a factor that fits in a limb multiplies the limbs in one pass.
    def *(other : ::Int::Primitive) : Integer
      if other.is_a?(Int128) || other.is_a?(UInt128)
        self * Integer.new(other)
      elsif other.is_a?(::Int::Signed) && other < 0
        multiply_by_limb(0_u64 &- other.to_i64.to_u64!, !negative?)
      else
        multiply_by_limb(other.to_u64!, negative?)
      end
    end

    # The square of the value.
    def square : Integer
      count = size
      if count <= 2
        return Integer.multiply_inline(@low, @high, @low, @high, false)
      end
      Integer.square_magnitude(@limbs, count, false)
    end

    # The magnitude times the limb *factor*, with the sign *negative*.
    protected def multiply_by_limb(factor : Limb, negative : Bool) : Integer
      count = size
      if count <= 2
        return Integer.multiply_inline(@low, @high, factor, Limb.zero, negative)
      end
      return Integer.zero if factor == 0
      limbs = @limbs
      if count == 3
        return Integer.multiply_three_by_one(limbs, factor, negative)
      end
      Integer.build(count + 1, negative) do |rp|
        rp[count] = Limbs.mul_1(rp, limbs, count, factor)
        count + 1
      end
    end

    # Whether *other*, a value of more than two limbs, has the same magnitude
    # as this value: the same limbs, or equal limbs of equal count (unequal
    # values usually differ in the top limb, which ends the comparison at
    # once).
    private def same_magnitude?(other : Integer) : Bool
      count = size
      return false unless count == other.size
      other_limbs = other.@limbs
      @limbs == other_limbs || Limbs.cmp(@limbs, other_limbs, count) == 0
    end

    # The product of the two-limb magnitudes `a_high:a_low` and
    # `b_high:b_low` with the sign *negative*: four 64 by 64 products in
    # registers, inline when the product fits in two limbs, else in one heap
    # buffer of exactly the product's limb count.
    protected def self.multiply_inline(a_low : Limb, a_high : Limb, b_low : Limb, b_high : Limb, negative : Bool) : Integer
      low_low = a_low.to_u128! &* b_low
      if a_high == 0 && b_high == 0
        return from_magnitude(low_low, negative)
      end
      low_high = a_low.to_u128! &* b_high
      high_low = a_high.to_u128! &* b_low
      high_high = a_high.to_u128! &* b_high
      # Limb 1 collects three 64-bit halves, so its sum may carry twice.
      middle = (low_low >> 64) &+ low_high.to_u64! &+ high_low.to_u64!
      upper = high_high &+ (low_high >> 64) &+ (high_low >> 64) &+ (middle >> 64)
      if upper == 0
        return from_magnitude((middle << 64) | low_low.to_u64!, negative)
      end
      from_three_or_four_limbs(low_low.to_u64!, middle.to_u64!, upper.to_u64!, (upper >> 64).to_u64!, negative)
    end

    # The product of the three limbs at *ap* and the limb *factor* (not zero)
    # with the sign *negative*, in registers.
    protected def self.multiply_three_by_one(ap : Pointer(Limb), factor : Limb, negative : Bool) : Integer
      product0 = ap[0].to_u128! &* factor
      product1 = ap[1].to_u128! &* factor &+ (product0 >> 64)
      product2 = ap[2].to_u128! &* factor &+ (product1 >> 64)
      from_three_or_four_limbs(product0.to_u64!, product1.to_u64!, product2.to_u64!, (product2 >> 64).to_u64!, negative)
    end

    # The value whose magnitude is `limb3:limb2:limb1:limb0`, at least
    # 2**128, in one heap buffer of exactly its limb count.
    protected def self.from_three_or_four_limbs(limb0 : Limb, limb1 : Limb, limb2 : Limb, limb3 : Limb, negative : Bool) : Integer
      count = limb3 == 0 ? 3 : 4
      heap = Limbs.allocate(count)
      heap[0] = limb0
      heap[1] = limb1
      heap[2] = limb2
      heap[3] = limb3 if count == 4
      new(negative ? -count : count, Limb.zero, Limb.zero, heap)
    end

    # The product of the *a_count* limbs at *ap* and the *b_count* limbs at
    # *bp* (`a_count >= 3`, `a_count >= b_count >= 2`) with the sign
    # *negative*.
    protected def self.multiply_magnitudes(ap : Pointer(Limb), a_count : Int32, bp : Pointer(Limb), b_count : Int32, negative : Bool) : Integer
      total = a_count + b_count
      build(total, negative) do |rp|
        Multiply.mul(rp, ap, a_count, bp, b_count)
        total
      end
    end

    # The square of the *count* limbs at *ap* (`count > 2`) with the sign
    # *negative*.
    protected def self.square_magnitude(ap : Pointer(Limb), count : Int32, negative : Bool) : Integer
      build(2 * count, negative) do |rp|
        Multiply.sqr(rp, ap, count)
        2 * count
      end
    end

    # ---- Number theory (in `NumberTheory`) ----

    def **(exponent : Int) : Integer
      NumberTheory.pow(self, exponent)
    end

    def gcd(other : Integer) : Integer
      NumberTheory.gcd(self, other)
    end

    def gcd(other : ::Int::Primitive) : Integer
      NumberTheory.gcd(self, Integer.new(other))
    end

    def lcm(other : Integer) : Integer
      NumberTheory.lcm(self, other)
    end

    def lcm(other : ::Int::Primitive) : Integer
      NumberTheory.lcm(self, Integer.new(other))
    end

    def isqrt : Integer
      NumberTheory.isqrt(self)
    end

    def self.factorial(n : Int) : Integer
      NumberTheory.factorial(n)
    end

    def remove(factor : Integer) : {Integer, UInt64}
      NumberTheory.remove(self, factor)
    end

    def invert(modulus : Integer) : Integer?
      NumberTheory.invert(self, modulus)
    end
  end
end
