# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"
require "crystal/big_num"

# The examples above the `-Duse_gmp` guard check the engine against itself and
# run in every build. Below the guard GMP's `BigInt` is the oracle, and only
# `-Duse_gmp` keeps `BigInt` on GMP; the default build puts it on the engine
# under test.

private alias Limbs = Crystal::BigNum::Limbs
private alias Limb = Crystal::BigNum::Limb

private def random_limbs(random : Random, count : Int32) : Slice(Limb)
  Slice(Limb).new(count) do
    case random.rand(4)
    when 0 then Limb::MAX
    when 1 then Limb.zero
    else        random.rand(Limb)
    end
  end
end

private def each_case(&)
  random = Random::PCG32.new(20261127)
  (0..40).each do |count|
    6.times { yield random, count }
  end
end

describe Crystal::BigNum::Limbs do
  it "applies and, and-not, or, or-not and xor limb by limb" do
    each_case do |random, count|
      a = random_limbs(random, count)
      b = random_limbs(random, count)
      result = Slice(Limb).new(count)
      Limbs.and_n(result.to_unsafe, a.to_unsafe, b.to_unsafe, count)
      result.should eq(Slice(Limb).new(count) { |i| a[i] & b[i] })
      Limbs.andn_n(result.to_unsafe, a.to_unsafe, b.to_unsafe, count)
      result.should eq(Slice(Limb).new(count) { |i| a[i] & ~b[i] })
      Limbs.ior_n(result.to_unsafe, a.to_unsafe, b.to_unsafe, count)
      result.should eq(Slice(Limb).new(count) { |i| a[i] | b[i] })
      Limbs.iorn_n(result.to_unsafe, a.to_unsafe, b.to_unsafe, count)
      result.should eq(Slice(Limb).new(count) { |i| a[i] | ~b[i] })
      Limbs.xor_n(result.to_unsafe, a.to_unsafe, b.to_unsafe, count)
      result.should eq(Slice(Limb).new(count) { |i| a[i] ^ b[i] })
    end
  end
end

{% if flag?(:use_gmp) %}
  require "big"

  # The number the limbs of *slice* spell, least significant first.
  private def value_of(slice : Slice(Limb)) : BigInt
    slice.reverse_each.reduce(BigInt.new(0)) { |total, limb| (total << 64) + limb }
  end

  describe Crystal::BigNum::Limbs do
    it "adds and subtracts runs of limbs with the carry out" do
      each_case do |random, count|
        a = random_limbs(random, count)
        b = random_limbs(random, count)
        sum = Slice(Limb).new(count)
        carry = Limbs.add_n(sum.to_unsafe, a.to_unsafe, b.to_unsafe, count)
        (value_of(sum) + (BigInt.new(carry) << (64 * count))).should eq(value_of(a) + value_of(b))
        difference = Slice(Limb).new(count)
        borrow = Limbs.sub_n(difference.to_unsafe, a.to_unsafe, b.to_unsafe, count)
        (value_of(difference) - (BigInt.new(borrow) << (64 * count))).should eq(value_of(a) - value_of(b))
      end
    end

    it "adds and subtracts in place" do
      each_case do |random, count|
        a = random_limbs(random, count)
        b = random_limbs(random, count)
        expected = value_of(a) + value_of(b)
        carry = Limbs.add_n(a.to_unsafe, a.to_unsafe, b.to_unsafe, count)
        (value_of(a) + (BigInt.new(carry) << (64 * count))).should eq(expected)
      end
    end

    it "adds and subtracts one limb, copying the rest" do
      each_case do |random, count|
        a = random_limbs(random, count)
        b = random.rand(Limb)
        result = Slice(Limb).new(count)
        carry = Limbs.add_1(result.to_unsafe, a.to_unsafe, count, b)
        (value_of(result) + (BigInt.new(carry) << (64 * count))).should eq(value_of(a) + b)
        borrow = Limbs.sub_1(result.to_unsafe, a.to_unsafe, count, b)
        (value_of(result) - (BigInt.new(borrow) << (64 * count))).should eq(value_of(a) - b)
      end
    end

    it "adds and subtracts runs of different lengths" do
      each_case do |random, count|
        shorter = random.rand(0..count)
        a = random_limbs(random, count)
        b = random_limbs(random, shorter)
        result = Slice(Limb).new(count)
        carry = Limbs.add(result.to_unsafe, a.to_unsafe, count, b.to_unsafe, shorter)
        (value_of(result) + (BigInt.new(carry) << (64 * count))).should eq(value_of(a) + value_of(b))
        borrow = Limbs.sub(result.to_unsafe, a.to_unsafe, count, b.to_unsafe, shorter)
        (value_of(result) - (BigInt.new(borrow) << (64 * count))).should eq(value_of(a) - value_of(b))
      end
    end

    it "multiplies by one limb, and adds or subtracts that product" do
      each_case do |random, count|
        a = random_limbs(random, count)
        r = random_limbs(random, count)
        b = random.rand(4) == 0 ? Limb::MAX : random.rand(Limb)
        product = Slice(Limb).new(count)
        high = Limbs.mul_1(product.to_unsafe, a.to_unsafe, count, b)
        (value_of(product) + (BigInt.new(high) << (64 * count))).should eq(value_of(a) * b)

        sum = r.dup
        high = Limbs.addmul_1(sum.to_unsafe, a.to_unsafe, count, b)
        (value_of(sum) + (BigInt.new(high) << (64 * count))).should eq(value_of(r) + value_of(a) * b)

        difference = r.dup
        high = Limbs.submul_1(difference.to_unsafe, a.to_unsafe, count, b)
        (value_of(difference) - (BigInt.new(high) << (64 * count))).should eq(value_of(r) - value_of(a) * b)
      end
    end

    it "shifts left and right by 1 to 63 bits, returning the bits shifted out" do
      each_case do |random, count|
        next if count == 0
        a = random_limbs(random, count)
        shift = random.rand(1..63)
        result = Slice(Limb).new(count)
        shifted_out = Limbs.lshift(result.to_unsafe, a.to_unsafe, count, shift)
        (value_of(result) + (BigInt.new(shifted_out) << (64 * count))).should eq(value_of(a) << shift)
        shifted_out = Limbs.rshift(result.to_unsafe, a.to_unsafe, count, shift)
        value_of(result).should eq(value_of(a) >> shift)
        shifted_out.should eq((value_of(a) & ((BigInt.new(1) << shift) - 1)) << (64 - shift))
        in_place = a.dup
        Limbs.lshift(in_place.to_unsafe, in_place.to_unsafe, count, shift)
        value_of(in_place).should eq((value_of(a) << shift) & ((BigInt.new(1) << (64 * count)) - 1))
      end
    end

    it "compares, normalizes, counts bits and complements" do
      each_case do |random, count|
        a = random_limbs(random, count)
        b = random.next_bool ? a.dup : random_limbs(random, count)
        Limbs.cmp(a.to_unsafe, b.to_unsafe, count).should eq(value_of(a) <=> value_of(b))
        normalized = Limbs.normalize(a.to_unsafe, count)
        value_of(a[0, normalized]).should eq(value_of(a))
        (normalized == 0 || a[normalized - 1] != 0).should be_true
        Limbs.popcount(a.to_unsafe, count).should eq(value_of(a).popcount)
        Limbs.trailing_zeros(a.to_unsafe, count).should eq(value_of(a).trailing_zeros_count) unless normalized == 0
        complement = Slice(Limb).new(count)
        Limbs.com(complement.to_unsafe, a.to_unsafe, count)
        (value_of(complement) + value_of(a)).should eq((BigInt.new(1) << (64 * count)) - 1)
      end
    end
  end
{% else %}
  pending "Crystal::BigNum::Limbs (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
