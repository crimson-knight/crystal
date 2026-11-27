require "spec"
require "big"
require "../../../../src/crystal/big_num"

private alias Engine = Crystal::BigNum
private alias Limb = Crystal::BigNum::Limb

# GMP (through `BigInt`) is the oracle: operands go in and results come out
# as raw limbs, so the comparison is limb for limb and sign for sign.
private def to_big(value : Engine::Integer) : BigInt
  limbs = value.limbs
  mpz = uninitialized LibGMP::MPZ
  LibGMP.init(pointerof(mpz))
  if limbs.size > 0
    pointer = LibGMP.limbs_write(pointerof(mpz), limbs.size)
    pointer.copy_from(limbs.to_unsafe, limbs.size)
    LibGMP.limbs_finish(pointerof(mpz), value.negative? ? -limbs.size : limbs.size)
  end
  BigInt.new(mpz)
end

private def from_big(value : BigInt) : Engine::Integer
  count = LibGMP.size(value).to_i
  pointer = LibGMP.limbs_read(value)
  Engine::Integer.from_limbs(Slice.new(pointer, count), value < 0)
end

private def same?(ours : Engine::Integer, oracle : BigInt) : Bool
  expected = from_big(oracle)
  ours.negative? == expected.negative? && ours.limbs == expected.limbs
end

# Limbs of four shapes: random, all ones, sparse, and a top limb of one.
private def operand_limbs(random : Random, count : Int32, shape : Int32) : Slice(Limb)
  Slice(Limb).new(count) do |index|
    case shape
    when 1 then Limb::MAX
    when 2 then random.rand(8) == 0 ? random.rand(Limb::MAX) : Limb.zero
    when 3 then index == count - 1 ? Limb.new(1) : random.rand(Limb::MAX)
    else        random.rand(Limb::MAX) | (index == count - 1 ? Limb.new(1) : Limb.zero)
    end
  end.tap { |limbs| limbs[count - 1] = Limb.new(1) if limbs[count - 1] == 0 }
end

# The product through `Multiply.mul` (an >= bn), checked against GMP.
private def check_mul(random : Random, an : Int32, bn : Int32, shape : Int32) : Nil
  a = operand_limbs(random, an, shape)
  b = operand_limbs(random, bn, shape)
  product = Slice(Limb).new(an + bn, Limb::MAX)
  Engine::Multiply.mul(product.to_unsafe, a.to_unsafe, an, b.to_unsafe, bn)
  ours = Engine::Integer.from_limbs(product, false)
  oracle = to_big(Engine::Integer.from_limbs(a, false)) * to_big(Engine::Integer.from_limbs(b, false))
  fail "mul #{an}x#{bn} shape #{shape}: #{ours.inspect} != #{oracle.to_s(16)}" unless same?(ours, oracle)
end

private def check_sqr(random : Random, n : Int32, shape : Int32) : Nil
  a = operand_limbs(random, n, shape)
  product = Slice(Limb).new(2 * n, Limb::MAX)
  Engine::Multiply.sqr(product.to_unsafe, a.to_unsafe, n)
  ours = Engine::Integer.from_limbs(product, false)
  big = to_big(Engine::Integer.from_limbs(a, false))
  fail "sqr #{n} shape #{shape}" unless same?(ours, big * big)
end

private def sizes_around(thresholds : Array(Int32)) : Array(Int32)
  thresholds.flat_map { |threshold| (threshold - 2..threshold + 2).to_a }.select(&.>(0)).uniq.sort!
end

describe Crystal::BigNum::Multiply do
  thresholds = [
    Engine::Multiply::MUL_KARATSUBA_THRESHOLD, Engine::Multiply::MUL_TOOM3_THRESHOLD,
    2 * Engine::Multiply::MUL_KARATSUBA_THRESHOLD, 3 * Engine::Multiply::MUL_TOOM3_THRESHOLD,
  ]
  square_thresholds = [
    Engine::Multiply::SQR_KARATSUBA_THRESHOLD, Engine::Multiply::SQR_TOOM3_THRESHOLD,
    2 * Engine::Multiply::SQR_KARATSUBA_THRESHOLD, 3 * Engine::Multiply::SQR_TOOM3_THRESHOLD,
  ]

  it "multiplies every pair of sizes up to 40 limbs" do
    random = Random::PCG32.new(1_u64)
    (1..40).each do |an|
      (1..an).each do |bn|
        4.times { |shape| check_mul(random, an, bn, shape) }
      end
    end
  end

  it "multiplies at and around each threshold, balanced and unbalanced" do
    random = Random::PCG32.new(2_u64)
    sizes = sizes_around(thresholds)
    sizes.each do |bn|
      sizes.each do |an|
        next if an < bn
        4.times { |shape| check_mul(random, an, bn, shape) }
      end
      # the unbalanced cut sits at an = 1.5 * bn
      [bn * 3 // 2 - 1, bn * 3 // 2, bn * 3 // 2 + 1, 2 * bn, 5 * bn + 3].each do |an|
        check_mul(random, an, bn, 0) if an >= bn
      end
    end
  end

  it "multiplies random shapes up to 2,000 limbs" do
    random = Random::PCG32.new(3_u64)
    200.times do
      an = random.rand(1..2000)
      bn = random.rand(1..an)
      check_mul(random, an, bn, random.rand(4))
    end
  end

  it "squares every size up to 40 limbs and around each threshold" do
    random = Random::PCG32.new(4_u64)
    ((1..40).to_a + sizes_around(square_thresholds) + [500, 1000, 1999]).each do |n|
      4.times { |shape| check_sqr(random, n, shape) }
    end
  end

  it "carries through all-ones limbs" do
    [1, 2, 3, 23, 24, 25, 79, 80, 81, 99, 100, 101, 300].each do |count|
      ones = Slice(Limb).new(count, Limb::MAX)
      big = to_big(Engine::Integer.from_limbs(ones, false))
      product = Slice(Limb).new(2 * count)
      Engine::Multiply.sqr(product.to_unsafe, ones.to_unsafe, count)
      same?(Engine::Integer.from_limbs(product, false), big * big).should be_true
      Engine::Multiply.mul(product.to_unsafe, ones.to_unsafe, count, ones.to_unsafe, count)
      same?(Engine::Integer.from_limbs(product, false), big * big).should be_true
    end
  end
end

describe "Crystal::BigNum::Integer#*" do
  it "multiplies values of every sign and size against GMP" do
    random = Random::PCG32.new(5_u64)
    [0, 1, 2, 3, 4, 30, 90, 150].each do |an|
      [0, 1, 2, 3, 4, 30, 90, 150].each do |bn|
        3.times do
          a = an == 0 ? Engine::Integer.zero : Engine::Integer.from_limbs(operand_limbs(random, an, random.rand(4)), random.next_bool)
          b = bn == 0 ? Engine::Integer.zero : Engine::Integer.from_limbs(operand_limbs(random, bn, random.rand(4)), random.next_bool)
          same?(a * b, to_big(a) * to_big(b)).should be_true
        end
      end
    end
  end

  it "squares when both operands hold the same magnitude" do
    random = Random::PCG32.new(6_u64)
    [1, 2, 3, 40, 120].each do |count|
      a = Engine::Integer.from_limbs(operand_limbs(random, count, 0), true)
      twin = Engine::Integer.from_limbs(a.limbs, false)
      expected = to_big(a) * to_big(a)
      same?(a * a, expected).should be_true
      same?(a * twin, -expected).should be_true
      same?(a.square, expected).should be_true
    end
  end

  it "keeps products up to 128 bits inline and spills above" do
    max64 = Engine::Integer.new(UInt64::MAX)
    same?(max64 * max64, BigInt.new(UInt64::MAX) * UInt64::MAX).should be_true
    (max64 * max64).size.should eq(2)
    max128 = Engine::Integer.new(UInt128::MAX)
    same?(max128 * max128, BigInt.new(UInt128::MAX) ** 2).should be_true
    same?(max128 * 2, BigInt.new(UInt128::MAX) * 2).should be_true
    same?(max128 * -1, -BigInt.new(UInt128::MAX)).should be_true
    two64 = Engine::Integer.new(1_u128 << 64)
    (two64 * two64).size.should eq(3)
    same?(Engine::Integer.new(Int128::MIN) * Engine::Integer.new(Int128::MIN), BigInt.new(Int128::MIN) ** 2).should be_true
  end

  it "multiplies by every primitive type" do
    random = Random::PCG32.new(7_u64)
    {% for type in %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128) %}
      [{{ type.id }}::MIN, {{ type.id }}::MAX, {{ type.id }}.new(0), {{ type.id }}.new(1), {{ type.id }}.new(7)].each do |factor|
        [0, 1, 2, 3, 50].each do |count|
          [false, true].each do |negative|
            a = count == 0 ? Engine::Integer.zero : Engine::Integer.from_limbs(operand_limbs(random, count, random.rand(4)), negative)
            same?(a * factor, to_big(a) * factor).should be_true
          end
        end
      end
    {% end %}
  end
end
