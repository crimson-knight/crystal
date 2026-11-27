# :nodoc: Forward declarations
struct BigInt < Int
end

struct BigFloat < Float
end

struct BigRational < Number
end

struct BigDecimal < Number
end

# The engine: every big type runs on the pure-Crystal `Crystal::BigNum`
# (`src/big/pure/`) by default, or on GMP (`src/big/gmp/`) under `-Duse_gmp`.
# 32-bit targets always use GMP: the engine's kernels are written for 64-bit
# limbs.
{% if flag?(:use_gmp) || !flag?(:bits64) %}
  require "./big/lib_gmp"
  require "./big/gmp/big_int"
  require "./big/gmp/big_float"
  require "./big/gmp/big_rational"
  require "./big/gmp/big_decimal"
  require "./big/gmp/number"
{% else %}
  require "./crystal/big_num"
  require "./big/pure/big_int"
  require "./big/pure/big_float"
  require "./big/pure/big_rational"
  require "./big/pure/big_decimal"
  require "./big/pure/number"
{% end %}
