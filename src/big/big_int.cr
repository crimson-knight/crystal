require "big"
require "random"

# A `BigInt` can represent arbitrarily large integers.
#
# It is implemented in pure Crystal (`Crystal::BigNum::Integer`). The
# `-Duse_gmp` compile-time flag switches it back to
# [GMP](https://gmplib.org/).
#
# NOTE: To use `BigInt`, you must explicitly import it with `require "big"`
struct BigInt < Int
  include Comparable(Int::Signed)
  include Comparable(Int::Unsigned)
  include Comparable(BigInt)
  include Comparable(Float)

  # The value, held by the engine.
  protected getter value : Crystal::BigNum::Integer

  # Creates a `BigInt` with the value zero.
  #
  # ```
  # require "big"
  #
  # BigInt.new # => 0
  # ```
  def initialize
    @value = Crystal::BigNum::Integer.zero
  end

  # Creates a `BigInt` with the value denoted by *str* in the given *base*.
  #
  # Raises `ArgumentError` if the string doesn't denote a valid integer.
  #
  # ```
  # require "big"
  #
  # BigInt.new("123456789123456789123456789123456789") # => 123456789123456789123456789123456789
  # BigInt.new("123_456_789_123_456_789_123_456_789")  # => 123456789123456789123456789
  # BigInt.new("1234567890ABCDEF", base: 16)           # => 1311768467294899695
  # ```
  def initialize(str : String, base : Int32 = 10)
    # Strip leading '+' char to smooth out cases with strings like "+123"
    str = str.lchop('+')
    # Strip '_' to make it compatible with int literals like "1_000_000"
    str = str.delete('_')
    @value = Crystal::BigNum::Integer.parse(str, base)
  end

  # Creates a `BigInt` from the given *num*.
  def self.new(num : Int::Primitive) : self
    new(Crystal::BigNum::Integer.new(num))
  end

  # :ditto:
  #
  # *num* must be finite. The value is truncated toward zero.
  def initialize(num : Float::Primitive)
    @value = Crystal::BigNum::Integer.new(num)
  end

  # :ditto:
  def self.new(num : BigFloat) : self
    num.to_big_i
  end

  # :ditto:
  def self.new(num : BigDecimal) : self
    num.to_big_i
  end

  # :ditto:
  def self.new(num : BigRational) : self
    num.to_big_i
  end

  # Returns *num*. Useful for generic code that does `T.new(...)` with `T`
  # being a `Number`.
  def self.new(num : BigInt) : self
    num
  end

  # :nodoc:
  def initialize(@value : Crystal::BigNum::Integer)
  end

  # Returns a number for given *digits* and *base*. The digits are expected as
  # an `Enumerable` with the least significant digit as the first element.
  #
  # *base* must not be less than 2.
  #
  # All digits must be within `0...base`.
  def self.from_digits(digits : Enumerable(Int), base : Int = 10) : self
    if base < 2
      raise ArgumentError.new("Invalid base #{base}")
    end

    result = BigInt.new
    multiplier = BigInt.new(1)
    first_element = true

    digits.each do |digit|
      if digit < 0
        raise ArgumentError.new("Invalid digit #{digit}")
      end

      if digit >= base
        raise ArgumentError.new("Invalid digit #{digit} for base #{base}")
      end

      # don't calculate multiplier upfront for the next digit
      # to avoid overflow at the last iteration
      if first_element
        first_element = false
        result = digit.to_big_i
      else
        multiplier *= base
        result += multiplier * digit
      end
    end

    result
  end

  def <=>(other : BigInt)
    @value <=> other.value
  end

  def <=>(other : Int)
    if other.is_a?(Int::Primitive) && Int64::MIN <= other <= Int64::MAX
      compare_signed_limb(other.to_i64!)
    else
      @value <=> operand(other)
    end
  end

  def <=>(other : Float::Primitive) : Int32?
    # GMP's `mpz_cmp_d`, which the GMP-backed `BigInt` has always returned,
    # gives the signed limb count of `self` for a zero (or negative zero)
    # double, so `(BigInt.new(2) ** 100) <=> 0.0 == 2`.
    return signed_limb_count if other.zero?

    @value <=> other
  end

  def +(other : BigInt) : BigInt
    BigInt.new(@value + other.value)
  end

  def +(other : Int) : BigInt
    BigInt.new(@value + operand(other))
  end

  def &+(other) : BigInt
    self + other
  end

  def -(other : BigInt) : BigInt
    BigInt.new(@value - other.value)
  end

  def -(other : Int) : BigInt
    BigInt.new(@value - operand(other))
  end

  def &-(other) : BigInt
    self - other
  end

  def - : BigInt
    BigInt.new(-@value)
  end

  def abs : BigInt
    BigInt.new(@value.abs)
  end

  def factorial : BigInt
    if self < 0
      raise ArgumentError.new("Factorial not defined for negative values")
    elsif self > UInt64::MAX
      raise ArgumentError.new("Factorial not supported for numbers bigger than #{UInt64::MAX}")
    end
    BigInt.new(Crystal::BigNum::Integer.factorial(to_u64))
  end

  def *(other : BigInt) : BigInt
    BigInt.new(@value * other.value)
  end

  def *(other : Int) : BigInt
    BigInt.new(@value * operand(other))
  end

  def &*(other) : BigInt
    self * other
  end

  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational

  def //(other : Int) : BigInt
    check_division_by_zero other

    unsafe_floored_div(other)
  end

  def tdiv(other : Int) : BigInt
    check_division_by_zero other

    unsafe_truncated_div(other)
  end

  def unsafe_floored_div(other : BigInt) : BigInt
    BigInt.new(@value // other.value)
  end

  def unsafe_floored_div(other : Int) : BigInt
    BigInt.new(@value // operand(other))
  end

  def unsafe_truncated_div(other : BigInt) : BigInt
    BigInt.new(@value.tdiv(other.value))
  end

  def unsafe_truncated_div(other : Int) : BigInt
    BigInt.new(@value.tdiv(operand(other)))
  end

  def %(other : Int) : BigInt
    check_division_by_zero other

    unsafe_floored_mod(other)
  end

  def remainder(other : Int) : BigInt
    check_division_by_zero other

    unsafe_truncated_mod(other)
  end

  def divmod(number : Int) : {BigInt, BigInt}
    check_division_by_zero number

    unsafe_floored_divmod(number)
  end

  def unsafe_floored_mod(other : BigInt) : BigInt
    BigInt.new(@value % other.value)
  end

  def unsafe_floored_mod(other : Int) : BigInt
    # A negative primitive divisor whose magnitude fits in 64 bits gives
    # `-(self mod |other|)`, as the GMP-backed `BigInt` always has (it calls
    # `mpz_fdiv_r_ui` with the magnitude, then negates). This differs from
    # the floored modulo when the remainder is not zero, for example
    # `BigInt.new(-5) % -3 == -1`. Kept so both builds agree.
    if other.is_a?(Int::Primitive) && other < 0 && other.abs_unsigned <= UInt64::MAX
      BigInt.new(-(@value % other.abs_unsigned))
    else
      BigInt.new(@value % operand(other))
    end
  end

  def unsafe_truncated_mod(other : BigInt) : BigInt
    BigInt.new(@value.remainder(other.value))
  end

  def unsafe_truncated_mod(other : Int) : BigInt
    BigInt.new(@value.remainder(operand(other)))
  end

  def unsafe_floored_divmod(number : BigInt) : {BigInt, BigInt}
    quotient, remainder = @value.divmod(number.value)
    {BigInt.new(quotient), BigInt.new(remainder)}
  end

  def unsafe_floored_divmod(number : Int) : {BigInt, BigInt}
    quotient, remainder = @value.divmod(operand(number))
    {BigInt.new(quotient), BigInt.new(remainder)}
  end

  def unsafe_truncated_divmod(number : BigInt) : Tuple(BigInt, BigInt)
    quotient, remainder = @value.tdivmod(number.value)
    {BigInt.new(quotient), BigInt.new(remainder)}
  end

  def unsafe_truncated_divmod(number : Int)
    quotient, remainder = @value.tdivmod(operand(number))
    {BigInt.new(quotient), BigInt.new(remainder)}
  end

  def divisible_by?(number : BigInt) : Bool
    @value.divisible_by?(number.value)
  end

  def divisible_by?(number : Int) : Bool
    @value.divisible_by?(operand(number))
  end

  # :nodoc:
  # returns `{reduced, count}` such that `self % (number ** count) == 0`,
  # `self % (number ** (count + 1)) != 0`, and `reduced == self / (number ** count)`
  def factor_by(number : Int) : {BigInt, UInt64}
    return {self, 0_u64} unless divisible_by?(number)

    reduced, count = @value.remove(number.to_big_i.value)
    {BigInt.new(reduced), count}
  end

  def ~ : BigInt
    BigInt.new(~@value)
  end

  def bit(bit : Int) : Int32
    return 0 if bit < 0
    return self < 0 ? 1 : 0 if bit > UInt64::MAX
    @value.bit(UInt64.new!(bit))
  end

  def &(other : BigInt) : BigInt
    BigInt.new(@value & other.value)
  end

  def &(other : Int) : BigInt
    BigInt.new(@value & operand(other))
  end

  def |(other : BigInt) : BigInt
    BigInt.new(@value | other.value)
  end

  def |(other : Int) : BigInt
    BigInt.new(@value | operand(other))
  end

  def ^(other : BigInt) : BigInt
    BigInt.new(@value ^ other.value)
  end

  def ^(other : Int) : BigInt
    BigInt.new(@value ^ operand(other))
  end

  def >>(other : Int) : BigInt
    BigInt.new(@value >> other)
  end

  # :nodoc:
  #
  # Because every Int needs this method.
  def unsafe_shr(count : Int) : self
    self >> count
  end

  def <<(other : Int) : BigInt
    BigInt.new(@value << other)
  end

  def **(other : Int) : BigInt
    if other < 0
      raise ArgumentError.new("Negative exponent isn't supported")
    elsif other == 1
      self
    else
      BigInt.new(@value ** other)
    end
  end

  # Returns the greatest common divisor of `self` and *other*.
  def gcd(other : BigInt) : BigInt
    BigInt.new(@value.gcd(other.value))
  end

  # :ditto:
  #
  # The result is a `UInt64` when *other* fits in one (its magnitude does),
  # except that `gcd(0)` gives `self` when `self.abs` does not fit.
  def gcd(other : Int) : Int
    if other.is_a?(Int::Primitive) && other.abs_unsigned <= UInt64::MAX
      divisor = @value.gcd(other).to_u64?
      divisor && divisor != 0 ? divisor : self
    else
      gcd(other.to_big_i)
    end
  end

  # Returns the least common multiple of `self` and *other*.
  def lcm(other : BigInt) : BigInt
    BigInt.new(@value.lcm(other.value))
  end

  # :ditto:
  def lcm(other : Int) : BigInt
    BigInt.new(@value.lcm(operand(other)))
  end

  def bit_length : Int32
    @value.bit_length
  end

  def to_s(base : Int = 10, *, precision : Int = 1, upcase : Bool = false) : String
    @value.to_s(base, upcase, precision: precision)
  end

  def to_s(io : IO, base : Int = 10, *, precision : Int = 1, upcase : Bool = false) : Nil
    @value.to_s(io, base, upcase, precision: precision)
  end

  def digits(base = 10) : Array(Int32)
    if self < 0
      raise ArgumentError.new("Can't request digits of negative number")
    end

    ary = [] of Int32
    self.to_s(base).each_char { |c| ary << c.to_i(base) }
    ary.reverse!
    ary
  end

  def popcount : Int
    @value.popcount
  end

  def trailing_zeros_count : Int
    @value.trailing_zeros_count
  end

  # :nodoc:
  def next_power_of_two : self
    one = BigInt.new(1)
    return one if self <= 0

    popcount == 1 ? self : one << bit_length
  end

  def to_i : Int32
    to_i32
  end

  def to_i! : Int32
    to_i32!
  end

  def to_u : UInt32
    to_u32
  end

  def to_u! : UInt32
    to_u32!
  end

  {% for n in [8, 16, 32, 64] %}
    def to_i{{n}} : Int{{n}}
      fitted = @value.to_i64?
      raise OverflowError.new unless fitted
      fitted.to_i{{n}}
    end

    def to_u{{n}} : UInt{{n}}
      fitted = @value.to_u64?
      raise OverflowError.new unless fitted
      fitted.to_u{{n}}
    end

    def to_i{{n}}! : Int{{n}}
      to_u{{n}}!.to_i{{n}}!
    end

    def to_u{{n}}! : UInt{{n}}
      @value.to_u64!.to_u{{n}}!
    end
  {% end %}

  def to_i128 : Int128
    fitted = @value.to_i128?
    raise OverflowError.new unless fitted
    fitted
  end

  def to_u128 : UInt128
    fitted = @value.to_u128?
    raise OverflowError.new unless fitted
    fitted
  end

  def to_i128! : Int128
    @value.to_i128!
  end

  def to_u128! : UInt128
    @value.to_u128!
  end

  def to_f : Float64
    to_f64
  end

  def to_f32 : Float32
    to_f64.to_f32
  end

  def to_f64 : Float64
    @value.to_f64
  end

  def to_f!
    to_f64!
  end

  def to_f32!
    to_f64.to_f32!
  end

  def to_f64!
    to_f64
  end

  def to_big_i : BigInt
    self
  end

  def to_big_f : BigFloat
    BigFloat.new(self)
  end

  def to_big_d : BigDecimal
    BigDecimal.new(self)
  end

  def to_big_r : BigRational
    BigRational.new(self)
  end

  def clone : BigInt
    self
  end

  # `self <=> other` as GMP's `mpz_cmp_si` gives it, which the GMP-backed
  # `BigInt` has always returned: the signed limb count of `self` minus the
  # sign of *other* when they differ or `self` is zero, so the result is not
  # always -1, 0 or 1 (`(BigInt.new(2) ** 200) <=> 3 == 3`).
  private def compare_signed_limb(other : Int64) : Int32
    own_size = signed_limb_count
    other_size = other <=> 0
    if own_size == 0 || own_size != other_size
      own_size - other_size
    else
      @value <=> other
    end
  end

  # The limb count of `self`, negated when `self` is negative (GMP's `SIZ`).
  private def signed_limb_count : Int32
    @value.negative? ? -@value.size : @value.size
  end

  private def check_division_by_zero(value)
    if value == 0
      raise DivisionByZeroError.new
    end
  end

  # *number* as the engine takes it: a primitive stays a primitive (the
  # engine has fast overloads for those), anything else becomes an engine
  # integer.
  private def operand(number : Int::Primitive) : Int::Primitive
    number
  end

  private def operand(number : BigInt) : Crystal::BigNum::Integer
    number.value
  end

  private def operand(number : Int) : Crystal::BigNum::Integer
    number.to_big_i.value
  end
end

struct Int
  include Comparable(BigInt)

  def <=>(other : BigInt)
    -(other <=> self)
  end

  def +(other : BigInt) : BigInt
    other + self
  end

  def &+(other : BigInt) : BigInt
    self + other
  end

  def -(other : BigInt) : BigInt
    to_big_i - other
  end

  def &-(other : BigInt) : BigInt
    self - other
  end

  def *(other : BigInt) : BigInt
    other * self
  end

  def &*(other : BigInt) : BigInt
    self * other
  end

  def %(other : BigInt) : BigInt
    to_big_i % other
  end

  # Returns the greatest common divisor of `self` and *other*.
  def gcd(other : BigInt) : Int
    other.gcd(self)
  end

  # Returns the least common multiple of `self` and *other*.
  def lcm(other : BigInt) : BigInt
    other.lcm(self)
  end

  # Returns a `BigInt` representing this integer.
  # ```
  # require "big"
  #
  # 123.to_big_i
  # ```
  def to_big_i : BigInt
    BigInt.new(self)
  end
end

struct Float
  include Comparable(BigInt)

  def <=>(other : BigInt)
    cmp = other <=> self
    -cmp if cmp
  end

  # Returns a `BigInt` representing this float (rounded using `floor`).
  # ```
  # require "big"
  #
  # 1212341515125412412412421.0.to_big_i
  # ```
  def to_big_i : BigInt
    BigInt.new(self)
  end
end

class String
  # Returns a `BigInt` from this string, in the given *base*.
  #
  # Raises `ArgumentError` if this string doesn't denote a valid integer.
  # ```
  # require "big"
  #
  # "3a060dbf8d1a5ac3e67bc8f18843fc48".to_big_i(16)
  # ```
  def to_big_i(base : Int32 = 10) : BigInt
    BigInt.new(self, base)
  end
end

module Math
  # Calculates the square root of *value*.
  #
  # ```
  # require "big"
  #
  # Math.sqrt(1_000_000_000_000.to_big_i * 1_000_000_000_000.to_big_i) # => 1000000000000.0
  # ```
  def sqrt(value : BigInt) : BigFloat
    sqrt(value.to_big_f)
  end

  # Calculates the integer square root of *value*.
  def isqrt(value : BigInt) : BigInt
    BigInt.new(value.@value.isqrt)
  end

  # Computes the smallest nonnegative power of 2 that is greater than or equal
  # to *v*.
  #
  # The returned value has the same type as the argument.
  #
  # ```
  # Math.pw2ceil(33) # => 64
  # Math.pw2ceil(64) # => 64
  # Math.pw2ceil(-5) # => 1
  # ```
  def pw2ceil(v : BigInt) : BigInt
    v.next_power_of_two
  end
end

module Random
  private def rand_int(max : BigInt) : BigInt
    # This is a copy of the algorithm in random.cr but with fewer special cases.
    unless max > 0
      raise ArgumentError.new "Invalid bound for rand: #{max}"
    end

    rand_max = BigInt.new(1) << (sizeof(typeof(next_u))*8)
    needed_parts = 1
    while rand_max < max && rand_max > 0
      rand_max <<= sizeof(typeof(next_u))*8
      needed_parts += 1
    end

    limit = rand_max // max * max

    loop do
      result = BigInt.new(next_u)
      (needed_parts - 1).times do
        result <<= sizeof(typeof(next_u))*8
        result |= BigInt.new(next_u)
      end

      # For a uniform distribution we may need to throw away some numbers.
      if result < limit
        return result % max
      end
    end
  end

  private def rand_range(range : Range(BigInt, BigInt)) : BigInt
    span = range.end - range.begin
    unless range.excludes_end?
      span += 1
    end
    unless span > 0
      raise ArgumentError.new "Invalid range for rand: #{range}"
    end
    range.begin + rand_int(span)
  end
end

# :nodoc:
struct Crystal::Hasher
  private HASH_MODULUS_INT_P = BigInt.new(HASH_MODULUS)

  def self.reduce_num(value : BigInt) : UInt64
    value.@value.hash_reduce
  end
end
