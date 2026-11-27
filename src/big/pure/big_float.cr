require "big"

# A `BigFloat` can represent arbitrarily large floats.
#
# It is implemented in pure Crystal (`Crystal::BigNum::Float`) with the
# semantics of GMP's `mpf_t`: the precision is a minimum in bits, kept in
# whole 64-bit limbs plus one, and results are truncated. The `-Duse_gmp`
# compile-time flag switches it back to [GMP](https://gmplib.org/).
#
# NOTE: To use `BigFloat`, you must explicitly import it with `require "big"`
struct BigFloat < Float
  include Comparable(Int)
  include Comparable(BigFloat)
  include Comparable(Float)

  @value : Crystal::BigNum::Float

  # :nodoc:
  #
  # The value, held by the engine.
  def big_num_value : Crystal::BigNum::Float
    @value
  end

  def initialize
    @value = Crystal::BigNum::Float.zero
  end

  def initialize(str : String)
    # Strip leading '+' char to smooth out cases with strings like "+123"
    str = str.lchop('+')
    # Strip '_' to make it compatible with int literals like "1_000_000"
    str = str.delete('_')
    @value = Crystal::BigNum::Float.parse?(str) || raise ArgumentError.new("Invalid BigFloat: #{str.inspect}")
  end

  def initialize(num : BigInt)
    @value = Crystal::BigNum::Float.from_integer(num.big_num_value)
  end

  def initialize(num : BigRational)
    @value = Crystal::BigNum::Float.from_rational(num.numerator.big_num_value, num.denominator.big_num_value)
  end

  def initialize(num : BigFloat)
    @value = num.big_num_value.set
  end

  def initialize(num : Int)
    @value = BigFloat.engine_value(num)
  end

  def initialize(num : Float::Primitive)
    @value = Crystal::BigNum::Float.from_f64(num.to_f64)
  end

  def initialize(num : Number)
    @value = Crystal::BigNum::Float.from_f64(num.to_f64)
  end

  def initialize(num : Float, precision : Int)
    raise ArgumentError.new "Can only construct from a finite number" unless num.finite?
    @value = Crystal::BigNum::Float.from_f64(num.to_f64, Crystal::BigNum::Float.limb_precision(precision.to_u64))
  end

  # :nodoc:
  def initialize(@value : Crystal::BigNum::Float)
  end

  # The engine value of the integer *num* at the default precision, as
  # `mpf_set_si`, `mpf_set_ui` or `mpf_set_z` gives it.
  protected def self.engine_value(num : Int) : Crystal::BigNum::Float
    Int.primitive_si_ui_check(num) do |si, ui, big_i|
      {
        si:    Crystal::BigNum::Float.from_i64({{ si }}),
        ui:    Crystal::BigNum::Float.from_u64({{ ui }}),
        big_i: Crystal::BigNum::Float.from_integer({{ big_i }}.big_num_value),
      }
    end
  end

  # The default precision in bits, rounded up to whole limbs as GMP's
  # `mpf_get_default_prec` reports it (64 at startup).
  def self.default_precision : UInt64
    Crystal::BigNum::Float.default_precision
  end

  # Sets the default precision, in bits, of every `BigFloat` made from now
  # on, in every thread.
  def self.default_precision=(prec : Int) : Nil
    Crystal::BigNum::Float.default_precision = prec.to_u64
  end

  # :inherit:
  def nan? : Bool
    # there are no NaNs in BigFloat
    false
  end

  # :inherit:
  def infinite? : Int32?
    # there are no infinities in BigFloat
    nil
  end

  def <=>(other : BigFloat)
    @value <=> other.big_num_value
  end

  def <=>(other : BigInt)
    @value.cmp_z(other.big_num_value)
  end

  def <=>(other : Float::Primitive) : Int32?
    @value.cmp_d(other.to_f64) unless other.nan?
  end

  def <=>(other : Int) : Int32
    Int.primitive_si_ui_check(other) do |si, ui, big_i|
      {
        si:    @value.cmp_si({{ si }}),
        ui:    @value.cmp_ui({{ ui }}),
        big_i: self <=> {{ big_i }},
      }
    end
  end

  def <=>(other : Number)
    @value <=> other.to_big_f.big_num_value
  end

  def - : BigFloat
    BigFloat.new(@value.neg)
  end

  def +(other : Int::Primitive) : BigFloat
    Int.primitive_ui_check(other) do |ui, neg_ui, big_i|
      {
        ui:     BigFloat.new(@value.add_ui({{ ui }})),
        neg_ui: BigFloat.new(@value.sub_ui({{ neg_ui }})),
        big_i:  self + {{ big_i }},
      }
    end
  end

  def +(other : Number) : BigFloat
    BigFloat.new(@value.add(other.to_big_f.big_num_value))
  end

  def -(other : Int::Primitive) : BigFloat
    Int.primitive_ui_check(other) do |ui, neg_ui, big_i|
      {
        ui:     BigFloat.new(@value.sub_ui({{ ui }})),
        neg_ui: BigFloat.new(@value.add_ui({{ neg_ui }})),
        big_i:  self - {{ big_i }},
      }
    end
  end

  def -(other : Number) : BigFloat
    BigFloat.new(@value.sub(other.to_big_f.big_num_value))
  end

  def *(other : Int::Primitive) : BigFloat
    Int.primitive_ui_check(other) do |ui, neg_ui, big_i|
      {
        ui:     BigFloat.new(@value.mul_ui({{ ui }})),
        neg_ui: BigFloat.new(@value.mul_ui({{ neg_ui }}).negate),
        big_i:  self * {{ big_i }},
      }
    end
  end

  def *(other : Number) : BigFloat
    BigFloat.new(@value.mul(other.to_big_f.big_num_value))
  end

  def /(other : Int::Primitive) : BigFloat
    # Division by 0 in BigFloat is not allowed, there is no BigFloat::Infinity
    raise DivisionByZeroError.new if other == 0
    Int.primitive_ui_check(other) do |ui, neg_ui, _|
      {
        ui:     BigFloat.new(@value.div_ui({{ ui }})),
        neg_ui: BigFloat.new(@value.div_ui({{ neg_ui }}).negate),
        big_i:  BigFloat.new(@value.div(BigFloat.new(other).big_num_value)),
      }
    end
  end

  def /(other : BigFloat) : BigFloat
    # Division by 0 in BigFloat is not allowed, there is no BigFloat::Infinity
    raise DivisionByZeroError.new if other == 0
    BigFloat.new(@value.div(other.big_num_value))
  end

  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational

  def **(other : BigInt) : BigFloat
    is_zero = self.zero?
    if is_zero
      case other
      when .>(0)
        return self
      when .<(0)
        # there is no BigFloat::Infinity
        raise ArgumentError.new "Cannot raise 0 to a negative power"
      end
    end

    result = Crystal::BigNum::Float.from_i64(1_i64)
    # define `0 ** 0 == 1`
    return BigFloat.new(result) if is_zero

    exponent = other.abs
    base_power = @value.set
    while exponent > 0
      result = result.mul(base_power) if exponent.to_i!.odd?
      exponent >>= 1
      base_power = base_power.mul(base_power) if exponent > 0
    end
    result = Crystal::BigNum::Float.ui_div(1_u64, result) if other < 0
    BigFloat.new(result)
  end

  def **(other : Int) : BigFloat
    # there is no BigFloat::Infinity
    if zero? && other < 0
      raise ArgumentError.new "Cannot raise 0 to a negative power"
    end

    Int.primitive_ui_check(other) do |ui, neg_ui, big_i|
      {
        ui:     BigFloat.new(@value.pow_ui({{ ui }})),
        neg_ui: BigFloat.new(Crystal::BigNum::Float.ui_div(1_u64, @value.pow_ui({{ neg_ui }}))),
        big_i:  self ** {{ big_i }},
      }
    end
  end

  def abs : BigFloat
    BigFloat.new(@value.abs)
  end

  # Rounds towards positive infinity.
  def ceil : BigFloat
    BigFloat.new(@value.ceil)
  end

  # Rounds towards negative infinity.
  def floor : BigFloat
    BigFloat.new(@value.floor)
  end

  # Rounds towards zero.
  def trunc : BigFloat
    BigFloat.new(@value.trunc)
  end

  # Returns the value as a `Float64`, truncated toward zero (not rounded).
  def to_f64 : Float64
    @value.to_f64
  end

  def to_f32 : Float32
    to_f64.to_f32
  end

  def to_f : Float64
    to_f64
  end

  def to_f32! : Float32
    to_f64.to_f32!
  end

  def to_f64! : Float64
    to_f64
  end

  def to_f! : Float64
    to_f64!
  end

  def to_big_f : BigFloat
    self
  end

  def to_big_i : BigInt
    BigInt.new(@value.to_integer)
  end

  def to_i64 : Int64
    raise OverflowError.new unless Int64::MIN <= self <= Int64::MAX
    @value.get_si
  end

  def to_i32 : Int32
    to_i64.to_i32
  end

  def to_i16 : Int16
    to_i64.to_i16
  end

  def to_i8 : Int8
    to_i64.to_i8
  end

  def to_i : Int32
    to_i32
  end

  def to_i! : Int32
    to_i32!
  end

  def to_i8! : Int8
    @value.get_si.to_i8!
  end

  def to_i16! : Int16
    @value.get_si.to_i16!
  end

  def to_i32! : Int32
    @value.get_si.to_i32!
  end

  def to_i64! : Int64
    @value.get_si
  end

  def to_u64 : UInt64
    raise OverflowError.new unless 0 <= self <= UInt64::MAX
    @value.get_ui
  end

  def to_u32 : UInt32
    to_u64.to_u32
  end

  def to_u16 : UInt16
    to_u64.to_u16
  end

  def to_u8 : UInt8
    to_u64.to_u8
  end

  def to_u : UInt32
    to_u32
  end

  def to_u! : UInt32
    to_u32!
  end

  def to_u8! : UInt8
    @value.get_ui.to_u8!
  end

  def to_u16! : UInt16
    @value.get_ui.to_u16!
  end

  def to_u32! : UInt32
    @value.get_ui.to_u32!
  end

  def to_u64! : UInt64
    @value.get_ui
  end

  # :nodoc:
  #
  # The value as `{m, e}` with `self == m * 2 ** e` exactly; `m` is odd, or
  # both are zero for zero.
  def exact_binary : {BigInt, Int64}
    mantissa, exponent = @value.exact_binary
    {BigInt.new(mantissa), exponent}
  end

  def to_s(io : IO) : Nil
    to_s_impl(io, point_range: -3..15, int_trailing_zeros: true)
  end

  protected def to_s_impl(*, point_range : Range, int_trailing_zeros : Bool) : String
    String.build { |io| to_s_impl(io, point_range: point_range, int_trailing_zeros: int_trailing_zeros) }
  end

  protected def to_s_impl(io : IO, *, point_range : Range, int_trailing_zeros : Bool) : Nil
    digits, decimal_exponent = @value.to_digits
    buffer = digits.to_slice

    # add negative sign
    if buffer[0]? == 45 # '-'
      io << '-'
      buffer = buffer[1..]
    end

    decimal_exponent -= buffer.size
    if int_trailing_zeros
      # the digits never end in a zero
      fraction = Float::Printer::FractionMode::WriteAll
    else
      # used by the Ryu Printf specs only
      fraction = Float::Printer::FractionMode::RemoveIfZero
    end

    Float::Printer.decimal(io, buffer, decimal_exponent, point_range, fraction)
  end

  # :inherit:
  def format(io : IO, separator = '.', delimiter = ',', decimal_places : Int? = nil, *, group : Int = 3, only_significant : Bool = false) : Nil
    number = self
    if decimal_places
      number = number.round(decimal_places)
    end

    if decimal_places && decimal_places >= 0
      string = number.abs.to_s_impl(point_range: .., int_trailing_zeros: true)
      integer, _, decimals = string.partition('.')
    else
      string = number.to_s_impl(point_range: .., int_trailing_zeros: true)
      _, _, decimals = string.partition(".")
      integer = number.trunc.to_big_i.abs.to_s
    end

    is_negative = number < 0

    format_impl(io, is_negative, integer, decimals, separator, delimiter, decimal_places, group, only_significant)
  end

  def clone : BigFloat
    self
  end

  # Rounds towards the nearest integer. If both neighboring integers are equidistant,
  # rounds towards the even neighbor (Banker's rounding).
  def round_even : self
    if self >= 0
      halfway = self + 0.5
    else
      halfway = self - 0.5
    end
    if halfway.integer?
      if halfway == (halfway / 2).trunc * 2
        halfway
      else
        halfway - sign
      end
    else
      if self >= 0
        halfway.floor
      else
        halfway.ceil
      end
    end
  end

  # Rounds towards the nearest integer. If both neighboring integers are equidistant,
  # rounds away from zero.
  def round_away : self
    if self >= 0
      (self + 0.5).floor
    else
      (self - 0.5).ceil
    end
  end

  # :inherit:
  def integer? : Bool
    @value.integer?
  end
end

struct BigInt
  # :nodoc:
  #
  # The engine value, for `BigFloat`.
  def big_num_value : Crystal::BigNum::Integer
    @value
  end
end

struct Number
  include Comparable(BigFloat)

  def +(other : BigFloat)
    other + self
  end

  def -(other : BigFloat)
    to_big_f - other
  end

  def *(other : BigFloat) : BigFloat
    other * self
  end

  def /(other : BigFloat) : BigFloat
    to_big_f / other
  end

  def to_big_f : BigFloat
    BigFloat.new(self)
  end
end

struct Int
  def <=>(other : BigFloat) : Int32
    -(other <=> self)
  end

  def -(other : BigFloat) : BigFloat
    Int.primitive_ui_check(self) do |ui, neg_ui, _|
      {
        ui:     BigFloat.new(other.big_num_value.neg.add_ui({{ ui }})),
        neg_ui: BigFloat.new(other.big_num_value.neg.sub_ui({{ neg_ui }})),
        big_i:  BigFloat.new(BigFloat.new(self).big_num_value.sub(other.big_num_value)),
      }
    end
  end

  def /(other : BigFloat) : BigFloat
    # Division by 0 in BigFloat is not allowed, there is no BigFloat::Infinity
    raise DivisionByZeroError.new if other == 0

    Int.primitive_ui_check(self) do |ui, neg_ui, _|
      {
        ui:     BigFloat.new(Crystal::BigNum::Float.ui_div({{ ui }}, other.big_num_value)),
        neg_ui: BigFloat.new(Crystal::BigNum::Float.ui_div({{ neg_ui }}, other.big_num_value).negate),
        big_i:  BigFloat.new(BigFloat.new(self).big_num_value.div(other.big_num_value)),
      }
    end
  end
end

struct Float
  def <=>(other : BigFloat)
    cmp = other <=> self
    -cmp if cmp
  end
end

class String
  # Converts `self` to a `BigFloat`.
  #
  # ```
  # require "big"
  # "1234.0".to_big_f
  # ```
  def to_big_f : BigFloat
    BigFloat.new(self)
  end
end

module Math
  # Returns the unbiased base 2 exponent of the given floating-point *value*.
  #
  # Raises `ArgumentError` if *value* is zero.
  def ilogb(value : BigFloat) : Int64
    raise ArgumentError.new "Cannot get exponent of zero" if value.zero?
    engine = value.big_num_value
    leading_zeros = engine.limbs[engine.size - 1].leading_zeros_count
    Crystal::BigNum::LIMB_BITS.to_i64 * engine.exponent - leading_zeros - 1
  end

  # Returns the unbiased radix-independent exponent of the given floating-point *value*.
  #
  # For `BigFloat` this is equivalent to `ilogb`.
  #
  # Raises `ArgumentError` is *value* is zero.
  def logb(value : BigFloat) : BigFloat
    ilogb(value).to_big_f
  end

  # Multiplies the given floating-point *value* by 2 raised to the power *exp*.
  def ldexp(value : BigFloat, exp : Int) : BigFloat
    if exp >= 0
      BigFloat.new(value.big_num_value.mul_2exp(exp.to_u64))
    else
      BigFloat.new(value.big_num_value.div_2exp(exp.abs.to_u64))
    end
  end

  # Returns the floating-point *value* with its exponent raised by *exp*.
  #
  # For `BigFloat` this is equivalent to `ldexp`.
  def scalbn(value : BigFloat, exp : Int) : BigFloat
    ldexp(value, exp)
  end

  # :ditto:
  def scalbln(value : BigFloat, exp : Int) : BigFloat
    ldexp(value, exp)
  end

  # Decomposes the given floating-point *value* into a normalized fraction and an integral power of two.
  def frexp(value : BigFloat) : {BigFloat, Int64}
    return {BigFloat.zero, 0_i64} if value.zero?

    # Since `0.5 <= frac.abs < 1.0`, the radix point should be just above the
    # most significant limb, and there should be no leading zeros in that limb.
    engine = value.big_num_value
    leading_zeros = engine.limbs[engine.size - 1].leading_zeros_count
    exp = Crystal::BigNum::LIMB_BITS.to_i64 * engine.exponent - leading_zeros

    # remove leading zeros in the most significant limb, then put the radix
    # point just above that limb
    frac = BigFloat.new(engine.mul_2exp(leading_zeros.to_u64).with_exponent(0_i64))

    {frac, exp}
  end

  # Returns the floating-point value with the magnitude of *value1* and the sign of *value2*.
  #
  # `BigFloat` does not support signed zeros; if `value2 == 0`, the returned value is non-negative.
  def copysign(value1 : BigFloat, value2 : BigFloat) : BigFloat
    if value1.negative? != value2.negative? # opposite signs
      -value1
    else
      value1
    end
  end

  # Calculates the square root of *value*.
  #
  # Raises `ArgumentError` if *value* is negative.
  #
  # ```
  # require "big"
  #
  # Math.sqrt(1_000_000_000_000.to_big_f * 1_000_000_000_000.to_big_f) # => 1000000000000.0
  # ```
  def sqrt(value : BigFloat) : BigFloat
    BigFloat.new(value.big_num_value.sqrt)
  end
end

# :nodoc:
struct String::Formatter(A)
  def int(flags, arg : BigFloat) : Nil
    int(flags, arg.to_big_i)
  end
end
