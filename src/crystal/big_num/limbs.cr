module Crystal::BigNum
  {% if flag?(:bits64) %}
    # :nodoc:
    alias Limb = UInt64
    # :nodoc:
    alias DoubleLimb = UInt128
  {% else %}
    # :nodoc:
    alias Limb = UInt32
    # :nodoc:
    alias DoubleLimb = UInt64
  {% end %}

  # :nodoc:
  LIMB_BITS = {{ flag?(:bits64) ? 64 : 32 }}

  # :nodoc:
  #
  # Kernels on runs of limbs, least significant limb first. Every kernel takes
  # raw pointers and a limb count, as GMP's `mpn` layer does, and leaves
  # allocation, signs and normalization of the result to its caller. Unless a
  # kernel says otherwise, the result may be the same run as an operand
  # (`rp == ap`), but must not overlap it any other way.
  #
  # The double-limb arithmetic is written with `DoubleLimb` so that LLVM
  # lowers it to the processor's carry chains (`adds`/`adcs` and `umulh` on
  # AArch64, `add`/`adc` and `mul`/`mulx` on x86-64). The inner loops are
  # unrolled by four.
  module Limbs
    # Adds the *n* limbs of *ap* and *bp* into *rp* and returns the carry
    # out (0 or 1).
    def self.add_n(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      {% if flag?(:x86_64) %}
        return add_n_with_adx(rp, ap, bp, n) if ProcessorKernels.adx?
      {% end %}
      generic_add_n(rp, ap, bp, n)
    end

    # The portable body of `add_n`. Each group of four limbs runs two carry
    # chains: the limb sums, which start fresh, and the incoming carry rippling
    # through them. Both lower to single runs of `adcs` on AArch64; a
    # three-term first sum would make LLVM split every step into two adds.
    @[AlwaysInline]
    def self.generic_add_n(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      carry = Limb.zero
      remaining = n
      while remaining >= 4
        sum = ap[0].to_u128! &+ bp[0]
        partial0 = sum.to_u64!
        sum = ap[1].to_u128! &+ bp[1] &+ (sum >> 64).to_u64!
        partial1 = sum.to_u64!
        sum = ap[2].to_u128! &+ bp[2] &+ (sum >> 64).to_u64!
        partial2 = sum.to_u64!
        sum = ap[3].to_u128! &+ bp[3] &+ (sum >> 64).to_u64!
        partial3 = sum.to_u64!
        carry_out = (sum >> 64).to_u64!
        sum = partial0.to_u128! &+ carry
        rp[0] = sum.to_u64!
        sum = partial1.to_u128! &+ (sum >> 64).to_u64!
        rp[1] = sum.to_u64!
        sum = partial2.to_u128! &+ (sum >> 64).to_u64!
        rp[2] = sum.to_u64!
        sum = partial3.to_u128! &+ (sum >> 64).to_u64!
        rp[3] = sum.to_u64!
        carry = carry_out | (sum >> 64).to_u64!
        ap += 4
        bp += 4
        rp += 4
        remaining &-= 4
      end
      while remaining > 0
        sum = ap[0].to_u128! &+ bp[0] &+ carry
        rp[0] = sum.to_u64!
        carry = (sum >> 64).to_u64!
        ap += 1
        bp += 1
        rp += 1
        remaining &-= 1
      end
      carry
    end

    # Subtracts the *n* limbs of *bp* from *ap* into *rp* and returns the
    # borrow out (0 or 1).
    def self.sub_n(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      {% if flag?(:x86_64) %}
        return sub_n_with_adx(rp, ap, bp, n) if ProcessorKernels.adx?
      {% end %}
      generic_sub_n(rp, ap, bp, n)
    end

    # The portable body of `sub_n`: `a - b - borrow` is `a + ~b + (1 - borrow)`
    # less the base, so it runs the two carry chains of `add_n` on `~b` with
    # the carry starting at 1, and the borrow is 1 less the carry out.
    @[AlwaysInline]
    def self.generic_sub_n(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      carry = Limb.new(1)
      remaining = n
      while remaining >= 4
        sum = ap[0].to_u128! &+ ~bp[0]
        partial0 = sum.to_u64!
        sum = ap[1].to_u128! &+ ~bp[1] &+ (sum >> 64).to_u64!
        partial1 = sum.to_u64!
        sum = ap[2].to_u128! &+ ~bp[2] &+ (sum >> 64).to_u64!
        partial2 = sum.to_u64!
        sum = ap[3].to_u128! &+ ~bp[3] &+ (sum >> 64).to_u64!
        partial3 = sum.to_u64!
        carry_out = (sum >> 64).to_u64!
        sum = partial0.to_u128! &+ carry
        rp[0] = sum.to_u64!
        sum = partial1.to_u128! &+ (sum >> 64).to_u64!
        rp[1] = sum.to_u64!
        sum = partial2.to_u128! &+ (sum >> 64).to_u64!
        rp[2] = sum.to_u64!
        sum = partial3.to_u128! &+ (sum >> 64).to_u64!
        rp[3] = sum.to_u64!
        carry = carry_out | (sum >> 64).to_u64!
        ap += 4
        bp += 4
        rp += 4
        remaining &-= 4
      end
      while remaining > 0
        sum = ap[0].to_u128! &+ ~bp[0] &+ carry
        rp[0] = sum.to_u64!
        carry = (sum >> 64).to_u64!
        ap += 1
        bp += 1
        rp += 1
        remaining &-= 1
      end
      Limb.new(1) &- carry
    end

    # Adds the single limb *b* to the *n* limbs of *ap* into *rp* and returns
    # the carry out. Once the carry stops, the rest of *ap* is copied.
    def self.add_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      carry = b
      index = 0
      while index < n
        sum = ap[index] &+ carry
        rp[index] = sum
        index += 1
        if sum >= carry
          (rp + index).copy_from(ap + index, n - index) unless rp == ap
          return Limb.zero
        end
        carry = Limb.new(1)
      end
      carry
    end

    # Subtracts the single limb *b* from the *n* limbs of *ap* into *rp* and
    # returns the borrow out. Once the borrow stops, the rest of *ap* is
    # copied.
    def self.sub_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      borrow = b
      index = 0
      while index < n
        limb = ap[index]
        rp[index] = limb &- borrow
        index += 1
        if limb >= borrow
          (rp + index).copy_from(ap + index, n - index) unless rp == ap
          return Limb.zero
        end
        borrow = Limb.new(1)
      end
      borrow
    end

    # Adds the *an* limbs of *ap* and the *bn* limbs of *bp* (`an >= bn`)
    # into the *an* limbs of *rp* and returns the carry out.
    def self.add(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Limb
      carry = add_n(rp, ap, bp, bn)
      add_1(rp + bn, ap + bn, an - bn, carry)
    end

    # Subtracts the *bn* limbs of *bp* from the *an* limbs of *ap*
    # (`an >= bn`) into the *an* limbs of *rp* and returns the borrow out.
    def self.sub(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Limb
      borrow = sub_n(rp, ap, bp, bn)
      sub_1(rp + bn, ap + bn, an - bn, borrow)
    end

    # Multiplies the *n* limbs of *ap* by the limb *b* into *rp* and returns
    # the high limb of the product.
    def self.mul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      {% if flag?(:x86_64) %}
        return mul_1_with_adx(rp, ap, n, b) if ProcessorKernels.adx?
      {% end %}
      generic_mul_1(rp, ap, n, b)
    end

    # The portable body of `mul_1`. Four products are formed first, then their
    # halves are summed in one carry chain (`adds`/`adcs` on AArch64), with the
    # pointers advanced rather than indexed so no bounds arithmetic sits in the
    # loop.
    @[AlwaysInline]
    def self.generic_mul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      carry = Limb.zero
      remaining = n
      while remaining >= 4
        product0 = ap[0].to_u128! &* b
        product1 = ap[1].to_u128! &* b
        product2 = ap[2].to_u128! &* b
        product3 = ap[3].to_u128! &* b
        sum = product0.to_u64!.to_u128! &+ carry
        rp[0] = sum.to_u64!
        sum = product1.to_u64!.to_u128! &+ (product0 >> 64).to_u64! &+ (sum >> 64).to_u64!
        rp[1] = sum.to_u64!
        sum = product2.to_u64!.to_u128! &+ (product1 >> 64).to_u64! &+ (sum >> 64).to_u64!
        rp[2] = sum.to_u64!
        sum = product3.to_u64!.to_u128! &+ (product2 >> 64).to_u64! &+ (sum >> 64).to_u64!
        rp[3] = sum.to_u64!
        carry = (product3 >> 64).to_u64! &+ (sum >> 64).to_u64!
        ap += 4
        rp += 4
        remaining &-= 4
      end
      while remaining > 0
        product = ap[0].to_u128! &* b &+ carry
        rp[0] = product.to_u64!
        carry = (product >> 64).to_u64!
        ap += 1
        rp += 1
        remaining &-= 1
      end
      carry
    end

    # Adds the product of the *n* limbs of *ap* and the limb *b* to the *n*
    # limbs of *rp* and returns the high limb that carries out.
    def self.addmul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      {% if flag?(:x86_64) %}
        return addmul_1_with_adx(rp, ap, n, b) if ProcessorKernels.adx?
      {% end %}
      generic_addmul_1(rp, ap, n, b)
    end

    # The portable body of `addmul_1`. Per group of four limbs: the four
    # products, then two separate carry chains, one summing the low halves with
    # the previous high halves and one adding that into *rp*. Each chain is a
    # single run of `adcs` on AArch64; the two carries meet only in the high
    # limb of the group, which cannot overflow.
    @[AlwaysInline]
    def self.generic_addmul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      carry = Limb.zero
      remaining = n
      while remaining >= 4
        product0 = ap[0].to_u128! &* b
        product1 = ap[1].to_u128! &* b
        product2 = ap[2].to_u128! &* b
        product3 = ap[3].to_u128! &* b
        sum = product0.to_u64!.to_u128! &+ carry
        term0 = sum.to_u64!
        sum = product1.to_u64!.to_u128! &+ (product0 >> 64).to_u64! &+ (sum >> 64).to_u64!
        term1 = sum.to_u64!
        sum = product2.to_u64!.to_u128! &+ (product1 >> 64).to_u64! &+ (sum >> 64).to_u64!
        term2 = sum.to_u64!
        sum = product3.to_u64!.to_u128! &+ (product2 >> 64).to_u64! &+ (sum >> 64).to_u64!
        term3 = sum.to_u64!
        high = (product3 >> 64).to_u64! &+ (sum >> 64).to_u64!
        sum = rp[0].to_u128! &+ term0
        rp[0] = sum.to_u64!
        sum = rp[1].to_u128! &+ term1 &+ (sum >> 64).to_u64!
        rp[1] = sum.to_u64!
        sum = rp[2].to_u128! &+ term2 &+ (sum >> 64).to_u64!
        rp[2] = sum.to_u64!
        sum = rp[3].to_u128! &+ term3 &+ (sum >> 64).to_u64!
        rp[3] = sum.to_u64!
        carry = high &+ (sum >> 64).to_u64!
        ap += 4
        rp += 4
        remaining &-= 4
      end
      while remaining > 0
        product = ap[0].to_u128! &* b &+ rp[0] &+ carry
        rp[0] = product.to_u64!
        carry = (product >> 64).to_u64!
        ap += 1
        rp += 1
        remaining &-= 1
      end
      carry
    end

    # Adds the product of the *n* limbs of *ap* (`n >= 1`) and the two limbs
    # at *bp* to the *n* limbs of *rp*, writes limb *n* of the sum to `rp[n]`
    # and returns limb `n + 1`. Two schoolbook rows in one pass: each limb of
    # *ap* and *rp* is loaded and stored once per two rows.
    #
    # Per group of four limbs the eight products are summed in four short
    # carry chains (row 0's halves, row 1's halves, the two rows, then *rp*)
    # that do not depend on the incoming carry; only the last chain adds the
    # two-limb carry, so the loop-carried path is one chain of four.
    def self.addmul_2(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, bp : Pointer(Limb)) : Limb
      b0 = bp[0]
      b1 = bp[1]
      state_low = Limb.zero
      state_high = Limb.zero
      remaining = n
      while remaining >= 4
        p0 = ap[0].to_u128! &* b0
        p1 = ap[1].to_u128! &* b0
        p2 = ap[2].to_u128! &* b0
        p3 = ap[3].to_u128! &* b0
        q0 = ap[0].to_u128! &* b1
        q1 = ap[1].to_u128! &* b1
        q2 = ap[2].to_u128! &* b1
        q3 = ap[3].to_u128! &* b1
        # row 0 at positions 0..4
        row0_0 = p0.to_u64!
        sum = p1.to_u64!.to_u128! &+ (p0 >> 64).to_u64!
        row0_1 = sum.to_u64!
        sum = p2.to_u64!.to_u128! &+ (p1 >> 64).to_u64! &+ (sum >> 64).to_u64!
        row0_2 = sum.to_u64!
        sum = p3.to_u64!.to_u128! &+ (p2 >> 64).to_u64! &+ (sum >> 64).to_u64!
        row0_3 = sum.to_u64!
        row0_4 = (p3 >> 64).to_u64! &+ (sum >> 64).to_u64!
        # row 1 at positions 1..5
        row1_1 = q0.to_u64!
        sum = q1.to_u64!.to_u128! &+ (q0 >> 64).to_u64!
        row1_2 = sum.to_u64!
        sum = q2.to_u64!.to_u128! &+ (q1 >> 64).to_u64! &+ (sum >> 64).to_u64!
        row1_3 = sum.to_u64!
        sum = q3.to_u64!.to_u128! &+ (q2 >> 64).to_u64! &+ (sum >> 64).to_u64!
        row1_4 = sum.to_u64!
        row1_5 = (q3 >> 64).to_u64! &+ (sum >> 64).to_u64!
        # both rows at positions 1..5 (the group's total is below B^6)
        sum = row0_1.to_u128! &+ row1_1
        rows_1 = sum.to_u64!
        sum = row0_2.to_u128! &+ row1_2 &+ (sum >> 64).to_u64!
        rows_2 = sum.to_u64!
        sum = row0_3.to_u128! &+ row1_3 &+ (sum >> 64).to_u64!
        rows_3 = sum.to_u64!
        sum = row0_4.to_u128! &+ row1_4 &+ (sum >> 64).to_u64!
        rows_4 = sum.to_u64!
        rows_5 = row1_5 &+ (sum >> 64).to_u64!
        # plus rp at positions 0..3
        sum = rp[0].to_u128! &+ row0_0
        limb0 = sum.to_u64!
        sum = rp[1].to_u128! &+ rows_1 &+ (sum >> 64).to_u64!
        limb1 = sum.to_u64!
        sum = rp[2].to_u128! &+ rows_2 &+ (sum >> 64).to_u64!
        limb2 = sum.to_u64!
        sum = rp[3].to_u128! &+ rows_3 &+ (sum >> 64).to_u64!
        limb3 = sum.to_u64!
        rp_carry = (sum >> 64).to_u64!
        # plus the carry in, at positions 0 and 1
        sum = limb0.to_u128! &+ state_low
        rp[0] = sum.to_u64!
        sum = limb1.to_u128! &+ state_high &+ (sum >> 64).to_u64!
        rp[1] = sum.to_u64!
        sum = limb2.to_u128! &+ (sum >> 64).to_u64!
        rp[2] = sum.to_u64!
        sum = limb3.to_u128! &+ (sum >> 64).to_u64!
        rp[3] = sum.to_u64!
        sum = rows_4.to_u128! &+ rp_carry &+ (sum >> 64).to_u64!
        state_low = sum.to_u64!
        state_high = rows_5 &+ (sum >> 64).to_u64!
        ap += 4
        rp += 4
        remaining &-= 4
      end
      while remaining > 0
        limb = ap[0]
        low = limb.to_u128! &* b0 &+ rp[0] &+ state_low
        rp[0] = low.to_u64!
        high = limb.to_u128! &* b1 &+ (low >> 64).to_u64! &+ state_high
        state_low = high.to_u64!
        state_high = (high >> 64).to_u64!
        ap += 1
        rp += 1
        remaining &-= 1
      end
      rp[0] = state_low
      state_high
    end

    # Subtracts the product of the *n* limbs of *ap* and the limb *b* from the
    # *n* limbs of *rp* and returns the high limb that borrows out.
    def self.submul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      {% if flag?(:x86_64) %}
        return submul_1_with_adx(rp, ap, n, b) if ProcessorKernels.adx?
      {% end %}
      generic_submul_1(rp, ap, n, b)
    end

    # The portable body of `submul_1`.
    @[AlwaysInline]
    def self.generic_submul_1(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
      carry = Limb.zero
      index = 0
      while index + 4 <= n
        {% for k in 0..3 %}
          product{{k}} = ap[index + {{k}}].to_u128! &* b &+ carry
          low{{k}} = product{{k}}.to_u64!
          limb{{k}} = rp[index + {{k}}]
          rp[index + {{k}}] = limb{{k}} &- low{{k}}
          carry = (product{{k}} >> 64).to_u64! &+ (limb{{k}} < low{{k}} ? 1_u64 : 0_u64)
        {% end %}
        index += 4
      end
      while index < n
        product = ap[index].to_u128! &* b &+ carry
        low = product.to_u64!
        limb = rp[index]
        rp[index] = limb &- low
        carry = (product >> 64).to_u64! &+ (limb < low ? 1_u64 : 0_u64)
        index += 1
      end
      carry
    end

    # Shifts the *n* limbs (`n >= 1`) of *ap* left by *count* bits
    # (`1 <= count < LIMB_BITS`) into *rp* and returns the bits shifted out at
    # the top, in the low bits of the result. *rp* may be *ap*, or above it.
    def self.lshift(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, count : Int32) : Limb
      back = LIMB_BITS - count
      high = ap[n - 1]
      out = high >> back
      index = n - 1
      while index >= 4
        {% for k in 1..4 %}
          low{{k}} = ap[index - {{k}}]
          rp[index - {{k}} + 1] = (high << count) | (low{{k}} >> back)
          high = low{{k}}
        {% end %}
        index -= 4
      end
      while index > 0
        low = ap[index - 1]
        rp[index] = (high << count) | (low >> back)
        high = low
        index -= 1
      end
      rp[0] = high << count
      out
    end

    # Shifts the *n* limbs (`n >= 1`) of *ap* right by *count* bits
    # (`1 <= count < LIMB_BITS`) into *rp* and returns the bits shifted out at
    # the bottom, in the high bits of the result. *rp* may be *ap*, or below
    # it.
    def self.rshift(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, count : Int32) : Limb
      back = LIMB_BITS - count
      low = ap[0]
      out = low << back
      index = 0
      while index + 5 <= n
        {% for k in 1..4 %}
          high{{k}} = ap[index + {{k}}]
          rp[index + {{k}} - 1] = (low >> count) | (high{{k}} << back)
          low = high{{k}}
        {% end %}
        index += 4
      end
      while index + 1 < n
        high = ap[index + 1]
        rp[index] = (low >> count) | (high << back)
        low = high
        index += 1
      end
      rp[n - 1] = low >> count
      out
    end

    # Compares the *n* limbs of *ap* and *bp* as unsigned numbers and returns
    # -1, 0 or 1.
    def self.cmp(ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Int32
      index = n - 1
      while index >= 0
        a = ap[index]
        b = bp[index]
        return a > b ? 1 : -1 if a != b
        index -= 1
      end
      0
    end

    # Returns *n* less the count of zero limbs at the top of *ap*.
    def self.normalize(ap : Pointer(Limb), n : Int32) : Int32
      while n > 0 && ap[n - 1] == 0
        n -= 1
      end
      n
    end

    # Whether all *n* limbs of *ap* are zero.
    def self.zero?(ap : Pointer(Limb), n : Int32) : Bool
      index = 0
      while index < n
        return false if ap[index] != 0
        index += 1
      end
      true
    end

    # The count of one bits in the *n* limbs of *ap*.
    def self.popcount(ap : Pointer(Limb), n : Int32) : UInt64
      total0 = total1 = total2 = total3 = 0_u64
      index = 0
      while index + 4 <= n
        total0 &+= ap[index].popcount
        total1 &+= ap[index + 1].popcount
        total2 &+= ap[index + 2].popcount
        total3 &+= ap[index + 3].popcount
        index += 4
      end
      while index < n
        total0 &+= ap[index].popcount
        index += 1
      end
      total0 &+ total1 &+ total2 &+ total3
    end

    # The index of the lowest one bit in the *n* limbs of *ap*, which must
    # not all be zero.
    def self.trailing_zeros(ap : Pointer(Limb), n : Int32) : UInt64
      index = 0
      while ap[index] == 0
        index += 1
      end
      index.to_u64 * LIMB_BITS + ap[index].trailing_zeros_count
    end

    # Writes the one's complement of the *n* limbs of *ap* into *rp*.
    def self.com(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      index = 0
      while index + 4 <= n
        rp[index] = ~ap[index]
        rp[index + 1] = ~ap[index + 1]
        rp[index + 2] = ~ap[index + 2]
        rp[index + 3] = ~ap[index + 3]
        index += 4
      end
      while index < n
        rp[index] = ~ap[index]
        index += 1
      end
    end

    {% for name, expression in {
                                 and_n:  "a & b",
                                 andn_n: "a & ~b",
                                 ior_n:  "a | b",
                                 iorn_n: "a | ~b",
                                 xor_n:  "a ^ b",
                               } %}
      # Writes `{{ expression.id }}` limb by limb for the *n* limbs of *ap*
      # (`a`) and *bp* (`b`) into *rp*.
      def self.{{ name.id }}(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Nil
        index = 0
        while index + 4 <= n
          {% for k in 0..3 %}
            a = ap[index + {{ k }}]
            b = bp[index + {{ k }}]
            rp[index + {{ k }}] = {{ expression.id }}
          {% end %}
          index += 4
        end
        while index < n
          a = ap[index]
          b = bp[index]
          rp[index] = {{ expression.id }}
          index += 1
        end
      end
    {% end %}

    # Copies *n* limbs from *ap* to *rp*; the runs may overlap.
    @[AlwaysInline]
    def self.copy(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      rp.move_from(ap, n)
    end

    # Writes *n* zero limbs at *rp*.
    @[AlwaysInline]
    def self.zero(rp : Pointer(Limb), n : Int32) : Nil
      rp.clear(n)
    end

    # A fresh run of *n* limbs from the collector's atomic heap (never
    # scanned for pointers). The limbs are not cleared.
    def self.allocate(n : Int32) : Pointer(Limb)
      GC.malloc_atomic(LibC::SizeT.new(n) * sizeof(Limb)).as(Pointer(Limb))
    end
  end
end
