# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"
require "crystal/big_num"

# The examples above the `-Duse_gmp` guard check the engine against itself and
# run in every build. Below the guard GMP's `BigInt` is the oracle, and only
# `-Duse_gmp` keeps `BigInt` on GMP; the default build puts it on the engine
# under test.

private alias Engine = Crystal::BigNum
private alias Limb = Crystal::BigNum::Limb

# Limbs of four shapes: random, all ones, sparse, and a top limb of one. The
# top limb is never zero.
private def operand_limbs(random : Random, count : Int32, shape : Int32) : Slice(Limb)
  limbs = Slice(Limb).new(count) do |index|
    case shape
    when 1 then Limb::MAX
    when 2 then random.rand(8) == 0 ? random.rand(Limb) : Limb.zero
    when 3 then index == count - 1 ? Limb.new(1) : random.rand(Limb)
    else        random.rand(Limb)
    end
  end
  limbs[count - 1] = Limb.new(1) if limbs[count - 1] == 0
  limbs
end

private def operand(random : Random, count : Int32, shape : Int32, negative : Bool = false) : Engine::Integer
  return Engine::Integer.zero if count == 0
  Engine::Integer.from_limbs(operand_limbs(random, count, shape), negative)
end

{% if flag?(:use_gmp) %}
  require "./integer_oracle"

  private def big(value : Engine::Integer) : BigInt
    IntegerOracle.to_big(value)
  end

  # The product through `Multiply.mul` (an >= bn), checked against GMP. The
  # result buffer starts as all ones so a limb left unwritten shows.
  private def check_mul(random : Random, an : Int32, bn : Int32, shape : Int32) : Nil
    a = operand_limbs(random, an, shape)
    b = operand_limbs(random, bn, shape)
    product = Slice(Limb).new(an + bn, Limb::MAX)
    Engine::Multiply.mul(product.to_unsafe, a.to_unsafe, an, b.to_unsafe, bn)
    ours = Engine::Integer.from_limbs(product, false)
    expected = big(Engine::Integer.from_limbs(a, false)) * big(Engine::Integer.from_limbs(b, false))
    fail "mul #{an}x#{bn} shape #{shape}: #{ours.inspect} != #{expected.to_s(16)}" unless IntegerOracle.same?(ours, expected)
  end

  private def check_sqr(random : Random, n : Int32, shape : Int32) : Nil
    a = operand_limbs(random, n, shape)
    product = Slice(Limb).new(2 * n, Limb::MAX)
    Engine::Multiply.sqr(product.to_unsafe, a.to_unsafe, n)
    ours = Engine::Integer.from_limbs(product, false)
    value = big(Engine::Integer.from_limbs(a, false))
    fail "sqr #{n} shape #{shape}: #{ours.inspect}" unless IntegerOracle.same?(ours, value * value)
  end

  describe Crystal::BigNum::Multiply do
    it "multiplies every pair of sizes up to 40 limbs in every shape" do
      random = Random::PCG32.new(1_u64)
      (1..40).each do |an|
        (1..an).each do |bn|
          4.times { |shape| check_mul(random, an, bn, shape) }
        end
      end
    end

    it "multiplies unbalanced and large operands" do
      random = Random::PCG32.new(2_u64)
      [{129, 1}, {130, 2}, {300, 3}, {1000, 7}, {2000, 64}, {130, 129}, {500, 499}].each do |an, bn|
        4.times { |shape| check_mul(random, an, bn, shape) }
      end
      100.times do
        an = random.rand(1..600)
        check_mul(random, an, random.rand(1..an), random.rand(4))
      end
    end

    it "squares every size up to 64 limbs in every shape, and larger sizes" do
      random = Random::PCG32.new(4_u64)
      ((1..64).to_a + [100, 129, 500, 1000]).each do |n|
        4.times { |shape| check_sqr(random, n, shape) }
      end
    end

    it "carries through all-ones limbs" do
      [1, 2, 3, 4, 5, 8, 31, 128].each do |count|
        ones = Slice(Limb).new(count, Limb::MAX)
        value = big(Engine::Integer.from_limbs(ones, false))
        product = Slice(Limb).new(2 * count)
        Engine::Multiply.sqr(product.to_unsafe, ones.to_unsafe, count)
        IntegerOracle.same?(Engine::Integer.from_limbs(product, false), value * value).should be_true
        Engine::Multiply.mul(product.to_unsafe, ones.to_unsafe, count, ones.to_unsafe, count)
        IntegerOracle.same?(Engine::Integer.from_limbs(product, false), value * value).should be_true
      end
    end
  end

  describe "Crystal::BigNum::Integer#*" do
    it "multiplies values of every sign and size against GMP" do
      random = Random::PCG32.new(5_u64)
      sizes = [0, 1, 2, 3, 4, 5, 30, 90]
      sizes.each do |an|
        sizes.each do |bn|
          4.times do |shape|
            a = operand(random, an, shape, random.next_bool)
            b = operand(random, bn, shape, random.next_bool)
            IntegerOracle.same?(a * b, big(a) * big(b)).should be_true
          end
        end
      end
    end

    it "squares when both operands hold the same magnitude" do
      random = Random::PCG32.new(6_u64)
      [0, 1, 2, 3, 4, 40, 120].each do |count|
        a = operand(random, count, 0, true)
        twin = Engine::Integer.from_limbs(a.limbs, false)
        expected = big(a) * big(a)
        IntegerOracle.same?(a * a, expected).should be_true
        IntegerOracle.same?(a * twin, -expected).should be_true
        IntegerOracle.same?(a.square, expected).should be_true
      end
    end

    it "keeps products up to 128 bits inline and sizes larger ones exactly" do
      max64 = Engine::Integer.new(UInt64::MAX)
      IntegerOracle.same?(max64 * max64, BigInt.new(UInt64::MAX) * UInt64::MAX).should be_true
      (max64 * max64).size.should eq(2)
      max128 = Engine::Integer.new(UInt128::MAX)
      IntegerOracle.same?(max128 * max128, BigInt.new(UInt128::MAX) ** 2).should be_true
      (max128 * max128).size.should eq(4)
      IntegerOracle.same?(max128 * 2, BigInt.new(UInt128::MAX) * 2).should be_true
      (max128 * 2).size.should eq(3)
      IntegerOracle.same?(max128 * -1, -BigInt.new(UInt128::MAX)).should be_true
      two64 = Engine::Integer.new(1_u128 << 64)
      (two64 * two64).size.should eq(3)
      IntegerOracle.same?(Engine::Integer.new(Int128::MIN) * Engine::Integer.new(Int128::MIN), BigInt.new(Int128::MIN) ** 2).should be_true
      three = Engine::Integer.from_limbs(Slice[Limb.new(5), Limb.new(6), Limb.new(1)], false)
      (three * 3).size.should eq(3)
      (three * Engine::Integer.new(3)).size.should eq(3)
      (three * Limb::MAX).size.should eq(4)
    end

    it "multiplies by every primitive type" do
      random = Random::PCG32.new(7_u64)
      {% for type in %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128) %}
        [{{ type.id }}::MIN, {{ type.id }}::MAX, {{ type.id }}.new(0), {{ type.id }}.new(1), {{ type.id }}.new(7)].each do |factor|
          [0, 1, 2, 3, 4, 50].each do |count|
            [false, true].each do |negative|
              a = operand(random, count, random.rand(4), negative)
              IntegerOracle.same?(a * factor, big(a) * factor).should be_true
            end
          end
        end
      {% end %}
    end
  end
{% else %}
  pending "Crystal::BigNum multiplication (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
