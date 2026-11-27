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
# pure-Crystal `Crystal::BigNum` (`src/big/pure/`) by default, and nothing links
# libgmp; see `doc/big_num.md`. The compiler flag `-Duse_gmp` selects GMP
# instead (`src/big/gmp/`, links `libgmp`). The flag is kept for one release,
# so programs can compare the two engines before it goes away. 32-bit targets
# always use GMP: the engine kernels are written for 64-bit limbs.
# `Crystal::BigNum::BACKS_BIG_TYPES` holds the choice.
require "./crystal/big_num/availability"

{% unless Crystal::BigNum::BACKS_BIG_TYPES %}
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
