module Crystal::BigNum
  struct Integer
    # ---- Division (G2c) ----
    #
    # Every variant divides the magnitudes once (`Divide.div_qr`, or
    # `Divide.divrem_1` / `Divide.mod_1` for a one-limb divisor, or the
    # two-limb helpers when the dividend fits in two limbs) and then fixes
    # the quotient and remainder for the signs:
    # * truncated (`tdiv`, `remainder`, `tdivmod`, `unsafe_truncated_*`):
    #   the quotient rounds toward zero and the remainder takes the sign of
    #   the dividend, as GMP's `tdiv_*`;
    # * floored (`//`, `%`, `divmod`, `unsafe_floored_*`): the quotient rounds
    #   toward minus infinity and the remainder takes the sign of the
    #   divisor, as GMP's `fdiv_*`.
    #
    # A zero divisor raises `DivisionByZeroError` in every variant, the
    # `unsafe_*` ones included. Dividends of at most two limbs are divided
    # with no allocation at all; larger ones allocate only the results.

    # Scratch for a quotient or remainder of up to this many limbs comes from
    # the stack; a result is then copied to the heap only if it is kept and
    # does not fit inline.
    private SCRATCH_LIMBS = 8

    def //(other : Integer) : Integer
      Integer.divide(self, other, floor: true, want_quotient: true, want_remainder: false)[0]
    end

    def //(other : ::Int::Primitive) : Integer
      self // Integer.new(other)
    end

    def %(other : Integer) : Integer
      Integer.divide(self, other, floor: true, want_quotient: false, want_remainder: true)[1]
    end

    def %(other : ::Int::Primitive) : Integer
      self % Integer.new(other)
    end

    def tdiv(other : Integer) : Integer
      Integer.divide(self, other, floor: false, want_quotient: true, want_remainder: false)[0]
    end

    def tdiv(other : ::Int::Primitive) : Integer
      tdiv(Integer.new(other))
    end

    def remainder(other : Integer) : Integer
      Integer.divide(self, other, floor: false, want_quotient: false, want_remainder: true)[1]
    end

    def remainder(other : ::Int::Primitive) : Integer
      remainder(Integer.new(other))
    end

    # The floored quotient and remainder.
    def divmod(other : Integer) : {Integer, Integer}
      Integer.divide(self, other, floor: true, want_quotient: true, want_remainder: true)
    end

    def divmod(other : ::Int::Primitive) : {Integer, Integer}
      divmod(Integer.new(other))
    end

    # The truncated quotient and remainder.
    def tdivmod(other : Integer) : {Integer, Integer}
      Integer.divide(self, other, floor: false, want_quotient: true, want_remainder: true)
    end

    def tdivmod(other : ::Int::Primitive) : {Integer, Integer}
      tdivmod(Integer.new(other))
    end

    # As `//` (GMP's `fdiv_q`); the name is `BigInt`'s.
    def unsafe_floored_div(other : Integer | ::Int::Primitive) : Integer
      self // other
    end

    # As `%` (GMP's `fdiv_r`).
    def unsafe_floored_mod(other : Integer | ::Int::Primitive) : Integer
      self % other
    end

    # As `divmod` (GMP's `fdiv_qr`).
    def unsafe_floored_divmod(other : Integer | ::Int::Primitive) : {Integer, Integer}
      divmod(other)
    end

    # As `tdiv` (GMP's `tdiv_q`).
    def unsafe_truncated_div(other : Integer | ::Int::Primitive) : Integer
      tdiv(other)
    end

    # As `remainder` (GMP's `tdiv_r`).
    def unsafe_truncated_mod(other : Integer | ::Int::Primitive) : Integer
      remainder(other)
    end

    # As `tdivmod` (GMP's `tdiv_qr`).
    def unsafe_truncated_divmod(other : Integer | ::Int::Primitive) : {Integer, Integer}
      tdivmod(other)
    end

    # Whether the value is a multiple of *other*. As GMP's `divisible_p`,
    # only zero is a multiple of zero (no error is raised).
    def divisible_by?(other : Integer) : Bool
      return zero? if other.zero?
      return true if zero?
      divisor_count = other.size
      return false if size < divisor_count
      # A multiple has at least as many low zero bits as the divisor.
      divisor_zeros = other.trailing_zeros_count
      return false if trailing_zeros_count < divisor_zeros
      return true if divisor_zeros == other.bit_length - 1
      if divisor_count == 1
        divisor = other.limb_at(0)
        return Divide.div_128_by_64(magnitude128, divisor)[1] == 0 if inline?
        return Divide.mod_1(@limbs, size, divisor) == 0
      end
      Integer.divide(self, other, floor: false, want_quotient: false, want_remainder: true)[1].zero?
    end

    def divisible_by?(other : ::Int::Primitive) : Bool
      divisible_by?(Integer.new(other))
    end

    # The quotient of the value by *other*, which must divide it exactly
    # (for lcm and rational canonicalization). The result is unspecified
    # when the division is not exact.
    def divexact(other : Integer) : Integer
      raise DivisionByZeroError.new if other.zero?
      a_count = size
      b_count = other.size
      negative = negative? != other.negative?
      return Integer.zero if a_count < b_count
      if a_count <= 2
        quotient = if b_count == 1
                     Divide.div_128_by_64(magnitude128, other.limb_at(0))[0]
                   else
                     Divide.div_128_by_128(magnitude128, other.magnitude128)[0].to_u128!
                   end
        return Integer.from_magnitude(quotient, negative)
      end
      ap = limb_pointer
      bp = other.limb_pointer
      Integer.build(a_count - b_count + 1, negative) do |qp|
        Divide.divexact(qp, ap, a_count, bp, b_count)
        a_count - b_count + 1
      end
    end

    # The quotient and remainder of *a* by *b*, rounded down (*floor*) or
    # toward zero; a part not wanted comes back as zero and costs no
    # allocation.
    protected def self.divide(a : Integer, b : Integer, *, floor : Bool, want_quotient : Bool, want_remainder : Bool) : {Integer, Integer}
      raise DivisionByZeroError.new if b.zero?
      a_count = a.size
      b_count = b.size
      signs_differ = a.negative? != b.negative?
      remainder_negative = floor ? b.negative? : a.negative?

      if a_count < b_count
        # |a| < |b|: the truncated quotient is zero and the remainder is a.
        if floor && signs_differ && !a.zero?
          return {Integer.new(-1), want_remainder ? a + b : zero}
        end
        return {zero, a}
      end

      if a_count <= 2
        a_magnitude = a.magnitude128
        b_magnitude = b.magnitude128
        if b_count == 1
          quotient, low_remainder = Divide.div_128_by_64(a_magnitude, b.limb_at(0))
          remainder = low_remainder.to_u128!
        else
          high_quotient, remainder = Divide.div_128_by_128(a_magnitude, b_magnitude)
          quotient = high_quotient.to_u128!
        end
        if floor && signs_differ && remainder != 0
          quotient &+= 1
          remainder = b_magnitude &- remainder
        end
        return {from_magnitude(quotient, signs_differ), from_magnitude(remainder, remainder_negative)}
      end

      round_away = floor && signs_differ
      ap = a.limb_pointer
      if b_count == 1
        divisor = b.limb_at(0)
        unless want_quotient
          remainder = Divide.mod_1(ap, a_count, divisor)
          remainder = divisor &- remainder if round_away && remainder != 0
          return {zero, from_magnitude(remainder.to_u128!, remainder_negative)}
        end
        # The quotient has a_count - 1 or a_count limbs: from three limbs on
        # it may still fit inline.
        return with_scratch(a_count + 1, a_count > 3) do |qp, quotient_on_heap|
          remainder = Divide.divrem_1(qp, ap, a_count, divisor)
          used = a_count
          if round_away && remainder != 0
            used = increment_into(qp, a_count)
            remainder = divisor &- remainder
          end
          {from_buffer(qp, used, signs_differ, quotient_on_heap), from_magnitude(remainder.to_u128!, remainder_negative)}
        end
      end

      bp = b.limb_pointer
      quotient_count = a_count - b_count + 1
      # A kept result that cannot fit inline goes straight to the heap; the
      # quotient has at least quotient_count - 1 limbs.
      with_scratch(quotient_count + 1, want_quotient && quotient_count > 3) do |qp, quotient_on_heap|
        with_scratch(b_count, want_remainder && b_count > 2) do |rp, remainder_on_heap|
          Divide.div_qr(qp, rp, ap, a_count, bp, b_count)
          used = quotient_count
          if round_away && !Limbs.zero?(rp, b_count)
            # Round the quotient away from zero; the remainder becomes
            # |b| - |r|.
            used = increment_into(qp, quotient_count) if want_quotient
            Limbs.sub_n(rp, bp, rp, b_count) if want_remainder
          end
          quotient = want_quotient ? from_buffer(qp, used, signs_differ, quotient_on_heap) : zero
          remainder = want_remainder ? from_buffer(rp, b_count, remainder_negative, remainder_on_heap) : zero
          {quotient, remainder}
        end
      end
    end

    # Yields *capacity* limbs of scratch and whether they are a fresh heap
    # buffer the result may keep (`from_buffer`'s *owned_heap*). Unless
    # *keep* asks for the heap, up to `SCRATCH_LIMBS` come from the stack
    # instead, valid only in the block.
    private def self.with_scratch(capacity : Int32, keep : Bool, &)
      if !keep && capacity <= SCRATCH_LIMBS
        buffer = uninitialized StaticArray(Limb, SCRATCH_LIMBS)
        yield buffer.to_unsafe, false
      else
        yield Limbs.allocate(capacity), true
      end
    end
  end
end
