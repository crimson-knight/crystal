require "big"

# GMP entry points the harness needs as an oracle that `src/big/lib_gmp.cr`
# does not bind. GMP is a black-box oracle here only.
lib LibGMPHarness
  $gmp_version = __gmp_version : UInt8*
  fun powm = __gmpz_powm(rop : LibGMP::MPZ*, base : LibGMP::MPZ*, exp : LibGMP::MPZ*, mod : LibGMP::MPZ*)
  fun invert = __gmpz_invert(rop : LibGMP::MPZ*, op1 : LibGMP::MPZ*, op2 : LibGMP::MPZ*) : LibC::Int
  fun remove = __gmpz_remove(rop : LibGMP::MPZ*, op : LibGMP::MPZ*, f : LibGMP::MPZ*) : LibGMP::BitcntT
  fun fac_ui = __gmpz_fac_ui(rop : LibGMP::MPZ*, n : LibGMP::UI)
  fun divexact = __gmpz_divexact(q : LibGMP::MPZ*, n : LibGMP::MPZ*, d : LibGMP::MPZ*)
end

module G2Harness
  # Builds, reads and extends `BigInt` (GMP) values at the limb level.
  module GMPOracle
    def self.version : String
      String.new(LibGMPHarness.gmp_version)
    end

    # Builds a `BigInt` whose magnitude is *limbs* (least significant first)
    # and whose sign is *negative*. High zero limbs are allowed.
    def self.from_limbs(limbs : Slice(UInt64), negative : Bool) : BigInt
      size = limbs.size
      while size > 0 && limbs[size - 1] == 0
        size -= 1
      end
      LibGMP.init2(out mpz, (size + 1) * 64)
      if size > 0
        target = LibGMP.limbs_write(pointerof(mpz), size)
        target.copy_from(limbs.to_unsafe, size)
      end
      LibGMP.limbs_finish(pointerof(mpz), negative ? -size : size)
      BigInt.new(mpz)
    end

    # The magnitude limbs of *value*, least significant first, read from GMP.
    def self.limbs(value : BigInt) : Slice(UInt64)
      mpz = value.to_unsafe
      size = mpz.value._mp_size.abs
      Slice.new(mpz.value._mp_d, size, read_only: true)
    end

    def self.negative?(value : BigInt) : Bool
      value.to_unsafe.value._mp_size < 0
    end

    def self.pow_mod(base : BigInt, exponent : BigInt, modulus : BigInt) : BigInt
      BigInt.new { |mpz| LibGMPHarness.powm(mpz, base, exponent, modulus) }
    end

    # mpz_invert: nil when no inverse exists.
    def self.invert(value : BigInt, modulus : BigInt) : BigInt?
      result = BigInt.new
      found = LibGMPHarness.invert(result, value, modulus)
      found == 0 ? nil : result
    end

    # mpz_remove: removes every factor *factor* from *value*.
    def self.remove(value : BigInt, factor : BigInt) : {BigInt, UInt64}
      result = BigInt.new
      count = LibGMPHarness.remove(result, value, factor)
      {result, count.to_u64}
    end

    # mpz_divexact: *value* / *divisor* when the division is exact.
    def self.divexact(value : BigInt, divisor : BigInt) : BigInt
      BigInt.new { |mpz| LibGMPHarness.divexact(mpz, value, divisor) }
    end

    def self.factorial(n : UInt64) : BigInt
      BigInt.new { |mpz| LibGMPHarness.fac_ui(mpz, n) }
    end
  end
end
