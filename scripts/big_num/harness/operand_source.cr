module G2Harness
  # Magnitude limbs and a sign: the one description both sides build from.
  record Operand, limbs : Slice(UInt64), negative : Bool do
    def bits : Int32
      return 0 if limbs.empty?
      (limbs.size - 1) * 64 + (64 - limbs.last.leading_zeros_count)
    end

    def zero? : Bool
      limbs.all?(&.zero?)
    end

    def abs : Operand
      Operand.new(limbs, false)
    end

    def negate : Operand
      Operand.new(limbs, !negative)
    end
  end

  # Draws operands per BIGNUM.md 5.2: sizes log-uniform from 0 to 8,192 bits
  # with 70% at or below 4,096, plus a fixed share of edge shapes, both signs.
  class OperandSource
    LOW_BITS = 4_096
    # Limb counts at and around the engine's starting thresholds (BIGNUM.md 4):
    # MUL_KARATSUBA 24, SQR_KARATSUBA 32, DIV_BZ 50, MUL_TOOM3 80,
    # SQR_TOOM3 100, GET_STR_DC 20.
    THRESHOLD_LIMBS = [20, 24, 32, 50, 80, 100]
    EDGE_SHARE      = 0.25

    getter max_bits : Int32

    def initialize(@random : Random::PCG32, @max_bits : Int32 = 8_192)
    end

    # A random bit size per 5.2: 70% log-uniform in 0..4,096, the rest
    # log-uniform in 4,097..max_bits.
    def bit_size : Int32
      low_cap = Math.min(LOW_BITS, @max_bits)
      if @max_bits <= LOW_BITS || @random.rand < 0.7
        log_uniform(0, low_cap)
      else
        log_uniform(LOW_BITS + 1, @max_bits)
      end
    end

    private def log_uniform(min : Int32, max : Int32) : Int32
      low = Math.log(min + 1.0)
      high = Math.log(max + 1.0)
      value = (Math.exp(low + @random.rand * (high - low)) - 1).to_i
      value.clamp(min, max)
    end

    def sign : Bool
      @random.rand(2) == 1
    end

    # An operand: an edge shape EDGE_SHARE of the time, else random bits of
    # a drawn size.
    def operand(bits : Int32? = nil) : Operand
      if bits.nil? && @random.rand < EDGE_SHARE
        edge
      else
        random_of(bits || bit_size, sign)
      end
    end

    # A random value of exactly *bits* bits (top bit set), mixing dense,
    # sparse and runs-of-ones fills so carries propagate far.
    def random_of(bits : Int32, negative : Bool) : Operand
      return Operand.new(Slice(UInt64).new(0), false) if bits <= 0
      count = (bits + 63) // 64
      limbs = Slice(UInt64).new(count)
      case @random.rand(6)
      when 0 # sparse
        (1 + @random.rand(4)).times { set_bit(limbs, @random.rand(bits)) }
      when 1 # long runs of ones
        count.times { |index| limbs[index] = @random.rand(4) == 0 ? @random.rand(UInt64) : UInt64::MAX }
      when 2 # long runs of zeros
        count.times { |index| limbs[index] = @random.rand(4) == 0 ? @random.rand(UInt64) : 0_u64 }
      else
        count.times { |index| limbs[index] = @random.rand(UInt64) }
      end
      top_bits = bits - (count - 1) * 64
      limbs[count - 1] &= top_bits == 64 ? UInt64::MAX : ((1_u64 << top_bits) - 1)
      set_bit(limbs, bits - 1)
      Operand.new(limbs, negative)
    end

    # A dense uniformly random value of exactly *bits* bits, for the bench.
    def dense_of(bits : Int32, negative : Bool = false) : Operand
      return Operand.new(Slice(UInt64).new(0), false) if bits <= 0
      count = (bits + 63) // 64
      limbs = Slice(UInt64).new(count) { @random.rand(UInt64) }
      top_bits = bits - (count - 1) * 64
      limbs[count - 1] &= top_bits == 64 ? UInt64::MAX : ((1_u64 << top_bits) - 1)
      set_bit(limbs, bits - 1)
      Operand.new(limbs, negative)
    end

    private def set_bit(limbs : Slice(UInt64), bit : Int32) : Nil
      limbs[bit // 64] |= 1_u64 << (bit % 64)
    end

    private def capped(bits : Int32) : Int32
      Math.min(bits, @max_bits)
    end

    # The edge shapes of 5.2, each with a random sign.
    def edge : Operand
      negative = sign
      case @random.rand(10)
      when 0 # zero
        Operand.new(Slice(UInt64).new(0), false)
      when 1 # +-1
        Operand.new(Slice[1_u64], negative)
      when 2 # limb boundaries
        random_of(capped([63, 64, 65, 127, 128, 129].sample(@random)), negative)
      when 3 # all-ones limbs
        count = 1 + @random.rand(Math.max(1, capped(LOW_BITS) // 64))
        Operand.new(Slice(UInt64).new(count, UInt64::MAX), negative)
      when 4 # powers of two and their neighbors
        power_neighbor(@random.rand(capped(LOW_BITS * 2)), negative)
      when 5 # sparse
        bits = bit_size
        limbs = Slice(UInt64).new(Math.max(1, (bits + 63) // 64))
        (1 + @random.rand(3)).times { set_bit(limbs, @random.rand(Math.max(1, bits))) }
        Operand.new(limbs, negative)
      when 6 # top limb just above 2^63 (Algorithm D add-back divisors)
        count = 1 + @random.rand(Math.max(1, capped(LOW_BITS) // 64))
        operand = random_of(count * 64, negative)
        operand.limbs[count - 1] = (1_u64 << 63) | @random.rand(16).to_u64
        operand
      when 7 # threshold sizes +-1 limb
        limbs = THRESHOLD_LIMBS.sample(@random) + @random.rand(3) - 1
        random_of(capped(limbs * 64 - @random.rand(64)), negative)
      when 8 # small values that fit primitives
        random_of(1 + @random.rand(128), negative)
      else
        random_of(bit_size, negative)
      end
    end

    # 2^k, 2^k - 1 or 2^k + 1.
    def power_neighbor(exponent : Int32, negative : Bool) : Operand
      limbs = Slice(UInt64).new(exponent // 64 + 1)
      limbs[exponent // 64] = 1_u64 << (exponent % 64)
      case @random.rand(3)
      when 0
        limbs[0] |= 1_u64 if exponent > 0
      when 1
        if exponent > 0
          limbs[exponent // 64] = 0
          (exponent // 64).times { |index| limbs[index] = UInt64::MAX }
          limbs[exponent // 64] = (1_u64 << (exponent % 64)) &- 1 if exponent % 64 != 0
        end
      end
      Operand.new(limbs, negative)
    end

    # A divisor for *dividend*: about half its size, its size, slightly
    # smaller, one limb, an add-back shape, or anything.
    def divisor_for(dividend : Operand) : Operand
      bits = dividend.bits
      case @random.rand(6)
      when 0 then random_of(Math.max(1, bits // 2), sign)
      when 1 then random_of(Math.max(1, bits), sign)
      when 2 then random_of(Math.max(1, bits - 1 - @random.rand(Math.max(1, bits // 4 + 1))), sign)
      when 3 then random_of(1 + @random.rand(64), sign)
      when 4
        count = Math.max(1, (bits // 2 + 63) // 64)
        shaped = random_of(count * 64, sign)
        shaped.limbs[count - 1] = (1_u64 << 63) | @random.rand(16).to_u64
        shaped
      else
        self.operand
      end
    end

    # A primitive operand of a random primitive type for the *_ui/*_si paths.
    def primitive : Int8 | Int16 | Int32 | Int64 | Int128 | UInt8 | UInt16 | UInt32 | UInt64 | UInt128
      edge = @random.rand(4) == 0
      case @random.rand(10)
      when 0 then edge ? [0_i8, 1_i8, -1_i8, Int8::MIN, Int8::MAX].sample(@random) : @random.rand(Int8)
      when 1 then edge ? [0_i16, -1_i16, Int16::MIN, Int16::MAX].sample(@random) : @random.rand(Int16)
      when 2 then edge ? [0, 1, -1, Int32::MIN, Int32::MAX].sample(@random) : @random.rand(Int32)
      when 3 then edge ? [0_i64, 1_i64, -1_i64, Int64::MIN, Int64::MAX].sample(@random) : @random.rand(Int64)
      when 4 then edge ? [0_i128, -1_i128, Int128::MIN, Int128::MAX, Int128.new(UInt64::MAX) + 1].sample(@random) : @random.rand(Int128)
      when 5 then edge ? [0_u8, UInt8::MAX].sample(@random) : @random.rand(UInt8)
      when 6 then edge ? [0_u16, UInt16::MAX].sample(@random) : @random.rand(UInt16)
      when 7 then edge ? [0_u32, UInt32::MAX].sample(@random) : @random.rand(UInt32)
      when 8 then edge ? [0_u64, 1_u64, UInt64::MAX, 1_u64 << 63].sample(@random) : @random.rand(UInt64)
      else        edge ? [0_u128, UInt128::MAX, UInt128.new(UInt64::MAX) + 1].sample(@random) : @random.rand(UInt128)
      end
    end

    # A Float64 operand: exact integers, fractions, huge and tiny values,
    # and the non-finite values.
    def float : Float64
      case @random.rand(8)
      when 0 then [0.0, -0.0, Float64::INFINITY, -Float64::INFINITY, Float64::NAN, Float64::MAX, -Float64::MAX, Float64::MIN_POSITIVE].sample(@random)
      when 1 then (@random.rand * 2 - 1) * 10.0 ** @random.rand(0..300)
      when 2 then (@random.rand(Int64) // (1_i64 << @random.rand(0..62))).to_f64
      when 3 then (@random.rand * 2 - 1) * 2.0 ** @random.rand(-60..1023)
      else        @random.rand(UInt64).unsafe_as(Float64)
      end
    end

    def rand(range) : Int32
      @random.rand(range)
    end

    def rand(max : Int32) : Int32
      @random.rand(max)
    end

    def sample(list : Array(U)) : U forall U
      list.sample(@random)
    end

    def chance(probability : Float64) : Bool
      @random.rand < probability
    end
  end
end
