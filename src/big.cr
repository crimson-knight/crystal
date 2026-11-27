# :nodoc: Forward declarations
struct BigInt < Int
end

struct BigFloat < Float
end

struct BigRational < Number
end

struct BigDecimal < Number
end

# The engine: every big type runs on the pure-Crystal `Crystal::BigNum` by
# default, or on GMP under `-Duse_gmp` (`src/big/gmp/`).
{% if flag?(:use_gmp) %}
  require "./big/lib_gmp"
  require "./big/gmp/big_int"
  require "./big/gmp/big_float"
  require "./big/gmp/big_rational"
  require "./big/gmp/big_decimal"
  require "./big/gmp/number"
{% else %}
  require "./crystal/big_num"
  require "./big/big_int"
  require "./big/big_float"
  require "./big/big_rational"
  require "./big/big_decimal"
  require "./big/number"
{% end %}
