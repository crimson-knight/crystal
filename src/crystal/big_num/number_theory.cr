module Crystal::BigNum
  # :nodoc:
  #
  # Number theory on `Integer` values: powers, factorials, greatest common
  # divisors and least common multiples, modular inverses, integer square
  # roots and factor removal. `Integer`'s methods of the same names delegate
  # here. Every result is GMP's for the same operands (`mpz_pow_ui`,
  # `mpz_fac_ui`, `mpz_gcd`, `mpz_lcm`, `mpz_invert`, `mpz_sqrt`,
  # `mpz_remove`).
  #
  # | Operation | Algorithm |
  # |---|---|
  # | `pow` | left-to-right binary exponentiation (square and multiply), Knuth TAOCP Vol. 2, 4.6.3; factors of two of the base become one shift |
  # | `factorial` | the product of the odd parts of 1 to n, as many factors per limb as fit, shifted by Legendre's count of twos; n up to 57 (results up to 256 bits) from a table built once by the same product |
  # | `gcd`, `lcm` | binary gcd (Stein; Knuth 4.5.2 Algorithm B) on one and two limbs; Lehmer's algorithm (Knuth 4.5.2 Algorithm L) with 62-bit leading digits from three limbs, down to two |
  # | `invert` | extended Euclid on one limb; extended Lehmer (Algorithm L carrying one cofactor) above, finishing with extended Euclid whose cofactor steps are gathered in one matrix |
  # | `isqrt` | a floating-point estimate and one Newton step on two limbs; one Karatsuba square root step (Brent and Zimmermann, *Modern Computer Arithmetic*, Algorithm 1.12) on three and four limbs; Newton's method seeded from the root of the top half above |
  # | `remove` | division by the largest power of the factor that fits a limb, then the factor's multiplicity in the first nonzero remainder |
  #
  # Operands and results of up to two limbs stay in registers as `UInt128`
  # values; larger work runs on limb buffers from the stack when small.
  module NumberTheory
    # Lehmer's leading digits have this many bits, so that a digit plus a
    # cofactor fits a signed 64-bit integer.
    private LEHMER_BITS = 62

    # Limb buffers of up to this many limbs come from the stack.
    private STACK_LIMBS = 40

    # ---- Power ----

    # *base* raised to *exponent* (`mpz_pow_ui`); `0 ** 0` is 1.
    def self.pow(base : Integer, exponent : Int) : Integer
      raise ArgumentError.new("Negative exponent isn't supported") if exponent < 0
      exponent_value = exponent.to_u64
      return Integer.new(1) if exponent_value == 0
      return base if exponent_value == 1 || base.zero?
      negative = base.negative? && exponent_value.odd?
      count = base.size
      if count == 1
        base_limb = base.limb_at(0)
        return Integer.new(negative ? -1 : 1) if base_limb == 1
        bits = LIMB_BITS - base_limb.leading_zeros_count.to_i32
        if exponent_value <= 128 && bits.to_u64 * exponent_value <= 128
          return Integer.from_magnitude(pow_128(base_limb, exponent_value), negative)
        end
      end
      zeros = base.trailing_zeros_count
      if zeros > 0
        odd = base.abs >> zeros
        shift = zeros.to_u128 * exponent_value
        raise ArgumentError.new("Result of ** too large") if shift > Int32::MAX
        powered = odd.size == 1 && odd.limb_at(0) == 1 ? Integer.new(1) : pow(odd, exponent_value)
        result = powered.abs << shift.to_i32
        return negative ? -result : result
      end
      pow_magnitude(base, exponent_value, negative)
    end

    # *base_limb* to the *exponent_value*, when the result fits 128 bits.
    private def self.pow_128(base_limb : Limb, exponent_value : UInt64) : UInt128
      result = base_limb.to_u128!
      index = 62 - exponent_value.leading_zeros_count.to_i32
      while index >= 0
        result = result &* result
        result = result &* base_limb if exponent_value.bit(index) == 1
        index -= 1
      end
      result
    end

    # The odd magnitude of *base* (more than one limb, or a result above
    # 128 bits) raised to *exponent_value* >= 2, with the sign *negative*.
    private def self.pow_magnitude(base : Integer, exponent_value : UInt64, negative : Bool) : Integer
      bn = base.size
      bits = base.bit_length.to_u128 * exponent_value
      raise ArgumentError.new("Result of ** too large") if bits > (Int32::MAX.to_u128 - 2) * LIMB_BITS
      capacity = (bits // LIMB_BITS).to_i32 + 2
      bp = base.limb_pointer
      if capacity <= STACK_LIMBS
        first = uninitialized StaticArray(Limb, STACK_LIMBS)
        second = uninitialized StaticArray(Limb, STACK_LIMBS)
        rp, used = pow_into(first.to_unsafe, second.to_unsafe, bp, bn, exponent_value)
        Integer.build(used, negative) do |target|
          Limbs.copy(target, rp, used)
          used
        end
      else
        rp, used = pow_into(Limbs.allocate(capacity), Limbs.allocate(capacity), bp, bn, exponent_value)
        Integer.from_buffer(rp, used, negative, true)
      end
    end

    # Left-to-right square and multiply of the *bn* limbs of *bp* to the
    # *exponent_value*, ping-ponging between *rp* and *tp* (each large enough for the
    # result plus two limbs). Returns the buffer that holds the result and
    # its limb count.
    private def self.pow_into(rp : Pointer(Limb), tp : Pointer(Limb), bp : Pointer(Limb), bn : Int32, exponent_value : UInt64) : {Pointer(Limb), Int32}
      Limbs.copy(rp, bp, bn)
      rn = bn
      index = 62 - exponent_value.leading_zeros_count.to_i32
      while index >= 0
        Multiply.sqr(tp, rp, rn)
        rn = Limbs.normalize(tp, 2 * rn)
        rp, tp = tp, rp
        if exponent_value.bit(index) == 1
          if bn == 1
            rp[rn] = Limbs.mul_1(rp, rp, rn, bp[0])
            rn = Limbs.normalize(rp, rn + 1)
          else
            Multiply.mul(tp, rp, rn, bp, bn)
            rn = Limbs.normalize(tp, rn + bn)
            rp, tp = tp, rp
          end
        end
        index -= 1
      end
      {rp, rn}
    end

    # ---- Factorial ----

    # Factorials up to this n (results up to 256 bits) come from a table.
    private FACTORIAL_TABLE_LIMIT = 57

    # 0! to 57!, built once by the plain product.
    private FACTORIAL_TABLE = begin
      list = Array(Integer).new(FACTORIAL_TABLE_LIMIT + 1)
      value = Integer.new(1)
      list << value
      (1..FACTORIAL_TABLE_LIMIT).each do |factor|
        value = value * factor
        list << value
      end
      list
    end

    # *n*! (`mpz_fac_ui`), with `BigInt#factorial`'s errors.
    def self.factorial(n : Int) : Integer
      raise ArgumentError.new("Factorial not defined for negative values") if n < 0
      raise ArgumentError.new("Factorial not supported for numbers bigger than #{UInt64::MAX}") if n > UInt64::MAX
      factor_count = n.to_u64
      return FACTORIAL_TABLE[factor_count] if factor_count <= FACTORIAL_TABLE_LIMIT
      odd_factorial_shifted(factor_count)
    end

    # *n*! (above the table) as the table's last entry times the odd parts
    # of the factors above it, as many per limb as fit, shifted left by the
    # factors' twos.
    private def self.odd_factorial_shifted(n : UInt64) : Integer
      # Each factor adds at most its bit length to the product.
      total_bits = 0_u128
      length = 1
      while length <= 64
        low = 1_u128 << (length - 1)
        break if low > n
        high = Math.min((1_u128 << length) - 1, n.to_u128)
        total_bits += (high - low + 1) * length
        length += 1
      end
      capacity = total_bits // LIMB_BITS + 2
      raise ArgumentError.new("Factorial too large") if capacity > Int32::MAX // 2
      odd = Limbs.allocate(capacity.to_i32)
      start = FACTORIAL_TABLE[FACTORIAL_TABLE_LIMIT]
      used = start.size
      Limbs.copy(odd, start.limb_pointer, used)
      chunk = Limb.new(1)
      twos = 0_u64
      factor = FACTORIAL_TABLE_LIMIT.to_u64 + 1
      while factor <= n
        zeros = factor.trailing_zeros_count
        twos += zeros
        part = factor >> zeros
        product = chunk.to_u128! &* part
        if (product >> LIMB_BITS) != 0
          odd[used] = Limbs.mul_1(odd, odd, used, chunk)
          used += 1 if odd[used] != 0
          chunk = part
        else
          chunk = product.to_u64!
        end
        factor += 1
      end
      odd[used] = Limbs.mul_1(odd, odd, used, chunk)
      used += 1 if odd[used] != 0
      limb_shift = (twos // LIMB_BITS).to_i32
      bit_shift = (twos % LIMB_BITS).to_i32
      total = used + limb_shift + 1
      Integer.build(total, false) do |rp|
        Limbs.zero(rp, limb_shift)
        if bit_shift == 0
          Limbs.copy(rp + limb_shift, odd, used)
          rp[total - 1] = Limb.zero
        else
          rp[total - 1] = Limbs.lshift(rp + limb_shift, odd, used, bit_shift)
        end
        total
      end
    end

    # ---- Greatest common divisor ----

    # The greatest common divisor of *a* and *b*, never negative
    # (`mpz_gcd`); `gcd(0, 0)` is 0.
    def self.gcd(a : Integer, b : Integer) : Integer
      a_count = a.size
      b_count = b.size
      return b.abs if a_count == 0
      return a.abs if b_count == 0
      if a_count <= 2 && b_count <= 2
        return Integer.from_magnitude(gcd_128(a.magnitude128, b.magnitude128), false)
      end
      ap = a.limb_pointer
      bp = b.limb_pointer
      if a_count < b_count || (a_count == b_count && Limbs.cmp(ap, bp, a_count) < 0)
        ap, bp = bp, ap
        a_count, b_count = b_count, a_count
      end
      capacity = a_count + 1
      if 4 * capacity <= 4 * STACK_LIMBS
        scratch = uninitialized StaticArray(Limb, 160)
        gcd_magnitudes(ap, a_count, bp, b_count, scratch.to_unsafe, capacity)
      else
        gcd_magnitudes(ap, a_count, bp, b_count, Limbs.allocate(4 * capacity), capacity)
      end
    end

    # The gcd of the two limbs *u* and *v* (either may be zero): Stein's
    # binary algorithm. Each step replaces the larger odd value by their
    # difference without its factors of two; the difference, its trailing
    # zero count and the smaller value are computed side by side, so a step
    # costs about four dependent instructions.
    def self.gcd_limb(u : Limb, v : Limb) : Limb
      return u | v if u == 0 || v == 0
      shift = (u | v).trailing_zeros_count
      u = u.unsafe_shr(u.trailing_zeros_count)
      v = v.unsafe_shr(v.trailing_zeros_count)
      while u != v
        difference = u &- v
        zeros = difference.trailing_zeros_count
        smaller = u < v ? u : v
        magnitude = u > v ? difference : v &- u
        u = magnitude.unsafe_shr(zeros)
        v = smaller
      end
      u.unsafe_shl(shift)
    end

    # The gcd of the 128-bit *u* and *v* (either may be zero): the binary
    # algorithm of `gcd_limb` on two limbs while either value has a high
    # limb, then `gcd_limb`.
    def self.gcd_128(u : DoubleLimb, v : DoubleLimb) : DoubleLimb
      return u | v if u == 0 || v == 0
      shift = (u | v).trailing_zeros_count
      u >>= u.trailing_zeros_count
      v >>= v.trailing_zeros_count
      u0 = u.to_u64!
      u1 = (u >> LIMB_BITS).to_u64!
      v0 = v.to_u64!
      v1 = (v >> LIMB_BITS).to_u64!
      while (u1 | v1) != 0
        low = u0.to_u128! &- v0
        d0 = low.to_u64!
        high = u1.to_u128! &- v1 &- ((low >> LIMB_BITS).to_u64! & 1)
        d1 = high.to_u64!
        below = (high >> LIMB_BITS) != 0
        e0 = v0 &- u0
        e1 = v1 &- u1 &- (u0 > v0 ? Limb.new(1) : Limb.zero)
        a0 = below ? e0 : d0
        a1 = below ? e1 : d1
        if below
          v0 = u0
          v1 = u1
        end
        if d0 == 0
          # The difference has 64 or more trailing zero bits (or is zero).
          return ((u1.to_u128! << LIMB_BITS) | u0) << shift if d1 == 0
          u0 = a1.unsafe_shr(a1.trailing_zeros_count)
          u1 = Limb.zero
        else
          zeros = d0.trailing_zeros_count
          u0 = a0.unsafe_shr(zeros) | a1.unsafe_shl(LIMB_BITS &- zeros)
          u1 = a1.unsafe_shr(zeros)
        end
      end
      DoubleLimb.new(gcd_limb(u0, v0)) << shift
    end

    # Lehmer's inner loop (Knuth 4.5.2, Algorithm L, steps L2 and L3) on
    # the leading digits *uh* >= *vh* (below 2**62): runs Euclid's steps on
    # the digits while the quotients bracketed by the cofactors agree.
    # Returns the cofactors `a, b, c, d` (the new pair is `a*u + b*v`,
    # `c*u + d*v`) and the count of steps; with no step the caller divides.
    private def self.lehmer(uh : Int64, vh : Int64) : {Int64, Int64, Int64, Int64, Int32}
      a = 1_i64
      b = 0_i64
      c = 0_i64
      d = 1_i64
      steps = 0
      loop do
        low_denominator = vh &+ c
        high_denominator = vh &+ d
        break if low_denominator == 0 || high_denominator == 0
        numerator = (uh &+ a).to_u64!
        q = numerator.unsafe_div(low_denominator.to_u64!)
        # The quotient of (uh + b) / (vh + d) is q too when
        # q * (vh + d) <= uh + b < (q + 1) * (vh + d).
        other = (uh &+ b).to_u64!.to_u128!
        product = q.to_u128! &* high_denominator.to_u64!
        break if product > other || other - product >= high_denominator.to_u64!
        quotient = q.to_i64!
        a, c = c, a &- quotient &* c
        b, d = d, b &- quotient &* d
        uh, vh = vh, uh &- quotient &* vh
        steps += 1
      end
      {a, b, c, d, steps}
    end

    # The pair `a*u + b*v`, `c*u + d*v` after *steps* Lehmer steps, in
    # wrapping 128-bit arithmetic (both results fit).
    private def self.combine_128(u : DoubleLimb, v : DoubleLimb, a : Int64, b : Int64, c : Int64, d : Int64, steps : Int32) : {DoubleLimb, DoubleLimb}
      new_u = a.to_i128!.to_u128! &* u &+ b.to_i128!.to_u128! &* v
      new_v = c.to_i128!.to_u128! &* u &+ d.to_i128!.to_u128! &* v
      {new_u, new_v}
    end

    # The gcd of the *un* limbs of *up* and the *vn* limbs of *vp*
    # (`up >= vp`, `un >= 3`, `vn >= 1`), with *scratch* holding four
    # buffers of *capacity* (`un + 1`) limbs.
    private def self.gcd_magnitudes(up : Pointer(Limb), un : Int32, vp : Pointer(Limb), vn : Int32, scratch : Pointer(Limb), capacity : Int32) : Integer
      u = scratch
      v = scratch + capacity
      s = scratch + 2 * capacity
      t = scratch + 3 * capacity
      Limbs.copy(u, up, un)
      Limbs.copy(v, vp, vn)
      loop do
        if vn == 0
          return Integer.build(un, false) do |rp|
            Limbs.copy(rp, u, un)
            un
          end
        end
        if un <= 2
          return Integer.from_magnitude(gcd_128(magnitude_of(u, un), magnitude_of(v, vn)), false)
        end
        if vn == 1
          divisor = v[0]
          return Integer.from_magnitude(DoubleLimb.new(gcd_limb(divisor, Divide.mod_1(u, un, divisor))), false)
        end
        shift = un * LIMB_BITS - u[un - 1].leading_zeros_count.to_i32 - LEHMER_BITS
        a, b, c, d, steps = lehmer(window(u, un, shift).to_i64!, window(v, vn, shift).to_i64!)
        if steps == 0
          Divide.div_qr(s, t, u, un, v, vn)
          remainder_count = Limbs.normalize(t, vn)
          u, v, t = v, t, u
          un, vn = vn, remainder_count
        else
          combine(s, u, un, v, vn, a, b, steps, true)
          combine(t, u, un, v, vn, c, d, steps, false)
          u, v, s, t = s, t, u, v
          vn = Limbs.normalize(v, un)
          un = Limbs.normalize(u, un)
        end
      end
    end

    # The 128-bit magnitude of the *n* (at most two) limbs at *p*.
    private def self.magnitude_of(p : Pointer(Limb), n : Int32) : DoubleLimb
      case n
      when 0 then DoubleLimb.zero
      when 1 then DoubleLimb.new(p[0])
      else        (p[1].to_u128! << LIMB_BITS) | p[0]
      end
    end

    # The 64 bits of the *n* limbs at *p* from bit *shift* up (zero above the
    # top).
    private def self.window(p : Pointer(Limb), n : Int32, shift : Int32) : Limb
      index = shift // LIMB_BITS
      return Limb.zero if index >= n
      offset = shift % LIMB_BITS
      low = p[index] >> offset
      if offset != 0 && index + 1 < n
        low |= p[index + 1] << (LIMB_BITS - offset)
      end
      low
    end

    # Writes the *un* limbs of `x*u + y*v` into *rp*, where `x, y` are the
    # first (*first_row*) or second row of a Lehmer matrix after *steps*
    # steps: the two entries have opposite signs (the first row's first
    # entry has the sign of `(-1)**steps`, the second row's the opposite)
    # and the result is known to lie in 0 to `B**un`, so the arithmetic may
    # wrap.
    private def self.combine(rp : Pointer(Limb), up : Pointer(Limb), un : Int32, vp : Pointer(Limb), vn : Int32, x : Int64, y : Int64, steps : Int32, first_row : Bool) : Nil
      x_positive = steps.even? == first_row
      x_magnitude = x.abs.to_u64!
      y_magnitude = y.abs.to_u64!
      if x_positive
        # x*u - |y|*v
        Limbs.mul_1(rp, up, un, x_magnitude)
        borrow = Limbs.submul_1(rp, vp, vn, y_magnitude)
        Limbs.sub_1(rp + vn, rp + vn, un - vn, borrow) if vn < un
      else
        # y*v - |x|*u
        carry = Limbs.mul_1(rp, vp, vn, y_magnitude)
        if vn < un
          rp[vn] = carry
          Limbs.zero(rp + vn + 1, un - vn - 1)
        end
        Limbs.submul_1(rp, up, un, x_magnitude)
      end
    end

    # ---- Least common multiple ----

    # The least common multiple of *a* and *b*, never negative (`mpz_lcm`);
    # 0 when either is 0.
    def self.lcm(a : Integer, b : Integer) : Integer
      return Integer.zero if a.zero? || b.zero?
      if a.size == 1 && b.size == 1
        x = a.limb_at(0)
        y = b.limb_at(0)
        divisor = gcd_limb(x, y)
        return Integer.from_magnitude(x.unsafe_div(divisor).to_u128! &* y, false)
      end
      divisor = gcd(a, b)
      a.abs.divexact(divisor) * b.abs
    end

    # ---- Modular inverse ----

    # The inverse of *a* modulo *m*, in 0 to `|m| - 1`, or nil when there is
    # none (`mpz_invert`): the sign of *m* is ignored, every value is its own
    # inverse's match modulo 1 (the result is 0), and nothing is invertible
    # modulo 0.
    def self.invert(a : Integer, m : Integer) : Integer?
      return nil if m.zero?
      modulus = m.abs
      return Integer.zero if modulus.size == 1 && modulus.limb_at(0) == 1
      count = modulus.size
      return invert_magnitudes(a, modulus) if count > 2
      # The residue fits two limbs, so it is built with no allocation.
      residue = a.negative? || a >= modulus ? a % modulus : a
      return nil if residue.zero?
      if count == 1
        inverse = invert_limb(modulus.limb_at(0), residue.limb_at(0))
        return inverse.try { |value| Integer.from_magnitude(DoubleLimb.new(value), false) }
      end
      inverse = invert_128(modulus.magnitude128, residue.magnitude128)
      inverse.try { |value| Integer.from_magnitude(value, false) }
    end

    # The inverse of *r* (0 < *r* < *m*) modulo the limb *m*: extended
    # Euclid, carrying the cofactor of *r* as a magnitude whose sign
    # alternates.
    private def self.invert_limb(m : Limb, r : Limb) : Limb?
      u = m
      v = r
      x0 = Limb.zero
      x1 = Limb.new(1)
      x0_negative = true
      while v != 0
        q = u.unsafe_div(v)
        u, v = v, u &- q &* v
        x0, x1 = x1, x0 &+ q &* x1
        x0_negative = !x0_negative
      end
      return nil unless u == 1
      x0_negative ? m &- x0 : x0
    end

    # The inverse of *r* (0 < *r* < *m*) modulo the two-limb *m*: Lehmer
    # steps in registers while the remainder has two limbs, then plain
    # Euclid, carrying the cofactor of *r* as a magnitude whose sign
    # alternates.
    private def self.invert_128(m : DoubleLimb, r : DoubleLimb) : DoubleLimb?
      u = m
      v = r
      x0 = DoubleLimb.zero
      x1 = DoubleLimb.new(1)
      x0_negative = true
      while (u >> LIMB_BITS) != 0 && v != 0
        if (v >> LIMB_BITS) == 0
          q, remainder = Divide.div_128_by_64(u, v.to_u64!)
          u, v = v, DoubleLimb.new(remainder)
          x0, x1 = x1, x0 &+ q &* x1
          x0_negative = !x0_negative
          next
        end
        shift = 2 * LIMB_BITS - LEHMER_BITS - u.leading_zeros_count.to_i32
        a, b, c, d, steps = lehmer((u >> shift).to_u64!.to_i64!, (v >> shift).to_u64!.to_i64!)
        if steps == 0
          q, remainder = Divide.div_128_by_128(u, v)
          u, v = v, remainder
          x0, x1 = x1, x0 &+ x1 &* q
          x0_negative = !x0_negative
        else
          u, v = combine_128(u, v, a, b, c, d, steps)
          # Each new cofactor adds two products of one sign.
          a_magnitude = a.abs.to_u64!.to_u128!
          b_magnitude = b.abs.to_u64!.to_u128!
          c_magnitude = c.abs.to_u64!.to_u128!
          d_magnitude = d.abs.to_u64!.to_u128!
          x0, x1 = a_magnitude &* x0 &+ b_magnitude &* x1, c_magnitude &* x0 &+ d_magnitude &* x1
          x0_negative = !x0_negative if steps.odd?
        end
      end
      return nil if (u >> LIMB_BITS) != 0
      small_u = u.to_u64!
      small_v = v.to_u64!
      while small_v != 0
        q = small_u.unsafe_div(small_v)
        small_u, small_v = small_v, small_u &- q &* small_v
        x0, x1 = x1, x0 &+ x1 &* q
        x0_negative = !x0_negative
      end
      return nil unless small_u == 1
      x0_negative ? m &- x0 : x0
    end

    # Limb buffers of `invert_magnitudes` (nine runs of `modulus.size + 2`)
    # come from the stack up to this many limbs.
    private INVERT_STACK_LIMBS = 360

    # The inverse of *a* modulo *modulus* (positive, three limbs or more), or
    # nil: extended Lehmer on limb buffers while the remainders have three
    # limbs or more, Lehmer steps on two-limb remainders, then extended
    # Euclid on one limb with its cofactors gathered in one matrix. The
    # cofactor of the residue is carried as two magnitudes `x0`, `x1` (each
    # at most the modulus) whose signs are opposite.
    private def self.invert_magnitudes(a : Integer, modulus : Integer) : Integer?
      capacity = modulus.size + 2
      if 9 * capacity <= INVERT_STACK_LIMBS
        scratch = uninitialized StaticArray(Limb, INVERT_STACK_LIMBS)
        invert_into(a, modulus, scratch.to_unsafe, capacity)
      else
        invert_into(a, modulus, Limbs.allocate(9 * capacity), capacity)
      end
    end

    # `invert_magnitudes` with *scratch* holding nine runs of *capacity*
    # limbs.
    private def self.invert_into(a : Integer, modulus : Integer, scratch : Pointer(Limb), capacity : Int32) : Integer?
      mn = modulus.size
      mp = modulus.limb_pointer
      u = scratch
      v = scratch + capacity
      s = scratch + 2 * capacity
      t = scratch + 3 * capacity
      x0 = scratch + 4 * capacity
      x1 = scratch + 5 * capacity
      y0 = scratch + 6 * capacity
      y1 = scratch + 7 * capacity
      quotient = scratch + 8 * capacity

      # The residue of a, from 0 to modulus - 1, goes to v.
      an = a.size
      ap = a.limb_pointer
      if an < mn || (an == mn && Limbs.cmp(ap, mp, mn) < 0)
        Limbs.copy(v, ap, an)
        vn = an
      else
        quotient_count = an - mn + 1
        wide = quotient_count <= capacity ? quotient : Limbs.allocate(quotient_count)
        Divide.div_qr(wide, v, ap, an, mp, mn)
        vn = Limbs.normalize(v, mn)
      end
      return nil if vn == 0
      if a.negative?
        Limbs.sub(t, mp, mn, v, vn)
        v, t = t, v
        vn = Limbs.normalize(v, mn)
      end

      Limbs.copy(u, mp, mn)
      un = mn
      x0n = 0
      x1[0] = Limb.new(1)
      x1n = 1
      x0_negative = true
      while vn > 0
        if un >= 3
          shift = un * LIMB_BITS - u[un - 1].leading_zeros_count.to_i32 - LEHMER_BITS
          m00, m01, m10, m11, steps = lehmer(window(u, un, shift).to_i64!, window(v, vn, shift).to_i64!)
          if steps == 0
            # One Euclid step: u, v = v, u mod v; x0, x1 = x1, x0 + q*x1.
            quotient_count = un - vn + 1
            Divide.div_qr(quotient, t, u, un, v, vn)
            quotient_count = Limbs.normalize(quotient, quotient_count)
            y0n = if quotient_count == 1
                    add_scaled(y0, x1, x1n, quotient[0], x0, x0n, Limb.new(1))
                  else
                    add_product(y0, x0, x0n, x1, x1n, quotient, quotient_count)
                  end
            remainder_count = Limbs.normalize(t, vn)
            u, v, t = v, t, u
            un, vn = vn, remainder_count
            x0, x1, y0 = x1, y0, x0
            x0n, x1n = x1n, y0n
            x0_negative = !x0_negative
          else
            combine(s, u, un, v, vn, m00, m01, steps, true)
            combine(t, u, un, v, vn, m10, m11, steps, false)
            u, v, s, t = s, t, u, v
            vn = Limbs.normalize(v, un)
            un = Limbs.normalize(u, un)
            y0n = add_scaled(y0, x0, x0n, m00.abs.to_u64!, x1, x1n, m01.abs.to_u64!)
            y1n = add_scaled(y1, x0, x0n, m10.abs.to_u64!, x1, x1n, m11.abs.to_u64!)
            x0, x1, y0, y1 = y0, y1, x0, x1
            x0n, x1n = y0n, y1n
            x0_negative = !x0_negative if steps.odd?
          end
        elsif un == 2
          wide_u = magnitude_of(u, 2)
          wide_v = magnitude_of(v, vn)
          if vn == 1
            q, remainder = Divide.div_128_by_64(wide_u, v[0])
            if (q >> LIMB_BITS) == 0
              y0n = add_scaled(y0, x1, x1n, q.to_u64!, x0, x0n, Limb.new(1))
            else
              quotient[0] = q.to_u64!
              quotient[1] = (q >> LIMB_BITS).to_u64!
              y0n = add_product(y0, x0, x0n, x1, x1n, quotient, 2)
            end
            wide_u, wide_v = wide_v, DoubleLimb.new(remainder)
            x0, x1, y0 = x1, y0, x0
            x0n, x1n = x1n, y0n
            x0_negative = !x0_negative
          else
            shift = 2 * LIMB_BITS - LEHMER_BITS - wide_u.leading_zeros_count.to_i32
            m00, m01, m10, m11, steps = lehmer((wide_u >> shift).to_u64!.to_i64!, (wide_v >> shift).to_u64!.to_i64!)
            if steps == 0
              q, remainder = Divide.div_128_by_128(wide_u, wide_v)
              y0n = add_scaled(y0, x1, x1n, q, x0, x0n, Limb.new(1))
              wide_u, wide_v = wide_v, remainder
              x0, x1, y0 = x1, y0, x0
              x0n, x1n = x1n, y0n
              x0_negative = !x0_negative
            else
              wide_u, wide_v = combine_128(wide_u, wide_v, m00, m01, m10, m11, steps)
              y0n = add_scaled(y0, x0, x0n, m00.abs.to_u64!, x1, x1n, m01.abs.to_u64!)
              y1n = add_scaled(y1, x0, x0n, m10.abs.to_u64!, x1, x1n, m11.abs.to_u64!)
              x0, x1, y0, y1 = y0, y1, x0, x1
              x0n, x1n = y0n, y1n
              x0_negative = !x0_negative if steps.odd?
            end
          end
          u[0] = wide_u.to_u64!
          u[1] = (wide_u >> LIMB_BITS).to_u64!
          v[0] = wide_v.to_u64!
          v[1] = (wide_v >> LIMB_BITS).to_u64!
          un = Limbs.normalize(u, 2)
          vn = Limbs.normalize(v, 2)
        else
          # One limb each: extended Euclid, the cofactor steps gathered in
          # the matrix [[m00, m01], [m10, m11]] (magnitudes) and applied once.
          small_u = u[0]
          small_v = v[0]
          m00 = Limb.new(1)
          m01 = Limb.zero
          m10 = Limb.zero
          m11 = Limb.new(1)
          steps = 0
          while small_v != 0
            q = small_u.unsafe_div(small_v)
            small_u, small_v = small_v, small_u &- q &* small_v
            m00, m01, m10, m11 = m10, m11, m00 &+ q &* m10, m01 &+ q &* m11
            steps += 1
          end
          y0n = add_scaled(y0, x0, x0n, m00, x1, x1n, m01)
          x0, y0 = y0, x0
          x0n = y0n
          x0_negative = !x0_negative if steps.odd?
          u[0] = small_u
          un = 1
          vn = 0
        end
      end
      return nil unless un == 1 && u[0] == 1
      cofactor = Integer.build(x0n, false) do |rp|
        Limbs.copy(rp, x0, x0n)
        x0n
      end
      x0_negative && !cofactor.zero? ? modulus - cofactor : cofactor
    end

    # Writes `x * p + y * q` (magnitudes of *pn* and *qn* limbs, limb
    # factors) into *rp* and returns its normalized limb count.
    private def self.add_scaled(rp : Pointer(Limb), p : Pointer(Limb), pn : Int32, x : Limb, q : Pointer(Limb), qn : Int32, y : Limb) : Int32
      if pn < qn
        p, q = q, p
        pn, qn = qn, pn
        x, y = y, x
      end
      return 0 if pn == 0
      rp[pn] = Limbs.mul_1(rp, p, pn, x)
      if qn > 0
        carry = Limbs.addmul_1(rp, q, qn, y)
        rp[pn] &+= Limbs.add_1(rp + qn, rp + qn, pn - qn, carry)
      end
      Limbs.normalize(rp, pn + 1)
    end

    # Writes `x + q * y` (the *xn* limbs of *x*, the *yn* limbs of *y*, the
    # *qn* limbs of *q*) into *rp*, which the result is known to fit, and
    # returns its normalized limb count.
    private def self.add_product(rp : Pointer(Limb), x : Pointer(Limb), xn : Int32, y : Pointer(Limb), yn : Int32, q : Pointer(Limb), qn : Int32) : Int32
      if yn == 0 || qn == 0
        Limbs.copy(rp, x, xn)
        return xn
      end
      product_count = yn + qn
      product = Limbs.allocate(product_count)
      if yn >= qn
        Multiply.mul(product, y, yn, q, qn)
      else
        Multiply.mul(product, q, qn, y, yn)
      end
      product_count = Limbs.normalize(product, product_count)
      if product_count >= xn
        Limbs.copy(rp, product, product_count)
        rp[product_count] = xn > 0 ? Limbs.add(rp, product, product_count, x, xn) : Limb.zero
        Limbs.normalize(rp, product_count + 1)
      else
        rp[xn] = Limbs.add(rp, x, xn, product, product_count)
        Limbs.normalize(rp, xn + 1)
      end
    end

    # ---- Integer square root ----

    # The integer square root of *n* (`mpz_sqrt`); raises for a negative
    # value, as `Math.isqrt` does for primitives.
    def self.isqrt(n : Integer) : Integer
      raise ArgumentError.new("Input must be non-negative integer") if n.negative?
      count = n.size
      return Integer.from_magnitude(DoubleLimb.new(isqrt_128(n.magnitude128)), false) if count <= 2
      return isqrt_256(n) if count <= 4
      isqrt_newton(n)
    end

    # The square root of the limb *x*, rounded down: the double-precision
    # square root, corrected by at most a step or two.
    def self.isqrt_limb(x : Limb) : Limb
      return x if x < 2
      root = Math.sqrt(x.to_f64).to_u64!
      root = Limb.new(0xFFFF_FFFF) if root > 0xFFFF_FFFF
      while root &* root > x
        root &-= 1
      end
      while (root &+ 1).to_u128! &* (root &+ 1) <= x
        root &+= 1
      end
      root
    end

    # The square root of the 128-bit *x*, rounded down: a double-precision
    # estimate raised above the root, then one Newton step from above
    # (`(s + x / s) / 2`), which lands on the root or one above.
    def self.isqrt_128(x : DoubleLimb) : Limb
      return isqrt_limb(x.to_u64!) if (x >> LIMB_BITS) == 0
      # The estimate is within 2**12 of the root; the margin puts it above.
      # (A root of 2**64 or more would not convert to a limb.)
      approximate = Math.sqrt(x.to_f64) + 16_384.0
      estimate = approximate < 18_446_744_073_709_551_616.0 ? approximate.to_u64! : Limb::MAX
      quotient = Divide.div_128_by_64(x, estimate)[0]
      # Near 2**128 the step can reach 2**64, one above any limb.
      root = Math.min((estimate.to_u128! &+ quotient) >> 1, DoubleLimb.new(Limb::MAX)).to_u64!
      while root.to_u128! &* root > x
        root &-= 1
      end
      root
    end

    # The square root of *n* of three or four limbs, rounded down: one step
    # of Zimmermann's Karatsuba square root on limbs (Brent and Zimmermann,
    # *Modern Computer Arithmetic*, Algorithm 1.12 `SqrtRem`). With *n*
    # shifted left by an even count to `a3:a2:a1:a0` (`a3 >= 2**62`), the
    # root `s1` and remainder `r1` of `a3:a2` and one division of `r1:a1` by
    # `2 * s1` give the root `s1 * B + q`, too large by one at most.
    private def self.isqrt_256(n : Integer) : Integer
      count = n.size
      np = n.limb_pointer
      padded = StaticArray(Limb, 4).new(Limb.zero)
      Limbs.copy(padded.to_unsafe, np, count)
      zeros = (4 - count) * LIMB_BITS + np[count - 1].leading_zeros_count.to_i32
      half_shift = zeros // 2
      limbs = shift_left_256(padded, 2 * half_shift)
      a3, a2, a1, a0 = limbs[3], limbs[2], limbs[1], limbs[0]
      top = (a3.to_u128! << LIMB_BITS) | a2
      s1 = isqrt_128(top)
      r1 = top &- s1.to_u128! &* s1
      # (r1 * B + a1) / (2 * s1) as ((r1 * B + a1) / 2) / s1: r1 <= 2 * s1,
      # so the halved numerator fits 128 bits.
      halved = (r1 << (LIMB_BITS - 1)) | (a1 >> 1)
      q, halved_remainder = Divide.div_128_by_64(halved, s1)
      remainder = (DoubleLimb.new(halved_remainder) << 1) | (a1 & 1)
      # The root is too large by one when remainder * B + a0 < q**2; both
      # sides have up to 129 bits (q is at most B).
      left_high = remainder >> LIMB_BITS
      left_low = (remainder << LIMB_BITS) | a0
      q_squared = q &* q
      right_high = (q >> LIMB_BITS) != 0 ? DoubleLimb.new(1) : DoubleLimb.zero
      root = (s1.to_u128! << LIMB_BITS) &+ q
      root &-= 1 if left_high < right_high || (left_high == right_high && left_low < q_squared)
      Integer.from_magnitude(root >> half_shift, false)
    end

    # The four limbs of *value* shifted left by *count* bits (below 256).
    private def self.shift_left_256(value : StaticArray(Limb, 4), count : Int32) : StaticArray(Limb, 4)
      limb_shift = count // LIMB_BITS
      bit_shift = count % LIMB_BITS
      result = StaticArray(Limb, 4).new(Limb.zero)
      index = 3
      while index >= limb_shift
        source = index - limb_shift
        limb = value[source] << bit_shift
        limb |= value[source - 1] >> (LIMB_BITS - bit_shift) if bit_shift != 0 && source > 0
        result[index] = limb
        index -= 1
      end
      result
    end

    # The square root of *n* above four limbs: the root of the top half
    # (and two bits) of *n*, raised one and scaled, then one Newton step
    # from above and a final correction.
    private def self.isqrt_newton(n : Integer) : Integer
      bits = n.bit_length
      top_bits = bits // 2 + 2
      top_bits += 1 if (bits - top_bits).odd?
      half_shift = (bits - top_bits) // 2
      top_root = isqrt(n >> (2 * half_shift))
      estimate = (top_root + 1) << half_shift
      root = (estimate + n // estimate) >> 1
      while root.square > n
        root -= 1
      end
      root
    end

    # ---- Factor removal ----

    # *value* with every factor *factor* divided out, and the count removed
    # (`mpz_remove`). Zero and the factors 1 and -1 remove nothing; a zero
    # factor raises `DivisionByZeroError`. A negative factor flips the sign
    # once per factor removed.
    def self.remove(value : Integer, factor : Integer) : {Integer, UInt64}
      raise DivisionByZeroError.new if factor.zero?
      return {value, 0_u64} if value.zero?
      if factor.size == 1
        f = factor.limb_at(0)
        return {value, 0_u64} if f == 1
        magnitude, count = remove_limb(value, f)
      else
        magnitude, count = remove_general(value.abs, factor.abs)
      end
      negative = value.negative? != (factor.negative? && count.odd?)
      {negative ? -magnitude.abs : magnitude.abs, count}
    end

    # The magnitude of *value* with every factor *f* (at least 2) divided
    # out, and the count removed. Dividing by `P = f**e`, the largest power
    # that fits a limb, removes *e* factors per pass; at the first nonzero
    # remainder `r` the count left is the multiplicity of *f* in `r`
    # (`f**c` divides the value exactly when it divides `r`, for `c < e`).
    private def self.remove_limb(value : Integer, f : Limb) : {Integer, UInt64}
      if f & (f &- 1) == 0
        step = f.trailing_zeros_count.to_u64
        count = value.trailing_zeros_count // step
        return {value.abs >> (count * step), count}
      end
      power = f
      exponent = 1_u64
      while power <= Limb::MAX // f
        power &*= f
        exponent += 1
      end
      count = 0_u64
      n = value.size
      if n <= 2
        x = value.magnitude128
        loop do
          quotient, remainder = Divide.div_128_by_64(x, power)
          if remainder != 0
            removed = multiplicity(remainder, f)
            if removed > 0
              x = Divide.div_128_by_64(x, power_of(f, removed))[0]
              count += removed
            end
            break
          end
          x = quotient
          count += exponent
        end
        return {Integer.from_magnitude(x, false), count}
      end
      if n <= STACK_LIMBS
        first = uninitialized StaticArray(Limb, STACK_LIMBS)
        second = uninitialized StaticArray(Limb, STACK_LIMBS)
        remove_limb_into(first.to_unsafe, second.to_unsafe, value, f, power, exponent)
      else
        remove_limb_into(Limbs.allocate(n), Limbs.allocate(n), value, f, power, exponent)
      end
    end

    # `remove_limb` above two limbs, with two scratch buffers of the
    # value's size.
    private def self.remove_limb_into(xp : Pointer(Limb), qp : Pointer(Limb), value : Integer, f : Limb, power : Limb, exponent : UInt64) : {Integer, UInt64}
      n = value.size
      Limbs.copy(xp, value.limb_pointer, n)
      count = 0_u64
      loop do
        remainder = Divide.divrem_1(qp, xp, n, power)
        if remainder != 0
          removed = multiplicity(remainder, f)
          if removed > 0
            Divide.divrem_1(qp, xp, n, power_of(f, removed))
            xp, qp = qp, xp
            n = Limbs.normalize(xp, n)
            count += removed
          end
          break
        end
        xp, qp = qp, xp
        n = Limbs.normalize(xp, n)
        count += exponent
      end
      result = Integer.build(n, false) do |rp|
        Limbs.copy(rp, xp, n)
        n
      end
      {result, count}
    end

    # The multiplicity of *f* (at least 2) in the nonzero limb *r*: divides
    # by *f*, *f*², *f*⁴, … while they divide, then tries the smaller powers
    # once each on the way back down.
    private def self.multiplicity(r : Limb, f : Limb) : UInt64
      powers = uninitialized StaticArray(Limb, 7)
      depth = 0
      count = 0_u64
      power = f
      step = 1_u64
      loop do
        quotient = r.unsafe_div(power)
        break unless quotient &* power == r
        r = quotient
        count += step
        powers[depth] = power
        depth += 1
        break if (power.to_u128! &* power) >> LIMB_BITS != 0
        power &*= power
        step <<= 1
      end
      while depth > 0
        depth -= 1
        power = powers[depth]
        quotient = r.unsafe_div(power)
        if quotient &* power == r
          r = quotient
          count += 1_u64 << depth
        end
      end
      count
    end

    # *f* to the *exponent*, known to fit a limb.
    private def self.power_of(f : Limb, exponent : UInt64) : Limb
      result = Limb.new(1)
      exponent.times { result &*= f }
      result
    end

    # The magnitude *value* with every factor *factor* (more than one limb)
    # divided out, and the count removed: one exact division per factor.
    private def self.remove_general(value : Integer, factor : Integer) : {Integer, UInt64}
      count = 0_u64
      while value.size >= factor.size
        quotient, remainder = value.tdivmod(factor)
        break unless remainder.zero?
        value = quotient
        count += 1
      end
      {value, count}
    end
  end
end
