# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"
require "crystal/big_num"

# The examples above the `-Duse_gmp` guard check the engine against itself and
# run in every build. Below the guard GMP's `BigInt` is the oracle, and only
# `-Duse_gmp` keeps `BigInt` on GMP; the default build puts it on the engine
# under test.

private alias Integer = Crystal::BigNum::Integer
private alias Limb = Crystal::BigNum::Limb
private alias Divide = Crystal::BigNum::Divide

private def integer(limbs : Array(Limb), negative = false) : Integer
  Integer.from_limbs(Slice.new(limbs.to_unsafe, limbs.size), negative)
end

private def random_limbs(random, count) : Array(Limb)
  limbs = Array(Limb).new(count) { random.rand(Limb) }
  limbs[-1] |= 1_u64 << random.rand(64) if count > 0
  limbs
end

describe Crystal::BigNum::Integer do
  it "divides values of up to 128 bits with no heap allocation" do
    values = [Integer.new(UInt128::MAX), Integer.new(-(Int128::MAX // 3)), Integer.new(UInt64::MAX), Integer.new(-7), Integer.new((1_u128 << 64) + 5)]
    divisors = [Integer.new(3), Integer.new(-(1_i128 << 70) - 1), Integer.new(UInt64::MAX - 2), Integer.new(UInt128::MAX >> 1)]
    sink = 0_u64
    # Warm up first, so nothing lazily set up is counted.
    values.each { |a| divisors.each { |b| sink &+= a.divmod(b)[1].to_u64! } }
    before = GC.stats.total_bytes
    1_000.times do
      values.each do |a|
        divisors.each do |b|
          q, r = a.divmod(b)
          sink &+= q.to_u64! &+ r.to_u64!
          q, r = a.tdivmod(b)
          sink &+= q.to_u64! &+ r.to_u64! &+ (a % 7).to_u64! &+ a.tdiv(-5).to_u64!
          sink &+= 1 if a.divisible_by?(b)
        end
      end
    end
    # 28,000 calls; one allocation per call would be 16 bytes or more
    # each. The runner itself may take a few bytes meanwhile.
    (GC.stats.total_bytes - before).should be < 1_000
    sink.should_not eq(0)
  end

  it "raises DivisionByZeroError for a zero divisor in every variant" do
    x = integer([1_u64, 2_u64, 3_u64])
    zero = Integer.zero
    {x, Integer.new(-5), zero}.each do |value|
      expect_raises(DivisionByZeroError) { value // zero }
      expect_raises(DivisionByZeroError) { value % zero }
      expect_raises(DivisionByZeroError) { value.tdiv(zero) }
      expect_raises(DivisionByZeroError) { value.remainder(zero) }
      expect_raises(DivisionByZeroError) { value.divmod(zero) }
      expect_raises(DivisionByZeroError) { value.tdivmod(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_floored_div(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_floored_mod(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_floored_divmod(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_truncated_div(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_truncated_mod(zero) }
      expect_raises(DivisionByZeroError) { value.unsafe_truncated_divmod(zero) }
      expect_raises(DivisionByZeroError) { value // 0 }
      expect_raises(DivisionByZeroError) { value.unsafe_truncated_divmod(0_u8) }
      expect_raises(DivisionByZeroError) { value.divexact(zero) }
    end
  end

  it "answers divisible_by? as GMP's divisible_p, zero divisor included" do
    Integer.zero.divisible_by?(Integer.zero).should be_true
    Integer.new(3).divisible_by?(Integer.zero).should be_false
    Integer.new(3).divisible_by?(0).should be_false
    big_power = integer([0_u64, 0_u64, 1_u64 << 5])
    big_power.divisible_by?(integer([0_u64, 1_u64])).should be_true
    big_power.divisible_by?(integer([0_u64, 0_u64, 1_u64 << 6])).should be_false
    (big_power + Integer.new(1 << 20)).divisible_by?(1 << 21).should be_false
    integer([0_u64, 0_u64, 3_u64]).divisible_by?(-3).should be_true
  end
end

{% if flag?(:use_gmp) %}
  require "big"

  # GMP (through the GMP-backed `BigInt`) is the oracle throughout.

  private def integer(value : BigInt) : Integer
    limbs = [] of Limb
    magnitude = value.abs
    while magnitude > 0
      limbs << (magnitude & UInt64::MAX).to_u64
      magnitude >>= 64
    end
    integer(limbs, value < 0)
  end

  private def big(value : Integer) : BigInt
    result = BigInt.new(0)
    value.limbs.reverse_each { |limb| result = (result << 64) | limb }
    value.negative? ? -result : result
  end

  # Checks every Integer-divisor variant of *a* by *b* against GMP.
  private def check_all_variants(a : BigInt, b : BigInt)
    x = integer(a)
    y = integer(b)
    q, r = x.divmod(y)
    {big(q), big(r)}.should eq(a.divmod(b))
    q, r = x.tdivmod(y)
    {big(q), big(r)}.should eq(a.unsafe_truncated_divmod(b))
    big(x // y).should eq(a // b)
    big(x % y).should eq(a % b)
    big(x.tdiv(y)).should eq(a.tdiv(b))
    big(x.remainder(y)).should eq(a.remainder(b))
    big(x.unsafe_floored_div(y)).should eq(a.unsafe_floored_div(b))
    big(x.unsafe_floored_mod(y)).should eq(a.unsafe_floored_mod(b))
    big(x.unsafe_truncated_div(y)).should eq(a.unsafe_truncated_div(b))
    big(x.unsafe_truncated_mod(y)).should eq(a.unsafe_truncated_mod(b))
    q, r = x.unsafe_floored_divmod(y)
    {big(q), big(r)}.should eq(a.unsafe_floored_divmod(b))
    q, r = x.unsafe_truncated_divmod(y)
    {big(q), big(r)}.should eq(a.unsafe_truncated_divmod(b))
    x.divisible_by?(y).should eq(a.divisible_by?(b))
  end

  private def signed_pairs(a : BigInt, b : BigInt)
    [{a, b}, {-a, b}, {a, -b}, {-a, -b}]
  end

  describe Crystal::BigNum::Divide do
    it "divides two limbs by one with the hardware divide (div_2by1_plain and the half-limb body)" do
      random = Random::PCG32.new(17)
      divisors = [1_u64 << 63, (1_u64 << 63) + 1, UInt64::MAX, UInt64::MAX - 1, 0x8000_0001_0000_0000_u64, 0xffff_ffff_0000_0000_u64]
      20.times { divisors << (random.rand(UInt64) | (1_u64 << 63)) }
      divisors.each do |d|
        highs = [0_u64, 1_u64, d - 1, d >> 1, d >> 32]
        5.times { highs << random.rand(d) }
        highs.each do |u1|
          [0_u64, UInt64::MAX, 1_u64 << 32, (1_u64 << 32) - 1, random.rand(UInt64)].each do |u0|
            q, r = Divide.div_2by1_plain(u1, u0, d)
            dividend = (BigInt.new(u1) << 64) + u0
            q.should eq(dividend // d)
            r.should eq(dividend % d)
            Divide.div_2by1_by_halves(u1, u0, d).should eq({q, r})
          end
        end
      end
    end

    it "divides 128-bit values by 64-bit and 128-bit ones" do
      random = Random::PCG32.new(19)
      values = [0_u128, 1_u128, UInt64::MAX.to_u128, UInt64::MAX.to_u128 + 1, UInt128::MAX, UInt128::MAX - 1, 1_u128 << 127, (1_u128 << 127) - 1]
      200.times { values << (random.rand(UInt128) >> random.rand(128)) }
      values.each do |u|
        values.each do |v|
          next if v == 0
          if v >> 64 == 0
            q, r = Divide.div_128_by_64(u, v.to_u64)
            BigInt.new(q).should eq(BigInt.new(u) // v)
            r.should eq(u % v)
          else
            q, r = Divide.div_128_by_128(u, v)
            BigInt.new(q).should eq(BigInt.new(u) // v)
            BigInt.new(r).should eq(BigInt.new(u) % v)
          end
        end
      end
    end

    it "computes the 2/1 and 3/2 reciprocals" do
      [1_u64 << 63, (1_u64 << 63) + 1, UInt64::MAX, 0xd5a3_1f00_0000_0001_u64].each do |d|
        expected = ((BigInt.new(1) << 128) - 1) // d - (BigInt.new(1) << 64)
        Divide.invert_limb(d).should eq(expected)
      end
      [{1_u64 << 63, 0_u64}, {(1_u64 << 63) + 1, UInt64::MAX}, {UInt64::MAX, UInt64::MAX}, {0x9000_0000_0000_0000_u64, 12345_u64}].each do |(d1, d0)|
        divisor = (BigInt.new(d1) << 64) + d0
        expected = ((BigInt.new(1) << 192) - 1) // divisor - (BigInt.new(1) << 64)
        Divide.invert_pair(d1, d0).should eq(expected)
      end
    end

    it "gives the same 3/2 quotient and remainder from the hardware divide as from the reciprocal" do
      random = Random::PCG32.new(37)
      200_000.times do |round|
        d1 = random.rand(UInt64) | (1_u64 << 63)
        d0 = round % 7 == 0 ? UInt64::MAX - random.rand(3).to_u64 : random.rand(UInt64)
        divisor = (d1.to_u128 << 64) | d0
        # n2:n1 below the divisor, often with n2 == d1 (the B - 1 estimate).
        top = round % 3 == 0 ? divisor - 1 - random.rand(UInt64) : ((random.rand(UInt64).to_u128 << 64) | random.rand(UInt64)) % divisor
        n2 = (top >> 64).to_u64!
        n1 = top.to_u64!
        n0 = random.rand(UInt64)
        expected = Divide.div_3by2(n2, n1, n0, d1, d0, Divide.invert_pair(d1, d0))
        Divide.div_3by2_by_divide(n2, n1, n0, d1, d0).should eq(expected)
      end
    end

    it "divides by one limb (divrem_1 and mod_1), normalized and not" do
      random = Random::PCG32.new(11)
      [1_u64, 3_u64, 10_u64 ** 19, 1_u64 << 63, (1_u64 << 63) + 1, UInt64::MAX, 0x1234_5678_u64].each do |d|
        [1, 2, 3, 5, 8, 64].each do |n|
          limbs = random_limbs(random, n)
          quotient = Array(Limb).new(n, 0_u64)
          remainder = Divide.divrem_1(quotient.to_unsafe, limbs.to_unsafe, n, d)
          dividend = big(integer(limbs))
          big(integer(quotient)).should eq(dividend // d)
          remainder.should eq(dividend % d)
          Divide.mod_1(limbs.to_unsafe, n, d).should eq(dividend % d)
        end
      end
    end

    it "runs Algorithm D's add-back step with a divisor top limb just above 2**63" do
      # The 3/2 estimate from the top limbs (0x1_00000000_00000002_00000000_00000000
      # by 0x80000000_00000001_00000000_00000000) is 2; the divisor's low limb
      # makes 2 one too large, so the step adds the divisor back.
      divisor = [UInt64::MAX, 0_u64, (1_u64 << 63) + 1]
      dividend = [0_u64, 0_u64, 2_u64, 1_u64]
      q, r = integer(dividend).tdivmod(integer(divisor))
      q.should eq(Integer.new(1))
      big(r).should eq(big(integer(dividend)) - big(integer(divisor)))
      signed_pairs(big(integer(dividend)), big(integer(divisor))).each { |(a, b)| check_all_variants(a, b) }
    end

    it "runs Algorithm D's overflowing estimate (quotient limb B - 1)" do
      divisor = [UInt64::MAX, 0_u64, (1_u64 << 63) + 1]
      dividend = [5_u64, 7_u64, 0_u64, (1_u64 << 63) + 1]
      q, _ = integer(dividend).tdivmod(integer(divisor))
      big(q).should eq(big(integer(dividend)) // big(integer(divisor)))
      signed_pairs(big(integer(dividend)), big(integer(divisor))).each { |(a, b)| check_all_variants(a, b) }
    end

    it "matches GMP with top limbs equal to the divisor's (add-back shapes)" do
      random = Random::PCG32.new(5)
      200.times do
        dn = 2 + random.rand(70)
        divisor = random_limbs(random, dn)
        divisor[-1] = (1_u64 << 63) | random.rand(3).to_u64
        divisor[-2] = UInt64::MAX - random.rand(2).to_u64 if random.next_bool
        dividend = random_limbs(random, dn + 1 + random.rand(80))
        dividend[-1] = divisor[-1]
        dividend[-2] = divisor[-2]
        check_all_variants(big(integer(dividend)), big(integer(divisor)))
      end
    end

    it "matches GMP for four-limb dividends by two-limb divisors in registers" do
      random = Random::PCG32.new(31)
      20_000.times do |round|
        divisor = random_limbs(random, 2)
        divisor[-1] |= 1_u64 << 63 if round % 4 == 0
        dividend = random_limbs(random, 4)
        if round % 3 == 0
          dividend[-1] = divisor[-1]
          dividend[-2] = divisor[-2] &- random.rand(2).to_u64
        end
        a = big(integer(dividend))
        b = big(integer(divisor))
        q, r = integer(dividend).tdivmod(integer(divisor))
        {big(q), big(r)}.should eq(a.unsafe_truncated_divmod(b))
        big(integer(dividend).tdiv(integer(divisor))).should eq(a.tdiv(b))
        q, r = (-integer(dividend)).divmod(integer(divisor))
        {big(q), big(r)}.should eq((-a).divmod(b))
      end
    end

    it "matches GMP for four-limb divisors in registers (add-back and B - 1 shapes)" do
      random = Random::PCG32.new(29)
      20_000.times do |round|
        divisor = random_limbs(random, 4)
        divisor[-1] = (1_u64 << 63) | random.rand(3).to_u64 if round % 3 == 0
        divisor[-2] = UInt64::MAX - random.rand(2).to_u64 if round % 5 == 0
        dividend = random_limbs(random, 4 + random.rand(9))
        if round % 2 == 0 && dividend.size > 5
          # Top limbs equal to the divisor's, at the top and one limb down.
          offset = 1 + random.rand(2)
          dividend[-offset] = divisor[-1]
          dividend[-offset - 1] = divisor[-2]
        end
        a = big(integer(dividend))
        b = big(integer(divisor))
        q, r = integer(dividend).tdivmod(integer(divisor))
        {big(q), big(r)}.should eq(a.unsafe_truncated_divmod(b))
      end
    end

    it "matches GMP for divisors from 2 to 130 limbs and quotients from 1 to 140 limbs" do
      random = Random::PCG32.new(3)
      [2, 3, 4, 5, 8, 31, 49, 50, 51, 64, 130].each do |dn|
        [0, 1, 2, 3, 7, dn - 1, dn, dn + 1, 140].each do |extra|
          divisor = random_limbs(random, dn)
          divisor[-1] >>= random.rand(64)
          divisor[-1] |= 1
          dividend = random_limbs(random, dn + extra)
          check_all_variants(big(integer(dividend)), big(integer(divisor)))
        end
      end
    end

    it "divides exactly" do
      random = Random::PCG32.new(9)
      [1, 2, 3, 10, 60, 120].each do |dn|
        [0, 1, 2, 30, 100].each do |extra|
          b = big(integer(random_limbs(random, dn))) << random.rand(130)
          q = big(integer(random_limbs(random, extra + 1)))
          {b, -b}.each do |divisor|
            {q, -q}.each do |quotient|
              big(integer(divisor * quotient).divexact(integer(divisor))).should eq(quotient)
            end
          end
        end
      end
    end
  end

  describe Crystal::BigNum::Integer do
    it "matches every variant for every sign combination and size" do
      random = Random::PCG32.new(1)
      sizes = [1, 2, 3, 4, 10, 49, 50, 51, 64, 65, 130]
      sizes.each do |an|
        sizes.each do |bn|
          3.times do
            a = big(integer(random_limbs(random, an)))
            b = big(integer(random_limbs(random, bn)) >> random.rand(64)).abs + 1
            signed_pairs(a, b).each { |(x, y)| check_all_variants(x, y) }
          end
        end
      end
    end

    it "handles small and edge operands" do
      values = [0, 1, 2, 3, 7, 64, (1_u64 << 63), UInt64::MAX].map { |v| BigInt.new(v) }
      values += [BigInt.new(1) << 64, (BigInt.new(1) << 64) + 1, (BigInt.new(1) << 128) - 1, BigInt.new(1) << 128, (BigInt.new(1) << 129) + 3]
      values.each do |a|
        values.each do |b|
          next if b.zero?
          signed_pairs(a, b).each { |(x, y)| check_all_variants(x, y) }
        end
      end
    end

    it "takes primitive divisors of every width" do
      random = Random::PCG32.new(2)
      [1, 2, 3, 20].each do |n|
        a = big(integer(random_limbs(random, n)))
        {% for type in %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128) %}
          [{{ type.id }}::MAX, {{ type.id }}.new(3), {{ type.id }}::MIN, {{ type.id }}.new(1)].each do |divisor|
            next if divisor == 0
            {a, -a}.each do |dividend|
              x = integer(dividend)
              g = BigInt.new(divisor)
              big(x // divisor).should eq(dividend // g)
              big(x % divisor).should eq(dividend % g)
              big(x.tdiv(divisor)).should eq(dividend.tdiv(g))
              big(x.remainder(divisor)).should eq(dividend.remainder(g))
              q, r = x.divmod(divisor)
              {big(q), big(r)}.should eq(dividend.divmod(g))
              q, r = x.tdivmod(divisor)
              {big(q), big(r)}.should eq(dividend.unsafe_truncated_divmod(g))
              big(x.unsafe_floored_mod(divisor)).should eq(dividend % g)
              x.divisible_by?(divisor).should eq(dividend.divisible_by?(g))
            end
          end
        {% end %}
      end
    end
  end
{% else %}
  pending "Crystal::BigNum division (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
