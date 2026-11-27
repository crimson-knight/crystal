require "spec"
require "crystal/big_num"

# The examples above the `-Duse_gmp` guard check the engine against itself and
# run in every build. Below the guard GMP's `BigInt` is the oracle, and only
# `-Duse_gmp` keeps `BigInt` on GMP; the default build puts it on the engine
# under test.

private alias Integer = Crystal::BigNum::Integer

private def edge_floats : Array(Float64)
  list = [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.0 ** 52, 2.0 ** 53, 2.0 ** 53 + 2, 2.0 ** 63, 2.0 ** 64,
          2.0 ** 64 - 2048, 2.0 ** 127, 2.0 ** 128, 2.0 ** 128 + 2.0 ** 76, 2.0 ** 1000, 1.0e300, 4.9e-324,
          Float64::MIN_POSITIVE, Float64::MAX, 123456789.987654321, 1.0e19, 9.999999999999999e18]
  random = Random::PCG32.new(4_7)
  200.times { list << random.rand(UInt64).unsafe_as(Float64) }
  list.select(&.finite?).flat_map { |value| [value, -value] }
end

describe "Crystal::BigNum::Integer and Float64" do
  describe ".new(Float64)" do
    it "takes Float32" do
      Integer.new(16777217.0_f32).should eq(Integer.new(16777216))
    end

    it "raises for NaN and the infinities, as BigInt does" do
      [Float64::NAN, Float64::INFINITY, -Float64::INFINITY].each do |value|
        expect_raises(ArgumentError, "Can only construct from a finite number") { Integer.new(value) }
      end
    end
  end

  describe "#to_f64" do
    it "gives an infinity of the value's sign from 2**1024 up" do
      (Integer.new(1) << 1024).to_f64.should eq(Float64::INFINITY)
      (-(Integer.new(1) << 5000)).to_f64.should eq(-Float64::INFINITY)
    end
  end

  describe "#<=>(Float64)" do
    it "is nil against NaN" do
      (Integer.new(1) <=> Float64::NAN).should be_nil
      (Integer.zero <=> Float64::NAN).should be_nil
    end

    it "sees a fraction and the bits below a double's mantissa" do
      (Integer.new(1) <=> 1.5).should eq(-1)
      (Integer.new(2) <=> 1.5).should eq(1)
      (Integer.new(-1) <=> -1.5).should eq(1)
      ((Integer.new(1) << 100) + Integer.new(1) <=> 2.0 ** 100).should eq(1)
      (Integer.new(1) << 100 <=> 2.0 ** 100).should eq(0)
      (Integer.zero <=> -0.0).should eq(0)
      (Integer.new(1) <=> 4.9e-324).should eq(1)
    end
  end
end

{% if flag?(:use_gmp) %}
  require "big"

  private def integer_of(value : BigInt) : Integer
    Integer.from_limbs(Slice.new(LibGMP.limbs_read(value), LibGMP.size(value).abs.to_i32), value < 0)
  end

  describe "Crystal::BigNum::Integer and Float64" do
    describe ".new(Float64)" do
      it "truncates toward zero, exactly, as mpz_set_d" do
        edge_floats.each do |value|
          Integer.new(value).to_s.should eq(BigInt.new(value).to_s), failure_message: value.to_s
        end
        Integer.new(-0.9).zero?.should be_true
        Integer.new(-0.9).negative?.should be_false
        Integer.new(2.0 ** 200).should eq(Integer.new(1) << 200)
      end
    end

    describe "#to_f64" do
      it "truncates toward zero as mpz_get_d" do
        values = [BigInt.new(0), BigInt.new(2) ** 53 + 1, BigInt.new(2) ** 54 - 1, BigInt.new(2) ** 64 - 1,
                  BigInt.new(2) ** 1024 - 1, BigInt.new(2) ** 1023, BigInt.new(10) ** 300 + 7]
        values += edge_floats.map { |value| BigInt.new(value) + 1 }
        values.flat_map { |value| [value, -value] }.each do |value|
          integer_of(value).to_f64.should eq(value.to_f64), failure_message: value.to_s
        end
        integer_of(BigInt.new(2) ** 53 + 1).to_f64.should eq(2.0 ** 53)
        integer_of(BigInt.new(2) ** 1024 - 1).to_f64.should eq(Float64::MAX)
      end
    end

    describe "#<=>(Float64)" do
      it "compares exactly, as mpz_cmp_d" do
        integers = edge_floats.map { |value| BigInt.new(value) }
        integers += integers.flat_map { |value| [value + 1, value - 1] }
        integers += [BigInt.new(2) ** 2000, -(BigInt.new(2) ** 2000), (BigInt.new(2) ** 64 + 1) << 100]
        floats = edge_floats + [Float64::INFINITY, -Float64::INFINITY]
        integers.each do |value|
          integer = integer_of(value)
          floats.each do |float|
            (integer <=> float).should eq(LibGMP.cmp_d(value, float).sign), failure_message: "#{value} <=> #{float}"
          end
          (integer <=> value.to_f64).should eq(LibGMP.cmp_d(value, value.to_f64).sign)
        end
      end
    end
  end
{% else %}
  pending "Crystal::BigNum float conversion (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
