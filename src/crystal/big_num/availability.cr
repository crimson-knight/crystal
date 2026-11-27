# Which engine runs the big types, as constants that macros can read
# (`{% if Crystal::BigNum::BACKS_BIG_TYPES %}`). `src/big.cr` and the specs
# decide from these two, so the rule lives here only.
# This file loads no engine code, so any target can require it.
module Crystal::BigNum
  {% if flag?(:bits64) %}
    # :nodoc:
    #
    # Whether the engine compiles for this target: its kernels are written
    # for 64-bit limbs.
    TARGET_SUPPORTED = true
  {% else %}
    # :nodoc:
    TARGET_SUPPORTED = false
  {% end %}

  {% if flag?(:bits64) && !flag?(:use_gmp) %}
    # :nodoc:
    #
    # Whether `BigInt`, `BigFloat`, `BigRational` and `BigDecimal` run on this
    # engine (`src/big/pure/`). They run on GMP (`src/big/gmp/`) under
    # `-Duse_gmp` and on every 32-bit target.
    BACKS_BIG_TYPES = true
  {% else %}
    # :nodoc:
    BACKS_BIG_TYPES = false
  {% end %}
end
