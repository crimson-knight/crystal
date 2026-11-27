require "big"

# Rational numbers are represented as the quotient of arbitrarily large
# numerators and denominators. Rationals are canonicalized such that the
# denominator and the numerator have no common factors, and that the
# denominator is positive. Zero has the unique representation 0/1.
#
# NOTE: To use `BigRational`, you must explicitly import it with `require "big"`
#
# ```
# require "big"
#
# r = BigRational.new(7.to_big_i, 3.to_big_i)
# r.to_s # => "7/3"
#
# r = BigRational.new(3, -9)
# r.to_s # => "-1/3"
# ```
#
# It is implemented in pure Crystal (`-Duse_gmp` puts it on
# [GMP](https://gmplib.org/) instead), with the same results either way.
struct BigRational < Number
  include Comparable(BigRational)
  include Comparable(Int)
  include Comparable(Float)

  # The value, held by the engine.
  protected getter value : Crystal::BigNum::Rational

  # Creates a new `BigRational`.
  #
  # If *denominator* is 0, this will raise an exception.
  def initialize(numerator : Int, denominator : Int)
    check_division_by_zero denominator

    @value = Crystal::BigNum::Rational.new(BigRational.engine_integer(numerator), BigRational.engine_integer(denominator))
  end

  # Creates a new `BigRational` with *num* as the numerator and 1 for denominator.
  def initialize(num : Int)
    initialize(num, 1)
  end

  # Creates an exact representation of float as rational.
  #
  # Raises `ArgumentError` if *num* is not finite.
  def self.new(num : Float::Primitive) : self
    raise ArgumentError.new "Can only construct from a finite number" unless num.finite?
    new(Crystal::BigNum::Rational.new(num))
  end

  # Creates an exact representation of float as rational.
  def self.new(num : BigFloat) : self
    mantissa, exponent = num.exact_binary
    new(Crystal::BigNum::Rational.from_binary(mantissa.@value, exponent))
  end

  # Creates a `BigRational` from the given *num*.
  def self.new(num : BigRational) : self
    num
  end

  # :ditto:
  def self.new(num : BigDecimal) : self
    num.to_big_r
  end

  # :nodoc:
  def initialize(@value : Crystal::BigNum::Rational)
  end

  # The engine integer equal to *value*.
  protected def self.engine_integer(value : Int) : Crystal::BigNum::Integer
    if value.is_a?(BigInt)
      value.@value
    else
      Crystal::BigNum::Integer.new(value)
    end
  end

  def numerator : BigInt
    BigInt.new(@value.numerator)
  end

  def denominator : BigInt
    BigInt.new(@value.denominator)
  end

  def <=>(other : BigRational) : Int32
    @value <=> other.value
  end

  def <=>(other : Float::Primitive) : Int32?
    return nil if other.nan?
    # `BigRational.new` rejects non-finite floats, so order against an infinity
    # directly: every finite rational is greater than -Infinity and less than
    # +Infinity. `Float#infinite?` is `1` for +Infinity and `-1` for -Infinity.
    if inf = other.infinite?
      -inf
    else
      self <=> BigRational.new(other)
    end
  end

  def <=>(other : BigFloat) : Int32
    self <=> other.to_big_r
  end

  def <=>(other : Int) : Int32
    Int.primitive_si_ui_check(other) do |si, ui, big_i|
      {
        si:    @value <=> {{ si }},
        ui:    @value <=> {{ ui }},
        big_i: self <=> {{ big_i }},
      }
    end
  end

  def <=>(other : BigInt) : Int32
    @value <=> other.@value
  end

  def ==(other : BigRational) : Bool
    @value == other.value
  end

  def +(other : BigRational) : BigRational
    BigRational.new(@value + other.value)
  end

  def +(other : Int) : BigRational
    self + other.to_big_r
  end

  def -(other : BigRational) : BigRational
    BigRational.new(@value - other.value)
  end

  def -(other : Int) : BigRational
    self - other.to_big_r
  end

  def *(other : BigRational) : BigRational
    BigRational.new(@value * other.value)
  end

  def *(other : Int) : BigRational
    self * other.to_big_r
  end

  def /(other : BigRational) : BigRational
    check_division_by_zero other
    BigRational.new(@value / other.value)
  end

  Number.expand_div [BigInt, BigFloat, BigDecimal], BigRational

  def //(other : BigRational) : BigRational
    check_division_by_zero other
    BigRational.new((numerator * other.denominator) // (denominator * other.numerator))
  end

  def //(other : Int) : BigRational
    check_division_by_zero other
    BigRational.new(numerator // (denominator * other))
  end

  def %(other : BigRational) : BigRational
    check_division_by_zero other
    BigRational.new(
      (numerator * other.denominator) % (denominator * other.numerator),
      denominator * other.denominator,
    )
  end

  def %(other : Int) : BigRational
    check_division_by_zero other
    BigRational.new(numerator % (denominator * other), denominator)
  end

  def tdiv(other : BigRational) : BigRational
    check_division_by_zero other
    BigRational.new((numerator * other.denominator).tdiv(denominator * other.numerator))
  end

  def tdiv(other : Int) : BigRational
    check_division_by_zero other
    BigRational.new(numerator.tdiv(denominator * other))
  end

  def remainder(other : BigRational) : BigRational
    check_division_by_zero other
    BigRational.new(
      (numerator * other.denominator).remainder(denominator * other.numerator),
      denominator * other.denominator,
    )
  end

  def remainder(other : Int) : BigRational
    check_division_by_zero other
    BigRational.new(numerator.remainder(denominator * other), denominator)
  end

  def ceil : BigRational
    BigRational.new(Crystal::BigNum::Rational.new(@value.ceil))
  end

  def floor : BigRational
    BigRational.new(Crystal::BigNum::Rational.new(@value.floor))
  end

  def trunc : BigRational
    BigRational.new(Crystal::BigNum::Rational.new(@value.trunc))
  end

  def round_away : BigRational
    BigRational.new(Crystal::BigNum::Rational.new(@value.round_away))
  end

  def round_even : BigRational
    BigRational.new(Crystal::BigNum::Rational.new(@value.round_even))
  end

  # :inherit:
  def integer? : Bool
    # since all `BigRational`s are canonicalized, the denominator must be
    # positive and coprime with the numerator
    @value.integer?
  end

  # Divides the rational by (2 ** *other*)
  #
  # ```
  # require "big"
  #
  # BigRational.new(2, 3) >> 2 # => 1/6
  # ```
  def >>(other : Int) : BigRational
    BigRational.new(@value >> other)
  end

  # Multiplies the rational by (2 ** *other*)
  #
  # ```
  # require "big"
  #
  # BigRational.new(2, 3) << 2 # => 8/3
  # ```
  def <<(other : Int) : BigRational
    BigRational.new(@value << other)
  end

  def - : BigRational
    BigRational.new(-@value)
  end

  # Raises the rational to the *other*th power
  #
  # This will raise `DivisionByZeroError` if rational is 0 and *other* is negative.
  #
  # ```
  # require "big"
  #
  # BigRational.new(2, 3) ** 2  # => 4/9
  # BigRational.new(2, 3) ** -1 # => 3/2
  # ```
  def **(other : Int) : BigRational
    if other < 0
      return (self ** other.abs).inv
    end
    BigRational.new(@value ** other)
  end

  # Returns a new `BigRational` as 1/r.
  #
  # This will raise an exception if rational is 0.
  def inv : BigRational
    check_division_by_zero self
    BigRational.new(@value.inv)
  end

  def abs : BigRational
    BigRational.new(@value.abs)
  end

  # Returns the `Float64` representing this rational.
  def to_f : Float64
    to_f64
  end

  def to_f32 : Float32
    to_f64.to_f32
  end

  def to_f64 : Float64
    @value.to_f64
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

  def to_i : Int32
    to_i32
  end

  delegate to_i8, to_i16, to_i32, to_i64, to_u8, to_u16, to_u32, to_u64, to: to_f64

  # Returns `self`.
  #
  # ```
  # require "big"
  #
  # BigRational.new(4, 5).to_big_r # => 4/5
  # ```
  def to_big_r : BigRational
    self
  end

  def to_big_f : BigFloat
    BigFloat.new(self)
  end

  def to_big_i : BigInt
    BigInt.new(@value.trunc)
  end

  # Returns the string representing this rational.
  #
  # Optionally takes a radix base (2 through 36).
  #
  # ```
  # require "big"
  #
  # r = BigRational.new(8243243, 562828882)
  # r.to_s     # => "8243243/562828882"
  # r.to_s(16) # => "7dc82b/218c1652"
  # r.to_s(36) # => "4woiz/9b3djm"
  # ```
  def to_s(base : Int = 10) : String
    check_base(base)
    @value.to_s(base)
  end

  def to_s(io : IO, base : Int = 10) : Nil
    check_base(base)
    @value.to_s(io, base)
  end

  def inspect : String
    to_s
  end

  def inspect(io : IO) : Nil
    to_s io
  end

  # :inherit:
  def format(io : IO, separator = '.', delimiter = ',', decimal_places : Int? = nil, *, group : Int = 3, only_significant : Bool = false) : Nil
    numerator.format(io, separator, delimiter, decimal_places, group: group, only_significant: only_significant)
    io << '/'
    denominator.format(io, separator, delimiter, decimal_places, group: group, only_significant: only_significant)
  end

  def clone : BigRational
    self
  end

  private def check_base(base : Int) : Nil
    raise "Invalid base #{base}" unless 2 <= base <= 36
  end

  private def check_division_by_zero(value)
    raise DivisionByZeroError.new if value == 0
  end
end

struct Int
  include Comparable(BigRational)

  # Returns a `BigRational` representing this integer.
  # ```
  # require "big"
  #
  # 123.to_big_r
  # ```
  def to_big_r : BigRational
    BigRational.new(self, 1)
  end

  def <=>(other : BigRational) : Int32
    -(other <=> self)
  end

  def +(other : BigRational) : BigRational
    other + self
  end

  def -(other : BigRational) : BigRational
    self.to_big_r - other
  end

  def /(other : BigRational)
    self.to_big_r / other
  end

  def *(other : BigRational) : BigRational
    other * self
  end
end

struct Float
  include Comparable(BigRational)

  # Returns a `BigRational` representing this float.
  # ```
  # require "big"
  #
  # 123.0.to_big_r
  # ```
  def to_big_r : BigRational
    BigRational.new(self)
  end

  def <=>(other : BigRational)
    cmp = other <=> self
    -cmp if cmp
  end
end

struct BigFloat
  def <=>(other : BigRational)
    -(other <=> self)
  end
end

module Math
  # Calculates the square root of *value*.
  #
  # ```
  # require "big"
  #
  # Math.sqrt(1_000_000_000_000.to_big_r * 1_000_000_000_000.to_big_r) # => 1000000000000.0
  # ```
  def sqrt(value : BigRational) : BigFloat
    sqrt(value.to_big_f)
  end
end

# :nodoc:
struct Crystal::Hasher
  def self.reduce_num(value : BigRational) : UInt64
    inverse = value.@value.denominator.invert(HASH_MODULUS_INT_P.@value)
    unless inverse
      # inverse doesn't exist, i.e. denominator is a multiple of HASH_MODULUS
      return value >= 0 ? HASH_INF_PLUS : HASH_INF_MINUS
    end
    UInt64.mulmod(reduce_num(value.numerator.abs), inverse.to_u64!, HASH_MODULUS) &* value.sign
  end
end
