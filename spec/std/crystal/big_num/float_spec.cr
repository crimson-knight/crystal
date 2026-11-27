# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"
require "crystal/big_num"

private alias EngineFloat = Crystal::BigNum::Float
private alias Integer = Crystal::BigNum::Integer
private alias Limb = Crystal::BigNum::Limb

private def float_of(limbs : Array(Limb), exponent : Int64, negative : Bool = false, precision : Int32 = 2) : EngineFloat
  EngineFloat.from_parts(Slice.new(limbs.to_unsafe, limbs.size), negative, exponent, precision)
end

private def parts_of(value : EngineFloat) : {Int32, Int64, Array(Limb)}
  {value.signed_size, value.exponent, value.limbs.to_a}
end

private def with_engine_precision(bits, &)
  old = EngineFloat.default_precision
  EngineFloat.default_precision = bits
  begin
    yield
  ensure
    EngineFloat.default_precision = old
  end
end

describe Crystal::BigNum::Float do
  describe "precision" do
    it "rounds bits up to whole limbs and keeps one limb more, at least 53 bits" do
      EngineFloat.limb_precision(0).should eq(2)
      EngineFloat.limb_precision(1).should eq(2)
      EngineFloat.limb_precision(64).should eq(2)
      EngineFloat.limb_precision(65).should eq(3)
      EngineFloat.limb_precision(128).should eq(3)
      EngineFloat.limb_precision(129).should eq(4)
      EngineFloat.bit_precision(3).should eq(128)
    end

    it "reports the default precision as mpf_get_default_prec does" do
      EngineFloat.default_precision.should eq(64)
      with_engine_precision(100) do
        EngineFloat.default_precision.should eq(128)
        EngineFloat.default_limb_precision.should eq(3)
      end
      EngineFloat.default_precision.should eq(64)
    end
  end

  describe ".from_f64" do
    it "keeps two limbs, the top one not zero" do
      parts_of(EngineFloat.from_f64(1.0)).should eq({2, 1_i64, [0_u64, 1_u64]})
      parts_of(EngineFloat.from_f64(-0.5)).should eq({-2, 0_i64, [0_u64, 1_u64 << 63]})
      parts_of(EngineFloat.from_f64(2.0 ** 64)).should eq({2, 2_i64, [0_u64, 1_u64]})
      parts_of(EngineFloat.from_f64(0.0)).should eq({0, 0_i64, [] of Limb})
    end

    it "decodes subnormals exactly" do
      value = EngineFloat.from_f64(Float64::MIN_POSITIVE / 4)
      value.exact_binary.should eq({Integer.new(1), -1024_i64})
    end

    it "rejects non-finite doubles" do
      expect_raises(ArgumentError) { EngineFloat.from_f64(Float64::NAN) }
      expect_raises(ArgumentError) { EngineFloat.from_f64(-Float64::INFINITY) }
    end
  end

  describe "arithmetic" do
    it "keeps the limbs mpf keeps" do
      four_limbs = float_of([1_u64, 2_u64, 3_u64, 4_u64], 4)
      small = float_of([5_u64], 1)
      # mpf_add keeps the precision in limbs below the top
      parts_of(four_limbs.add(small, 2)).should eq({2, 4_i64, [3_u64, 4_u64]})
      # mpf_sub keeps one limb more
      parts_of(four_limbs.sub(small, 2)).should eq({3, 4_i64, [2_u64, 3_u64, 4_u64]})
      # mpf_mul keeps the precision plus one
      parts_of(four_limbs.mul(four_limbs, 2)).should eq({3, 7_i64, [9_u64, 24_u64, 16_u64]})
      parts_of(EngineFloat.from_u64(1).div(EngineFloat.from_u64(3), 2)).should eq({2, 0_i64, [0x5555555555555555_u64] * 2})
    end

    it "skips the limbs that cancel in a subtraction" do
      one_limb_up = float_of([0_u64, 0_u64, 1_u64], 3)
      just_below = float_of([Limb::MAX, Limb::MAX], 2)
      parts_of(one_limb_up.sub(just_below, 2)).should eq({1, 1_i64, [1_u64]})
      parts_of(just_below.sub(one_limb_up, 2)).should eq({-1, 1_i64, [1_u64]})
      parts_of(one_limb_up.sub(one_limb_up, 2)).should eq({0, 0_i64, [] of Limb})
    end

    it "truncates mul_ui with the carries from the dropped limbs" do
      value = float_of([Limb::MAX, Limb::MAX, Limb::MAX], 3)
      parts_of(value.mul_ui(3_u64, 2)).should eq({3, 4_i64, [Limb::MAX, Limb::MAX, 2_u64]})
    end

    it "takes the square root of the top limbs" do
      parts_of(EngineFloat.from_u64(4).sqrt(2)).should eq({2, 1_i64, [0_u64, 2_u64]})
      expect_raises(ArgumentError) { EngineFloat.from_i64(-4).sqrt }
    end

    it "raises the precision for pow_ui as mpf_pow_ui does" do
      parts_of(EngineFloat.from_u64(3).pow_ui(5_u64, 2)).should eq({1, 1_i64, [243_u64]})
    end
  end

  describe "#to_digits" do
    it "gives mpf_get_str's digits" do
      EngineFloat.from_f64(0.1).to_digits.should eq({"100000000000000005551", 0_i64})
      EngineFloat.from_f64(-1.5).to_digits.should eq({"-15", 1_i64})
      EngineFloat.zero.to_digits.should eq({"", 0_i64})
    end
  end

  describe ".parse?" do
    it "reads what mpf_set_str reads" do
      EngineFloat.parse?("  -1 2.5").not_nil!.to_digits.should eq({"-125", 2_i64})
      EngineFloat.parse?("1@5").not_nil!.to_digits.should eq({"1", 6_i64})
      EngineFloat.parse?("1e5xyz").not_nil!.to_digits.should eq({"1", 6_i64})
      EngineFloat.parse?(".5e-1").not_nil!.to_digits.should eq({"5", -1_i64})
      EngineFloat.parse?("0e").not_nil!.zero?.should be_true
      EngineFloat.parse?("1e").should be_nil
      EngineFloat.parse?("1.2.3").should be_nil
      EngineFloat.parse?("+1").should be_nil
      EngineFloat.parse?(".").should be_nil
      EngineFloat.parse?("").should be_nil
    end
  end

  describe "conversions" do
    it "truncates to a double" do
      # 0.1 rounds up to the nearest double; truncation stays below it
      tenth = EngineFloat.from_u64(1).div(EngineFloat.from_u64(10), 2)
      tenth.to_f64.should eq(0.09999999999999999)
      EngineFloat.from_f64(1.0).mul_2exp(2000_u64).to_f64.should eq(Float64::INFINITY)
      EngineFloat.from_f64(-1.0).div_2exp(2000_u64).to_f64.unsafe_as(UInt64).should eq(0_u64)
    end

    it "reads integer limbs as mpf_get_si and mpf_get_ui do" do
      minus_two_to_64 = float_of([1_u64], 2, negative: true)
      minus_two_to_64.get_si.should eq(Int64::MIN)
      minus_two_to_64.get_ui.should eq(0_u64)
      EngineFloat.from_f64(-2.75).get_si.should eq(-2)
      EngineFloat.from_f64(-2.75).get_ui.should eq(2)
    end

    it "gives the exact binary value" do
      EngineFloat.from_f64(0.75).exact_binary.should eq({Integer.new(3), -2_i64})
      EngineFloat.from_f64(-6.0).exact_binary.should eq({Integer.new(-3), 1_i64})
      EngineFloat.zero.exact_binary.should eq({Integer.zero, 0_i64})
    end
  end

  describe "comparison" do
    it "compares exactly, with mpf_cmp_d's value against a zero double" do
      one_and_a_half = EngineFloat.from_f64(1.5)
      (one_and_a_half <=> EngineFloat.from_f64(1.5)).should eq(0)
      one_and_a_half.cmp_d(1.25).should eq(1)
      one_and_a_half.cmp_d(Float64::INFINITY).should eq(-1)
      one_and_a_half.cmp_d(0.0).should eq(2)
      one_and_a_half.cmp_si(-1).should eq(1)
      one_and_a_half.cmp_ui(2).should eq(-1)
      one_and_a_half.cmp_z(Integer.new(1)).should eq(1)
    end
  end
end

# GMP's `mpf` is the oracle in these examples; only `-Duse_gmp` links it.
{% if flag?(:use_gmp) %}
  require "big"

  private def gmp_of(value : EngineFloat) : LibGMP::MPF
    LibGMP.mpf_init2(out mpf, EngineFloat.bit_precision(value.precision))
    mpf._mp_d.copy_from(value.limbs.to_unsafe, value.size) if value.size > 0
    mpf._mp_size = value.signed_size
    mpf._mp_exp = value.exponent
    mpf
  end

  private def gmp_parts(mpf : LibGMP::MPF) : {Int32, Int64, Array(Limb)}
    count = mpf._mp_size.abs
    {mpf._mp_size, count == 0 ? 0_i64 : mpf._mp_exp.to_i64, Array(Limb).new(count) { |index| mpf._mp_d[index] }}
  end

  describe "Crystal::BigNum::Float against GMP's mpf" do
    it "matches add, sub, mul, div and get_str on random limbs" do
      random = Random::PCG32.new(20261127)
      400.times do
        operands = Array.new(2) do
          count = random.rand(1..12)
          limbs = Array(Limb).new(count) { random.rand(3) == 0 ? [0_u64, Limb::MAX].sample(random) : random.rand(Limb) }
          limbs[-1] = 1_u64 if limbs[-1] == 0
          float_of(limbs, random.rand(-6_i64..6_i64), random.rand(2) == 0, Math.max(count - 1, 2))
        end
        precision = random.rand(2..9)
        left, right = operands
        lp = gmp_of(left)
        rp = gmp_of(right)
        {% for operation in %w(add sub mul div) %}
          LibGMP.mpf_init2(out {{ operation.id }}_result, EngineFloat.bit_precision(precision))
          LibGMP.mpf_{{ operation.id }}(pointerof({{ operation.id }}_result), pointerof(lp), pointerof(rp))
          gmp_parts({{ operation.id }}_result).should eq(parts_of(left.{{ operation.id }}(right, precision)))
        {% end %}
        digits = String.new(LibGMP.mpf_get_str(nil, out exponent, 10, 0, pointerof(lp)))
        left.to_digits.should eq({digits, exponent.to_i64})
      end
    end
  end
{% end %}
