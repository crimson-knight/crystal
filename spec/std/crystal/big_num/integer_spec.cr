require "spec"

# GMP's `BigInt` is the oracle in these examples, and only `-Duse_gmp` keeps
# `BigInt` on GMP; the default build puts it on the engine under test.
{% if flag?(:use_gmp) %}
  require "big"
  require "crystal/big_num"

  private alias Integer = Crystal::BigNum::Integer
  private alias Limb = Crystal::BigNum::Limb

  private def limbs_of(value : Integer) : Array(Limb)
    value.limbs.to_a
  end

  describe Crystal::BigNum::Integer do
    describe ".new" do
      it "takes every primitive integer type at its edges" do
        {% for type in %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128) %}
          { {{ type.id }}::MIN, {{ type.id }}::MAX, {{ type.id }}.zero, {{ type.id }}.new(1) }.each do |value|
            integer = Integer.new(value)
            big = BigInt.new(value)
            integer.negative?.should eq(big < 0)
            limbs_of(integer).should eq(limbs_of(Integer.from_limbs(Slice.new(LibGMP.limbs_read(big), LibGMP.size(big).to_i32), big < 0)))
            integer.to_i128!.should eq(value.to_i128!)
          end
        {% end %}
      end

      it "keeps zero unsigned with no limbs" do
        Integer.new(0).zero?.should be_true
        Integer.new(0).negative?.should be_false
        Integer.new(0).size.should eq(0)
        Integer.new(0).limbs.size.should eq(0)
        Integer.from_limbs(Slice[0_u64, 0_u64], true).zero?.should be_true
        Integer.from_limbs(Slice[0_u64, 0_u64], true).negative?.should be_false
      end

      it "holds Int128 and UInt128 values in two limbs" do
        limbs_of(Integer.new(UInt128::MAX)).should eq([Limb::MAX, Limb::MAX])
        limbs_of(Integer.new(Int128::MIN)).should eq([0_u64, 1_u64 << 63])
        Integer.new(Int128::MIN).negative?.should be_true
      end
    end

    describe ".from_limbs" do
      it "copies and drops high zero limbs" do
        source = Slice[1_u64, 2_u64, 3_u64, 0_u64, 0_u64]
        value = Integer.from_limbs(source, true)
        source[0] = 9_u64
        limbs_of(value).should eq([1_u64, 2_u64, 3_u64])
        value.size.should eq(3)
        value.negative?.should be_true
        Integer.from_limbs(Slice[5_u64, 0_u64, 0_u64], false).should eq(Integer.new(5))
      end

      it "gives a read-only view of the limbs" do
        expect_raises(Exception, /read-only/) { Integer.new(1).limbs[0] = 2_u64 }
        expect_raises(Exception, /read-only/) { (Integer.new(1) << 300).limbs[0] = 2_u64 }
      end
    end

    describe "#+ and #-" do
      it "carries out of the inline limbs into a third" do
        sum = Integer.new(UInt128::MAX) + Integer.new(1)
        limbs_of(sum).should eq([0_u64, 0_u64, 1_u64])
        (sum - 1).should eq(Integer.new(UInt128::MAX))
        (-sum + 1).should eq(-Integer.new(UInt128::MAX))
      end

      it "cancels to zero across signs" do
        a = Integer.new(1) << 500
        (a - a).zero?.should be_true
        (a + -a).negative?.should be_false
      end
    end

    describe "#<=> and #==" do
      it "orders by sign, then size, then limbs" do
        values = [-(Integer.new(1) << 300), Integer.new(Int128::MIN), Integer.new(-1), Integer.new(0), Integer.new(1), Integer.new(UInt64::MAX), Integer.new(1) << 64, Integer.new(1) << 300]
        values.each_with_index do |a, i|
          values.each_with_index do |b, j|
            (a <=> b).should eq(i <=> j)
            (a == b).should eq(i == j)
          end
        end
        (Integer.new(3) <=> 4).should eq(-1)
        (Integer.new(-3) == -3).should be_true
      end
    end

    describe "#hash" do
      it "matches BigInt and the primitive integers for equal values" do
        list_of_values = [0, 1, -1, Int64::MAX, Int64::MIN, UInt64::MAX, Int128::MIN, UInt128::MAX]
        list_of_values.each do |value|
          Integer.new(value).hash.should eq(BigInt.new(value).hash)
          Integer.new(value).hash.should eq(value.hash)
        end
        big = (BigInt.new(1) << 4000) - 12345
        ours = (Integer.new(1) << 4000) - 12345
        ours.hash.should eq(big.hash)
        (-ours).hash.should eq((-big).hash)
        ours.hash_reduce.should eq(Crystal::Hasher.reduce_num(big))
      end
    end

    describe "bit operations" do
      it "presents the two's complement of negative values, as GMP" do
        (Integer.new(-12) & Integer.new(10)).should eq(Integer.new(-12 & 10))
        (Integer.new(-12) | Integer.new(10)).should eq(Integer.new(-12 | 10))
        (Integer.new(-12) ^ Integer.new(-10)).should eq(Integer.new(-12 ^ -10))
        (~Integer.new(0)).should eq(Integer.new(-1))
        (~Integer.new(-1)).should eq(Integer.new(0))
        Integer.new(-6).bit(0).should eq(0)
        Integer.new(-6).bit(1).should eq(1)
        Integer.new(-6).bit(2).should eq(0)
        Integer.new(-6).bit(1000).should eq(1)
        Integer.new(6).bit(-1).should eq(0)
      end

      it "counts bits with GMP's rules for zero and negatives" do
        Integer.new(-5).popcount.should eq(UInt64::MAX)
        Integer.new(0).trailing_zeros_count.should eq(UInt64::MAX)
        Integer.new(-40).trailing_zeros_count.should eq(3)
        Integer.new(0).bit_length.should eq(1)
        Integer.new(-6).bit_length.should eq(3)
        (Integer.new(1) << 4096).bit_length.should eq(4097)
      end
    end

    describe "shifts" do
      it "rounds a negative right shift toward minus infinity" do
        (Integer.new(-7) >> 1).should eq(Integer.new(-4))
        (Integer.new(-8) >> 1).should eq(Integer.new(-4))
        (Integer.new(-1) >> 10_000).should eq(Integer.new(-1))
        (Integer.new(7) >> 10_000).should eq(Integer.new(0))
        (-((Integer.new(1) << 300) + 1) >> 300).should eq(Integer.new(-2))
        (-(Integer.new(1) << 300) >> 300).should eq(Integer.new(-1))
      end

      it "shifts left across limbs and back" do
        value = Integer.new(0x1234_5678_9abc_def0_u64)
        {1, 63, 64, 65, 127, 128, 129, 1000}.each do |count|
          ((value << count) >> count).should eq(value)
          ((-value << count) >> count).should eq(-value)
        end
        (value << -4).should eq(value >> 4)
      end
    end

    describe "conversions" do
      it "converts in range and gives nil out of range" do
        Integer.new(Int64::MIN).to_i64?.should eq(Int64::MIN)
        (Integer.new(Int64::MIN) - 1).to_i64?.should be_nil
        Integer.new(UInt64::MAX).to_u64?.should eq(UInt64::MAX)
        Integer.new(-1).to_u64?.should be_nil
        (Integer.new(UInt64::MAX) + 1).to_u64?.should be_nil
        Integer.new(Int128::MIN).to_i128?.should eq(Int128::MIN)
        Integer.new(UInt128::MAX).to_u128?.should eq(UInt128::MAX)
        (Integer.new(UInt128::MAX) + 1).to_u128?.should be_nil
      end

      it "wraps the two's complement, as BigInt#to_u64!" do
        Integer.new(-1).to_u64!.should eq(UInt64::MAX)
        Integer.new(-3).to_i64!.should eq(-3_i64)
        (-(Integer.new(1) << 64) - 5).to_i64!.should eq(-5_i64)
        (Integer.new(-1) << 70).to_u64!.should eq(0_u64)
        Integer.new(-1).to_i128!.should eq(-1_i128)
      end
    end
  end
{% else %}
  pending "Crystal::BigNum::Integer (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
