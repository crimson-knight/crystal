module Crystal::BigNum
  struct Integer
    # ---- Division (G2c) ----
    #
    # Every variant divides the magnitudes once (`Divide.div_qr`, or
    # `Divide.divrem_1` / `Divide.mod_1` for a one-limb divisor) and then
    # fixes the quotient and remainder for the signs:
    # * truncated (`tdiv`, `remainder`, `tdivmod`, `unsafe_truncated_*`):
    #   the quotient rounds toward zero and the remainder takes the sign of
    #   the dividend, as GMP's `tdiv_*`;
    # * floored (`//`, `%`, `divmod`, `unsafe_floored_*`): the quotient rounds
    #   toward minus infinity and the remainder takes the sign of the
    #   divisor, as GMP's `fdiv_*`.
    #
    # A zero divisor raises `DivisionByZeroError` in every variant, the
    # `unsafe_*` ones included.

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

    {% for pair in [{"unsafe_floored_div", "//"}, {"unsafe_floored_mod", "%"}, {"unsafe_floored_divmod", "divmod"},
                    {"unsafe_truncated_div", "tdiv"}, {"unsafe_truncated_mod", "remainder"}, {"unsafe_truncated_divmod", "tdivmod"}] %}
      # As `{{ pair[1].id }}`; the name is `BigInt`'s. A zero divisor raises
      # `DivisionByZeroError` here too.
      def {{ pair[0].id }}(other : Integer | ::Int::Primitive)
        {% if pair[1] == "//" || pair[1] == "%" %}
          self {{ pair[1].id }} other
        {% else %}
          {{ pair[1].id }}(other)
        {% end %}
      end
    {% end %}

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
      if divisor_count == 1
        divisor = other.limb_at(0)
        return true if divisor & (divisor &- 1) == 0
        return magnitude128 % divisor == 0 if inline?
        return Divide.mod_1(@limbs, size, divisor) == 0
      end
      return true if divisor_zeros == other.bit_length - 1
      Integer.divide(self, other, floor: false, want_quotient: false, want_remainder: true)[1].zero?
    end

    def divisible_by?(other : ::Int::Primitive) : Bool
      divisible_by?(Integer.new(other))
    end

    # The quotient of the value by *other*, which must divide it exactly
    # (Jebelean's exact division; for lcm and rational canonicalization).
    # The result is unspecified when the division is not exact.
    def divexact(other : Integer) : Integer
      raise DivisionByZeroError.new if other.zero?
      a_count = size
      b_count = other.size
      negative = negative? != other.negative?
      return Integer.zero if a_count < b_count
      if a_count <= 2
        return Integer.from_magnitude(magnitude128 // other.magnitude128, negative)
      end
      ap = limb_pointer
      bp = other.limb_pointer
      Integer.build(a_count - b_count + 1, negative) do |qp|
        Divide.divexact(qp, ap, a_count, bp, b_count)
        a_count - b_count + 1
      end
    end

    # The quotient and remainder of *a* by *b*, rounded down (*floor*) or
    # toward zero; the parts not wanted come back as zero.
    protected def self.divide(a : Integer, b : Integer, *, floor : Bool, want_quotient : Bool, want_remainder : Bool) : {Integer, Integer}
      raise DivisionByZeroError.new if b.zero?
      a_count = a.size
      b_count = b.size
      signs_differ = a.negative? != b.negative?
      remainder_negative = floor ? b.negative? : a.negative?

      if a_count < b_count
        # |a| < |b|: the truncated quotient is zero.
        if floor && signs_differ && !a.zero?
          return {Integer.new(-1), want_remainder ? a + b : zero}
        end
        return {zero, a}
      end

      if a_count <= 2
        a_magnitude = a.magnitude128
        b_magnitude = b.magnitude128
        if a_count == 1
          a_limb = a_magnitude.to_u64!
          b_limb = b_magnitude.to_u64!
          quotient = (a_limb // b_limb).to_u128!
          remainder = (a_limb &- quotient.to_u64! &* b_limb).to_u128!
        else
          quotient = a_magnitude // b_magnitude
          remainder = a_magnitude &- quotient &* b_magnitude
        end
        if floor && signs_differ && remainder != 0
          quotient &+= 1
          remainder = b_magnitude &- remainder
        end
        return {from_magnitude(quotient, signs_differ), from_magnitude(remainder, remainder_negative)}
      end

      ap = a.limb_pointer
      if b_count == 1
        divide_by_limb(ap, a_count, b.limb_at(0), signs_differ, remainder_negative, floor, want_quotient)
      else
        divide_by_limbs(ap, a_count, b.limb_pointer, b_count, signs_differ, remainder_negative, floor, want_quotient)
      end
    end

    # The quotient and remainder of the *a_count* limbs at *ap* (more than
    # two) by the limb *divisor*.
    private def self.divide_by_limb(ap : Pointer(Limb), a_count : Int32, divisor : Limb, signs_differ : Bool, remainder_negative : Bool, floor : Bool, want_quotient : Bool) : {Integer, Integer}
      round_away = floor && signs_differ
      unless want_quotient
        remainder = Divide.mod_1(ap, a_count, divisor)
        remainder = divisor &- remainder if round_away && remainder != 0
        return {zero, from_magnitude(remainder.to_u128!, remainder_negative)}
      end
      qp = Limbs.allocate(a_count + 1)
      remainder = Divide.divrem_1(qp, ap, a_count, divisor)
      used = a_count
      if round_away && remainder != 0
        qp[a_count] = Limbs.add_1(qp, qp, a_count, Limb.new(1))
        used += 1
        remainder = divisor &- remainder
      end
      {from_buffer(qp, used, signs_differ, true), from_magnitude(remainder.to_u128!, remainder_negative)}
    end

    # The quotient and remainder of the *a_count* limbs at *ap* by the
    # *b_count* limbs at *bp* (`a_count >= b_count >= 2`, `a_count >= 3`).
    private def self.divide_by_limbs(ap : Pointer(Limb), a_count : Int32, bp : Pointer(Limb), b_count : Int32, signs_differ : Bool, remainder_negative : Bool, floor : Bool, want_quotient : Bool) : {Integer, Integer}
      quotient_count = a_count - b_count + 1
      qp = Limbs.allocate(quotient_count + 1)
      rp = Limbs.allocate(b_count)
      Divide.div_qr(qp, rp, ap, a_count, bp, b_count)
      used = quotient_count
      if floor && signs_differ && !Limbs.zero?(rp, b_count)
        # Round the quotient away from zero; the remainder becomes
        # |b| - |r|.
        qp[quotient_count] = Limbs.add_1(qp, qp, quotient_count, Limb.new(1))
        used += 1
        Limbs.sub_n(rp, bp, rp, b_count)
      end
      quotient = want_quotient ? from_buffer(qp, used, signs_differ, true) : zero
      {quotient, from_buffer(rp, b_count, remainder_negative, true)}
    end
  end
end
