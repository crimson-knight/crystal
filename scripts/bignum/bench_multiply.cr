# Multiplication bench (BIGNUM.md 5.3): ours (`Crystal::BigNum::Integer#*`)
# against GMP (`BigInt#*`) on the same operands, in one binary.
#
#   CRYSTAL_PATH=$PWD/src crystal-alpha build --release scripts/bignum/bench_multiply.cr -o bench_multiply
#   ./bench_multiply [max_bits] [rounds]
#
# Each row is the median over the rounds of ns per operation; ours and GMP
# alternate within every round. Ratio = GMP time / our time.
require "big"
require "../../src/crystal/big_num"

alias Engine = Crystal::BigNum

def random_integer(random : Random, bits : Int32) : Engine::Integer
  count = (bits + 63) // 64
  limbs = Slice(Engine::Limb).new(count) { random.rand(Engine::Limb::MAX) }
  limbs[count - 1] |= Engine::Limb.new(1) << 63
  Engine::Integer.from_limbs(limbs, false)
end

def to_big(value : Engine::Integer) : BigInt
  value.limbs.reverse_each.reduce(BigInt.new(0)) { |sum, limb| (sum << 64) + limb }
end

# ns per call of the block, timed over enough calls to take about 20 ms.
def time_per_operation(iterations : Int32, &) : Float64
  start = Time.instant
  iterations.times { yield }
  (Time.instant - start).total_nanoseconds / iterations
end

def median(values : Array(Float64)) : Float64
  sorted = values.sort
  (sorted[(sorted.size - 1) // 2] + sorted[sorted.size // 2]) / 2
end

max_bits = (ARGV[0]? || "1048576").to_i
rounds = (ARGV[1]? || "6").to_i
random = Random::PCG32.new(42_u64)
sink = 0_u64
puts "| row | bits | ours ns/op | GMP ns/op | GMP / ours |"
puts "|---|---|---:|---:|---:|"
[64, 128, 256, 512, 1024, 2048, 4096, 8192, 32768, 131072, 1048576].each do |bits|
  next if bits > max_bits
  {"mul balanced", "mul n x n/4", "sqr"}.each do |row|
    a = random_integer(random, bits)
    b = case row
        when "mul balanced" then random_integer(random, bits)
        when "sqr"          then a
        else                     random_integer(random, Math.max(64, bits // 4))
        end
    big_a = to_big(a)
    big_b = row == "sqr" ? big_a : to_big(b)
    raise "mismatch #{row} #{bits}" unless to_big(a * b) == big_a * big_b
    # calibrate on GMP: about 20 ms per measurement
    probe = time_per_operation(3) { sink &+= (big_a * big_b).to_u64! }
    iterations = Math.max(3, (20_000_000.0 / Math.max(probe, 1.0)).to_i)
    ours = [] of Float64
    theirs = [] of Float64
    rounds.times do
      ours << time_per_operation(iterations) { sink &+= (a * b).size.to_u64 }
      theirs << time_per_operation(iterations) { sink &+= (big_a * big_b).to_u64! }
    end
    ours_median = median(ours)
    theirs_median = median(theirs)
    printf("| %s | %d | %.1f | %.1f | %.2f |\n", row, bits, ours_median, theirs_median, theirs_median / ours_median)
  end
end
STDERR.puts sink if sink == 42
