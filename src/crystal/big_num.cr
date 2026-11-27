# :nodoc:
#
# The pure-Crystal engine under `BigInt` (and later `BigFloat` and
# `BigRational`): limb kernels, the per-processor kernel choice, and the
# integer type. Every algorithm is written from Knuth and the published
# papers; GMP serves only as the oracle in the differential specs.
module Crystal::BigNum
end

require "./big_num/limbs"
require "./big_num/limbs_aarch64"
require "./big_num/processor_kernels"
require "./big_num/multiply"
require "./big_num/integer"
require "./big_num/divide"
require "./big_num/integer_division"
