require "./gmp_oracle"

module G2Harness
  # A stand-in for `Crystal::BigNum::Integer` with the engine contract's
  # names, computed by GMP. It serves two purposes:
  #
  # * the harness's self-check: run against it, every operation must report
  #   0 differences (the harness itself adds none);
  # * the planted-bug check: `ReferenceDouble.plant = "<op>"` makes the double
  #   return a wrong answer whenever the harness is running that operation,
  #   and the harness must flag it. This works for every operation class
  #   whether or not the real engine implements it yet.
  struct ReferenceDouble
    class_property plant : String? = nil
    class_property current_op : String = ""

    getter value : BigInt

    def initialize(@value : BigInt)
    end

    def self.new(value : ::Int::Primitive) : self
      new(BigInt.new(value)).planted
    end

    def self.new(value : Float64) : self
      new(BigInt.new(value)).planted
    end

    def self.from_limbs(limbs : Slice(UInt64), negative : Bool) : self
      built = new(GMPOracle.from_limbs(limbs, negative))
      # Operands of every operation are built here, so only the from_limbs
      # operation itself plants a bug in construction.
      current_op == "from_limbs" ? built.planted : built
    end

    def self.parse(str : String, base : Int32) : self
      new(BigInt.new(str, base)).planted
    end

    def self.factorial(n : ::Int) : self
      new(GMPOracle.factorial(n.to_u64)).planted
    end

    def self.planting? : Bool
      plant == current_op
    end

    # The planted bug: the low bit of the result flips.
    def planted : self
      ReferenceDouble.planting? ? ReferenceDouble.new(@value ^ 1) : self
    end

    private def wrap(value : BigInt) : self
      ReferenceDouble.new(value).planted
    end

    # A comparison result: the planted bug reverses it.
    private def plant_sign(value : Int32) : Int32
      ReferenceDouble.planting? ? (value == 0 ? 1 : -value) : value
    end

    private def plant(value : Bool) : Bool
      ReferenceDouble.planting? ? !value : value
    end

    private def plant(value : ::Int)
      ReferenceDouble.planting? ? value &+ 1 : value
    end

    private def plant(value : Float64) : Float64
      ReferenceDouble.planting? ? (value.unsafe_as(UInt64) ^ 1).unsafe_as(Float64) : value
    end

    private def plant(value : String) : String
      ReferenceDouble.planting? ? value + "0" : value
    end

    private def plant(value : Nil) : Nil
      nil
    end

    def limbs : Slice(UInt64)
      GMPOracle.limbs(@value)
    end

    def negative? : Bool
      @value < 0
    end

    def zero? : Bool
      @value == 0
    end

    def size : Int32
      @value.to_unsafe.value._mp_size.abs
    end

    def + : self
      wrap(@value)
    end

    def square : self
      wrap(@value * @value)
    end

    def - : self
      wrap(-@value)
    end

    def abs : self
      wrap(@value.abs)
    end

    def ~ : self
      wrap(~@value)
    end

    {% for op in %w(+ - * // % & | ^) %}
      def {{op.id}}(other : ReferenceDouble) : self
        wrap(@value {{op.id}} other.value)
      end

      def {{op.id}}(other : ::Int::Primitive) : self
        wrap(@value {{op.id}} other)
      end
    {% end %}

    {% for name in %w(tdiv remainder) %}
      def {{name.id}}(other : ReferenceDouble) : self
        wrap(@value.{{name.id}}(other.value))
      end

      def {{name.id}}(other : ::Int::Primitive) : self
        wrap(@value.{{name.id}}(other))
      end
    {% end %}

    def divmod(other : ReferenceDouble | ::Int::Primitive) : {self, self}
      divisor = other.is_a?(ReferenceDouble) ? other.value : other
      quotient, remainder = @value.divmod(divisor)
      {wrap(quotient), ReferenceDouble.new(remainder)}
    end

    def tdivmod(other : ReferenceDouble | ::Int::Primitive) : {self, self}
      divisor = other.is_a?(ReferenceDouble) ? other.value : other
      {wrap(@value.tdiv(divisor)), ReferenceDouble.new(@value.remainder(divisor))}
    end

    def **(exponent : ::Int) : self
      wrap(@value ** exponent)
    end

    def <<(count : ::Int) : self
      wrap(@value << count)
    end

    def >>(count : ::Int) : self
      wrap(@value >> count)
    end

    def <=>(other : ReferenceDouble) : Int32
      plant_sign((@value <=> other.value).sign)
    end

    def <=>(other : ::Int::Primitive) : Int32
      plant_sign((@value <=> other).sign)
    end

    def <=>(other : Float64) : Int32?
      result = @value <=> other
      result.nil? ? nil : plant_sign(result.sign)
    end

    def ==(other : ReferenceDouble) : Bool
      plant(@value == other.value)
    end

    def hash : UInt64
      plant(@value.hash)
    end

    def bit(index : ::Int) : Int32
      plant(@value.bit(index))
    end

    def popcount : UInt64
      plant(@value.popcount.to_u64)
    end

    def trailing_zeros_count : UInt64
      plant(@value.trailing_zeros_count.to_u64)
    end

    def bit_length : Int32
      plant(@value.bit_length)
    end

    def divisible_by?(other : ReferenceDouble) : Bool
      plant(@value.divisible_by?(other.value))
    end

    def divisible_by?(other : ::Int::Primitive) : Bool
      plant(@value.divisible_by?(other))
    end

    def gcd(other : ReferenceDouble) : self
      wrap(@value.gcd(other.value))
    end

    def gcd(other : ::Int::Primitive) : self
      wrap(@value.gcd(other).to_big_i)
    end

    def lcm(other : ReferenceDouble) : self
      wrap(@value.lcm(other.value))
    end

    def lcm(other : ::Int::Primitive) : self
      wrap(@value.lcm(other))
    end

    def isqrt : self
      wrap(Math.isqrt(@value))
    end

    def remove(factor : ReferenceDouble) : {self, UInt64}
      result, count = GMPOracle.remove(@value, factor.value)
      {wrap(result), count}
    end

    def invert(modulus : ReferenceDouble) : self?
      result = GMPOracle.invert(@value, modulus.value)
      if result
        wrap(result)
      elsif ReferenceDouble.planting?
        ReferenceDouble.new(BigInt.new(0))
      end
    end

    def pow_mod(exponent : ReferenceDouble, modulus : ReferenceDouble) : self
      wrap(GMPOracle.pow_mod(@value, exponent.value, modulus.value))
    end

    {% for pair in [{"i64", Int64}, {"u64", UInt64}, {"i128", Int128}, {"u128", UInt128}] %}
      def to_{{ pair[0].id }}? : {{ pair[1] }}?
        converted = @value.to_{{ pair[0].id }} rescue nil
        if converted
          plant(converted)
        elsif ReferenceDouble.planting?
          {{ pair[1] }}.new(0)
        end
      end
    
      def to_{{ pair[0].id }}! : {{ pair[1] }}
        plant(@value.to_{{ pair[0].id }}!)
      end
    {% end %}

    def to_f64 : Float64
      plant(@value.to_f64)
    end

    def to_s(base : Int32 = 10, upcase : Bool = false, *, precision : Int32 = 1) : String
      plant(@value.to_s(base, upcase: upcase, precision: precision))
    end

    def size_in_base(base : Int32) : Int64
      plant(LibGMP.sizeinbase(@value, base).to_i64)
    end
  end
end
