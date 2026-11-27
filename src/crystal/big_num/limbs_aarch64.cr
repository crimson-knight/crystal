{% if flag?(:aarch64) %}
  module Crystal::BigNum::Limbs
    # `add_n` with its groups of four limbs in our own AArch64 assembly: one
    # `adcs` chain whose carry stays in the flags across the whole loop (the
    # counter uses `sub` and `cbnz`, which leave the flags alone). LLVM's
    # code for the generic body restarts the chain each group and ran at
    # half GMP's speed on Apple M4 (BIGNUM.md 4.8 allows assembly for a
    # kernel only on that evidence).
    def self.add_n_with_assembly(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      groups = (n >> 2).to_u64!
      carry = Limb.zero
      if groups > 0
        asm("
          mov x5, $1
          mov x6, $2
          mov x7, $3
          mov x8, $4
          cmn xzr, xzr
        1:
          ldp x9, x10, [x6], #16
          ldp x11, x12, [x6], #16
          ldp x13, x14, [x7], #16
          ldp x15, x16, [x7], #16
          adcs x9, x9, x13
          adcs x10, x10, x14
          adcs x11, x11, x15
          adcs x12, x12, x16
          stp x9, x10, [x5], #16
          stp x11, x12, [x5], #16
          sub x8, x8, #1
          cbnz x8, 1b
          cset $0, cs"
                : "=&r"(carry)
                : "r"(rp), "r"(ap), "r"(bp), "r"(groups)
                : "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "cc", "memory"
                : "volatile")
      end
      done = n & ~3
      generic_add_n(rp + done, ap + done, bp + done, n &- done, carry)
    end

    # `sub_n` with its groups of four limbs in our own AArch64 assembly (one
    # `sbcs` chain; see `add_n_with_assembly`).
    def self.sub_n_with_assembly(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
      groups = (n >> 2).to_u64!
      borrow = Limb.zero
      if groups > 0
        asm("
          mov x5, $1
          mov x6, $2
          mov x7, $3
          mov x8, $4
          cmp xzr, xzr
        1:
          ldp x9, x10, [x6], #16
          ldp x11, x12, [x6], #16
          ldp x13, x14, [x7], #16
          ldp x15, x16, [x7], #16
          sbcs x9, x9, x13
          sbcs x10, x10, x14
          sbcs x11, x11, x15
          sbcs x12, x12, x16
          stp x9, x10, [x5], #16
          stp x11, x12, [x5], #16
          sub x8, x8, #1
          cbnz x8, 1b
          cset $0, cc"
                : "=&r"(borrow)
                : "r"(rp), "r"(ap), "r"(bp), "r"(groups)
                : "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "cc", "memory"
                : "volatile")
      end
      done = n & ~3
      generic_sub_n(rp + done, ap + done, bp + done, n &- done, borrow)
    end
  end
{% end %}
