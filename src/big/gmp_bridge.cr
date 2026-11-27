require "big"

# :nodoc:
#
# The bridge between the pure `BigInt` and the GMP-backed `BigFloat` and
# `BigRational`, which stay on GMP until they move to the engine too. A GMP
# integer is built from a `BigInt`'s limbs, and a `BigInt` from a GMP
# integer's limbs; either way the limbs are copied, so nothing is shared.
# Loaded only in the default build (`-Duse_gmp` loads `src/big/gmp/`).
struct BigInt
  {% unless LibGMP::MpLimb == Crystal::BigNum::Limb %}
    {% raise "BigInt's GMP bridge needs GMP's limb (#{LibGMP::MpLimb}) to be the engine's limb (#{Crystal::BigNum::Limb})" %}
  {% end %}

  # :nodoc:
  #
  # Yields a pointer to a GMP integer equal to `self`, valid only inside the
  # block, and returns the block's value.
  def with_mpz(& : Pointer(LibGMP::MPZ) -> T) : T forall T
    mpz = to_mpz
    yield pointerof(mpz)
  end

  # :nodoc:
  #
  # A fresh GMP integer equal to `self`.
  def to_mpz : LibGMP::MPZ
    Crystal::GMPAllocator.route_to_gc
    limbs = @value.limbs
    count = limbs.size
    LibGMP.init2(out mpz, LibGMP::BitcntT.new((count + 1) * sizeof(LibGMP::MpLimb) * 8))
    if count > 0
      target = LibGMP.limbs_write(pointerof(mpz), LibGMP::MpSize.new(count))
      target.copy_from(limbs.to_unsafe, count)
    end
    LibGMP.limbs_finish(pointerof(mpz), LibGMP::MpSize.new(@value.negative? ? -count : count))
    mpz
  end

  # :nodoc:
  #
  # The value of the GMP integer *mpz*, with its limbs copied.
  def self.from_mpz(mpz : LibGMP::MPZ) : BigInt
    signed_size = mpz._mp_size
    limbs = Slice.new(mpz._mp_d, signed_size.abs, read_only: true)
    new(Crystal::BigNum::Integer.from_limbs(limbs, signed_size < 0))
  end

  # :nodoc:
  #
  # Yields a pointer to a fresh GMP integer (zero) for the block to set, then
  # returns its value.
  def self.from_mpz(& : Pointer(LibGMP::MPZ) ->) : BigInt
    Crystal::GMPAllocator.route_to_gc
    LibGMP.init(out mpz)
    yield pointerof(mpz)
    from_mpz(mpz)
  end
end

struct BigFloat
  # :nodoc:
  #
  # `{m, e}` with `self == m * 2**e` exactly (`{0, 0}` for zero): the seam
  # `BigRational.new(BigFloat)` reads. The pure `BigFloat` defines its own;
  # this one reads the GMP float's limbs, which are copied.
  def exact_binary : {BigInt, Int64}
    mpf = to_unsafe.value
    signed_size = mpf._mp_size
    return {BigInt.new, 0_i64} if signed_size == 0
    count = signed_size.abs
    limbs = Slice.new(mpf._mp_d, count, read_only: true)
    mantissa = BigInt.new(Crystal::BigNum::Integer.from_limbs(limbs, signed_size < 0))
    {mantissa, (mpf._mp_exp.to_i64 - count) * Crystal::BigNum::LIMB_BITS}
  end
end

struct BigRational
  # :nodoc:
  #
  # A fresh GMP rational equal to `self`, for the GMP-backed `BigFloat`'s
  # `mpf_set_q` (`BigFloat.new(BigRational)`) until `BigFloat` leaves GMP.
  def to_unsafe : Pointer(LibGMP::MPQ)
    Crystal::GMPAllocator.route_to_gc
    mpq = Pointer(LibGMP::MPQ).malloc(1)
    LibGMP.mpq_init(mpq)
    numerator.with_mpz { |mpz| LibGMP.mpq_set_num(mpq, mpz) }
    denominator.with_mpz { |mpz| LibGMP.mpq_set_den(mpq, mpz) }
    mpq
  end
end
