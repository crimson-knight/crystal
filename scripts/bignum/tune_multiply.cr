# Finds the multiplication thresholds of `Crystal::BigNum::Multiply` on this
# processor, the way the thresholds in `multiply.cr` were set:
#
#   CRYSTAL_PATH=$PWD/src crystal-alpha build --release -Dbignum_threshold_tuning \
#     scripts/bignum/tune_multiply.cr -o tune_multiply
#   ./tune_multiply
#
# For each threshold it times, at every size in its range, the product with
# the faster algorithm taking over at the top level against the product
# without it (median of 9 runs), and reports the first size from which the
# faster algorithm wins at that size and the next three.
require "../../src/crystal/big_num"

alias Engine = Crystal::BigNum
alias Multiply = Crystal::BigNum::Multiply

NEVER = Int32::MAX // 4

def time_of(iterations : Int32, &) : Float64
  start = Time.instant
  iterations.times { yield }
  (Time.instant - start).total_nanoseconds / iterations
end

def median_time(iterations : Int32, &block : ->) : Float64
  times = Array(Float64).new(9) { time_of(iterations) { block.call } }
  times.sort[4]
end

random = Random::PCG32.new(11_u64)
a = Slice(Engine::Limb).new(1024) { random.rand(Engine::Limb::MAX) }
b = Slice(Engine::Limb).new(1024) { random.rand(Engine::Limb::MAX) }
r = Slice(Engine::Limb).new(2048)

# Whether the algorithm switched on by *enable* beats the one before it at *size*.
def crossover(label : String, range : Range(Int32, Int32), &measure : Int32, Bool -> Float64) : Int32
  wins = [] of Int32
  range.each do |size|
    time_without = measure.call(size, false)
    time_with = measure.call(size, true)
    STDERR.printf("%s %4d  without %10.1f ns  with %10.1f ns  %s\n", label, size, time_without, time_with, time_with < time_without ? "faster" : "")
    wins << size if time_with < time_without
  end
  found = range.find { |size| (0..3).all? { |step| wins.includes?(size + step) || size + step > range.end } }
  found || range.end
end

iterations_for = ->(size : Int32) { Math.max(20, 4_000_000 // (size * size)) }

mul_karatsuba = crossover("MUL_KARATSUBA", 8..64) do |size, enable|
  Multiply.mul_karatsuba_threshold = enable ? size : NEVER
  Multiply.mul_toom3_threshold = NEVER
  median_time(iterations_for.call(size)) { Multiply.mul(r.to_unsafe, a.to_unsafe, size, b.to_unsafe, size) }
end
Multiply.mul_karatsuba_threshold = mul_karatsuba

mul_toom3 = crossover("MUL_TOOM3", (mul_karatsuba + 8)..300) do |size, enable|
  Multiply.mul_toom3_threshold = enable ? size : NEVER
  median_time(iterations_for.call(size)) { Multiply.mul(r.to_unsafe, a.to_unsafe, size, b.to_unsafe, size) }
end
Multiply.mul_toom3_threshold = mul_toom3

sqr_karatsuba = crossover("SQR_KARATSUBA", 8..96) do |size, enable|
  Multiply.sqr_karatsuba_threshold = enable ? size : NEVER
  Multiply.sqr_toom3_threshold = NEVER
  median_time(iterations_for.call(size)) { Multiply.sqr(r.to_unsafe, a.to_unsafe, size) }
end
Multiply.sqr_karatsuba_threshold = sqr_karatsuba

sqr_toom3 = crossover("SQR_TOOM3", (sqr_karatsuba + 8)..400) do |size, enable|
  Multiply.sqr_toom3_threshold = enable ? size : NEVER
  median_time(iterations_for.call(size)) { Multiply.sqr(r.to_unsafe, a.to_unsafe, size) }
end

puts %({"MUL_KARATSUBA_THRESHOLD": #{mul_karatsuba}, "MUL_TOOM3_THRESHOLD": #{mul_toom3}, "SQR_KARATSUBA_THRESHOLD": #{sqr_karatsuba}, "SQR_TOOM3_THRESHOLD": #{sqr_toom3}})
