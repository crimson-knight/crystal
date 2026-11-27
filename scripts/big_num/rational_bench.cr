# Times `Crystal::BigNum::Rational` against GMP's `mpq_t` (through the
# GMP-backed `BigRational`) for +, * and <=> at several part sizes.
#
# Build from the fork's root:
#   CRYSTAL_PATH=lib:$PWD/src crystal-alpha build --release -Duse_gmp scripts/big_num/rational_bench.cr -o bin/rational_bench
# Run:
#   bin/rational_bench [rounds=6]
#
# Each row runs `rounds` interleaved rounds (ours, then GMP); the table shows
# the median ns/op of each side and ratio = GMP time / our time. Both sides
# see the same operands: numerators and denominators of exactly `bits` bits,
# dense and random, canonicalized before timing.
require "./harness/gmp_oracle"
require "./harness/operand_source"
require "crystal/big_num"

module G3bBench
  alias Rational = Crystal::BigNum::Rational
  alias Integer = Crystal::BigNum::Integer

  POOL = 64

  def self.pairs(bits : Int32) : {Array(BigRational), Array(Rational)}
    source = G2Harness::OperandSource.new(Random::PCG32.new(bits.to_u64))
    gmp = [] of BigRational
    ours = [] of Rational
    (POOL * 2).times do
      numerator = source.dense_of(bits, source.sign)
      denominator = source.dense_of(bits)
      gmp << BigRational.new(G2Harness::GMPOracle.from_limbs(numerator.limbs, numerator.negative),
        G2Harness::GMPOracle.from_limbs(denominator.limbs, false))
      ours << Rational.new(Integer.from_limbs(numerator.limbs, numerator.negative), Integer.from_limbs(denominator.limbs, false))
    end
    {gmp, ours}
  end

  # Nanoseconds per call of the block over *iterations* calls.
  def self.time(iterations : Int32, &) : Float64
    started = Time.instant
    iterations.times { |index| yield index }
    (Time.instant - started).total_nanoseconds / iterations
  end

  def self.median(values : Array(Float64)) : Float64
    sorted = values.sort
    middle = sorted.size // 2
    sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  end

  def self.perform(rounds : Int32) : Nil
    puts "| operation | bits per part | ours ns/op | GMP ns/op | GMP / ours |"
    puts "|---|---:|---:|---:|---:|"
    [64, 256, 1_024, 4_096].each do |bits|
      gmp, ours = pairs(bits)
      iterations = Math.max(1_000, 20_000_000 // (bits * bits // 64 + 64))
      sink = 0_i64
      %w(add mul compare).each do |operation|
        our_times = [] of Float64
        gmp_times = [] of Float64
        rounds.times do
          our_times << time(iterations) do |index|
            left = ours[index % POOL]
            right = ours[POOL + index % POOL]
            case operation
            when "add" then sink &+= (left + right).numerator.size
            when "mul" then sink &+= (left * right).numerator.size
            else            sink &+= left <=> right
            end
          end
          gmp_times << time(iterations) do |index|
            left = gmp[index % POOL]
            right = gmp[POOL + index % POOL]
            case operation
            when "add" then sink &+= (left + right).to_unsafe.value._mp_num._mp_size
            when "mul" then sink &+= (left * right).to_unsafe.value._mp_num._mp_size
            else            sink &+= LibGMP.mpq_cmp(left, right)
            end
          end
        end
        ours_ns = median(our_times)
        gmp_ns = median(gmp_times)
        puts "| #{operation} | #{bits} | #{ours_ns.round(1)} | #{gmp_ns.round(1)} | #{(gmp_ns / ours_ns).round(2)} |"
      end
      STDERR.puts "sink #{sink}"
    end
  end
end

G3bBench.perform((ARGV[0]? || "6").to_i)
