struct BigInt
  Number.expand_div [Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128], BigFloat
  Number.expand_div [Float32, Float64], BigFloat
end

struct BigFloat
  def fdiv(other : Number::Primitive) : self
    self.class.new(self / other)
  end

  Number.expand_div [Float32, Float64], BigFloat
end

struct BigDecimal
  Number.expand_div [Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128], BigDecimal
  Number.expand_div [Float32, Float64], BigDecimal
end

struct BigRational
  Number.expand_div [Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128], BigRational
  Number.expand_div [Float32, Float64], BigRational
end

struct Int
  # :nodoc:
  # Yields 3 expressions: `Call`s nodes that convert *var* into an `Int64` (GMP's `SI`),
  # a `UInt64` (GMP's `UI`), and a `BigInt` respectively. These expressions are not
  # evaluated unless they are interpolated in *block*.
  #
  # *block* should return a named tuple: the value for `:si` is returned by the
  # macro if *var* fits into an `Int64` (GMP's `SI`), the value for `:ui` returned if
  # *var* fits into a `UInt64` (GMP's `UI`), and the value for `:big_i` otherwise.
  macro primitive_si_ui_check(var, &block)
    {%
      exps = yield(
        "::Int64.new!(#{var.id})".id,
        "::UInt64.new!(#{var.id})".id,
        "::BigInt.new(#{var.id})".id,
      )
    %}
    if ::Int64::MIN <= {{ var }} <= ::UInt64::MAX
      if {{ var }} <= ::Int64::MAX
        {{ exps[:si] }}
      else
        {{ exps[:ui] }}
      end
    else
      {{ exps[:big_i] }}
    end
  end

  # :nodoc:
  # Yields 3 expressions: `Call`s nodes that convert *var* into a `UInt64` (GMP's `UI`),
  # the negative of *var* into a `UInt64` (GMP's `UI`), and *var* into a `BigInt`,
  # respectively. These expressions are not evaluated unless they are
  # interpolated in *block*.
  #
  # *block* should return a named tuple: the value for `:ui` is returned by the
  # macro if *var* fits into a `UInt64` (GMP's `UI`), the value for `:neg_ui` returned if
  # the negative of *var* fits into a `UInt64` (GMP's `UI`), and the value for `:big_i`
  # otherwise.
  macro primitive_ui_check(var, &block)
    {%
      exps = yield(
        "::UInt64.new!(#{var.id})".id,
        "::UInt64.new!((#{var.id}).abs_unsigned)".id,
        "::BigInt.new(#{var.id})".id,
      )
    %}
    if ::UInt64::MIN <= {{ var }} <= ::UInt64::MAX
      {{ exps[:ui] }}
    elsif {{ var }}.responds_to?(:abs_unsigned) && {{ var }}.abs_unsigned <= ::UInt64::MAX
      {{ exps[:neg_ui] }}
    else
      {{ exps[:big_i] }}
    end
  end
end

struct Int8
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Int16
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Int32
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Int64
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Int128
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct UInt8
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct UInt16
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct UInt32
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct UInt64
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct UInt128
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Float
  def fdiv(other : BigInt | BigFloat | BigDecimal | BigRational) : self
    self.class.new(self / other)
  end
end

struct Float32
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigFloat], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end

struct Float64
  Number.expand_div [BigInt], BigFloat
  Number.expand_div [BigFloat], BigFloat
  Number.expand_div [BigDecimal], BigDecimal
  Number.expand_div [BigRational], BigRational
end
