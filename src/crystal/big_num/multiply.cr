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
    @[AlwaysInline]
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
    # caller takes the general path. On x86-64 with BMI2 the routines compiled
    # for `+bmi2` run instead: `mulx` leaves the flags to the carry chains,
    # which LLVM then interleaves (about 2 ns faster for 4 by 4 on AMD Zen 3).
    @[AlwaysInline]
    protected def self.mul_small(rp : Pointer(Limb), ap : Pointer(Limb), an : Int32, bp : Pointer(Limb), bn : Int32) : Bool
      {% begin %}
      {% if flag?(:x86_64) %}
        if ProcessorKernels.adx?
          if an == 4 && bn == 4
            mul_4_by_4_with_assembly(rp, ap, bp)
            return true
          end
          case an &* 8 &+ bn
          {% for an in 1..4 %}
            {% for bn in 1..an %}
              when {{ an * 8 + bn }} then mul_{{ an }}_by_{{ bn }}_with_bmi2(rp, ap, bp)
            {% end %}
          {% end %}
          end
          return true
        end
      {% end %}
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
    # registers and chains the carries. Each pair of sizes has a body for
    # the baseline target and, on x86-64, one compiled for `+bmi2`.
    {% for an in 1..4 %}
      {% for bn in 1..an %}
        {% for variant in (flag?(:x86_64) ? ["", "_with_bmi2"] : [""]) %}
          {% if variant != "" %}@[TargetFeature("+bmi2")]{% end %}
          private def self.mul_{{ an }}_by_{{ bn }}{{ variant.id }}(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb)) : Nil
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
    {% end %}

    {% if flag?(:x86_64) %}
      # The 4 by 4 product in our own x86-64 assembly (BIGNUM.md 4.8: the
      # `+bmi2` body LLVM builds left `mul` at 256 bits at or just under GMP
      # on AMD Zen 3 and Intel Emerald Rapids). Row 0 is one `mulx` and
      # `add`/`adc` chain; each later row adds `a * b[j]` with two carry
      # chains at once, `adcx` (CF) for the low halves and `adox` (OF) for
      # the high halves, so no limb waits on the other chain. The result
      # limbs stay in registers until their row is done. Needs BMI2 and ADX
      # (`ProcessorKernels.adx?`).
      def self.mul_4_by_4_with_assembly(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb)) : Nil
        asm("
          movq (%rcx), %rdx
          mulxq (%rsi), %r8, %r9
          mulxq 8(%rsi), %rax, %r10
          addq %rax, %r9
          mulxq 16(%rsi), %rax, %r11
          adcq %rax, %r10
          mulxq 24(%rsi), %rax, %r12
          adcq %rax, %r11
          adcq $$0, %r12
          movq %r8, (%rdi)

          movq 8(%rcx), %rdx
          xorl %r13d, %r13d
          mulxq (%rsi), %rax, %rbx
          adcxq %rax, %r9
          adoxq %rbx, %r10
          mulxq 8(%rsi), %rax, %rbx
          adcxq %rax, %r10
          adoxq %rbx, %r11
          mulxq 16(%rsi), %rax, %rbx
          adcxq %rax, %r11
          adoxq %rbx, %r12
          mulxq 24(%rsi), %rax, %rbx
          adcxq %rax, %r12
          adoxq %rbx, %r13
          movl $$0, %eax
          adcxq %rax, %r13
          movq %r9, 8(%rdi)

          movq 16(%rcx), %rdx
          xorl %r14d, %r14d
          mulxq (%rsi), %rax, %rbx
          adcxq %rax, %r10
          adoxq %rbx, %r11
          mulxq 8(%rsi), %rax, %rbx
          adcxq %rax, %r11
          adoxq %rbx, %r12
          mulxq 16(%rsi), %rax, %rbx
          adcxq %rax, %r12
          adoxq %rbx, %r13
          mulxq 24(%rsi), %rax, %rbx
          adcxq %rax, %r13
          adoxq %rbx, %r14
          movl $$0, %eax
          adcxq %rax, %r14
          movq %r10, 16(%rdi)

          movq 24(%rcx), %rdx
          xorl %r15d, %r15d
          mulxq (%rsi), %rax, %rbx
          adcxq %rax, %r11
          adoxq %rbx, %r12
          mulxq 8(%rsi), %rax, %rbx
          adcxq %rax, %r12
          adoxq %rbx, %r13
          mulxq 16(%rsi), %rax, %rbx
          adcxq %rax, %r13
          adoxq %rbx, %r14
          mulxq 24(%rsi), %rax, %rbx
          adcxq %rax, %r14
          adoxq %rbx, %r15
          movl $$0, %eax
          adcxq %rax, %r15
          movq %r11, 24(%rdi)
          movq %r12, 32(%rdi)
          movq %r13, 40(%rdi)
          movq %r14, 48(%rdi)
          movq %r15, 56(%rdi)
        " :: "{rdi}"(rp), "{rsi}"(ap), "{rcx}"(bp) : "rax", "rbx", "rdx", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "cc", "memory")
      end
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
