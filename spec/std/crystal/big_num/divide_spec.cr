require "spec"
require "big"
require "crystal/big_num"

# GMP (through the GMP-backed `BigInt`) is the oracle throughout.
private alias Integer = Crystal::BigNum::Integer
private alias Limb = Crystal::BigNum::Limb
private alias Divide = Crystal::BigNum::Divide

private def integer(limbs : Array(Limb), negative = false) : Integer
  Integer.from_limbs(Slice.new(limbs.to_unsafe, limbs.size), negative)
end

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

private def random_limbs(random, count) : Array(Limb)
  limbs = Array(Limb).new(count) { random.rand(Limb) }
  limbs[-1] |= 1_u64 << random.rand(64) if count > 0
  limbs
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

  it "matches GMP at the DIV_BZ threshold +-1 limb, both for the divisor and the quotient" do
    random = Random::PCG32.new(3)
    bz = Divide::DIV_BZ
    [bz - 1, bz, bz + 1, 2 * bz - 1, 2 * bz, 2 * bz + 1].each do |dn|
      [0, 1, bz - 1, bz, bz + 1, dn - 1, dn, dn + 1, 3 * dn + 7].each do |extra|
        divisor = random_limbs(random, dn)
        divisor[-1] >>= random.rand(64)
        divisor[-1] |= 1
        dividend = random_limbs(random, dn + extra)
        check_all_variants(big(integer(dividend)), big(integer(divisor)))
      end
    end
  end

  it "divides exactly (Jebelean)" do
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
