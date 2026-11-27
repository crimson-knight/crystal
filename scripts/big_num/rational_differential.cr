# Differential test of `Crystal::BigNum::Rational` against GMP's `mpq_t`
# (relay chunk G3b). Built with `-Duse_gmp`, so the GMP-backed `BigRational`
# (the oracle) and the engine type sit in one binary.
#
# Build from the fork's root:
#   CRYSTAL_PATH=lib:$PWD/src crystal-alpha build --release -Duse_gmp scripts/big_num/rational_differential.cr -o bin/rational_differential
# Run:
#   bin/rational_differential --seed 1 --count 1000000 [--first-index 0] [--ops add,mul] [--max-bits 8192] [--json out.json]
#
# Operation `index % ops.size` runs at each index, with its own
# `Random::PCG32.new(seed, index)`, so the reproducer line a difference
# prints replays that one operation alone. Results are compared at the
# representation level (numerator and denominator limbs and signs) plus
# `to_s` bytes; comparisons by their raw return value; floats by their bits.
require "json"
require "option_parser"
require "./harness/gmp_oracle"
require "./harness/operand_source"
require "crystal/big_num"

module G3bDifferential
  alias Rational = Crystal::BigNum::Rational
  alias Integer = Crystal::BigNum::Integer
  alias Operand = G2Harness::Operand
  alias OperandSource = G2Harness::OperandSource

  LIST_OF_OPERATIONS = %w(canonicalize add sub mul div neg abs inv pow mul_2exp div_2exp
    cmp cmp_z cmp_si cmp_ui equal set_d get_d set_f to_s floor ceil trunc round_away round_even)

  # One rational drawn for both sides: the unreduced parts, built on each side
  # and canonicalized there.
  record Pair, numerator : Operand, denominator : Operand

  # Draws rationals of the shapes the brief asks for.
  class RationalSource
    getter operands : OperandSource
    # The generator under *operands*, for draws wider than 32 bits.
    getter random : Random::PCG32

    def initialize(@random : Random::PCG32, max_bits : Int32)
      @operands = OperandSource.new(@random, max_bits)
    end

    def int(bits : Int32? = nil) : Operand
      @operands.operand(bits)
    end

    def nonzero(bits : Int32? = nil) : Operand
      value = int(bits)
      value.zero? ? Operand.new(Slice[1_u64], @operands.sign) : value
    end

    def from_big(value : BigInt) : Operand
      Operand.new(G2Harness::GMPOracle.limbs(value).dup, value < 0)
    end

    def big(operand : Operand) : BigInt
      G2Harness::GMPOracle.from_limbs(operand.limbs, operand.negative)
    end

    # A product of small primes to random powers: highly composite.
    def composite : BigInt
      value = BigInt.new(1)
      [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31].each do |prime|
        value *= BigInt.new(prime) ** @operands.rand(0..(prime < 8 ? 60 : 12))
      end
      @operands.chance(0.5) ? value : value * big(nonzero(@operands.rand(1..256)))
    end

    def pair : Pair
      case @operands.rand(12)
      when 0 # zero, with any nonzero denominator
        Pair.new(Operand.new(Slice(UInt64).new(0), false), nonzero)
      when 1 # +-1
        Pair.new(Operand.new(Slice[1_u64], @operands.sign), Operand.new(Slice[1_u64], @operands.sign))
      when 2 # equal parts
        value = nonzero
        Pair.new(value, @operands.chance(0.5) ? value : value.negate)
      when 3 # a common factor in both parts
        factor = big(nonzero(@operands.bit_size // 2 + 1))
        Pair.new(from_big(big(int) * factor), from_big(big(nonzero) * factor))
      when 4 # highly composite parts
        Pair.new(from_big(composite * (@operands.sign ? -1 : 1)), from_big(composite))
      when 5 # coprime neighbors a / (a + 1)
        value = big(nonzero)
        Pair.new(from_big(value), from_big(value + 1 == 0 ? BigInt.new(2) : value + 1))
      when 6 # an integer
        Pair.new(int, Operand.new(Slice[1_u64], @operands.sign))
      when 7 # a power of two below
        Pair.new(int, from_big(BigInt.new(1) << @operands.rand(0..@operands.max_bits)))
      when 8 # sizes far apart
        Pair.new(nonzero(@operands.rand(1..64)), nonzero)
      else
        Pair.new(int, nonzero)
      end
    end

    # A finite double: edge values (zeros, subnormals, powers of two, the
    # largest and least finite values) or random bits.
    def float : Float64
      value = case @operands.rand(8)
              when 0
                @operands.sample([0.0, -0.0, Float64::MAX, -Float64::MAX, Float64::MIN_POSITIVE, -Float64::MIN_POSITIVE,
                                  Float64::MIN_POSITIVE.prev_float, 5.0e-324, -5.0e-324, 1.0, -1.0, 0.5, 2.0 ** 52, 2.0 ** 53])
              when 1 # subnormal
                (@random.rand(1_u64..0x000F_FFFF_FFFF_FFFF_u64) | (@operands.sign ? 1_u64 << 63 : 0_u64)).unsafe_as(Float64)
              when 2 # a power of two
                (@operands.sign ? -1.0 : 1.0) * Math.ldexp(1.0, @operands.rand(-1074..1023))
              when 3
                @operands.float
              else
                @random.rand(UInt64::MIN..UInt64::MAX).unsafe_as(Float64)
              end
      value.finite? ? value : 1.5
    end
  end

  # Both sides of one value.
  record Both, gmp : BigRational, engine : Rational

  def self.gmp_rational(pair : Pair, source : RationalSource) : BigRational
    BigRational.new(source.big(pair.numerator), source.big(pair.denominator))
  end

  def self.engine_integer(operand : Operand) : Integer
    Integer.from_limbs(operand.limbs, operand.negative)
  end

  def self.engine_rational(pair : Pair) : Rational
    Rational.new(engine_integer(pair.numerator), engine_integer(pair.denominator))
  end

  def self.both(source : RationalSource) : Both
    pair = source.pair
    Both.new(gmp_rational(pair, source), engine_rational(pair))
  end

  # A value near the edges of the double range, for `get_d`: an exact
  # double nudged by a tiny rational, or a power of two near the overflow
  # and underflow boundaries times a random fraction.
  def self.float_edge(source : RationalSource) : Both
    random = source.operands
    if random.chance(0.5)
      exact = BigRational.new(source.float)
      nudge = BigRational.new(BigInt.new(random.sign ? 1 : -1), source.big(source.nonzero) * (BigInt.new(1) << random.rand(60..1200)))
      value = exact + nudge
    else
      exponent = random.sample([-1080, -1075, -1074, -1073, -1060, -1023, -1022, -1021, 1022, 1023, 1024, 1025]) + random.rand(-3..3)
      fraction = BigRational.new(source.big(source.int(random.rand(1..120))), source.big(source.nonzero(random.rand(1..120))))
      power = exponent >= 0 ? BigRational.new(BigInt.new(1) << exponent, BigInt.new(1)) : BigRational.new(BigInt.new(1), BigInt.new(1) << -exponent)
      value = fraction * power
    end
    numerator = value.numerator
    denominator = value.denominator
    Both.new(value, Rational.new(engine_integer(source.from_big(numerator)), engine_integer(source.from_big(denominator))))
  end

  # The representation of a GMP rational: the parts' signed limbs, then the
  # decimal string GMP prints.
  def self.describe(value : BigRational) : String
    mpq = value.to_unsafe.value
    "#{describe_mpz(mpq._mp_num)} / #{describe_mpz(mpq._mp_den)} | #{value.to_s}"
  end

  def self.describe_mpz(mpz : LibGMP::MPZ) : String
    count = mpz._mp_size.abs
    limbs = Slice.new(mpz._mp_d, count).map(&.to_s(16)).join(',')
    "#{mpz._mp_size < 0 ? '-' : '+'}[#{limbs}]"
  end

  def self.describe(value : Rational) : String
    "#{describe_integer(value.numerator)} / #{describe_integer(value.denominator)} | #{value.to_s}"
  end

  def self.describe_integer(value : Integer) : String
    limbs = value.limbs.map(&.to_s(16)).join(',')
    "#{value.negative? ? '-' : '+'}[#{limbs}]"
  end

  def self.describe(value : Float64) : String
    "#{value} (0x#{value.unsafe_as(UInt64).to_s(16)})"
  end

  def self.integer_of(value : BigInt) : Integer
    Integer.from_limbs(G2Harness::GMPOracle.limbs(value), value < 0)
  end

  def self.rational_of(value : BigInt) : BigRational
    BigRational.new(value, BigInt.new(1))
  end

  # A GMP float of random precision whose value is a random rational,
  # truncated by `mpf_set_q`, or a random integer scaled by a power of two.
  def self.gmp_float(source : RationalSource) : BigFloat
    random = source.operands
    precision = source.random.rand(1_u64..4_096_u64)
    LibGMP.mpf_init2(out mpf, precision)
    if random.chance(0.5)
      LibGMP.mpf_set_q(pointerof(mpf), gmp_rational(source.pair, source))
    else
      LibGMP.mpf_set_z(pointerof(mpf), source.big(source.int))
      shift = source.random.rand(0_u64..5_000_u64)
      if random.chance(0.5)
        LibGMP.mpf_div_2exp(pointerof(mpf), pointerof(mpf), shift)
      else
        LibGMP.mpf_mul_2exp(pointerof(mpf), pointerof(mpf), shift)
      end
    end
    BigFloat.new(mpf)
  end

  # The engine's reading of a GMP float as mantissa * 2 ** exponent, from
  # its limbs (the same reading `BigFloat#exact_binary` makes in the default
  # build's GMP bridge).
  def self.exact_binary(value : BigFloat) : {Integer, Int64}
    mpf = value.to_unsafe.value
    signed_size = mpf._mp_size
    return {Integer.zero, 0_i64} if signed_size == 0
    count = signed_size.abs
    mantissa = Integer.from_limbs(Slice.new(mpf._mp_d, count, read_only: true), signed_size < 0)
    {mantissa, (mpf._mp_exp.to_i64 - count) * 64}
  end

  # Runs operation *name* on operands drawn from *source*: the operand
  # descriptions, then the GMP result and the engine result as strings.
  def self.run(name : String, source : RationalSource) : {Array(String), String, String}
    random = source.operands
    case name
    when "canonicalize"
      pair = source.pair
      {[pair.numerator.inspect, pair.denominator.inspect], describe(gmp_rational(pair, source)), describe(engine_rational(pair))}
    when "add", "sub", "mul", "div"
      a = both(source)
      b = both(source)
      b = Both.new(BigRational.new(1, 3), Rational.new(Integer.new(1), Integer.new(3))) if name == "div" && b.engine.zero?
      gmp = case name
            when "add" then a.gmp + b.gmp
            when "sub" then a.gmp - b.gmp
            when "mul" then a.gmp * b.gmp
            else            a.gmp / b.gmp
            end
      engine = case name
               when "add" then a.engine + b.engine
               when "sub" then a.engine - b.engine
               when "mul" then a.engine * b.engine
               else            a.engine / b.engine
               end
      {[describe(a.gmp), describe(b.gmp)], describe(gmp), describe(engine)}
    when "neg", "abs", "inv"
      a = both(source)
      a = Both.new(BigRational.new(-7, 5), Rational.new(Integer.new(-7), Integer.new(5))) if name == "inv" && a.engine.zero?
      gmp = name == "neg" ? -a.gmp : (name == "abs" ? a.gmp.abs : a.gmp.inv)
      engine = name == "neg" ? -a.engine : (name == "abs" ? a.engine.abs : a.engine.inv)
      {[describe(a.gmp)], describe(gmp), describe(engine)}
    when "pow"
      a = both(source)
      exponent = random.rand(0..(a.gmp.numerator.abs.bit_length + a.gmp.denominator.bit_length > 512 ? 3 : 12))
      exponent = -exponent if random.chance(0.3) && !a.engine.zero?
      {[describe(a.gmp), exponent.to_s], describe(a.gmp ** exponent), describe(a.engine ** exponent)}
    when "mul_2exp", "div_2exp"
      a = both(source)
      count = random.chance(0.2) ? source.random.rand(0_u64..3_u64) : source.random.rand(0_u64..9_000_u64)
      gmp = name == "mul_2exp" ? a.gmp << count : a.gmp >> count
      engine = name == "mul_2exp" ? a.engine << count : a.engine >> count
      {[describe(a.gmp), count.to_s], describe(gmp), describe(engine)}
    when "cmp", "equal"
      a = both(source)
      b = random.chance(0.15) ? a : both(source)
      if random.chance(0.2) # an integer, which GMP compares as mpq_cmp_z
        integer = source.int
        b = Both.new(BigRational.new(source.big(integer), BigInt.new(1)), Rational.new(engine_integer(integer)))
      end
      if random.chance(0.15) && !a.engine.zero?
        # neighbors: a and a +- 1/big
        nudge = BigRational.new(BigInt.new(1), source.big(source.nonzero))
        nudged = random.chance(0.5) ? a.gmp + nudge : a.gmp - nudge
        b = Both.new(nudged, Rational.new(integer_of(nudged.numerator), integer_of(nudged.denominator)))
      end
      if name == "cmp"
        {[describe(a.gmp), describe(b.gmp)], LibGMP.mpq_cmp(a.gmp, b.gmp).to_s, (a.engine <=> b.engine).to_s}
      else
        {[describe(a.gmp), describe(b.gmp)], (LibGMP.mpq_equal(a.gmp, b.gmp) != 0).to_s, (a.engine == b.engine).to_s}
      end
    when "cmp_z"
      a = both(source)
      z = random.chance(0.2) ? a.gmp.to_big_i : source.big(source.int)
      {[describe(a.gmp), z.to_s], LibGMP.mpq_cmp_z(a.gmp, z).to_s, (a.engine <=> integer_of(z)).to_s}
    when "cmp_si"
      a = random.chance(0.5) ? both(source) : small_both(source)
      n = random.chance(0.3) ? random.sample([0_i64, 1_i64, -1_i64, Int64::MIN, Int64::MAX]) : source.random.rand(Int64::MIN..Int64::MAX) >> random.rand(0..63)
      {[describe(a.gmp), n.to_s], LibGMP.mpq_cmp_si(a.gmp, n, 1).to_s, (a.engine <=> n).to_s}
    when "cmp_ui"
      a = random.chance(0.5) ? both(source) : small_both(source)
      n = random.chance(0.3) ? random.sample([0_u64, 1_u64, UInt64::MAX, 1_u64 << 63]) : source.random.rand(UInt64::MIN..UInt64::MAX) >> random.rand(0..63)
      {[describe(a.gmp), n.to_s], LibGMP.mpq_cmp_ui(a.gmp, n, 1).to_s, (a.engine <=> n).to_s}
    when "set_d"
      value = source.float
      gmp = BigRational.new { |mpq| LibGMP.mpq_set_d(mpq, value) }
      {[describe(value)], describe(gmp), describe(Rational.new(value))}
    when "get_d"
      a = random.chance(0.5) ? both(source) : float_edge(source)
      {[describe(a.gmp)], describe(LibGMP.mpq_get_d(a.gmp)), describe(a.engine.to_f64)}
    when "set_f"
      value = gmp_float(source)
      gmp = BigRational.new { |mpq| LibGMP.mpq_set_f(mpq, value) }
      mantissa, exponent = exact_binary(value)
      {["mpf #{value.to_unsafe.value._mp_size} limbs exp #{value.to_unsafe.value._mp_exp} prec #{value.to_unsafe.value._mp_prec}", describe_integer(mantissa)],
       describe(gmp), describe(Rational.from_binary(mantissa, exponent))}
    when "to_s"
      a = both(source)
      base = random.rand(2..36)
      {[describe(a.gmp), base.to_s], String.new(LibGMP.mpq_get_str(nil, base, a.gmp)), a.engine.to_s(base)}
    when "floor", "ceil", "trunc", "round_away", "round_even"
      a = both(source)
      gmp = case name
            when "floor"      then a.gmp.floor
            when "ceil"       then a.gmp.ceil
            when "trunc"      then a.gmp.trunc
            when "round_away" then a.gmp.round_away
            else                   a.gmp.round_even
            end
      integer = case name
                when "floor"      then a.engine.floor
                when "ceil"       then a.engine.ceil
                when "trunc"      then a.engine.trunc
                when "round_away" then a.engine.round_away
                else                   a.engine.round_even
                end
      {[describe(a.gmp)], describe(gmp), describe(Rational.new(integer))}
    else
      raise ArgumentError.new("Unknown operation #{name}")
    end
  end

  # A rational with small parts, so the primitive comparisons reach their
  # cross-multiplication branch.
  def self.small_both(source : RationalSource) : Both
    random = source.operands
    pair = Pair.new(source.int(random.rand(0..192)), source.nonzero(random.rand(1..192)))
    Both.new(gmp_rational(pair, source), engine_rational(pair))
  end

  struct Tally
    include JSON::Serializable
    property count : Int64 = 0
    property differences : Int64 = 0

    def initialize
    end
  end

  class Command
    @seed : UInt64 = 1
    @first_index : UInt64 = 0
    @count : Int64 = 10_000
    @max_bits : Int32 = 8_192
    @list_of_operations : Array(String) = LIST_OF_OPERATIONS.dup
    @json_path : String? = nil

    def initialize(arguments : Array(String))
      OptionParser.parse(arguments) do |parser|
        parser.banner = "usage: rational_differential [options]"
        parser.on("--seed N", "PCG32 seed (default 1)") { |value| @seed = value.to_u64 }
        parser.on("--first-index N", "first operation index (default 0)") { |value| @first_index = value.to_u64 }
        parser.on("--count N", "operations to run (default 10000)") { |value| @count = value.to_i64 }
        parser.on("--ops LIST", "comma-separated operations (default all)") { |value| @list_of_operations = value.split(',').map(&.strip) }
        parser.on("--max-bits N", "largest part size in bits (default 8192)") { |value| @max_bits = value.to_i }
        parser.on("--json PATH", "write the summary JSON here") { |value| @json_path = value }
      end
      unknown = @list_of_operations - LIST_OF_OPERATIONS
      raise ArgumentError.new("Unknown operations: #{unknown.join(", ")}") unless unknown.empty?
    end

    def perform : Int32
      tallies = @list_of_operations.to_h { |name| {name, Tally.new} }
      started = Time.instant
      @count.times do |offset|
        index = @first_index + offset.to_u64
        name = @list_of_operations[index % @list_of_operations.size]
        source = RationalSource.new(Random::PCG32.new(@seed, index), @max_bits)
        operands, gmp, engine = G3bDifferential.run(name, source)
        tally = tallies[name]
        tally.count += 1
        if gmp != engine
          tally.differences += 1
          STDOUT.puts "DIFFERENCE #{name} reproduce: rational_differential --seed #{@seed} --first-index #{index} --count 1 --ops #{@list_of_operations.join(',')} --max-bits #{@max_bits}"
          operands.each_with_index { |operand, position| STDOUT.puts "  operand #{position}: #{operand}" }
          STDOUT.puts "  gmp:    #{gmp}"
          STDOUT.puts "  engine: #{engine}"
        end
        tallies[name] = tally
      end
      total = tallies.values.sum(&.count)
      differences = tallies.values.sum(&.differences)
      summary = {
        seed: @seed, first_index: @first_index, count: @count, max_bits: @max_bits,
        gmp_version: G2Harness::GMPOracle.version, crystal_version: Crystal::VERSION,
        operations: tallies, total_count: total, total_differences: differences,
        elapsed_seconds: (Time.instant - started).total_seconds,
      }.to_pretty_json
      if path = @json_path
        File.write(path, summary + "\n")
      end
      STDOUT.puts "seed=#{@seed} first_index=#{@first_index} operations=#{total} differences=#{differences}"
      differences == 0 ? 0 : 1
    end
  end
end

exit G3bDifferential::Command.new(ARGV).perform
