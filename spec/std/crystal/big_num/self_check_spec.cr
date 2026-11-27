require "spec"
require "crystal/big_num"

# The engine checked against itself, in every build: each operation is tested
# through an identity that ties it to other operations (a product divides back
# to its factor, a parse reads back what `to_s` wrote), so these examples need
# no oracle. The GMP-backed examples in the other files run under `-Duse_gmp`.

private alias Integer = Crystal::BigNum::Integer
private alias Limb = Crystal::BigNum::Limb
private alias Limbs = Crystal::BigNum::Limbs
private alias Multiply = Crystal::BigNum::Multiply

# Limbs of four shapes: random, all ones, sparse, and a top limb of one.
private def shaped_limbs(random : Random, count : Int32, shape : Int32) : Slice(Limb)
  Slice(Limb).new(count) do |index|
    case shape
    when 1 then Limb::MAX
    when 2 then random.rand(8) == 0 ? random.rand(Limb) : Limb.zero
    when 3 then index == count - 1 ? Limb.new(1) : random.rand(Limb)
    else        random.rand(Limb)
    end
  end
end

private def random_integer(random : Random, count : Int32) : Integer
  Integer.from_limbs(shaped_limbs(random, count, random.rand(4)), random.next_bool)
end

# Limb counts from 0 to 12 (the inline, unrolled and general paths), then a
# few sizes well past them.
private def each_operand_pair(&)
  random = Random::PCG32.new(20_261_127)
  sizes = (0..12).to_a + [20, 40, 70, 130]
  sizes.each do |an|
    sizes.each do |bn|
      3.times { yield random_integer(random, an), random_integer(random, bn), random }
    end
  end
end

describe "Crystal::BigNum self-checks" do
  describe "Limbs" do
    it "undoes an addition with a subtraction, carry and borrow included" do
      random = Random::PCG32.new(1)
      (1..40).each do |count|
        6.times do
          a = shaped_limbs(random, count, random.rand(4))
          b = shaped_limbs(random, count, random.rand(4))
          sum = Slice(Limb).new(count)
          carry = Limbs.add_n(sum.to_unsafe, a.to_unsafe, b.to_unsafe, count)
          back = Slice(Limb).new(count)
          borrow = Limbs.sub_n(back.to_unsafe, sum.to_unsafe, b.to_unsafe, count)
          back.should eq(a)
          borrow.should eq(carry)
        end
      end
    end

    it "undoes a left shift with a right shift, and complements twice to the start" do
      random = Random::PCG32.new(2)
      (1..40).each do |count|
        a = shaped_limbs(random, count, random.rand(4))
        shift = random.rand(1..63)
        shifted = Slice(Limb).new(count + 1)
        shifted[count] = Limbs.lshift(shifted.to_unsafe, a.to_unsafe, count, shift)
        back = Slice(Limb).new(count + 1)
        Limbs.rshift(back.to_unsafe, shifted.to_unsafe, count + 1, shift).should eq(0)
        back[0, count].should eq(a)
        back[count].should eq(0)
        complement = Slice(Limb).new(count)
        Limbs.com(complement.to_unsafe, a.to_unsafe, count)
        Limbs.com(complement.to_unsafe, complement.to_unsafe, count)
        complement.should eq(a)
      end
    end
  end

  describe "multiplication" do
    it "commutes, distributes over addition and divides back to each factor" do
      each_operand_pair do |a, b, random|
        c = random_integer(random, random.rand(0..8))
        product = a * b
        product.should eq(b * a)
        (a * (b + c)).should eq(product + a * c)
        product.sign.should eq(a.sign * b.sign)
        unless b.zero?
          (product // b).should eq(a)
          (product % b).zero?.should be_true
          product.divexact(b).should eq(a)
        end
      end
    end

    it "squares as it multiplies, and writes every limb of the product" do
      random = Random::PCG32.new(3)
      (1..40).each do |n|
        4.times do |shape|
          a = shaped_limbs(random, n, shape)
          a[n - 1] = Limb.new(1) if a[n - 1] == 0
          square = Slice(Limb).new(2 * n, Limb::MAX)
          Multiply.sqr(square.to_unsafe, a.to_unsafe, n)
          product = Slice(Limb).new(2 * n, Limb.zero)
          Multiply.mul(product.to_unsafe, a.to_unsafe, n, a.to_unsafe, n)
          square.should eq(product)
          (1..n).each do |bn|
            from_ones = Slice(Limb).new(n + bn, Limb::MAX)
            from_zeros = Slice(Limb).new(n + bn, Limb.zero)
            Multiply.mul(from_ones.to_unsafe, a.to_unsafe, n, a.to_unsafe, bn)
            Multiply.mul(from_zeros.to_unsafe, a.to_unsafe, n, a.to_unsafe, bn)
            from_ones.should eq(from_zeros)
          end
        end
      end
    end
  end

  describe "division" do
    it "gives quotient * divisor + remainder == dividend, floored and truncated" do
      each_operand_pair do |a, b|
        next if b.zero?
        q, r = a.divmod(b)
        (q * b + r).should eq(a)
        (r.abs < b.abs).should be_true
        (r.zero? || r.sign == b.sign).should be_true
        tq, tr = a.tdivmod(b)
        (tq * b + tr).should eq(a)
        (tr.abs < b.abs).should be_true
        (tr.zero? || tr.sign == a.sign).should be_true
        (a // b).should eq(q)
        (a % b).should eq(r)
        a.tdiv(b).should eq(tq)
        a.remainder(b).should eq(tr)
        a.divisible_by?(b).should eq(r.zero?)
      end
    end

    it "divides by every primitive width as by the same value as an Integer" do
      each_operand_pair do |a, _, random|
        {random.rand(Int8), random.rand(UInt16), random.rand(Int32), random.rand(UInt64), random.rand(Int64), Int64::MIN, UInt64::MAX}.each do |divisor|
          next if divisor == 0
          a.divmod(divisor).should eq(a.divmod(Integer.new(divisor)))
          a.tdivmod(divisor).should eq(a.tdivmod(Integer.new(divisor)))
        end
      end
    end
  end

  describe "radix conversion" do
    # Base 62 is the one asymmetric case, kept from `BigInt`: `to_s` writes
    # 0-9a-zA-Z and `parse` reads GMP's 0-9A-Za-z, so the letters swap case.
    it "reads back what to_s writes, in every base to_s takes and both cases" do
      random = Random::PCG32.new(4)
      [0, 1, 2, 3, 5, 9, 17, 33].each do |count|
        4.times do
          value = random_integer(random, count)
          (2..36).each do |base|
            Integer.parse(value.to_s(base), base).should eq(value)
            Integer.parse(value.to_s(base, upcase: true), base).should eq(value)
          end
          swapped = value.to_s(62).gsub { |char| char.lowercase? ? char.upcase : char.downcase }
          Integer.parse(swapped, 62).should eq(value)
          precision = random.rand(1..200)
          text = value.to_s(precision: precision)
          Integer.parse(text, 10).should eq(value)
          (text.lchop('-').size >= precision).should be_true
        end
      end
    end

    it "writes powers of ten and of two as their digits" do
      (0..300).each do |exponent|
        (Integer.new(10) ** exponent).to_s.should eq("1" + "0" * exponent)
        (Integer.new(1) << exponent).to_s(2).should eq("1" + "0" * exponent)
        (Integer.new(-1) << exponent).to_s(16).should eq("-" + {"1", "2", "4", "8"}[exponent % 4] + "0" * (exponent // 4))
      end
    end
  end

  describe "number theory" do
    it "raises to a power as repeated multiplication" do
      random = Random::PCG32.new(5)
      [0, 1, 2, 3, 5].each do |count|
        base = random_integer(random, count)
        product = Integer.new(1)
        (0..40).each do |exponent|
          (base ** exponent).should eq(product)
          product *= base
        end
      end
    end

    it "builds factorials by the recurrence n! = n * (n - 1)!" do
      product = Integer.new(1)
      Integer.factorial(0).should eq(product)
      (1..400).each do |n|
        product *= n
        Integer.factorial(n).should eq(product)
      end
    end

    it "finds a gcd that divides both operands and leaves coprime cofactors, and lcm * gcd == |a * b|" do
      each_operand_pair do |a, b, random|
        shared = random_integer(random, random.rand(0..4)).abs
        shared = Integer.new(1) if shared.zero?
        a *= shared
        b *= shared
        g = a.gcd(b)
        g.negative?.should be_false
        if a.zero? && b.zero?
          g.zero?.should be_true
          next
        end
        a.divisible_by?(g).should be_true
        b.divisible_by?(g).should be_true
        a.divexact(g).gcd(b.divexact(g)).should eq(Integer.new(1))
        g.divisible_by?(shared).should be_true
        (a.lcm(b) * g).should eq((a * b).abs)
      end
    end

    it "takes an integer square root r with r**2 <= n < (r + 1)**2" do
      random = Random::PCG32.new(6)
      (0..20).each do |count|
        8.times do
          n = random_integer(random, count).abs
          root = n.isqrt
          (root * root <= n).should be_true
          ((root + 1) * (root + 1) > n).should be_true
          (n * n).isqrt.should eq(n)
        end
      end
    end

    it "inverts modulo m so that a * inverse % m == 1, and finds none when gcd > 1" do
      each_operand_pair do |a, m|
        next if m.abs <= Integer.new(1)
        inverse = a.invert(m)
        if a.gcd(m) == Integer.new(1)
          inverse.should_not be_nil
          if inverse
            (a * inverse % m.abs).should eq(Integer.new(1))
          end
        else
          inverse.should be_nil
        end
      end
    end

    it "removes a factor completely and counts how often it divided" do
      random = Random::PCG32.new(7)
      [2_i64, 3_i64, 10_i64, 7_i64, 1_i64 << 40].each do |factor_value|
        factor = Integer.new(factor_value)
        (0..6).each do |count|
          rest = random_integer(random, count)
          next if rest.zero?
          rest = rest.remove(factor)[0]
          times = random.rand(0..60)
          value = rest * factor ** times
          value.remove(factor).should eq({rest, times.to_u64})
        end
      end
    end
  end
end
