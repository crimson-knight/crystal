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
  # | 2 limbs | `divrem_2`: Algorithm D reduced to one 3/2 division per quotient limb (same paper, algorithm 5) |
  # | 3 limbs and more | Knuth, TAOCP Vol. 2, 4.3.1, Algorithm D, each quotient limb estimated with the 3/2 reciprocal of the same paper (algorithm 5) |
  #
  # Values of at most two limbs are divided by `div_128_by_64` and
  # `div_128_by_128`, which use the processor's 64-bit divide and never
  # allocate.
  module Divide
    # The most limbs of scratch `div_qr` takes from the stack before it
    # allocates from the heap instead.
    STACK_LIMBS = 160

    # The largest divisor whose throwaway remainder `divexact` keeps on the
    # stack.
    private EXACT_STACK_LIMBS = 32

    private HALF_BITS = LIMB_BITS // 2
    private HALF_MASK = (Limb.new(1) << HALF_BITS) &- 1

    # ---- Two-limb by one-limb, without a reciprocal ----

    # Divides *u1*:*u0* (`u1 < d`) by the normalized limb *d* (top bit set);
    # returns the quotient and the remainder.
    #
    # On x86-64 this is one `div` instruction, which divides the two-limb
    # `rdx:rax` by a limb (our own assembly, BIGNUM.md 4.8: the bodies LLVM
    # builds from 64-bit divides left `tdiv_q_half` at 256 bits below GMP on
    # every x86-64 family measured). `u1 < d` keeps the quotient within a
    # limb, so the instruction cannot fault. Elsewhere, and with
    # `-Dbignum_generic_kernels`, `div_2by1_by_halves` runs.
    @[AlwaysInline]
    def self.div_2by1_plain(u1 : Limb, u0 : Limb, d : Limb) : {Limb, Limb}
      {% if flag?(:x86_64) && flag?(:bits64) && !flag?(:bignum_generic_kernels) %}
        quotient = uninitialized Limb
        remainder = uninitialized Limb
        asm("divq $4" : "={rax}"(quotient), "={rdx}"(remainder) : "{rax}"(u0), "{rdx}"(u1), "r"(d))
        {quotient, remainder}
      {% else %}
        div_2by1_by_halves(u1, u0, d)
      {% end %}
    end

    # `div_2by1_plain` with two hardware divides of a limb by a half limb:
    # Knuth's Algorithm D on half-limb digits, as Warren, *Hacker's Delight*
    # (2nd ed., 2013), 9-4 `divlu`.
    def self.div_2by1_by_halves(u1 : Limb, u0 : Limb, d : Limb) : {Limb, Limb}
      d_high = d >> HALF_BITS
      d_low = d & HALF_MASK
      u0_high = u0 >> HALF_BITS
      u0_low = u0 & HALF_MASK

      q1 = u1 // d_high
      rhat = u1 &- q1 &* d_high
      while q1 > HALF_MASK || q1 &* d_low > ((rhat << HALF_BITS) | u0_high)
        q1 &-= 1
        rhat &+= d_high
        break if rhat > HALF_MASK
      end
      middle = ((u1 << HALF_BITS) | u0_high) &- q1 &* d

      q0 = middle // d_high
      rhat = middle &- q0 &* d_high
      while q0 > HALF_MASK || q0 &* d_low > ((rhat << HALF_BITS) | u0_low)
        q0 &-= 1
        rhat &+= d_high
        break if rhat > HALF_MASK
      end
      remainder = ((middle << HALF_BITS) | u0_low) &- q0 &* d
      {(q1 << HALF_BITS) | q0, remainder}
    end

    # Divides the 128-bit *u* by the nonzero limb *d*; returns the quotient
    # and the remainder.
    def self.div_128_by_64(u : DoubleLimb, d : Limb) : {DoubleLimb, Limb}
      u1 = (u >> LIMB_BITS).to_u64!
      u0 = u.to_u64!
      return {DoubleLimb.new(u0 // d), u0 % d} if u1 == 0
      q1 = u1 // d
      r1 = u1 &- q1 &* d
      shift = d.leading_zeros_count.to_i32
      if shift == 0
        q0, r = div_2by1_plain(r1, u0, d)
      else
        q0, r = div_2by1_plain((r1 << shift) | (u0 >> (LIMB_BITS - shift)), u0 << shift, d << shift)
        r >>= shift
      end
      {(q1.to_u128! << LIMB_BITS) | q0, r}
    end

    # Divides the 128-bit *u* by the 128-bit *v* whose high limb is nonzero
    # (so the quotient fits a limb); returns the quotient and the remainder.
    # *Hacker's Delight* 9-5: the quotient of `u / 2` by the normalized top
    # limb of *v* is at most one too large.
    def self.div_128_by_128(u : DoubleLimb, v : DoubleLimb) : {Limb, DoubleLimb}
      shift = (v >> LIMB_BITS).to_u64!.leading_zeros_count.to_i32
      v_top = ((v << shift) >> LIMB_BITS).to_u64!
      half = u >> 1
      estimate, _ = div_2by1_plain((half >> LIMB_BITS).to_u64!, half.to_u64!, v_top)
      q = estimate >> (LIMB_BITS - 1 - shift)
      q &-= 1 if q != 0
      r = u &- v &* q
      if r >= v
        q &+= 1
        r &-= v
      end
      {q, r}
    end

    # ---- Reciprocals ----

    # The 2/1 reciprocal of the normalized limb *d* (top bit set):
    # `floor((B**2 - 1) / d) - B` with `B = 2**64`.
    def self.invert_limb(d : Limb) : Limb
      # (B**2 - 1) - B*d = (~d) * B + (B - 1), and ~d < d, so the quotient
      # fits a limb.
      div_2by1_plain(~d, Limb::MAX, d)[0]
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
      t1 = (product >> LIMB_BITS).to_u64!
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
      product = v.to_u128! &* u1 &+ ((u1.to_u128! << LIMB_BITS) | u0)
      q1 = (product >> LIMB_BITS).to_u64! &+ 1
      q0 = product.to_u64!
      r = u0 &- q1 &* d
      # The first correction is taken about half the time; written as
      # selects it stays off the branch predictor.
      over = r > q0
      q1 = over ? q1 &- 1 : q1
      r = over ? r &+ d : r
      # The second is rare (probability about 2**-64 per call).
      if r >= d
        q1 &+= 1
        r &-= d
      end
      {q1, r}
    end

    # Divides the three limbs *n2*:*n1*:*n0* (with `n2:n1 < d1:d0`) by the
    # normalized two-limb divisor *d1*:*d0* with its 3/2 reciprocal *v*;
    # returns the quotient limb and the two-limb remainder
    # (Möller-Granlund, algorithm 5).
    @[AlwaysInline]
    def self.div_3by2(n2 : Limb, n1 : Limb, n0 : Limb, d1 : Limb, d0 : Limb, v : Limb) : {Limb, DoubleLimb}
      product = v.to_u128! &* n2 &+ ((n2.to_u128! << LIMB_BITS) | n1)
      q1 = (product >> LIMB_BITS).to_u64!
      q0 = product.to_u64!
      r1 = n1 &- q1 &* d1
      divisor = (d1.to_u128! << LIMB_BITS) | d0
      remainder = ((r1.to_u128! << LIMB_BITS) | n0) &- divisor &- (d0.to_u128! &* q1)
      q1 &+= 1
      if (remainder >> LIMB_BITS).to_u64! >= q0
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

    # ---- Two-limb divisors ----

    # Divides the *n* limbs of *np* (`n >= 2`) by the two limbs of *dp*
    # (`dp[1] != 0`): writes the `n - 1` quotient limbs to *qp* (which must
    # not overlap *np*) and returns the remainder. Algorithm D with a
    # two-limb divisor needs no multiply-subtract: each step is one 3/2
    # division, and the dividend is normalized on the fly, with no scratch.
    def self.divrem_2(qp : Pointer(Limb), np : Pointer(Limb), n : Int32, dp : Pointer(Limb)) : DoubleLimb
      return divrem_2_of_four(qp, np, dp) if n == 4
      shift = dp[1].leading_zeros_count.to_i32
      divisor = ((dp[1].to_u128! << LIMB_BITS) | dp[0]) << shift
      d1 = (divisor >> LIMB_BITS).to_u64!
      d0 = divisor.to_u64!
      dinv = invert_pair(d1, d0)
      if shift == 0
        remainder = (np[n - 1].to_u128! << LIMB_BITS) | np[n - 2]
        if remainder >= divisor
          remainder &-= divisor
          qp[n - 2] = Limb.new(1)
        else
          qp[n - 2] = Limb.zero
        end
        index = n - 2
        while index > 0
          index -= 1
          q, remainder = div_3by2((remainder >> LIMB_BITS).to_u64!, remainder.to_u64!, np[index], d1, d0, dinv)
          qp[index] = q
        end
        remainder
      else
        back = LIMB_BITS - shift
        top = np[n - 1]
        below = np[n - 2]
        r1 = top >> back
        r0 = (top << shift) | (below >> back)
        index = n - 2
        while index >= 0
          next_limb = below << shift
          if index > 0
            below = np[index - 1]
            next_limb |= below >> back
          end
          q, remainder = div_3by2(r1, r0, next_limb, d1, d0, dinv)
          qp[index] = q
          r1 = (remainder >> LIMB_BITS).to_u64!
          r0 = remainder.to_u64!
          index -= 1
        end
        ((r1.to_u128! << LIMB_BITS) | r0) >> shift
      end
    end

    # `divrem_2` for a four-limb dividend (256 bits by 128), unrolled with
    # every limb in a register: three 3/2 divisions after the normalizing
    # shift, or a compare and two when the divisor is already normalized.
    private def self.divrem_2_of_four(qp : Pointer(Limb), np : Pointer(Limb), dp : Pointer(Limb)) : DoubleLimb
      shift = dp[1].leading_zeros_count.to_i32
      divisor = ((dp[1].to_u128! << LIMB_BITS) | dp[0]).unsafe_shl(shift)
      d1 = (divisor >> LIMB_BITS).to_u64!
      d0 = divisor.to_u64!
      dinv = invert_pair(d1, d0)
      n0, n1, n2, n3 = np[0], np[1], np[2], np[3]
      if shift == 0
        top = (n3.to_u128! << LIMB_BITS) | n2
        q2 = Limb.zero
        if top >= divisor
          top &-= divisor
          q2 = Limb.new(1)
        end
        q1, remainder = div_3by2((top >> LIMB_BITS).to_u64!, top.to_u64!, n1, d1, d0, dinv)
        q0, remainder = div_3by2((remainder >> LIMB_BITS).to_u64!, remainder.to_u64!, n0, d1, d0, dinv)
        qp[0], qp[1], qp[2] = q0, q1, q2
        remainder
      else
        back = LIMB_BITS - shift
        # The dividend shifted left: u4:u3:u2:u1:u0, with u4 below d1.
        u4 = n3.unsafe_shr(back)
        u3 = n3.unsafe_shl(shift) | n2.unsafe_shr(back)
        u2 = n2.unsafe_shl(shift) | n1.unsafe_shr(back)
        u1 = n1.unsafe_shl(shift) | n0.unsafe_shr(back)
        u0 = n0.unsafe_shl(shift)
        q2, remainder = div_3by2(u4, u3, u2, d1, d0, dinv)
        q1, remainder = div_3by2((remainder >> LIMB_BITS).to_u64!, remainder.to_u64!, u1, d1, d0, dinv)
        q0, remainder = div_3by2((remainder >> LIMB_BITS).to_u64!, remainder.to_u64!, u0, d1, d0, dinv)
        qp[0], qp[1], qp[2] = q0, q1, q2
        remainder.unsafe_shr(shift)
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
      return schoolbook_div_qr_by_four(qp, np, nn, dp, dinv) if dn == 4
      top = np + (nn - dn)
      qh = Limbs.cmp(top, dp, dn) >= 0 ? Limb.new(1) : Limb.zero
      Limbs.sub_n(top, top, dp, dn) if qh != 0
      d1 = dp[dn - 1]
      d0 = dp[dn - 2]
      n1 = np[nn - 1]
      index = nn - dn
      while index > 0
        index -= 1
        # The window is np[index, dn + 1]; its top limb is n1, kept in a
        # register (the stored copy is stale).
        window = np + index
        n_mid = window[dn - 1]
        if n1 == d1 && n_mid == d0
          # The 3/2 estimate needs n1:n_mid below the divisor's top limbs;
          # here the quotient limb is B - 1 and the window's top limb cancels.
          q = Limb::MAX
          Limbs.submul_1(window, dp, dn, q)
          n1 = window[dn - 1]
        else
          q, remainder = div_3by2(n1, n_mid, window[dn - 2], d1, d0, dinv)
          n1 = (remainder >> LIMB_BITS).to_u64!
          n0 = remainder.to_u64!
          # Short rows take the portable body inline, with no call.
          low_count = dn - 2
          borrow = low_count <= 4 ? Limbs.generic_submul_1(window, dp, low_count, q) : Limbs.submul_1(window, dp, low_count, q)
          borrow_out = n0 < borrow ? Limb.new(1) : Limb.zero
          n0 &-= borrow
          window[dn - 2] = n0
          borrow = n1 < borrow_out ? Limb.new(1) : Limb.zero
          n1 &-= borrow_out
          if borrow != 0
            # The estimate was one too large (Knuth's step D6): add the
            # divisor back.
            n1 &+= d1 &+ Limbs.add_n(window, window, dp, dn - 1)
            q &-= 1
          end
        end
        qp[index] = q
      end
      np[dn - 1] = n1
      qh
    end

    # `schoolbook_div_qr` for a four-limb divisor (256 bits), with the
    # divisor and the four-limb partial remainder in registers: each step
    # reads one dividend limb and writes one quotient limb, and the
    # remainder is stored once at the end.
    def self.schoolbook_div_qr_by_four(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dinv : Limb) : Limb
      d0, d1, d2, d3 = dp[0], dp[1], dp[2], dp[3]
      r0, r1, r2, r3 = np[nn - 4], np[nn - 3], np[nn - 2], np[nn - 1]
      # The top quotient limb: 1 when the top four dividend limbs reach the
      # divisor, which they then lose.
      qh = Limb.zero
      if r3 > d3 || (r3 == d3 && (r2 > d2 || (r2 == d2 && (r1 > d1 || (r1 == d1 && r0 >= d0)))))
        qh = Limb.new(1)
        r0, r1, r2, r3 = subtract_four(r0, r1, r2, r3, d0, d1, d2, d3)
      end
      index = nn - 4
      while index > 0
        index -= 1
        # The window is r3:r2:r1:r0:u, below the divisor times B.
        u = np[index]
        if r3 == d3 && r2 == d2
          # The quotient limb is B - 1 (see `schoolbook_div_qr`): the window
          # less (B - 1) * d is r2:r1:r0:u - d * B + d, whose top limb cancels.
          q = Limb::MAX
          sum0 = u.to_u128! &+ d0
          sum1 = r0.to_u128! &+ d1 &+ (sum0 >> 64)
          sum2 = r1.to_u128! &+ d2 &+ (sum1 >> 64)
          sum3 = r2.to_u128! &+ d3 &+ (sum2 >> 64)
          # Less d * B: subtract d0..d2 from limbs 1..3.
          r0, r1, r2, r3 = subtract_four(sum0.to_u64!, sum1.to_u64!, sum2.to_u64!, sum3.to_u64!, Limb.zero, d0, d1, d2)
        else
          q, remainder = div_3by2(r3, r2, r1, d3, d2, dinv)
          n1 = (remainder >> LIMB_BITS).to_u64!
          n0 = remainder.to_u64!
          # r0:u less q * d1:d0, the borrow carried into n1:n0.
          product0 = q.to_u128! &* d0
          low0 = product0.to_u64!
          t0 = u &- low0
          carry = (product0 >> LIMB_BITS).to_u64! &+ (u < low0 ? 1_u64 : 0_u64)
          product1 = q.to_u128! &* d1 &+ carry
          low1 = product1.to_u64!
          t1 = r0 &- low1
          borrow = (product1 >> LIMB_BITS).to_u64! &+ (r0 < low1 ? 1_u64 : 0_u64)
          borrow_out = n0 < borrow ? Limb.new(1) : Limb.zero
          n0 &-= borrow
          negative = n1 < borrow_out
          n1 &-= borrow_out
          if negative
            # The estimate was one too large (Knuth's step D6): add the
            # divisor back.
            sum0 = t0.to_u128! &+ d0
            sum1 = t1.to_u128! &+ d1 &+ (sum0 >> 64)
            sum2 = n0.to_u128! &+ d2 &+ (sum1 >> 64)
            t0 = sum0.to_u64!
            t1 = sum1.to_u64!
            n0 = sum2.to_u64!
            n1 &+= d3 &+ (sum2 >> 64).to_u64!
            q &-= 1
          end
          r0, r1, r2, r3 = t0, t1, n0, n1
        end
        qp[index] = q
      end
      np[0], np[1], np[2], np[3] = r0, r1, r2, r3
      qh
    end

    # `a3:a2:a1:a0 - b3:b2:b1:b0` modulo B**4, in registers.
    @[AlwaysInline]
    private def self.subtract_four(a0 : Limb, a1 : Limb, a2 : Limb, a3 : Limb, b0 : Limb, b1 : Limb, b2 : Limb, b3 : Limb) : {Limb, Limb, Limb, Limb}
      sum0 = a0.to_u128! &+ ~b0 &+ 1
      sum1 = a1.to_u128! &+ ~b1 &+ (sum0 >> 64)
      sum2 = a2.to_u128! &+ ~b2 &+ (sum1 >> 64)
      {sum0.to_u64!, sum1.to_u64!, sum2.to_u64!, a3 &+ ~b3 &+ (sum2 >> 64).to_u64!}
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
      if dn == 2
        remainder = divrem_2(qp, np, nn, dp)
        rp[0] = remainder.to_u64!
        rp[1] = (remainder >> LIMB_BITS).to_u64!
        return
      end
      # Scratch: the normalized numerator (nn + 1) and divisor (dn).
      needed = nn + 1 + dn
      if needed <= STACK_LIMBS
        stack = uninitialized StaticArray(Limb, STACK_LIMBS)
        normalized_div_qr(qp, rp, np, nn, dp, dn, stack.to_unsafe)
      else
        normalized_div_qr(qp, rp, np, nn, dp, dn, Limbs.allocate(needed))
      end
    end

    private def self.normalized_div_qr(qp : Pointer(Limb), rp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32, scratch : Pointer(Limb)) : Nil
      shift = dp[dn - 1].leading_zeros_count.to_i32
      n2 = scratch
      if shift == 0
        Limbs.copy(n2, np, nn)
        dinv = invert_pair(dp[dn - 1], dp[dn - 2])
        qp[nn - dn] = schoolbook_div_qr(qp, n2, nn, dp, dn, dinv)
        Limbs.copy(rp, n2, dn)
      else
        # With the extra numerator limb the top quotient limb is always 0,
        # and the quotient's nn - dn + 1 limbs all come from the loop.
        d2 = scratch + (nn + 1)
        Limbs.lshift(d2, dp, dn, shift)
        n2[nn] = Limbs.lshift(n2, np, nn, shift)
        dinv = invert_pair(d2[dn - 1], d2[dn - 2])
        schoolbook_div_qr(qp, n2, nn + 1, d2, dn, dinv)
        Limbs.rshift(rp, n2, dn, shift)
      end
    end

    # ---- Exact division ----

    # Divides the *nn* limbs of *np* by the *dn* limbs of *dp*
    # (`nn >= dn >= 1`, `dp[dn - 1] != 0`) when the division is known to be
    # exact, writing the `nn - dn + 1` quotient limbs to *qp* (which must not
    # overlap the inputs). The division is the plain one (`divrem_1`, or
    # Algorithm D through `div_qr`) with the remainder thrown away.
    def self.divexact(qp : Pointer(Limb), np : Pointer(Limb), nn : Int32, dp : Pointer(Limb), dn : Int32) : Nil
      # Common low zero limbs go first: they shorten both operands and leave
      # the quotient as it is.
      while dp[0] == 0
        dp += 1
        np += 1
        dn -= 1
        nn -= 1
      end
      if dn == 1
        divrem_1(qp, np, nn, dp[0])
      elsif dn <= EXACT_STACK_LIMBS
        remainder = uninitialized StaticArray(Limb, EXACT_STACK_LIMBS)
        div_qr(qp, remainder.to_unsafe, np, nn, dp, dn)
      else
        div_qr(qp, Limbs.allocate(dn), np, nn, dp, dn)
      end
    end
  end
end
