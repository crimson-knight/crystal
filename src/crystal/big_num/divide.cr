module Crystal::BigNum
  # :nodoc:
  #
  # Division on magnitudes (runs of limbs, least significant first), in the
  # style of the `Limbs` kernels: raw pointers and limb counts, with signs,
  # allocation of results and normalization left to the caller.
  #
  # | Divisor size | Algorithm |
  # |---|---|
  # | 1 limb | `divrem_1` / `mod_1`: 2/1 division by an invariant integer with a precomputed reciprocal (Möller and Granlund, "Improved division by invariant integers", IEEE Trans. Computers 60(2), 2011, algorithm 4) |
  # | 2 limbs to `DIV_BZ` | Knuth, TAOCP Vol. 2, 4.3.1, Algorithm D, each quotient limb estimated with the 3/2 reciprocal of the same paper (algorithm 5) |
  # | `DIV_BZ` and above | Burnikel and Ziegler, "Fast Recursive Division", MPI-I-98-1-022, 1998 |
  #
  # Exact division (`divexact`) is Jebelean's right-to-left method
  # (Jebelean, "An algorithm for exact division", J. Symbolic Computation
  # 15, 1993).
  module Divide
    # The divisor size (in limbs) from which `div_qr` divides recursively
    # (Burnikel-Ziegler) instead of with Algorithm D. Tuned per chip family;
    # see `reports/chip-profiles/` in the vault.
    DIV_BZ = 50

    # The most limbs of scratch `div_qr` takes from the stack before it
    # allocates from the heap instead.
    STACK_LIMBS = 384

    # ---- Reciprocals ----

    # The 2/1 reciprocal of the normalized limb *d* (top bit set):
    # `floor((B**2 - 1) / d) - B` with `B = 2**64`.
    def self.invert_limb(d : Limb) : Limb
      # (B**2 - 1) - B*d = (~d) * B + (B - 1), and ~d < d, so the quotient
      # fits a limb.
      (((~d).to_u128! << 64) | Limb::MAX).//(d.to_u128!).to_u64!
    end

    # The 3/2 reciprocal of the normalized two-limb divisor *d1*:*d0*:
    # `floor((B**3 - 1) / (d1 * B + d0)) - B` (Möller-Granlund, algorithm 6).
    def self.invert_pair(d1 : Limb, d0 : Limb) : Limb
      v = invert_limb(d1)
      p = d1 &* v
      p &+= d0
      if p < d0
        v &-= 1
        if p >= d1
          v &-= 1
          p &-= d1
        end
        p &-= d1
      end
      product = d0.to_u128! &* v
      t1 = (product >> 64).to_u64!
      t0 = product.to_u64!
      p &+= t1
      if p < t1
        v &-= 1
        if p > d1 || (p == d1 && t0 >= d0)
          v &-= 1
        end
      end
      v
    end

    # Divides the two limbs *u1*:*u0* (`u1 < d`) by the normalized limb *d*
    # with its reciprocal *v*; returns the quotient and the remainder
    # (Möller-Granlund, algorithm 4).
    @[AlwaysInline]
    def self.div_2by1(u1 : Limb, u0 : Limb, d : Limb, v : Limb) : {Limb, Limb}
      # (q1, q0) = v * u1 + (u1, u0), written so that only one multiply-high
      # sits on the path from u1 to the remainder.
      product = v.to_u128! &* u1
      q0 = product.to_u64! &+ u0
      q1 = (product >> 64).to_u64! &+ u1 &+ (q0 < u0 ? Limb.new(1) : Limb.zero)
      # r = u0 - (q1 + 1) * d, with u0 - d formed off the critical path.
      u0_less_d = u0 &- d
      # An empty asm statement (no instruction) keeps LLVM from folding the
      # subtraction back into the multiply, which would put it on the path.
      asm("" : "=r"(u0_less_d) : "0"(u0_less_d))
      r = u0_less_d &- q1 &* d
      # The first correction is taken about half the time: a select, off the
      # branch predictor. Without it the quotient is q1 + 1.
      over = r > q0
      r_plus = r &+ d
      asm("" : "=r"(r_plus) : "0"(r_plus))
      r = over ? r_plus : r
      q1 = over ? q1 : q1 &+ 1
      # The second is rare (probability about 2**-64 per call for random input):
      # a real branch, so it stays off the dependency chain.
      return correct_2by1(q1, r, d) if r >= d
      {q1, r}
    end
    
    @[NoInline]
    protected def self.correct_2by1(q1 : Limb, r : Limb, d : Limb) : {Limb, Limb}
      {q1 &+ 1, r &- d}
    end
    
    # Divides the three limbs *n2*:*n1*:*n0* (with `n2:n1 < d1:d0`) by the
    # normalized two-limb divisor *d1*:*d0* with its 3/2 reciprocal *v*;
    # returns the quotient limb and the two-limb remainder
    # (Möller-Granlund, algorithm 5).
    @[AlwaysInline]
    def self.div_3by2(n2 : Limb, n1 : Limb, n0 : Limb, d1 : Limb, d0 : Limb, v : Limb) : {Limb, DoubleLimb}
      product = v.to_u128! &* n2 &+ ((n2.to_u128! << 64) | n1)
      q1 = (product >> 64).to_u64!
      q0 = product.to_u64!
      r1 = n1 &- q1 &* d1
      divisor = (d1.to_u128! << 64) | d0
      remainder = ((r1.to_u128! << 64) | n0) &- divisor &- (d0.to_u128! &* q1)
      q1 &+= 1
      if (remainder >> 64).to_u64! >= q0
        q1 &-= 1
        remainder &+= divisor
      end
      if remainder >= divisor
        q1 &+= 1
        remainder &-= divisor
      end
      {q1, remainder}
    end

    # ---- One-limb divisors ----

    # Divides the *n* limbs of *np* (`n >= 1`) by the nonzero limb *d*,
    # writes the *n* quotient limbs to *qp* (which may be *np*) and returns
    # the remainder.
    def self.divrem_1(qp : Pointer(Limb), np : Pointer(Limb), n : Int32, d : Limb) : Limb
      shift = d.leading_zeros_count.to_i32
      d <<= shift
      v = invert_limb(d)
      index = n - 1
      if shift == 0
        r = np[index]
        if r >= d
          r &-= d
          qp[index] = Limb.new(1)
        else
          qp[index] = Limb.zero
        end
        index -= 1
        while index >= 0
          q, r = div_2by1(r, np[index], d, v)
          qp[index] = q
          index -= 1
        end
        r
      else
        back = LIMB_BITS - shift
        high = np[index]
        r = high >> back
        while index > 0
          low = np[index - 1]
          q, r = div_2by1(r, (high << shift) | (low >> back), d, v)
          qp[index] = q
          high = low
          index -= 1
        end
        q, r = div_2by1(r, high << shift, d, v)
        qp[0] = q
        r >> shift
      end
    end

    # The remainder of the *n* limbs of *np* (`n >= 1`) divided by the
    # nonzero limb *d*.
    def self.mod_1(np : Pointer(Limb), n : Int32, d : Limb) : Limb
      shift = d.leading_zeros_count.to_i32
      d <<= shift
      v = invert_limb(d)
      index = n - 1
      if shift == 0
        r = np[index]
        r &-= d if r >= d
        index -= 1
        while index >= 0
          _, r = div_2by1(r, np[index], d, v)
          index -= 1
        end
        r
      else
        back = LIMB_BITS - shift
        high = np[index]
        r = high >> back
        while index > 0
          low = np[index - 1]
          _, r = div_2by1(r, (high << shift) | (low >> back), d, v)
          high = low
          index -= 1
        end
        _, r = div_2by1(r, high << shift, d, v)
        r >> shift
      end
    end

    # ---- Algorithm D ----

    # Knuth's Algorithm D on a normalized divisor: divides the *nn* limbs of
    # *np* by the *dn* limbs of *dp* (`nn >= dn >= 2`, top bit of
    # `dp[dn - 1]` set), with *dinv* the 3/2 reciprocal of the divisor's top
    # two limbs. Writes the low `nn - dn` quotient limbs to *qp*, leaves the
    # remainder in the low *dn* limbs of *np*, and returns the top quotient
    # limb (0 or 1).
    def self.schoolbook_div_qr(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32, dinv : Limb) : Limb
      top = np + (nn - dn)
      qh = Limbs.cmp(top, dp, dn) >= 0 ? Limb.new(1) : Limb.zero
      Limbs.sub_n(top, top, dp, dn) if qh != 0
      d1 = dp[dn - 1]
      d0 = dp[dn - 2]
      n1 = np[nn - 1]
      index = nn - dn
      while index > 0
        index -= 1
        # The window is np[index, dn + 1]; its top limb is n1.
        window = np + index
        n_mid = window[dn - 1]
        if n1 == d1 && n_mid == d0
          # The estimate would overflow a limb; the quotient limb is B - 1,
          # and the top limb of the window cancels.
          q = Limb::MAX
          Limbs.submul_1(window, dp, dn, q)
          n1 = window[dn - 1]
        else
          q, remainder = div_3by2(n1, n_mid, window[dn - 2], d1, d0, dinv)
          n1 = (remainder >> 64).to_u64!
          n0 = remainder.to_u64!
          borrow = Limbs.submul_1(window, dp, dn - 2, q)
          borrow_out = n0 < borrow ? Limb.new(1) : Limb.zero
          n0 &-= borrow
          window[dn - 2] = n0
          borrow = n1 < borrow_out ? Limb.new(1) : Limb.zero
          n1 &-= borrow_out
          if borrow != 0
            # The estimate was one too large: add the divisor back.
            n1 &+= d1 &+ Limbs.add_n(window, window, dp, dn - 1)
            q &-= 1
          end
        end
        qp[index] = q
      end
      np[dn - 1] = n1
      qh
    end

    # ---- Burnikel-Ziegler ----

    # Divides the 2 * *n* limbs of *np* by the normalized *n* limbs of *dp*
    # recursively (Burnikel-Ziegler's D2n/1n, its two halves done as the
    # D3n/2n step: a recursive division by the divisor's top half, then a
    # correction by one multiplication). Writes *n* quotient limbs to *qp*,
    # leaves the remainder in the low *n* limbs of *np*, and returns the top
    # quotient limb (0 or 1). *tp* is scratch for *n* limbs.
    def self.recursive_div_qr_n(qp : Pointer(Limb), np : Pointer(Limb), dp : Pointer(Limb), n : Int32, dinv : Limb, tp : Pointer(Limb)) : Limb
      low = n >> 1
      high = n - low

      # High half: the top 2 * high limbs by the divisor's top high limbs.
      qh = if high < DIV_BZ
             schoolbook_div_qr(qp + low, np + 2 * low, 2 * high, dp + low, high, dinv)
           else
             recursive_div_qr_n(qp + low, np + 2 * low, dp + low, high, dinv, tp)
           end
      # Correct with the divisor's low limbs: subtract q * dp[0, low].
      multiply(tp, qp + low, high, dp, low)
      borrow = Limbs.sub_n(np + low, np + low, tp, n)
      borrow &+= Limbs.sub_n(np + n, np + n, dp, low) if qh != 0
      while borrow != 0
        qh &-= Limbs.sub_1(qp + low, qp + low, high, Limb.new(1))
        borrow &-= Limbs.add_n(np + low, np + low, dp, n)
      end

      # Low half: the next 2 * low limbs by the divisor's top low limbs.
      ql = if low < DIV_BZ
             schoolbook_div_qr(qp, np + high, 2 * low, dp + high, low, dinv)
           else
             recursive_div_qr_n(qp, np + high, dp + high, low, dinv, tp)
           end
      multiply(tp, dp, high, qp, low)
      borrow = Limbs.sub_n(np, np, tp, n)
      borrow &+= Limbs.sub_n(np + low, np + low, dp, high) if ql != 0
      while borrow != 0
        Limbs.sub_1(qp, qp, low, Limb.new(1))
        borrow &-= Limbs.add_n(np, np, dp, n)
      end
      qh
    end

    # Divides the *nn* limbs of *np* by the normalized *dn* limbs of *dp*
    # (`nn >= dn >= DIV_BZ`) recursively. Same contract as
    # `schoolbook_div_qr`; *tp* is scratch for *dn* limbs.
    def self.recursive_div_qr(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32, dinv : Limb, tp : Pointer(Limb)) : Limb
      qn = nn - dn
      if qn >= dn
        # The quotient in blocks of dn limbs from the top; the first block
        # takes the qn mod dn limbs that do not fill a block.
        first = qn % dn
        qh = Limb.zero
        if first == 0
          qh = recursive_div_qr_n(qp + qn - dn, np + nn - 2 * dn, dp, dn, dinv, tp)
          done = dn
        else
          qh = unbalanced_div_qr(qp + qn - first, np + nn - dn - first, first + dn, dp, dn, dinv, tp)
          done = first
        end
        while done < qn
          done += dn
          recursive_div_qr_n(qp + qn - done, np + nn - dn - done, dp, dn, dinv, tp)
        end
        qh
      else
        unbalanced_div_qr(qp, np, nn, dp, dn, dinv, tp)
      end
    end

    # Divides the *nn* limbs of *np* by the normalized *dn* limbs of *dp* when
    # the quotient is shorter than the divisor (`qn = nn - dn < dn`): divides
    # the top 2 * qn limbs by the divisor's top qn limbs, then corrects with
    # the divisor's low limbs. Same contract as `schoolbook_div_qr`.
    def self.unbalanced_div_qr(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32, dinv : Limb, tp : Pointer(Limb)) : Limb
      qn = nn - dn
      return schoolbook_div_qr(qp, np, nn, dp, dn, dinv) if qn < DIV_BZ
      rest = dn - qn
      qh = recursive_div_qr_n(qp, np + rest, dp + rest, qn, dinv, tp)
      # The remainder so far is np[rest, qn] over the untouched np[0, rest];
      # subtract q * dp[0, rest] from np[0, dn].
      multiply(tp, qp, qn, dp, rest)
      borrow = Limbs.sub_n(np, np, tp, dn)
      borrow &+= Limbs.sub_n(np + qn, np + qn, dp, rest) if qh != 0
      while borrow != 0
        qh &-= Limbs.sub_1(qp, qp, qn, Limb.new(1))
        borrow &-= Limbs.add_n(np, np, dp, dn)
      end
      qh
    end

    # *rp* = the *an* limbs of *ap* times the *bn* limbs of *bp*
    # (`an + bn` limbs; either count may be the larger, and 0 gives zeros).
    def self.multiply(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Nil
      if an < bn
        ap, bp = bp, ap
        an, bn = bn, an
      end
      if bn == 0
        Limbs.zero(rp, an)
        return
      end
      {% if Crystal::BigNum.has_constant?("Multiply") %}
        Multiply.mul(rp, ap, an, bp, bn)
      {% else %}
        rp[an] = Limbs.mul_1(rp, ap, an, bp[0])
        index = 1
        while index < bn
          rp[an + index] = Limbs.addmul_1(rp + index, ap, an, bp[index])
          index += 1
        end
      {% end %}
    end

    # ---- The entry point ----

    # Divides the *nn* limbs of *np* by the *dn* limbs of *dp*
    # (`nn >= dn >= 1`, `dp[dn - 1] != 0`): writes the `nn - dn + 1` quotient
    # limbs to *qp* and the *dn* remainder limbs to *rp*. Neither output may
    # overlap an input; the inputs are left as they are.
    def self.div_qr(qp : Pointer(Limb), rp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32) : Nil
      if dn == 1
        rp[0] = divrem_1(qp, np, nn, dp[0])
        return
      end
      shift = dp[dn - 1].leading_zeros_count.to_i32
      # Scratch: the normalized numerator (nn + 1), the normalized divisor
      # (dn) and the recursion's scratch (dn).
      needed = nn + 1 + 2 * dn
      if needed <= STACK_LIMBS
        stack = uninitialized StaticArray(Limb, STACK_LIMBS)
        normalized_div_qr(qp, rp, np, nn, dp, dn, shift, stack.to_unsafe)
      else
        normalized_div_qr(qp, rp, np, nn, dp, dn, shift, Limbs.allocate(needed))
      end
    end

    private def self.normalized_div_qr(qp : Pointer(Limb), rp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32, shift : Int32, scratch : Pointer(Limb)) : Nil
      n2 = scratch
      d2 = scratch + (nn + 1)
      tp = d2 + dn
      if shift == 0
        Limbs.copy(n2, np, nn)
        d2 = dp
        count = nn
      else
        Limbs.lshift(d2, dp, dn, shift)
        n2[nn] = Limbs.lshift(n2, np, nn, shift)
        count = nn + 1
      end
      dinv = invert_pair(d2[dn - 1], d2[dn - 2])
      qh = if dn < DIV_BZ || count - dn < DIV_BZ
             schoolbook_div_qr(qp, n2, count, d2, dn, dinv)
           else
             recursive_div_qr(qp, n2, count, d2, dn, dinv, tp)
           end
      # With the extra limb the quotient has count - dn = nn - dn + 1 limbs
      # and qh is 0; without it qh is the top quotient limb.
      qp[nn - dn] = qh if shift == 0
      if shift == 0
        Limbs.copy(rp, n2, dn)
      else
        Limbs.rshift(rp, n2, dn, shift)
      end
    end

    # ---- Exact division ----

    # The inverse of the odd limb *d* modulo B, by Newton's iteration
    # (each step doubles the correct low bits; `d` itself is right to 3
    # bits, as `d * d = 1 (mod 8)`).
    def self.binvert_limb(d : Limb) : Limb
      inverse = d
      5.times { inverse = inverse &* (Limb.new(2) &- d &* inverse) }
      inverse
    end

    # Divides the *nn* limbs of *np* by the *dn* limbs of *dp*
    # (`nn >= dn >= 1`, `dp[dn - 1] != 0`) when the division is known to be
    # exact, writing the `nn - dn + 1` quotient limbs to *qp* (which must not
    # overlap the inputs). Jebelean's method: the quotient is found from the
    # low end, one limb at a time, each limb the low numerator limb times the
    # inverse of the divisor's low limb modulo B; only the low `nn - dn + 1`
    # limbs of the numerator take part.
    def self.divexact(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32) : Nil
      # Common low zero limbs, then the divisor's low zero bits, go first.
      while dp[0] == 0
        dp += 1
        np += 1
        dn -= 1
        nn -= 1
      end
      qn = nn - dn + 1
      shift = dp[0].trailing_zeros_count.to_i32
      work = Limbs.allocate(qn + 2 + Math.min(dn, qn))
      count = Math.min(nn, qn + 1)
      Limbs.copy(work, np, count)
      work[count] = Limb.zero if count == qn
      if shift != 0
        Limbs.rshift(work, work, qn + 1, shift)
        divisor = work + (qn + 1)
        used = Math.min(dn, qn)
        if dn > used
          # The bits of the next divisor limb shift into the last one used.
          Limbs.rshift(divisor, dp, used + 1, shift)
        else
          Limbs.rshift(divisor, dp, used, shift)
        end
        dp = divisor
        dn = used
      end
      inverse = binvert_limb(dp[0])
      index = 0
      while index < qn
        q = work[index] &* inverse
        qp[index] = q
        length = Math.min(dn, qn - index)
        borrow = Limbs.submul_1(work + index, dp, length, q)
        if index + length < qn
          Limbs.sub_1(work + index + length, work + index + length, qn - index - length, borrow)
        end
        index += 1
      end
    end
  end
end
