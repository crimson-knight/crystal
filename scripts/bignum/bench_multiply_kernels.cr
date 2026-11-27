# Kernel-level bench: our `Limbs` and `Multiply` routines against GMP's `mpn`
# functions on raw limbs (GMP as a black-box oracle for timing only).
#
#   CRYSTAL_PATH=$PWD/src crystal-alpha build --release scripts/bignum/bench_multiply_kernels.cr -o bench_kernels
#   ./bench_kernels
require "big"
require "../../src/crystal/big_num"

alias Engine = Crystal::BigNum
alias Limb = Crystal::BigNum::Limb

@[Link("gmp")]
lib LibGMPKernels
  fun addmul_1 = __gmpn_addmul_1(rp : UInt64*, ap : UInt64*, n : LibC::Long, b : UInt64) : UInt64
  fun mul_1 = __gmpn_mul_1(rp : UInt64*, ap : UInt64*, n : LibC::Long, b : UInt64) : UInt64
  fun mul = __gmpn_mul(rp : UInt64*, ap : UInt64*, an : LibC::Long, bp : UInt64*, bn : LibC::Long) : UInt64
  fun add_n = __gmpn_add_n(rp : UInt64*, ap : UInt64*, bp : UInt64*, n : LibC::Long) : UInt64
  fun sub_n = __gmpn_sub_n(rp : UInt64*, ap : UInt64*, bp : UInt64*, n : LibC::Long) : UInt64
  fun sqr = __gmpn_sqr(rp : UInt64*, ap : UInt64*, n : LibC::Long) : Void
end

def time_per_operation(iterations : Int32, &) : Float64
  start = Time.instant
  iterations.times { yield }
  (Time.instant - start).total_nanoseconds / iterations
end

def median(values : Array(Float64)) : Float64
  sorted = values.sort
  sorted[sorted.size // 2]
end

def compare(label : String, iterations : Int32, ours : Proc(Nil), theirs : Proc(Nil)) : Nil
  ours_times = [] of Float64
  theirs_times = [] of Float64
  7.times do
    ours_times << time_per_operation(iterations) { ours.call }
    theirs_times << time_per_operation(iterations) { theirs.call }
  end
  o = median(ours_times)
  t = median(theirs_times)
  printf("%-24s ours %9.1f ns  GMP %9.1f ns  GMP/ours %.2f\n", label, o, t, t / o)
end

random = Random::PCG32.new(7_u64)
a = Slice(Limb).new(4096) { random.rand(Limb::MAX) }
b = Slice(Limb).new(4096) { random.rand(Limb::MAX) }
r = Slice(Limb).new(8192 + 8)
sizes = (ARGV[0]? || "4,8,12,16,20,24,28,32,40,48,64,96,128,256").split(',').map(&.to_i)
sizes.each do |n|
  iterations = Math.max(200, 20_000_000 // (n * n + 50))
  compare("addmul_1 #{n}", iterations * 4,
    -> { Engine::Limbs.addmul_1(r.to_unsafe, a.to_unsafe, n, b[0]); nil },
    -> { LibGMPKernels.addmul_1(r.to_unsafe, a.to_unsafe, n, b[0]); nil })
  compare("add_n #{n}", iterations * 4,
    -> { Engine::Limbs.add_n(r.to_unsafe, a.to_unsafe, b.to_unsafe, n); nil },
    -> { LibGMPKernels.add_n(r.to_unsafe, a.to_unsafe, b.to_unsafe, n); nil })
  compare("sub_n #{n}", iterations * 4,
    -> { Engine::Limbs.sub_n(r.to_unsafe, a.to_unsafe, b.to_unsafe, n); nil },
    -> { LibGMPKernels.sub_n(r.to_unsafe, a.to_unsafe, b.to_unsafe, n); nil })
  compare("mul #{n}x#{n}", iterations,
    -> { Engine::Multiply.mul(r.to_unsafe, a.to_unsafe, n, b.to_unsafe, n); nil },
    -> { LibGMPKernels.mul(r.to_unsafe, a.to_unsafe, n, b.to_unsafe, n); nil })
  compare("sqr #{n}", iterations,
    -> { Engine::Multiply.sqr(r.to_unsafe, a.to_unsafe, n); nil },
    -> { LibGMPKernels.sqr(r.to_unsafe, a.to_unsafe, n); nil })
end
