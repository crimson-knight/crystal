module Crystal::BigNum
  struct Integer
    # The value of *value* truncated toward zero, decoded exactly from its
    # IEEE 754 sign, exponent and mantissa (BIGNUM.md 4.7), as `mpz_set_d`.
    # Raises `ArgumentError` for NaN and the infinities, as `BigInt.new`
    # does. Values below 2**128 in magnitude need no allocation.
    def self.new(value : Float64) : Integer
      raise ArgumentError.new "Can only construct from a finite number" unless value.finite?
      bits = value.unsafe_as(UInt64)
      negative = bits >> 63 != 0
      exponent = ((bits >> 52) & 0x7FF).to_i32
      # |value| < 1, zero and subnormals included.
      return zero if exponent < 1023
      mantissa = (bits & 0x000F_FFFF_FFFF_FFFF_u64) | 0x0010_0000_0000_0000_u64
      # value = mantissa * 2**shift
      shift = exponent &- 1075
      if shift <= 0
        from_magnitude((mantissa >> (0 &- shift)).to_u128!, negative)
      elsif shift <= 75
        from_magnitude(mantissa.to_u128! << shift, negative)
      else
        limb_shift = shift // LIMB_BITS
        bit_shift = shift % LIMB_BITS
        # The 53-bit mantissa reaches the limb above when shifted past 11.
        count = bit_shift > 11 ? limb_shift &+ 2 : limb_shift &+ 1
        build(count, negative) do |rp|
          Limbs.zero(rp, limb_shift)
          rp[limb_shift] = mantissa << bit_shift
          rp[limb_shift &+ 1] = mantissa >> (LIMB_BITS &- bit_shift) if bit_shift > 11
          count
        end
      end
    end

    # :ditto:
    def self.new(value : Float32) : Integer
      new(value.to_f64)
    end

    # The value as a `Float64`, truncated toward zero, as `mpz_get_d`: the
    # top 53 bits of the magnitude are kept and the rest dropped. A value of
    # 2**1024 or more in magnitude gives an infinity of its sign.
    def to_f64 : Float64
      count = size
      return 0.0 if count == 0
      top = limb_at(count &- 1)
      zeros = top.leading_zeros_count.to_i32
      bits = count.to_i64 &* LIMB_BITS &- zeros
      sign = negative? ? 1_u64 << 63 : 0_u64
      return (sign | 0x7FF0_0000_0000_0000_u64).unsafe_as(Float64) if bits > 1024
      window = top << zeros
      if zeros > 0 && count > 1
        window |= limb_at(count &- 2) >> (LIMB_BITS &- zeros)
      end
      fraction = (window >> 11) & 0x000F_FFFF_FFFF_FFFF_u64
      (sign | ((bits &+ 1022).to_u64! << 52) | fraction).unsafe_as(Float64)
    end

    # Compares the value with *other* exactly, as `mpz_cmp_d`; nil when
    # *other* is NaN. The infinities lie beyond every value.
    def <=>(other : Float64) : Int32?
      return nil if other.nan?
      bits = other.unsafe_as(UInt64)
      exponent = ((bits >> 52) & 0x7FF).to_i32
      fraction = bits & 0x000F_FFFF_FFFF_FFFF_u64
      other_sign = exponent == 0 && fraction == 0 ? 0 : (bits >> 63 != 0 ? -1 : 1)
      own_sign = sign
      return own_sign <=> other_sign if own_sign != other_sign || own_sign == 0
      order = compare_magnitude(exponent, fraction)
      negative? ? 0 &- order : order
    end

    # Compares the nonzero magnitude with that of a nonzero, non-NaN double
    # whose exponent field is *exponent* and whose fraction field is
    # *fraction*.
    private def compare_magnitude(exponent : Int32, fraction : UInt64) : Int32
      return -1 if exponent == 0x7FF # an infinity
      return 1 if exponent < 1023    # below 1
      float_bits = exponent &- 1022  # the bit length of the double's integer part
      count = size
      top = limb_at(count &- 1)
      zeros = top.leading_zeros_count.to_i32
      own_bits = count &* LIMB_BITS &- zeros
      return own_bits > float_bits ? 1 : -1 if own_bits != float_bits
      # Equal bit lengths: compare the top 64 bits of each, aligned.
      window = top << zeros
      below = count > 1 ? limb_at(count &- 2) : Limb.zero
      window |= below >> (LIMB_BITS &- zeros) if zeros > 0
      float_window = (fraction | 0x0010_0000_0000_0000_u64) << 11
      return window > float_window ? 1 : -1 if window != float_window
      # Up to 64 bits the windows held both values whole. Beyond, the
      # double is an integer with zeros below its window, so any one bit
      # left in the magnitude makes it the larger.
      return 0 if count == 1
      below &= (Limb.new(1) << (LIMB_BITS &- zeros)) &- 1 if zeros > 0
      return 1 if below != 0
      Limbs.zero?(limb_pointer, count &- 2) ? 0 : 1
    end

    # :ditto:
    def <=>(other : Float32) : Int32?
      self <=> other.to_f64
    end
  end
end
