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

# :nodoc:
#
# The bridge from the pure `BigFloat` to the GMP-backed `BigRational`, which
# stays on GMP until it moves to the engine too (relay piece G3b). A GMP
# float is built from a `BigFloat`'s limbs, and a `BigFloat` from a GMP
# float's limbs; either way the limbs are copied. `BigFloat` itself calls no
# GMP function.
struct BigFloat
  # :nodoc:
  #
  # A pointer to a fresh GMP float equal to `self`, with its precision.
  def to_unsafe : Pointer(LibGMP::MPF)
    Crystal::GMPAllocator.route_to_gc
    engine = big_num_value
    mpf = Pointer(LibGMP::MPF).malloc(1)
    LibGMP.mpf_init2(mpf, Crystal::BigNum::Float.bit_precision(engine.precision))
    count = engine.size
    mpf.value._mp_d.copy_from(engine.limbs.to_unsafe, count) if count > 0
    mpf.value._mp_size = engine.signed_size
    mpf.value._mp_exp = engine.exponent
    mpf
  end

  # :nodoc:
  #
  # Yields a pointer to a fresh GMP float (zero, at the default precision)
  # for the block to set, then returns its value.
  def self.new(& : Pointer(LibGMP::MPF) ->) : BigFloat
    Crystal::GMPAllocator.route_to_gc
    LibGMP.mpf_init2(out mpf, default_precision)
    yield pointerof(mpf)
    limbs = Slice.new(mpf._mp_d, mpf._mp_size.abs, read_only: true)
    new(Crystal::BigNum::Float.from_parts(limbs, mpf._mp_size < 0, mpf._mp_exp.to_i64, mpf._mp_prec))
  end
end
