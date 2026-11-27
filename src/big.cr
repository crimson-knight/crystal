# :nodoc: Forward declarations
struct BigInt < Int
end

struct BigFloat < Float
end

struct BigRational < Number
end

struct BigDecimal < Number
end

# The engine: `BigInt` on the pure-Crystal `Crystal::BigNum::Integer` by
# default, or every big type on GMP under `-Duse_gmp` (`src/big/gmp/`).
# `BigFloat`, `BigRational` and `BigDecimal` stay on GMP in both builds for
# now; in the default build they reach `BigInt` through `big/gmp_bridge`.
{% if flag?(:use_gmp) %}
  require "./big/lib_gmp"
  require "./big/gmp/big_int"
  require "./big/gmp/big_float"
  require "./big/gmp/big_rational"
  require "./big/gmp/big_decimal"
  require "./big/gmp/number"
{% else %}
  require "./crystal/big_num"
  require "./big/lib_gmp"
  require "./big/big_int"
  require "./big/gmp_bridge"
  require "./big/big_float"
  require "./big/big_rational"
  require "./big/big_decimal"
  require "./big/number"
{% end %}
