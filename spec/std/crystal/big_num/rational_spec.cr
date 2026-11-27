# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"
require "big"
require "crystal/big_num"

private alias Integer = Crystal::BigNum::Integer
private alias Rational = Crystal::BigNum::Rational

private def rational(numerator, denominator = 1) : Rational
  Rational.new(Integer.new(numerator), Integer.new(denominator))
end

private def power_of_two(exponent) : Integer
  Integer.new(1) << exponent
end

private def parts(value : Rational) : {String, String}
  {value.numerator.to_s, value.denominator.to_s}
end

describe Crystal::BigNum::Rational do
  describe ".new" do
    it "canonicalizes: no common factor, positive denominator" do
      parts(rational(6, -4)).should eq({"-3", "2"})
      parts(rational(-6, -4)).should eq({"3", "2"})
      parts(rational(12, 4)).should eq({"3", "1"})
      parts(rational(7, 7)).should eq({"1", "1"})
    end

    it "gives zero as 0/1" do
      parts(rational(0, -5)).should eq({"0", "1"})
      parts(Rational.zero).should eq({"0", "1"})
    end

    it "raises on a zero denominator" do
      expect_raises(DivisionByZeroError) { rational(1, 0) }
    end

    it "reduces highly composite parts" do
      numerator = Integer.new(2) ** 64 * Integer.new(3) ** 40
      denominator = Integer.new(2) ** 70 * Integer.new(5) ** 10 * Integer.new(3) ** 39
      value = Rational.new(numerator, denominator)
      value.numerator.should eq(Integer.new(3))
      value.denominator.should eq(Integer.new(2) ** 6 * Integer.new(5) ** 10)
    end

    it "decodes doubles exactly" do
      parts(Rational.new(0.5)).should eq({"1", "2"})
      parts(Rational.new(-0.0)).should eq({"0", "1"})
      parts(Rational.new(-3.0)).should eq({"-3", "1"})
      parts(Rational.new(0.1)).should eq({"3602879701896397", "36028797018963968"})
      Rational.new(5.0e-324).denominator.should eq(power_of_two(1074))
      Rational.new(Float64::MIN_POSITIVE).denominator.should eq(power_of_two(1022))
      Rational.new(Float64::MAX).numerator.should eq((power_of_two(53) - Integer.new(1)) << 971)
      parts(Rational.new(1.5_f32)).should eq({"3", "2"})
    end

    it "rejects NaN and the infinities" do
      expect_raises(ArgumentError) { Rational.new(Float64::NAN) }
      expect_raises(ArgumentError) { Rational.new(Float64::INFINITY) }
      expect_raises(ArgumentError) { Rational.new(-Float64::INFINITY) }
    end

    it "builds mantissa * 2**exponent" do
      parts(Rational.from_binary(Integer.new(12), -4)).should eq({"3", "4"})
      parts(Rational.from_binary(Integer.new(-3), 2)).should eq({"-12", "1"})
      parts(Rational.from_binary(Integer.new(5), -1)).should eq({"5", "2"})
      parts(Rational.from_binary(Integer.zero, -7)).should eq({"0", "1"})
    end
  end

  describe "arithmetic" do
    it "adds and subtracts with gcd reduction" do
      parts(rational(1, 6) + rational(1, 3)).should eq({"1", "2"})
      parts(rational(1, 2) + rational(1, 3)).should eq({"5", "6"})
      parts(rational(1, 6) + rational(5, 6)).should eq({"1", "1"})
      parts(rational(1, 6) - rational(1, 6)).should eq({"0", "1"})
      parts(rational(3, 4) - rational(-1, 4)).should eq({"1", "1"})
      parts(Rational.zero + rational(2, 3)).should eq({"2", "3"})
    end

    it "multiplies and divides with cross reduction" do
      parts(rational(2, 3) * rational(9, 4)).should eq({"3", "2"})
      parts(rational(2, 3) * Rational.zero).should eq({"0", "1"})
      parts(rational(2, 3) / rational(-4, 9)).should eq({"-3", "2"})
      expect_raises(DivisionByZeroError) { rational(2, 3) / Rational.zero }
    end

    it "negates, takes the absolute value and inverts" do
      parts(-rational(2, 3)).should eq({"-2", "3"})
      parts(rational(-2, 3).abs).should eq({"2", "3"})
      parts(rational(-2, 3).inv).should eq({"-3", "2"})
      expect_raises(DivisionByZeroError) { Rational.zero.inv }
    end

    it "raises to integer powers" do
      parts(rational(-2, 3) ** 3).should eq({"-8", "27"})
      parts(rational(-2, 3) ** -2).should eq({"9", "4"})
      parts(rational(5, 7) ** 0).should eq({"1", "1"})
    end

    it "shifts, cancelling factors of two" do
      parts(rational(3, 4) << 2).should eq({"3", "1"})
      parts(rational(3, 4) << 3).should eq({"6", "1"})
      parts(rational(12, 1) >> 4).should eq({"3", "4"})
      parts(rational(-3, 1) >> 1).should eq({"-3", "2"})
      parts(rational(3, 4) >> -2).should eq({"3", "1"})
      parts(rational(3, 1) << -2).should eq({"3", "4"})
      parts(Rational.zero << 5).should eq({"0", "1"})
    end
  end

  describe "rounding" do
    it "floors, ceils and truncates" do
      rational(-7, 2).floor.should eq(Integer.new(-4))
      rational(-7, 2).ceil.should eq(Integer.new(-3))
      rational(-7, 2).trunc.should eq(Integer.new(-3))
      rational(7, 2).floor.should eq(Integer.new(3))
    end

    it "rounds halves away from zero or to even" do
      rational(5, 2).round_away.should eq(Integer.new(3))
      rational(-5, 2).round_away.should eq(Integer.new(-3))
      rational(5, 2).round_even.should eq(Integer.new(2))
      rational(7, 2).round_even.should eq(Integer.new(4))
      rational(-5, 2).round_even.should eq(Integer.new(-2))
      rational(8, 3).round_even.should eq(Integer.new(3))
    end
  end

  describe "comparison" do
    big = power_of_two(300)

    it "returns GMP's values for mpq_cmp" do
      (Rational.zero <=> rational(5, 3)).should eq(-1)
      (Rational.zero <=> Rational.new(big, Integer.new(3))).should eq(-5)
      (Rational.new(big, Integer.new(3)) <=> Rational.zero).should eq(5)
      (Rational.new(-big, Integer.new(3)) <=> rational(1)).should eq(-5)
      (Rational.new(big, Integer.new(3)) <=> rational(1, 7)).should eq(5)
      (Rational.new(Integer.new(1), big) <=> rational(1, 7)).should eq(-1)
      (Rational.new(Integer.new(-1), big) <=> rational(-1, 7)).should eq(1)
      (rational(2, 3) <=> rational(3, 4)).should eq(-1)
      (rational(2, 3) <=> rational(4, 6)).should eq(0)
      # two integers compare to -1, 0 or 1
      (Rational.new(big) <=> rational(3)).should eq(1)
    end

    it "returns GMP's values for mpq_cmp_z" do
      (Rational.new(big, Integer.new(3)) <=> Integer.new(5)).should eq(5)
      (Rational.new(big, Integer.new(3)) <=> big * big).should eq(-5)
      (Rational.new(big) <=> Integer.new(12468)).should eq(1)
      (Rational.new(-big) <=> Integer.new(5)).should eq(-5)
    end

    it "returns GMP's values for mpq_cmp_si and mpq_cmp_ui" do
      (Rational.new(big, Integer.new(3)) <=> 5_i64).should eq(5)
      (Rational.new(big, Integer.new(3)) <=> -5_i64).should eq(1)
      (Rational.new(-big, Integer.new(3)) <=> -5_i64).should eq(-5)
      (Rational.new(-big, Integer.new(3)) <=> 5_i64).should eq(-1)
      (Rational.new(Integer.new(1), big) <=> 5_u64).should eq(-1)
      (Rational.new(Integer.new(1), big) <=> 0_i64).should eq(1)
      (Rational.new(Integer.new(-1), big) <=> 0_i64).should eq(-1)
      (Rational.new(big) <=> 0_i64).should eq(5)
      (Rational.zero <=> 5_i64).should eq(-1)
      (Rational.zero <=> -5_i64).should eq(1)
      # against 1: numerator and denominator by limb count
      (Rational.new(power_of_two(200) + Integer.new(1), power_of_two(150)) <=> 1_u64).should eq(4)
      (rational(3, 2) <=> 1_u64).should eq(1)
      (rational(2, 3) <=> 1_i64).should eq(-1)
      (Rational.new(Integer.new(-1), power_of_two(100)) <=> -1_i64).should eq(1)
    end

    it "is equal exactly when the parts are" do
      (rational(2, 4) == rational(1, 2)).should be_true
      (rational(1, 2) == rational(-1, 2)).should be_false
    end
  end

  describe "#to_f64" do
    it "truncates toward zero" do
      rational(1, 3).to_f64.should eq(1.0 / 3.0)
      rational(2, 3).to_f64.should eq(0.6666666666666666)
      rational(-2, 3).to_f64.should eq(-0.6666666666666666)
      (Rational.new(Float64::MAX) + rational(1, 2)).to_f64.should eq(Float64::MAX)
      Rational.new(power_of_two(1024) - Integer.new(1)).to_f64.should eq(Float64::MAX)
    end

    it "keeps subnormals and flushes what lies below them to positive zero" do
      Rational.new(5.0e-324).to_f64.should eq(5.0e-324)
      (Rational.new(5.0e-324) * rational(3, 2)).to_f64.should eq(5.0e-324)
      value = (Rational.new(-5.0e-324) * rational(3, 4)).to_f64
      value.should eq(0.0)
      value.sign_bit.should eq(1)
      Rational.new(Float64::MIN_POSITIVE.prev_float).to_f64.should eq(Float64::MIN_POSITIVE.prev_float)
    end

    it "gives an infinity of the value's sign from 2**1024 up" do
      Rational.new(power_of_two(1024)).to_f64.should eq(Float64::INFINITY)
      Rational.new(-power_of_two(1100), Integer.new(3)).to_f64.should eq(-Float64::INFINITY)
    end

    it "is zero for zero" do
      Rational.zero.to_f64.should eq(0.0)
    end
  end

  describe "#to_s" do
    it "prints the numerator, then the denominator unless it is 1" do
      rational(-255, 7).to_s(16).should eq("-ff/7")
      rational(-255).to_s(2).should eq("-11111111")
      rational(8243243, 562828882).to_s(36).should eq("4woiz/9b3djm")
      Rational.zero.to_s.should eq("0")
    end
  end

  # GMP's `mpq_t` (through the GMP-backed `BigRational`) is the oracle, and
  # only `-Duse_gmp` keeps `BigRational` on GMP.
  {% if flag?(:use_gmp) %}
    describe "against GMP" do
      it "agrees on random values" do
        random = Random::PCG32.new(20261127)
        500.times do
          a = BigRational.new(BigInt.new(random.rand(Int64)) << random.rand(0..200), BigInt.new(random.rand(1_u64..UInt64::MAX)) << random.rand(0..200))
          b = BigRational.new(BigInt.new(random.rand(Int64)), BigInt.new(random.rand(1_u64..UInt64::MAX)))
          x = Rational.new(Integer.parse(a.numerator.to_s, 10), Integer.parse(a.denominator.to_s, 10))
          y = Rational.new(Integer.parse(b.numerator.to_s, 10), Integer.parse(b.denominator.to_s, 10))
          (x + y).to_s.should eq((a + b).to_s)
          (x - y).to_s.should eq((a - b).to_s)
          (x * y).to_s.should eq((a * b).to_s)
          (x / y).to_s.should eq((a / b).to_s) unless b == 0
          (x <=> y).should eq(a <=> b)
          x.to_f64.should eq(a.to_f64)
        end
      end
    end
  {% end %}
end
