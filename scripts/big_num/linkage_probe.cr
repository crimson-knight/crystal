# The linkage probe's program (BIGNUM.md 5.4): requires "big" and uses
# `BigInt` only, across its public surface. `scripts/big_num/linkage_probe.rb`
# builds it twice and reads the binaries; it is never run for its output.
require "big"

a = BigInt.new("123456789012345678901234567890")
b = 987_654_321.to_big_i << 100
c = (a * b + a - b) // 7_u8
d = (c % 1_000_003) ** 3
e = a.gcd(b) + a.lcm(17) + Math.isqrt(b) + 25.to_big_i.factorial
f = (a & b) | (a ^ ~b) >> 3
g = BigInt.from_digits([1, 2, 3])
comparisons = {a < b, a == 1.5, a <=> 2.0**70, a.divisible_by?(3), a.bit(5)}
quotient, remainder = a.divmod(-12_345)
puts a.to_s(16), c, d, e.to_s(precision: 40), f, g, comparisons, quotient, remainder
puts a.to_i64!, b.to_u128!, a.to_f64, a.hash, a.popcount, a.trailing_zeros_count, a.bit_length
puts BigInt.new(1e40), a.digits.size, a.factor_by(3), b.tdiv(-7), b.remainder(-7)
