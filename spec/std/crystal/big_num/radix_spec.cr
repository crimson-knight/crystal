require "spec"
require "big"
require "crystal/big_num"

private alias Integer = Crystal::BigNum::Integer

private def integer_of(value : BigInt) : Integer
  Integer.from_limbs(Slice.new(LibGMP.limbs_read(value), LibGMP.size(value).abs.to_i32), value < 0)
end

# What GMP's `mpz_set_str` gives for *text* itself (the stdlib's `BigInt.new`
# strips `+` and `_` first), or nil when GMP rejects it.
private def gmp_parse(text : String, base : Int32) : BigInt?
  status = LibGMP.init_set_str(out mpz, text, base)
  status == 0 ? BigInt.new(mpz) : nil
end

private def parse_like_gmp(text : String, base : Int32) : Nil
  expected = gmp_parse(text, base)
  actual = Integer.parse?(text, base)
  if expected
    actual.should_not be_nil, failure_message: "#{text.inspect} in base #{base}: GMP gives #{expected}, ours rejects it"
    actual.not_nil!.to_s.should eq(expected.to_s), failure_message: "#{text.inspect} in base #{base}"
  else
    actual.should be_nil, failure_message: "#{text.inspect} in base #{base}: GMP rejects it, ours gives #{actual}"
  end
end

private def sample_values : Array(BigInt)
  random = Random::PCG32.new(20_261_127)
  list = [BigInt.new(0), BigInt.new(1), BigInt.new(-1), BigInt.new(9), BigInt.new(10), BigInt.new(UInt64::MAX),
          BigInt.new(10) ** 19, BigInt.new(10) ** 19 - 1, BigInt.new(10) ** 38, BigInt.new(10) ** 38 - 1,
          BigInt.new(2) ** 64, BigInt.new(2) ** 128 - 1, BigInt.new(2) ** 128, -(BigInt.new(2) ** 255)]
  [1, 63, 64, 65, 127, 128, 129, 192, 256, 257, 512, 1_000, 2_048, 4_096, 8_192].each do |bits|
    2.times do
      value = BigInt.new(random.rand(UInt64)) % (BigInt.new(1) << bits)
      while value.bit_length < bits
        value = (value << 64) | BigInt.new(random.rand(UInt64))
      end
      value >>= value.bit_length - bits
      list << value << -value
    end
  end
  list
end

describe "Crystal::BigNum::Integer radix conversion" do
  describe "#to_s" do
    it "matches BigInt#to_s in every base, both cases, signed" do
      sample_values.each do |value|
        integer = integer_of(value)
        ((2..36).to_a + [62]).each do |base|
          integer.to_s(base).should eq(value.to_s(base)), failure_message: "#{value} in base #{base}"
          integer.to_s(base, upcase: true).should eq(value.to_s(base, upcase: true)) unless base == 62
        end
      end
    end

    it "pads to the precision as BigInt does, zero included" do
      sample_values.first(20).each do |value|
        integer = integer_of(value)
        [0, 1, 2, 5, 20, 40, 100].each do |precision|
          {2, 10, 16, 36, 62}.each do |base|
            integer.to_s(base, precision: precision).should eq(value.to_s(base, precision: precision))
          end
        end
      end
      Integer.zero.to_s(precision: 0).should eq("")
      Integer.zero.to_s.should eq("0")
      Integer.new(-85).to_s(precision: 5).should eq("-00085")
    end

    it "writes base 62 as 0-9a-zA-Z" do
      Integer.new(10).to_s(62).should eq("a")
      Integer.new(36).to_s(62).should eq("A")
      Integer.new(61).to_s(62).should eq("Z")
    end

    it "writes to an IO" do
      value = integer_of(BigInt.new(-3) ** 200)
      io = IO::Memory.new
      value.to_s(io, 7, precision: 400)
      io.to_s.should eq((BigInt.new(-3) ** 200).to_s(7, precision: 400))
      io = IO::Memory.new
      Integer.new(255).to_s(io, 16, upcase: true)
      io.to_s.should eq("FF")
    end

    it "rejects what BigInt rejects" do
      expect_raises(ArgumentError, "Invalid base 1") { Integer.new(1).to_s(1) }
      expect_raises(ArgumentError, "Invalid base 37") { Integer.new(1).to_s(37) }
      expect_raises(ArgumentError, "upcase must be false for base 62") { Integer.new(1).to_s(62, upcase: true) }
      expect_raises(ArgumentError, "Precision must be non-negative") { Integer.new(1).to_s(precision: -1) }
    end
  end

  describe ".parse" do
    it "reads every value BigInt#to_s writes, in every base" do
      sample_values.each do |value|
        ((2..36).to_a + [62]).each do |base|
          text = value.to_s(base)
          Integer.parse(text, base).to_s.should eq(BigInt.new(text, base).to_s), failure_message: "#{text} in base #{base}"
          upper = value.to_s(base, upcase: true) unless base == 62
          Integer.parse(upper, base).should eq(integer_of(value)) if upper
        end
      end
    end

    it "reads base 62 as GMP does: A-Z before a-z" do
      Integer.parse("A", 62).should eq(Integer.new(10))
      Integer.parse("a", 62).should eq(Integer.new(36))
      Integer.parse("z", 62).should eq(Integer.new(61))
      Integer.parse("Z", 40).should eq(Integer.new(35))
      Integer.parse("a", 40).should eq(Integer.new(36))
      Integer.parse?("y", 40).should be_nil
    end

    it "accepts exactly the syntax mpz_set_str accepts" do
      texts = ["0", "-0", "00000", "  12", "\t\n\v\f\r 12", "- 12", "-12", "--12", "1 2 3", "1\t2\n3", "12 ",
               "", " ", "-", "x", "0x", "0x1f", "0X1F", "-0x1f", "0x 1f", "0 x1f", "0b101", "0B2", "017", "019",
               "0", "00x1", "12\u00009", "\u0000", "1 2", "１２", "1_2", "+12", "9" * 19, "9" * 20, "9" * 38,
               "9" * 39, "1" + "0" * 38, "0" * 50 + "123", "1 " * 40, "ff", "FF", "fF", "zz", "ZZ", "1!"]
      bases = [0, 1, 2, 8, 10, 16, 36, 37, 62, 63, -1, 100]
      texts.each do |text|
        bases.each { |base| parse_like_gmp(text, base) }
      end
    end

    it "raises the error BigInt raises" do
      expect_raises(ArgumentError, "Invalid BigInt: 12z") { Integer.parse("12z", 10) }
      expect_raises(ArgumentError, "Invalid BigInt: ") { Integer.parse("", 10) }
    end

    it "parses a 147,000-digit decimal (the Postgres NUMERIC maximum) as GMP does" do
      random = Random::PCG32.new(147_000)
      text = String.build do |io|
        io << '-' << (1 + random.rand(9))
        146_999.times { io << random.rand(10) }
      end
      Integer.parse(text, 10).to_s.should eq(BigInt.new(text).to_s)
    end

    it "parses up to 38 decimal digits with no heap allocation" do
      text = "-" + "9" * 38
      Integer.parse(text, 10)
      before = GC.stats.total_bytes
      sum = 0_u64
      1_000.times { sum &+= Integer.parse(text, 10).to_u64! }
      (GC.stats.total_bytes - before).should eq(0)
      sum.should_not eq(1)
    end
  end

  describe "#size_in_base" do
    it "gives mpz_sizeinbase's bound for every bit length up to 4,200 in every base" do
      gmp = BigInt.new(1)
      ours = Integer.new(1)
      4_200.times do
        (2..62).each do |base|
          ours.size_in_base(base).should eq(LibGMP.sizeinbase(gmp, base).to_i64)
        end
        gmp <<= 1
        ours <<= 1
      end
      Integer.zero.size_in_base(10).should eq(1)
    end
  end
end
