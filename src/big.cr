# :nodoc: Forward declarations
struct BigInt < Int
end

struct BigFloat < Float
end

struct BigRational < Number
end

struct BigDecimal < Number
end

# The engine: `BigInt`, `BigFloat`, `BigRational` and `BigDecimal` run on the
# pure-Crystal `Crystal::BigNum` by default, and nothing links libgmp; see
# `doc/big_num.md`. The compiler flag `-Duse_gmp` selects GMP instead
# (`src/big/gmp/`, links `libgmp`). The flag is kept for one release, so
# programs can compare the two engines before it goes away.
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
