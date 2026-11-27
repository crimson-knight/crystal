module Crystal::BigNum
  # :nodoc:
  #
  # An exact rational number: two `Integer`s, the numerator and the
  # denominator, always canonical as GMP's `mpq_t` after
  # `mpq_canonicalize`: the denominator is positive, the two parts share no
  # factor, and zero is 0/1. Every operation returns a canonical value, so
  # two equal rationals have identical parts.
  #
  # Arithmetic reduces with the greatest common divisor as Knuth, TAOCP
  # vol. 2, 4.5.1 describes, keeping the intermediate products small.
  # Comparisons return what GMP's `mpq_cmp`, `mpq_cmp_z`, `mpq_cmp_si` and
  # `mpq_cmp_ui` return, not only their sign (see `#<=>`).
  struct Rational
    include Comparable(Rational)

    getter numerator : Integer
    getter denominator : Integer

    # Wraps parts that are already canonical: the caller vouches for them.
    def initialize(*, @numerator : Integer, @denominator : Integer)
    end

    # Zero (0/1).
    def self.zero : Rational
      new(numerator: Integer.zero, denominator: Integer.new(1))
    end

    # The integer *value* (*value*/1).
    def self.new(value : Integer) : Rational
      new(numerator: value, denominator: Integer.new(1))
    end

    # :ditto:
    def self.new(value : ::Int::Primitive) : Rational
      new(numerator: Integer.new(value), denominator: Integer.new(1))
    end

    # *top* / *bottom* in canonical form, as `mpq_canonicalize`. Raises
    # `DivisionByZeroError` when *bottom* is zero.
    def self.new(top : Integer, bottom : Integer) : Rational
      raise DivisionByZeroError.new if bottom.zero?
      return zero if top.zero?
      if bottom.negative?
        top = -top
        bottom = -bottom
      end
      divisor = top.gcd(bottom)
      if divisor == 1
        new(numerator: top, denominator: bottom)
      else
        new(numerator: top.divexact(divisor), denominator: bottom.divexact(divisor))
      end
    end

    # The exact value of *value*, decoded from its IEEE 754 sign, exponent
    # and mantissa, as `mpq_set_d`. Raises `ArgumentError` for NaN and the
    # infinities. Negative zero gives zero.
    def self.new(value : Float64) : Rational
      raise ArgumentError.new "Can only construct from a finite number" unless value.finite?
      bits = value.unsafe_as(UInt64)
      negative = bits >> 63 != 0
      exponent = ((bits >> 52) & 0x7FF).to_i64
      mantissa = bits & 0x000F_FFFF_FFFF_FFFF_u64
      if exponent == 0
        exponent = -1074_i64
      else
        mantissa |= 0x0010_0000_0000_0000_u64
        exponent -= 1075
      end
      from_binary(Integer.new(negative ? -mantissa.to_i64 : mantissa.to_i64), exponent)
    end

    # :ditto:
    def self.new(value : Float32) : Rational
      new(value.to_f64)
    end

    # The exact value of *mantissa* times 2 ** *exponent*, as `mpq_set_f`
    # gives for a binary float of that value.
    def self.from_binary(mantissa : Integer, exponent : Int64) : Rational
      return zero if mantissa.zero?
      return new(numerator: mantissa << exponent, denominator: Integer.new(1)) if exponent >= 0
      twos = Math.min(mantissa.trailing_zeros_count.to_i64, -exponent)
      new(numerator: mantissa >> twos, denominator: Integer.new(1) << (-exponent - twos))
    end

    def zero? : Bool
      @numerator.zero?
    end

    def negative? : Bool
      @numerator.negative?
    end

    # -1, 0 or 1 as the value is negative, zero or positive.
    def sign : Int32
      @numerator.sign
    end

    # Whether the value is an integer (its denominator is 1).
    def integer? : Bool
      @denominator == 1
    end

    # ---- Arithmetic (Knuth, TAOCP 4.5.1) ----

    def +(other : Rational) : Rational
      add(other.numerator, other.denominator)
    end

    def -(other : Rational) : Rational
      add(-other.numerator, other.denominator)
    end

    # u/u' + v/v' with d1 = gcd(u', v'): when d1 is 1 the sum
    # (u v' + u' v) / (u' v') is already canonical; otherwise
    # t = u (v'/d1) + v (u'/d1), d2 = gcd(t, d1), and the sum is
    # (t/d2) / ((u'/d1) (v'/d2)).
    private def add(v : Integer, v_denominator : Integer) : Rational
      u = @numerator
      u_denominator = @denominator
      return Rational.new(numerator: v, denominator: v_denominator) if u.zero?
      return self if v.zero?
      d1 = u_denominator.gcd(v_denominator)
      if d1 == 1
        sum = u * v_denominator + u_denominator * v
        return Rational.zero if sum.zero?
        return Rational.new(numerator: sum, denominator: u_denominator * v_denominator)
      end
      u_part = u_denominator.divexact(d1)
      v_part = v_denominator.divexact(d1)
      t = u * v_part + v * u_part
      return Rational.zero if t.zero?
      d2 = t.gcd(d1)
      if d2 == 1
        Rational.new(numerator: t, denominator: u_part * v_denominator)
      else
        Rational.new(numerator: t.divexact(d2), denominator: u_part * v_denominator.divexact(d2))
      end
    end

    # (u/u')(v/v') with d1 = gcd(u, v') and d2 = gcd(u', v) is
    # ((u/d1)(v/d2)) / ((u'/d2)(v'/d1)).
    def *(other : Rational) : Rational
      multiply(other.numerator, other.denominator)
    end

    # Raises `DivisionByZeroError` when *other* is zero.
    def /(other : Rational) : Rational
      raise DivisionByZeroError.new if other.zero?
      v = other.denominator
      v_denominator = other.numerator
      if v_denominator.negative?
        v = -v
        v_denominator = -v_denominator
      end
      multiply(v, v_denominator)
    end

    private def multiply(v : Integer, v_denominator : Integer) : Rational
      u = @numerator
      return Rational.zero if u.zero? || v.zero?
      u_denominator = @denominator
      d1 = u.gcd(v_denominator)
      d2 = u_denominator.gcd(v)
      unless d1 == 1
        u = u.divexact(d1)
        v_denominator = v_denominator.divexact(d1)
      end
      unless d2 == 1
        v = v.divexact(d2)
        u_denominator = u_denominator.divexact(d2)
      end
      Rational.new(numerator: u * v, denominator: u_denominator * v_denominator)
    end

    def - : Rational
      Rational.new(numerator: -@numerator, denominator: @denominator)
    end

    def abs : Rational
      Rational.new(numerator: @numerator.abs, denominator: @denominator)
    end

    # 1 / self, as `mpq_inv`. Raises `DivisionByZeroError` for zero.
    def inv : Rational
      raise DivisionByZeroError.new if zero?
      if negative?
        Rational.new(numerator: -@denominator, denominator: -@numerator)
      else
        Rational.new(numerator: @denominator, denominator: @numerator)
      end
    end

    # self ** *exponent*; a negative *exponent* inverts (and raises
    # `DivisionByZeroError` for zero). The powers of coprime parts stay
    # coprime, so no reduction is needed.
    def **(exponent : Int) : Rational
      return (self ** (0_i64 - exponent.to_i64)).inv if exponent < 0
      Rational.new(numerator: @numerator ** exponent, denominator: @denominator ** exponent)
    end

    # self * 2 ** *count*, as `mpq_mul_2exp`: the factors of two in the
    # denominator cancel first. A negative *count* divides.
    def <<(count : Int) : Rational
      return self >> (0_i64 - count.to_i64) if count < 0
      return self if count == 0 || zero?
      count = count.to_i64
      twos = Math.min(@denominator.trailing_zeros_count.to_i64, count)
      Rational.new(numerator: @numerator << (count - twos), denominator: @denominator >> twos)
    end

    # self / 2 ** *count*, as `mpq_div_2exp`: the factors of two in the
    # numerator cancel first. A negative *count* multiplies.
    def >>(count : Int) : Rational
      return self << (0_i64 - count.to_i64) if count < 0
      return self if count == 0 || zero?
      count = count.to_i64
      twos = Math.min(@numerator.trailing_zeros_count.to_i64, count)
      Rational.new(numerator: @numerator >> twos, denominator: @denominator << (count - twos))
    end

    # ---- Rounding to an integer ----

    # The greatest integer at or below the value.
    def floor : Integer
      @numerator // @denominator
    end

    # The least integer at or above the value.
    def ceil : Integer
      -((-@numerator) // @denominator)
    end

    # The value rounded toward zero.
    def trunc : Integer
      @numerator.tdiv(@denominator)
    end

    # The nearest integer, ties away from zero.
    def round_away : Integer
      quotient, remainder = @numerator.tdivmod(@denominator)
      quotient += sign if remainder.abs * 2 >= @denominator
      quotient
    end

    # The nearest integer, ties to the even neighbor.
    def round_even : Integer
      quotient, remainder = @numerator.tdivmod(@denominator)
      twice = remainder.abs * 2
      if twice > @denominator || (twice == @denominator && quotient.bit(0) == 1)
        quotient += sign
      end
      quotient
    end

    # ---- Comparison ----
    #
    # GMP's comparison functions return a value whose sign is the order, and
    # which is often not -1, 0 or 1: when a quick test on the sizes settles
    # the order, they return the numerator's signed limb count. `BigRational`
    # passes that value on, so these methods return the same values. The
    # rules below were found by tabulating GMP 6.3's results (black box) and
    # are proven by `scripts/big_num/rational_differential.cr`.

    def ==(other : Rational) : Bool
      @numerator == other.numerator && @denominator == other.denominator
    end

    # Orders the value against *other*, returning what `mpq_cmp` returns.
    # With a/b the value and c/d *other*: a zero or differing signs settle
    # the order; an integer *other* compares as `<=>(Integer)` (two integers
    # give -1, 0 or 1); when the limb counts or the bit lengths of the cross products a*d and c*b differ by two or more,
    # the result is the signed limb count of a, negated when a/b is the
    # smaller in magnitude; otherwise the cross products decide (-1, 0, 1).
    def <=>(other : Rational) : Int32
      a = @numerator
      b = @denominator
      c = other.numerator
      d = other.denominator
      a_size = signed_size_of(a)
      c_size = signed_size_of(c)
      return -c_size if a_size == 0
      return a_size if c_size == 0
      return a_size if (a_size ^ c_size) < 0
      return self <=> c if d == 1
      left_size = a.size + d.size
      right_size = c.size + b.size
      return a_size if left_size > right_size + 1
      return -a_size if right_size > left_size + 1
      left_bits = a.bit_length.to_i64 + d.bit_length
      right_bits = c.bit_length.to_i64 + b.bit_length
      return a_size if left_bits > right_bits + 1
      return -a_size if right_bits > left_bits + 1
      order = (a.abs * d) <=> (c.abs * b)
      a_size < 0 ? -order : order
    end

    # Orders the value against the integer *other*, returning what
    # `mpq_cmp_z` returns: as `<=>(Rational)`, except that the bit lengths
    # use the exact bounds an integer allows (|a/b| < 2**(bits(a) -
    # bits(b) + 1) and |c| >= 2**(bits(c) - 1)).
    def <=>(other : Integer) : Int32
      a = @numerator
      b = @denominator
      a_size = signed_size_of(a)
      c_size = signed_size_of(other)
      return -c_size if a_size == 0
      return a_size if c_size == 0
      return a_size if (a_size ^ c_size) < 0
      return (a <=> other).sign if b == 1
      a_bits = a.bit_length.to_i64
      bound_bits = other.bit_length.to_i64 + b.bit_length
      return a_size if a_bits >= bound_bits + 1
      return -a_size if bound_bits >= a_bits + 2
      order = a.abs <=> other.abs * b
      a_size < 0 ? -order : order
    end

    # Orders the value against *other*, returning what
    # `mpq_cmp_si(self, other, 1)` returns: a nonnegative *other* compares
    # as `mpq_cmp_ui`; a negative one is below any nonnegative value (1),
    # and against a negative value compares the magnitudes the other way.
    def <=>(other : Int64) : Int32
      if other >= 0
        compare_unsigned(@numerator, other.to_u64!)
      elsif negative?
        0 &- compare_unsigned(@numerator.abs, 0_u64 &- other.to_u64!)
      else
        1
      end
    end

    # Orders the value against *other*, returning what
    # `mpq_cmp_ui(self, other, 1)` returns.
    def <=>(other : UInt64) : Int32
      compare_unsigned(@numerator, other)
    end

    # What `mpq_cmp_ui(numerator / @denominator, other, 1)` returns: the
    # numerator's signed limb count against zero; -1 for a value at or below
    # zero; the order of numerator and denominator by limb count, then by
    # value, against 1; the signed limb count (negated when the value is the
    # smaller) when the numerator has two limbs more than the denominator or
    # fewer limbs than it; otherwise -1, 0 or 1 from the cross product.
    private def compare_unsigned(numerator : Integer, other : UInt64) : Int32
      numerator_size = signed_size_of(numerator)
      return numerator_size if other == 0
      return -1 if numerator_size <= 0
      denominator_size = @denominator.size
      if other == 1
        return numerator_size if numerator_size > denominator_size
        return -numerator_size if numerator_size < denominator_size
        return numerator <=> @denominator
      end
      return numerator_size if numerator_size > denominator_size + 1
      return -numerator_size if denominator_size > numerator_size
      numerator <=> @denominator * Integer.new(other)
    end

    private def signed_size_of(value : Integer) : Int32
      value.negative? ? -value.size : value.size
    end

    # ---- Conversions ----

    # The value as a `Float64`, truncated toward zero, as `mpq_get_d`: a
    # value of 2**1024 or more in magnitude gives an infinity of its sign,
    # a value below the least subnormal gives positive zero.
    def to_f64 : Float64
      return 0.0 if zero?
      magnitude = @numerator.abs
      numerator_bits = magnitude.bit_length
      denominator_bits = @denominator.bit_length
      # A quotient of at least 55 bits: 53 for the mantissa and room below.
      shift = 55 - (numerator_bits - denominator_bits)
      quotient = scaled_quotient(magnitude, shift)
      quotient_bits = quotient.bit_length
      exponent = quotient_bits - 1 - shift
      result = if exponent >= 1024
                 Float64::INFINITY
               elsif exponent >= -1022
                 drop = quotient_bits - 53
                 Math.ldexp((quotient >> drop).to_f64, drop - shift)
               else
                 # Below the normal range: whole multiples of 2**-1074.
                 Math.ldexp(scaled_quotient(magnitude, 1074).to_f64, -1074)
               end
      return 0.0 if result == 0.0
      negative? ? -result : result
    end

    # floor(magnitude * 2 ** shift / denominator).
    private def scaled_quotient(magnitude : Integer, shift : Int32) : Integer
      if shift >= 0
        (magnitude << shift) // @denominator
      else
        (magnitude >> (0 - shift)) // @denominator
      end
    end

    # The value in *base* (2 to 36, lowercase digits), as `mpq_get_str`:
    # the numerator, then `/` and the denominator unless it is 1.
    def to_s(base : Int = 10) : String
      String.build { |io| to_s(io, base) }
    end

    # :ditto:
    def to_s(io : IO, base : Int = 10) : Nil
      @numerator.to_s(io, base)
      unless integer?
        io << '/'
        @denominator.to_s(io, base)
      end
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
