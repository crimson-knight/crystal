module Crystal::BigNum
  # :nodoc:
  #
  # Multiplication and squaring of limb runs, schoolbook at every size (Knuth,
  # TAOCP Vol. 2, 4.3.1, Algorithm M): one `Limbs.mul_1` row for the lowest
  # limb of the shorter operand, then one `Limbs.addmul_1` row for each of its
  # other limbs. The rows run along the longer operand, so an unbalanced
  # product needs no special handling. Squaring has its own basecase: each
  # cross product once, then one pass that doubles them and adds the
  # diagonal squares. Operands of up to `SMALL_LIMBS` limbs (256 bits) take
  # fully unrolled routines that keep every limb in a register.
  #
  # Nothing here allocates; the caller owns the result buffer.
  module Multiply
    # Writes the `an + bn` limbs of the product of the *an* limbs of *ap* and
    # the *bn* limbs of *bp* into *rp*. Requires `an >= bn >= 1`; *rp* must
    # not overlap *ap* or *bp*.
    def self.mul(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Nil
      return if an <= SMALL_LIMBS && mul_small(rp, ap, an, bp, bn)
      rp[an] = Limbs.mul_1(rp, ap, an, bp[0])
      index = 1
      while index < bn
        rp[an &+ index] = Limbs.addmul_1(rp + index, ap, an, bp[index])
        index &+= 1
      end
    end

    # Writes the `2 * n` limbs of the square of the *n* limbs (`n >= 1`) of
    # *ap* into *rp*, which must not overlap *ap*.
    #
    # Row *i* adds `a[i] * a[i+1..]` at limb `2i + 1`, so the cross products
    # `a[i] * a[j]` (`i < j`) fill limbs 1 to `2n - 2`. The last pass shifts
    # them left by one bit and adds `a[i] ** 2` at limb `2i`.
    def self.sqr(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Nil
      return if n <= SMALL_LIMBS && sqr_small(rp, ap, n)
      rp[n] = Limbs.mul_1(rp + 1, ap + 1, n &- 1, ap[0])
      index = 1
      while index < n &- 1
        rp[n &+ index] = Limbs.addmul_1(rp + (2 &* index &+ 1), ap + (index &+ 1), n &- 1 &- index, ap[index])
        index &+= 1
      end
      rp[0] = Limb.zero
      rp[2 &* n &- 1] = Limb.zero
      shifted_in = Limb.zero
      carry = Limb.zero
      index = 0
      while index < n
        cross_low = rp[2 &* index]
        cross_high = rp[2 &* index &+ 1]
        doubled_low = (cross_low << 1) | shifted_in
        doubled_high = (cross_high << 1) | (cross_low >> (LIMB_BITS - 1))
        shifted_in = cross_high >> (LIMB_BITS - 1)
        limb = ap[index]
        diagonal = limb.to_u128! &* limb
        sum = doubled_low.to_u128! &+ diagonal.to_u64! &+ carry
        rp[2 &* index] = sum.to_u64!
        sum = doubled_high.to_u128! &+ (diagonal >> 64).to_u64! &+ (sum >> 64).to_u64!
        rp[2 &* index &+ 1] = sum.to_u64!
        carry = (sum >> 64).to_u64!
        index &+= 1
      end
    end

    # ---- Small operands ----

    # Operands of up to this many limbs multiply in straight-line code.
    SMALL_LIMBS = 4

    # Writes the product of *an* by *bn* limbs (`SMALL_LIMBS >= an >= bn`)
    # with one fully unrolled routine per pair of sizes, and returns true; for
    # any other pair of sizes it writes nothing and returns false, and the
    # caller takes the general path.
    @[AlwaysInline]
    protected def self.mul_small(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Bool
      {% begin %}
      case an &* 8 &+ bn
      {% for an in 1..4 %}
        {% for bn in 1..an %}
          when {{ an * 8 + bn }}
            mul_{{ an }}_by_{{ bn }}(rp, ap, bp)
            true
        {% end %}
      {% end %}
      else
        false
      end
      {% end %}
    end

    # Writes the square of *n* limbs (`SMALL_LIMBS >= n >= 1`) with one fully
    # unrolled routine per size, and returns true; for any other size it
    # writes nothing and returns false.
    @[AlwaysInline]
    protected def self.sqr_small(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32) : Bool
      {% begin %}
      case n
      {% for n in 1..4 %}
        when {{ n }}
          sqr_{{ n }}(rp, ap)
          true
      {% end %}
      else
        false
      end
      {% end %}
    end

    # The schoolbook rows of Algorithm M with every limb in a local: row *j*
    # adds `a * b[j]` at limb *j*, and LLVM keeps the running result in
    # registers and chains the carries.
    {% for an in 1..4 %}
      {% for bn in 1..an %}
        private def self.mul_{{ an }}_by_{{ bn }}(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb)) : Nil
          {% for i in 0...an %}
            a{{ i }} = ap[{{ i }}].to_u128!
          {% end %}
          {% for j in 0...bn %}
            b = bp[{{ j }}]
            carry = 0_u128
            {% for i in 0...an %}
              {% if j == 0 %}
                product = a{{ i }} &* b &+ carry
              {% else %}
                product = a{{ i }} &* b &+ r{{ i + j }} &+ carry
              {% end %}
              r{{ i + j }} = product.to_u64!.to_u128!
              carry = product >> 64
            {% end %}
            r{{ an + j }} = carry
          {% end %}
          {% for k in 0...(an + bn) %}
            rp[{{ k }}] = r{{ k }}.to_u64!
          {% end %}
        end
      {% end %}
    {% end %}

    # The basecase square with every limb in a local: the cross products
    # once, then doubled, then the diagonal squares added.
    {% for n in 1..4 %}
      private def self.sqr_{{ n }}(rp : Pointer(Limb), ap : Pointer(Limb)) : Nil
        {% for i in 0...n %}
          a{{ i }} = ap[{{ i }}].to_u128!
        {% end %}
        {% for k in 0...(2 * n) %}
          r{{ k }} = 0_u128
        {% end %}
        {% for i in 0...(n - 1) %}
          carry = 0_u128
          {% for j in (i + 1)...n %}
            product = a{{ i }} &* a{{ j }}.to_u64! &+ r{{ i + j }} &+ carry
            r{{ i + j }} = product.to_u64!.to_u128!
            carry = product >> 64
          {% end %}
          r{{ i + n }} = carry
        {% end %}
        shifted_in = 0_u128
        carry = 0_u128
        {% for i in 0...n %}
          doubled_low = ((r{{ 2 * i }} << 1) | shifted_in) & Limb::MAX
          doubled_high = ((r{{ 2 * i + 1 }} << 1) | (r{{ 2 * i }} >> 63)) & Limb::MAX
          shifted_in = r{{ 2 * i + 1 }} >> 63
          diagonal = a{{ i }} &* a{{ i }}.to_u64!
          sum = doubled_low &+ diagonal.to_u64! &+ carry
          rp[{{ 2 * i }}] = sum.to_u64!
          sum = doubled_high &+ (diagonal >> 64) &+ (sum >> 64)
          rp[{{ 2 * i + 1 }}] = sum.to_u64!
          carry = sum >> 64
        {% end %}
      end
    {% end %}
  end
end
