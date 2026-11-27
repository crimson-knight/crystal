require "spec"

# GMP's `BigInt` is the oracle in these examples, and only `-Duse_gmp` keeps
# `BigInt` on GMP; the default build puts it on the engine under test.
{% if flag?(:use_gmp) %}
  require "big"
  require "crystal/big_num"

  # GMP (through the GMP-backed `BigInt` and `LibGMP`) is the oracle throughout.
  private alias Integer = Crystal::BigNum::Integer
  private alias Limb = Crystal::BigNum::Limb

  private def integer(value : BigInt) : Integer
    limbs = [] of Limb
    magnitude = value.abs
    while magnitude > 0
      limbs << (magnitude & UInt64::MAX).to_u64
      magnitude >>= 64
    end
    Integer.from_limbs(Slice.new(limbs.to_unsafe, limbs.size), value < 0)
  end

  private def integer(value : Int) : Integer
    integer(value.to_big_i)
  end

  private def big(value : Integer) : BigInt
    result = BigInt.new(0)
    value.limbs.reverse_each { |limb| result = (result << 64) | limb }
    value.negative? ? -result : result
  end

  # A random value of *bits* bits (top bit set), dense or with long runs.
  private def random_big(random : Random, bits : Int32) : BigInt
    return BigInt.new(0) if bits <= 0
    value = BigInt.new(0)
    ((bits + 63) // 64).times do
      limb = case random.rand(4)
             when 0 then UInt64::MAX
             when 1 then random.rand(UInt64) & random.rand(UInt64)
             else        random.rand(UInt64)
             end
      value = (value << 64) | limb
    end
    value &= (BigInt.new(1) << bits) - 1
    value | (BigInt.new(1) << (bits - 1))
  end

  # Bit sizes at and around the limb boundaries the code branches on.
  private SIZES = [1, 2, 31, 32, 33, 61, 62, 63, 64, 65, 96, 126, 127, 128, 129, 191, 192, 193, 255, 256, 257, 320, 512, 1_000, 2_048, 4_096]

  private def gmp_invert(value : BigInt, modulus : BigInt) : BigInt?
    result = BigInt.new
    LibGMP.invert(result, value, modulus) == 0 ? nil : result
  end

  private def gmp_remove(value : BigInt, factor : BigInt) : {BigInt, UInt64}
    result = BigInt.new
    count = LibGMP.remove(result, value, factor)
    {result, count.to_u64}
  end

  describe Crystal::BigNum::NumberTheory do
    describe "**" do
      it "follows BigInt at the edges" do
        big(integer(0) ** 0).should eq(1)
        big(integer(0) ** 5).should eq(0)
        big(integer(7) ** 0).should eq(1)
        big(integer(-7) ** 1).should eq(-7)
        big(integer(-1) ** 1_000_001).should eq(-1)
        big(integer(-1) ** 1_000_000).should eq(1)
        big(integer(2) ** 127).should eq(BigInt.new(2) ** 127)
        big(integer(2) ** 128).should eq(BigInt.new(2) ** 128)
        big(integer(-2) ** 1_001).should eq(BigInt.new(-2) ** 1_001)
        big(integer(-12) ** 41).should eq(BigInt.new(-12) ** 41)
        big(integer(UInt64::MAX) ** 2).should eq(UInt64::MAX.to_big_i ** 2)
        big(integer(3) ** 80).should eq(BigInt.new(3) ** 80)
        big(integer(3) ** 81).should eq(BigInt.new(3) ** 81)
      end

      it "raises for a negative exponent as BigInt does" do
        expect_raises(ArgumentError, "Negative exponent isn't supported") { integer(3) ** -1 }
      end

      it "matches GMP on random bases and exponents" do
        random = Random::PCG32.new(1_u64)
        SIZES.each do |bits|
          [2, 3, 5, 7, 16, 33].each do |exponent|
            base = random_big(random, bits)
            base = -base if random.next_bool
            base <<= random.rand(70) if random.rand(3) == 0
            big(integer(base) ** exponent).should eq(base ** exponent)
          end
        end
      end
    end

    describe ".factorial" do
      it "matches GMP from 0 to 300" do
        (0..300).each do |n|
          big(Integer.factorial(n)).should eq(n.to_big_i.factorial)
        end
      end

      it "shares the table's values up to 57!" do
        Integer.factorial(57).should eq(Integer.factorial(57))
        big(Integer.factorial(57_u64)).should eq(BigInt.new(57).factorial)
        big(Integer.factorial(58_u8)).should eq(BigInt.new(58).factorial)
      end

      it "raises as BigInt#factorial does" do
        expect_raises(ArgumentError, "Factorial not defined for negative values") { Integer.factorial(-1) }
        expect_raises(ArgumentError, "Factorial not supported for numbers bigger than #{UInt64::MAX}") do
          Integer.factorial(UInt64::MAX.to_u128 + 1)
        end
      end
    end

    describe "gcd" do
      it "is never negative and treats zero as GMP does" do
        big(integer(0).gcd(integer(0))).should eq(0)
        big(integer(0).gcd(integer(-12))).should eq(12)
        big(integer(-12).gcd(integer(0))).should eq(12)
        big(integer(-12).gcd(integer(-18))).should eq(6)
        big(integer(-(BigInt.new(1) << 200)).gcd(integer(0))).should eq(BigInt.new(1) << 200)
        big(integer(BigInt.new(1) << 200).gcd(integer(BigInt.new(1) << 130))).should eq(BigInt.new(1) << 130)
      end

      it "takes primitive arguments" do
        big(integer(BigInt.new(10) ** 30).gcd(-(10_i64 ** 18))).should eq(BigInt.new(10) ** 18)
        big(integer(36).gcd(0)).should eq(36)
        big(integer(36).gcd(UInt128::MAX)).should eq(3)
      end

      it "handles two-limb operands whose low limbs are equal" do
        random = Random::PCG32.new(12_u64)
        200.times do
          low = BigInt.new(random.rand(UInt64) | 1)
          a = (BigInt.new(random.rand(UInt64)) << 64) | low
          b = (BigInt.new(random.rand(UInt64) >> random.rand(64)) << 64) | low
          big(integer(a).gcd(integer(b))).should eq(a.gcd(b))
          big(integer(a).gcd(integer(a))).should eq(a)
        end
      end

      it "matches GMP on random and shared-factor operands" do
        random = Random::PCG32.new(2_u64)
        SIZES.each do |a_bits|
          SIZES.each do |b_bits|
            a = random_big(random, a_bits)
            b = random_big(random, b_bits)
            shared = random_big(random, 1 + random.rand(200))
            [{a, b}, {a * shared, b * shared}, {-a << 3, b << 70}].each do |x, y|
              big(integer(x).gcd(integer(y))).should eq(x.gcd(y))
            end
          end
        end
      end
    end

    describe "lcm" do
      it "is zero with a zero operand and never negative" do
        big(integer(0).lcm(integer(5))).should eq(0)
        big(integer(-4).lcm(integer(0))).should eq(0)
        big(integer(-4).lcm(integer(6))).should eq(12)
        big(integer(-4).lcm(-6)).should eq(12)
      end

      it "matches GMP on random operands" do
        random = Random::PCG32.new(3_u64)
        SIZES.each do |a_bits|
          SIZES.each do |b_bits|
            a = random_big(random, a_bits)
            b = random_big(random, b_bits)
            b = -b if random.next_bool
            big(integer(a).lcm(integer(b))).should eq(a.lcm(b))
          end
        end
      end
    end

    describe "invert" do
      it "follows mpz_invert at the edges" do
        integer(3).invert(integer(0)).should be_nil
        integer(0).invert(integer(0)).should be_nil
        big(integer(5).invert(integer(1)).not_nil!).should eq(0)
        big(integer(5).invert(integer(-1)).not_nil!).should eq(0)
        big(integer(0).invert(integer(1)).not_nil!).should eq(0)
        integer(0).invert(integer(5)).should be_nil
        integer(2).invert(integer(4)).should be_nil
        big(integer(3).invert(integer(-7)).not_nil!).should eq(5)
        big(integer(-3).invert(integer(7)).not_nil!).should eq(2)
        integer(BigInt.new(1) << 300).invert(integer(BigInt.new(1) << 200)).should be_nil
      end

      it "matches GMP on random operands" do
        random = Random::PCG32.new(4_u64)
        SIZES.each do |m_bits|
          SIZES.each do |a_bits|
            modulus = random_big(random, m_bits)
            modulus = -modulus if random.next_bool
            value = random_big(random, a_bits)
            value = -value if random.next_bool
            ours = integer(value).invert(integer(modulus))
            theirs = gmp_invert(value, modulus)
            (ours ? big(ours) : nil).should eq(theirs)
            # The odd neighbor of the modulus is invertible far more often.
            odd = modulus | 1
            ours = integer(value).invert(integer(odd))
            theirs = gmp_invert(value, odd)
            (ours ? big(ours) : nil).should eq(theirs)
          end
        end
      end
    end

    describe "isqrt" do
      it "raises for a negative value as Math.isqrt does" do
        expect_raises(ArgumentError, "Input must be non-negative integer") { integer(-4).isqrt }
      end

      it "matches GMP at squares, their neighbors and all-ones values" do
        [0, 1, 2, 3, 4, 63, 64, 65, 127, 128, 129, 191, 192, 255, 256, 257, 511, 512, 513, 1_024, 4_096].each do |bits|
          all_ones = (BigInt.new(1) << bits) - 1
          [all_ones, all_ones + 1, all_ones + 2].each do |value|
            big(integer(value).isqrt).should eq(Math.isqrt(value))
          end
          root = all_ones >> (bits // 2)
          [root * root - 1, root * root, root * root + 1, (root + 1) * (root + 1) - 1].each do |value|
            next if value < 0
            big(integer(value).isqrt).should eq(Math.isqrt(value))
          end
        end
      end

      it "matches GMP on three and four limbs at every bit length and every root shape" do
        # Every normalizing shift, the largest and smallest roots of each
        # length (estimates at the 2**64 clamp), squares and their
        # neighbors, and remainders of exactly 2 * root.
        random = Random::PCG32.new(192_u64)
        (129..256).each do |bits|
          low = BigInt.new(1) << (bits - 1)
          high = (BigInt.new(1) << bits) - 1
          [low, low + 1, high, high - 1].each do |value|
            big(integer(value).isqrt).should eq(Math.isqrt(value))
          end
          8.times do
            root = Math.isqrt(random_big(random, bits))
            [root * root - 1, root * root, root * root + 1, root * root + 2 * root].each do |value|
              next unless value.bit_length.in?(129..256)
              big(integer(value).isqrt).should eq(Math.isqrt(value))
            end
          end
        end
      end

      it "matches GMP on random values" do
        random = Random::PCG32.new(5_u64)
        (1..300).each do |bits|
          value = random_big(random, bits)
          big(integer(value).isqrt).should eq(Math.isqrt(value))
        end
        SIZES.each do |bits|
          10.times do
            value = random_big(random, bits)
            big(integer(value).isqrt).should eq(Math.isqrt(value))
          end
        end
      end
    end

    describe "remove" do
      it "follows mpz_remove at the edges" do
        expect_raises(DivisionByZeroError) { integer(7).remove(integer(0)) }
        value, count = integer(0).remove(integer(5))
        {big(value), count}.should eq({BigInt.new(0), 0_u64})
        value, count = integer(-7).remove(integer(-1))
        {big(value), count}.should eq({BigInt.new(-7), 0_u64})
        value, count = integer(7).remove(integer(1))
        {big(value), count}.should eq({BigInt.new(7), 0_u64})
        value, count = integer(80).remove(integer(-2))
        {big(value), count}.should eq({BigInt.new(5), 4_u64})
        value, count = integer(-40).remove(integer(-2))
        {big(value), count}.should eq({BigInt.new(5), 3_u64})
        value, count = integer(-24).remove(integer(-2))
        {big(value), count}.should eq({BigInt.new(3), 3_u64})
      end

      it "removes powers of ten as BigDecimal's normalization needs" do
        [64, 128, 192, 256, 512, 4_096].each do |bits|
          (0..60).step(7).each do |zeros|
            value = (BigInt.new(10) ** zeros) * 7 + (BigInt.new(10) ** zeros) * random_big(Random::PCG32.new(bits.to_u64), bits)
            ours, count = integer(value).remove(integer(10))
            {big(ours), count}.should eq(gmp_remove(value, BigInt.new(10)))
          end
        end
      end

      it "matches GMP on random values and factors" do
        random = Random::PCG32.new(6_u64)
        factors = [2, 3, 5, 6, 7, 10, 12, 16, 100, 1_000, 65_537, 1_000_000_007, 4_294_967_291, 4_294_967_311, UInt64::MAX - 58]
        factors.each do |small|
          SIZES.each do |bits|
            factor = BigInt.new(small)
            factor = -factor if random.next_bool
            value = random_big(random, bits) * factor ** random.rand(0..40)
            value = -value if random.next_bool
            ours, count = integer(value).remove(integer(factor))
            {big(ours), count}.should eq(gmp_remove(value, factor))
          end
        end
        [65, 128, 129, 191].each do |factor_bits|
          factor = random_big(random, factor_bits)
          value = random_big(random, 300) * factor ** 5
          ours, count = integer(value).remove(integer(-factor))
          {big(ours), count}.should eq(gmp_remove(value, -factor))
        end
      end
    end
  end
{% else %}
  pending "Crystal::BigNum number theory (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
