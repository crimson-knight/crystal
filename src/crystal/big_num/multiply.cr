module Crystal::BigNum
  # :nodoc:
  #
  # Multiplication and squaring of limb runs, chosen by the size of the
  # smaller operand:
  #
  # - below `MUL_KARATSUBA_THRESHOLD` limbs: schoolbook (Knuth, TAOCP Vol. 2,
  #   4.3.1, Algorithm M): one `mul_1` row, then `addmul_1` rows;
  # - up to `MUL_TOOM3_THRESHOLD`: Karatsuba (Karatsuba and Ofman 1962; Knuth
  #   4.3.3), the subtractive form with `|a0 - a1| * |b0 - b1|`;
  # - above: Toom-3 (Toom 1963, Cook 1966) at the points 0, 1, -1, -2 and
  #   infinity, with Bodrato's evaluation and interpolation sequence (Bodrato
  #   and Zanoni, ISSAC 2007). The signed intermediate values are kept in two's
  #   complement over a fixed width, so the exact divisions by 2 and 3 are a
  #   shift and a multiplication by the inverse of 3 modulo the limb base.
  #
  # Squaring has its own schoolbook (each cross product once, doubled, plus the
  # diagonal) and its own thresholds. Operands much longer than the other are
  # cut into pieces the size of the shorter one. Scratch space for a top-level
  # call is taken once: on the stack when small, else from the atomic heap.
  #
  # The thresholds are compile-time constants per architecture, from the tuned
  # values in the chip profile table (`reports/chip-profiles/`). A program
  # compiled with `-Dbignum_threshold_tuning` can change them at run time; the
  # tuning program (`scripts/bignum/tune_multiply.cr`) uses that.
  module Multiply
    {% if flag?(:aarch64) %}
      # Tuned on Apple M4 (macOS) and confirmed on the Colima Linux VM.
      MUL_KARATSUBA_THRESHOLD =  24
      MUL_TOOM3_THRESHOLD     =  80
      SQR_KARATSUBA_THRESHOLD =  32
      SQR_TOOM3_THRESHOLD     = 100
    {% else %}
      MUL_KARATSUBA_THRESHOLD =  24
      MUL_TOOM3_THRESHOLD     =  80
      SQR_KARATSUBA_THRESHOLD =  32
      SQR_TOOM3_THRESHOLD     = 100
    {% end %}

    # Scratch runs up to this many limbs live on the stack.
    private STACK_SCRATCH_LIMBS = 8192

    {% for name in %w(mul_karatsuba mul_toom3 sqr_karatsuba sqr_toom3) %}
      {% if flag?(:bignum_threshold_tuning) %}
        class_property {{ name.id }}_threshold : Int32 = {{ name.upcase.id }}_THRESHOLD
      {% else %}
        @[AlwaysInline]
        def self.{{ name.id }}_threshold : Int32
          {{ name.upcase.id }}_THRESHOLD
        end
      {% end %}
    {% end %}

    # Writes the `an + bn` limbs of the product of the *an* limbs of *ap* and
    # the *bn* limbs of *bp* into *rp*. Requires `an >= bn >= 1`; *rp* must
    # not overlap *ap* or *bp*.
    def self.mul(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Nil
      if bn == 1
        rp[an] = Limbs.mul_1(rp, ap, an, bp[0])
      elsif bn < mul_karatsuba_threshold
        basecase_mul(rp, ap, an, bp, bn)
      else
        multiply_with_scratch(rp, ap, an, bp, bn)
      end
    end

    # Writes the `2 * n` limbs of the square of the *n* limbs of *ap* into
    # *rp*, which must not overlap *ap*.
    def self.sqr(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      if n < sqr_karatsuba_threshold
        basecase_sqr(rp, ap, n)
      else
        square_with_scratch(rp, ap, n)
      end
    end

    # Kept out of line so that the small products, which need no scratch, do
    # not pay for the stack frame that holds it.
    @[NoInline]
    private def self.multiply_with_scratch(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Nil
      with_scratch(scratch_limbs(an, bn)) do |scratch|
        multiply(rp, ap, an, bp, bn, scratch)
      end
    end

    @[NoInline]
    private def self.square_with_scratch(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      with_scratch(scratch_limbs(n, n)) do |scratch|
        square(rp, ap, n, scratch)
      end
    end

    # Yields a scratch run of at least *count* limbs.
    private def self.with_scratch(count : Int32, &)
      if count <= STACK_SCRATCH_LIMBS
        buffer = uninitialized StaticArray(Limb, STACK_SCRATCH_LIMBS)
        yield buffer.to_unsafe
      else
        scratch = Limbs.allocate(count)
        yield scratch
        GC.free(scratch.as(Void*))
      end
    end

    # An upper bound on the scratch limbs `multiply` and `square` use for
    # operands of *an* and *bn* limbs (`an >= bn`).
    def self.scratch_limbs(an : Int32, bn : Int32) : Int32
      if 2 * an >= 3 * bn
        2 * bn + balanced_scratch_limbs(bn)
      else
        balanced_scratch_limbs(an)
      end
    end

    # Every recursive step on *size* limbs takes at most `6 * size + 32`
    # scratch limbs for itself (Toom-3: `16 * (ceil(size / 3) + 1)`;
    # Karatsuba: `4 * ceil(size / 2) + 2`; a piece of an unbalanced product:
    # twice the piece) and recurses on at most `2 * size / 3 + 2` limbs.
    private def self.balanced_scratch_limbs(size : Int32) : Int32
      total = 0
      while size >= Math.min(mul_karatsuba_threshold, sqr_karatsuba_threshold)
        total += 6 * size + 32
        size = 2 * size // 3 + 2
      end
      total
    end

    # ---- Dispatch ----

    # The product of *an* and *bn* limbs (`an >= bn >= 1`) into *rp*.
    protected def self.multiply(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32, scratch : Pointer(Limb)) : Nil
      if bn < mul_karatsuba_threshold
        basecase_mul(rp, ap, an, bp, bn)
      elsif 2 * an >= 3 * bn
        unbalanced(rp, ap, an, bp, bn, scratch)
      elsif bn >= mul_toom3_threshold && toom3_fits?(an, bn)
        toom3(rp, ap, an, bp, bn, scratch, false)
      else
        toom2(rp, ap, an, bp, bn, scratch, false)
      end
    end

    # The square of *n* limbs into *rp*.
    protected def self.square(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, scratch : Pointer(Limb)) : Nil
      if n < sqr_karatsuba_threshold
        basecase_sqr(rp, ap, n)
      elsif n >= sqr_toom3_threshold
        toom3(rp, ap, n, ap, n, scratch, true)
      else
        toom2(rp, ap, n, ap, n, scratch, true)
      end
    end

    # Whether Toom-3 can split *an* and *bn* limbs: both top pieces must be
    # nonempty.
    private def self.toom3_fits?(an : Int32, bn : Int32) : Bool
      piece = (an + 2) // 3
      an > 2 * piece && bn > 2 * piece
    end

    # ---- Schoolbook ----

    # Knuth's Algorithm M, one row per limb of *bp*, the rows after the first
    # taken two at a time (`Limbs.addmul_2`): *rp* receives `an + bn` limbs.
    # Requires `an >= bn >= 1`.
    def self.basecase_mul(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Nil
      rp[an] = Limbs.mul_1(rp, ap, an, bp[0])
      index = 1
      while index + 1 < bn
        rp[an + index + 1] = Limbs.addmul_2(rp + index, ap, an, bp + index)
        index += 2
      end
      rp[an + index] = Limbs.addmul_1(rp + index, ap, an, bp[index]) if index < bn
    end

    # The square of *n* limbs into the `2 * n` limbs of *rp*: the cross
    # products `a[i] * a[j]` (`i < j`) once each, then, in one pass, doubled
    # and added to the diagonal squares `a[i] ** 2`.
    def self.basecase_sqr(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      if n == 1
        product = ap[0].to_u128! &* ap[0]
        rp[0] = product.to_u64!
        rp[1] = (product >> 64).to_u64!
        return
      end
      # Row i adds a[i] * a[i+1..] at limb 2i + 1; the cross products fill
      # limbs 1 to 2n - 2. Rows i and i + 1 go together: a[i] * a[i+1] at limb
      # 2i + 1, then (a[i] + a[i+1] * B) * a[i+2..] at limb 2i + 2.
      rp[n] = Limbs.mul_1(rp + 1, ap + 1, n - 1, ap[0])
      index = 1
      while index < n - 1
        if index + 2 < n
          rp[n + index + 1] = Limbs.addmul_2(rp + 2 * index + 2, ap + index + 2, n - 2 - index, ap + index)
          product = ap[index].to_u128! &* ap[index + 1]
          sum = rp[2 * index + 1].to_u128! &+ product.to_u64!
          rp[2 * index + 1] = sum.to_u64!
          sum = rp[2 * index + 2].to_u128! &+ (product >> 64).to_u64! &+ (sum >> 64).to_u64!
          rp[2 * index + 2] = sum.to_u64!
          Limbs.add_1(rp + 2 * index + 3, rp + 2 * index + 3, n - 1 - index, (sum >> 64).to_u64!)
          index += 2
        else
          rp[n + index] = Limbs.addmul_1(rp + 2 * index + 1, ap + index + 1, n - 1 - index, ap[index])
          index += 1
        end
      end
      rp[0] = Limb.zero
      rp[2 * n - 1] = Limb.zero
      shifted_in = Limb.zero
      carry = Limb.zero
      index = 0
      while index < n
        cross_low = rp[2 * index]
        cross_high = rp[2 * index + 1]
        doubled_low = (cross_low << 1) | shifted_in
        doubled_high = (cross_high << 1) | (cross_low >> 63)
        shifted_in = cross_high >> 63
        limb = ap[index]
        diagonal = limb.to_u128! &* limb
        sum = doubled_low.to_u128! &+ diagonal.to_u64! &+ carry
        rp[2 * index] = sum.to_u64!
        sum = doubled_high.to_u128! &+ (diagonal >> 64).to_u64! &+ (sum >> 64).to_u64!
        rp[2 * index + 1] = sum.to_u64!
        carry = (sum >> 64).to_u64!
        index += 1
      end
    end

    # ---- Unbalanced operands ----

    # *an* limbs times *bn* limbs with `2 * an >= 3 * bn`: *ap* is cut into
    # *bn*-limb pieces, each multiplied by *bp* and added in at its offset.
    private def self.unbalanced(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32, scratch : Pointer(Limb)) : Nil
      piece_product = scratch
      child = scratch + 2 * bn
      multiply(rp, ap, bn, bp, bn, child)
      offset = bn
      while offset < an
        piece = Math.min(bn, an - offset)
        if piece == bn
          multiply(piece_product, ap + offset, bn, bp, bn, child)
        else
          multiply(piece_product, bp, bn, ap + offset, piece, child)
        end
        # The limbs above offset + bn are fresh: add the low part, carry into
        # the high part.
        Limbs.add(rp + offset, piece_product, bn + piece, rp + offset, bn)
        offset += bn
      end
    end

    # ---- Karatsuba ----

    # Karatsuba on *an* and *bn* limbs, split at `n = ceil(an / 2)`
    # (`bn > n`): with `a = a1 * B^n + a0` and `b = b1 * B^n + b0`,
    # `a * b = a0b0 + (a0b0 + a1b1 - (a0 - a1)(b0 - b1)) * B^n + a1b1 * B^2n`.
    # With *squaring*, *bp* is *ap*.
    #
    # Scratch: `vm1` (2n), the differences (n each), then the children's
    # scratch at 4n.
    private def self.toom2(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32, scratch : Pointer(Limb), squaring : Bool) : Nil
      n = an - an // 2
      s = an - n
      t = bn - n
      vm1 = scratch
      a_difference = scratch + 2 * n
      b_difference = a_difference + n
      child = scratch + 4 * n

      negative = absolute_difference(a_difference, ap, n, ap + n, s)
      if squaring
        negative = false
        square(vm1, a_difference, n, child)
        square(rp, ap, n, child)
        square(rp + 2 * n, ap + n, s, child)
      else
        negative ^= absolute_difference(b_difference, bp, n, bp + n, t)
        multiply(vm1, a_difference, n, b_difference, n, child)
        multiply(rp, ap, n, bp, n, child)
        multiply(rp + 2 * n, ap + n, s, bp + n, t, child)
      end

      # With v0 = L0 + H0 * B^n and vinf = L1 + H1 * B^n (H1 has h limbs), the
      # product is L0 + (L0 + X) * B^n + (X + H1) * B^2n + H1 * B^3n, X = H0 + L1,
      # then -+ vm1 at B^n. All of it is computed modulo B^total, which the
      # product fits, so carries out of the top are dropped.
      total = an + bn
      high = s + t - n
      x_carry = Limbs.add_n(rp + 2 * n, rp + n, rp + 2 * n, n)
      low_carry = Limbs.add_n(rp + n, rp, rp + 2 * n, n)
      high_carry = Limbs.add(rp + 2 * n, rp + 2 * n, n, rp + 3 * n, high)
      Limbs.add_1(rp + 2 * n, rp + 2 * n, n + high, low_carry + x_carry)
      Limbs.add_1(rp + 3 * n, rp + 3 * n, high, high_carry + x_carry) if high > 0
      if negative
        Limbs.add(rp + n, rp + n, total - n, vm1, 2 * n)
      else
        Limbs.sub(rp + n, rp + n, total - n, vm1, 2 * n)
      end
    end

    # Writes `|x - y|` (*xn* limbs, `xn >= yn`) into *rp* and returns whether
    # `x < y`.
    private def self.absolute_difference(rp : Pointer(Limb), xp : Pointer(Limb), xn : Int32, yp : Pointer(Limb), yn : Int32) : Bool
      if xn > yn && !Limbs.zero?(xp + yn, xn - yn)
        Limbs.sub(rp, xp, xn, yp, yn)
        false
      elsif Limbs.cmp(xp, yp, yn) >= 0
        Limbs.sub_n(rp, xp, yp, yn)
        Limbs.zero(rp + yn, xn - yn)
        false
      else
        Limbs.sub_n(rp, yp, xp, yn)
        Limbs.zero(rp + yn, xn - yn)
        true
      end
    end

    # ---- Toom-3 ----

    # Toom-3 on *an* and *bn* limbs split at `n = ceil(an / 3)` into
    # `a = a2 * B^2n + a1 * B^n + a0` (and *b* likewise), evaluated at 0, 1,
    # -1, -2 and infinity. With *squaring*, *bp* is *ap*.
    #
    # Evaluations take `m = n + 1` limbs and products `w = 2m` limbs, signed
    # values in two's complement modulo `B^w`. Scratch: six evaluations (6m),
    # five products (5w), then the children's scratch.
    private def self.toom3(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32, scratch : Pointer(Limb), squaring : Bool) : Nil
      n = (an + 2) // 3
      s = an - 2 * n
      t = bn - 2 * n
      m = n + 1
      w = 2 * m

      a1 = scratch
      am1 = a1 + m
      am2 = am1 + m
      b1 = am2 + m
      bm1 = b1 + m
      bm2 = bm1 + m
      v0 = bm2 + m
      v1 = v0 + w
      vm1 = v1 + w
      vm2 = vm1 + w
      vinf = vm2 + w
      child = vinf + w

      a_negative_1, a_negative_2 = evaluate(a1, am1, am2, ap, n, s)
      if squaring
        square(v1, a1, m, child)
        square(vm1, am1, m, child)
        square(vm2, am2, m, child)
        square(v0, ap, n, child)
        square(vinf, ap + 2 * n, s, child)
      else
        b_negative_1, b_negative_2 = evaluate(b1, bm1, bm2, bp, n, t)
        multiply(v1, a1, m, b1, m, child)
        multiply(vm1, am1, m, bm1, m, child)
        multiply(vm2, am2, m, bm2, m, child)
        multiply(v0, ap, n, bp, n, child)
        multiply(vinf, ap + 2 * n, s, bp + 2 * n, t, child)
        negate(vm1, w) if a_negative_1 != b_negative_1
        negate(vm2, w) if a_negative_2 != b_negative_2
      end
      Limbs.zero(v0 + 2 * n, w - 2 * n)
      Limbs.zero(vinf + s + t, w - s - t)

      # Bodrato's sequence for the points 0, 1, -1, -2 and infinity.
      # r3 = (v(-2) - v(1)) / 3
      Limbs.sub_n(vm2, vm2, v1, w)
      divide_exactly_by_3(vm2, w)
      # r1 = (v(1) - v(-1)) / 2
      Limbs.sub_n(v1, v1, vm1, w)
      halve(v1, w)
      # r2 = v(-1) - v(0)
      Limbs.sub_n(vm1, vm1, v0, w)
      # r3 = (r2 - r3) / 2 + 2 * v(inf)
      Limbs.sub_n(vm2, vm1, vm2, w)
      halve(vm2, w)
      Limbs.add_n(vm2, vm2, vinf, w)
      Limbs.add_n(vm2, vm2, vinf, w)
      # r2 = r2 + r1 - v(inf)
      Limbs.add_n(vm1, vm1, v1, w)
      Limbs.sub_n(vm1, vm1, vinf, w)
      # r1 = r1 - r3
      Limbs.sub_n(v1, v1, vm2, w)

      # The coefficients v0, v1, vm1, vm2 and vinf (all nonnegative now) go
      # in at 0, n, 2n, 3n and 4n.
      total = an + bn
      Limbs.copy(rp, v0, 2 * n)
      Limbs.zero(rp + 2 * n, 2 * n)
      Limbs.copy(rp + 4 * n, vinf, s + t)
      {% for pair in [{"v1", 1}, {"vm1", 2}, {"vm2", 3}] %}
        offset = {{ pair[1] }} * n
        Limbs.add(rp + offset, rp + offset, total - offset, {{ pair[0].id }}, Math.min(w, total - offset))
      {% end %}
    end

    # Evaluates the three pieces of the *n*, *n* and *top*-limb split at *xp*
    # at 1, -1 and -2 into the `n + 1` limbs at *p1*, *pm1* and *pm2*, and
    # returns whether the values at -1 and -2 are negative (their limbs hold
    # the magnitudes).
    private def self.evaluate(p1 : Pointer(Limb), pm1 : Pointer(Limb), pm2 : Pointer(Limb), xp : Pointer(Limb), n : Int32, top : Int32) : {Bool, Bool}
      x0 = xp
      x1 = xp + n
      x2 = xp + 2 * n
      m = n + 1
      # x0 + x2
      p1[n] = Limbs.add(p1, x0, n, x2, top)
      # x(-1) = x0 + x2 - x1, two's complement over m limbs
      pm1[n] = p1[n] &- Limbs.sub_n(pm1, p1, x1, n)
      # x(1) = x0 + x2 + x1
      p1[n] &+= Limbs.add_n(p1, p1, x1, n)
      # x(-2) = 2 * (x(-1) + x2) - x0, two's complement over m limbs
      Limbs.add(pm2, pm1, m, x2, top)
      Limbs.lshift(pm2, pm2, m, 1)
      Limbs.sub(pm2, pm2, m, x0, n)
      negative_1 = pm1[n] >> (LIMB_BITS - 1) == 1
      negative_2 = pm2[n] >> (LIMB_BITS - 1) == 1
      negate(pm1, m) if negative_1
      negate(pm2, m) if negative_2
      {negative_1, negative_2}
    end

    # The two's complement negation of the *n* limbs at *rp*, in place.
    private def self.negate(rp : Pointer(Limb), n : Int32) : Nil
      Limbs.com(rp, rp, n)
      Limbs.add_1(rp, rp, n, Limb.new(1))
    end

    # Halves the even two's complement value in the *n* limbs at *rp*.
    private def self.halve(rp : Pointer(Limb), n : Int32) : Nil
      sign = rp[n - 1] & (Limb.new(1) << (LIMB_BITS - 1))
      Limbs.rshift(rp, rp, n, 1)
      rp[n - 1] |= sign
    end

    # The inverse of 3 modulo the limb base.
    private INVERSE_OF_3 = Limb::MAX // 3 * 2 + 1

    # Divides the two's complement value in the *n* limbs at *rp*, a multiple
    # of 3, by 3 in place (exact division, Jebelean 1993): each quotient limb
    # is the running limb times the inverse of 3, and the high part of three
    # times it carries into the next limb.
    private def self.divide_exactly_by_3(rp : Pointer(Limb), n : Int32) : Nil
      carry = Limb.zero
      index = 0
      while index < n
        limb = rp[index]
        running = limb &- carry
        borrow = running > limb ? Limb.new(1) : Limb.zero
        quotient = running &* INVERSE_OF_3
        rp[index] = quotient
        carry = (quotient.to_u128! &* 3 >> LIMB_BITS).to_u64! &+ borrow
        index += 1
      end
    end
  end
end
