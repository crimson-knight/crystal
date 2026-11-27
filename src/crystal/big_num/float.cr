module Crystal::BigNum
  # :nodoc:
  #
  # An arbitrary-precision binary float with the representation and the
  # semantics of GMP's `mpf_t`, as the GMP manual documents them and the
  # differential (`scripts/big_num/float_differential.cr`) confirms limb by
  # limb (BIGNUM.md 3.3):
  #
  # * The value is `limbs * B ** (exponent - size)` with `B = 2 ** 64`: the
  #   mantissa limbs (least significant first), a signed limb count whose
  #   sign is the sign of the value, and an exponent counted in whole limbs.
  #   The most significant limb is never zero; zero has no limbs and
  #   exponent 0. Low limbs may be zero.
  # * The precision is counted in limbs: a precision of *n* bits becomes
  #   `ceil(n / 64) + 1` limbs, so one limb more than *n* needs, and an
  #   operation keeps the limbs its `mpf` counterpart keeps (often the
  #   precision plus one).
  # * Results are truncated, never rounded. There is no NaN, no infinity and
  #   no signed zero.
  #
  # Values are immutable: every operation builds its result in a fresh
  # buffer, and copies share limbs. Every operation that makes a value takes
  # the limb precision of the result (`mpf_init` uses the default).
  struct Float
    include Comparable(Float)

    # The default precision in bits, as `mpf_get_default_prec` reports it
    # (the precision in limbs, less one, times 64). Starts at 64 bits, as
    # GMP's does.
    @@default_precision = Atomic(UInt64).new(64_u64)

    # Signed limb count: the sign of the value and the count of limbs.
    @size : Int32
    # Exponent in limbs: the value is `limbs * B ** (@exponent - size)`.
    @exponent : Int64
    # Precision in limbs (`mpf`'s `_mp_prec`).
    @precision : Int32
    # The limbs, least significant first.
    @limbs : Pointer(Limb)

    protected def initialize(@size : Int32, @exponent : Int64, @precision : Int32, @limbs : Pointer(Limb))
    end

    # ---- Precision ----

    # The limb precision for a request of *bits* bits: `ceil(bits / 64) + 1`,
    # where a request below 53 bits counts as 53 (a double's mantissa).
    def self.limb_precision(bits : Int) : Int32
      ((Math.max(bits.to_u128, 53_u128) + 2 * LIMB_BITS - 1) // LIMB_BITS).to_i32
    end

    # The default precision in bits, rounded as `mpf_get_default_prec`
    # rounds it.
    def self.default_precision : UInt64
      @@default_precision.get
    end

    # Sets the default precision to at least *bits* bits.
    def self.default_precision=(bits : Int) : Nil
      @@default_precision.set(bit_precision(limb_precision(bits)))
    end

    # The default precision in limbs.
    def self.default_limb_precision : Int32
      limb_precision(default_precision)
    end

    # The bits a limb precision stands for, as `mpf_get_prec` reports them.
    def self.bit_precision(limb_precision : Int32) : UInt64
      (limb_precision.to_u64 - 1) * LIMB_BITS
    end

    # The precision of the value in bits (`mpf_get_prec`).
    def bit_precision : UInt64
      Float.bit_precision(@precision)
    end

    # ---- Representation ----

    # The precision in limbs.
    def precision : Int32
      @precision
    end

    # The signed limb count.
    def signed_size : Int32
      @size
    end

    # The count of limbs.
    def size : Int32
      @size.abs
    end

    # The exponent in limbs.
    def exponent : Int64
      @exponent
    end

    # The mantissa limbs, least significant first (read-only).
    def limbs : Slice(Limb)
      Slice.new(@limbs, size, read_only: true)
    end

    def zero? : Bool
      @size == 0
    end

    def negative? : Bool
      @size < 0
    end

    # -1, 0 or 1 as the value is negative, zero or positive.
    def sign : Int32
      @size <=> 0
    end

    # The value with the given parts. The limbs are copied; the caller makes
    # sure the most significant limb is not zero.
    def self.from_parts(limbs : Slice(Limb), negative : Bool, exponent : Int64, precision : Int32) : Float
      return zero(precision) if limbs.empty?
      copy(limbs.to_unsafe, limbs.size, negative, exponent, precision)
    end

    # The same value and precision with the exponent replaced: `Math.frexp`
    # uses it to put the binary point above the top limb.
    def with_exponent(exponent : Int64) : Float
      zero? ? self : Float.new(@size, exponent, @precision, @limbs)
    end

    # The value as `m * 2 ** e` exactly, with `m` odd (or `{0, 0}` for zero).
    def exact_binary : {Integer, Int64}
      return {Integer.zero, 0_i64} if zero?
      mantissa = Float.integer_of(@limbs, size, negative?)
      zeros = mantissa.trailing_zeros_count
      {mantissa >> zeros, (@exponent - size) * LIMB_BITS + zeros.to_i64}
    end

    # ---- Construction ----

    # Zero at *precision* limbs.
    def self.zero(precision : Int32 = default_limb_precision) : Float
      new(0, 0_i64, precision, Pointer(Limb).null)
    end

    # The value of *value* (`mpf_set_ui`).
    def self.from_u64(value : UInt64, precision : Int32 = default_limb_precision) : Float
      return zero(precision) if value == 0
      pointer = Limbs.allocate(1)
      pointer[0] = value
      new(1, 1_i64, precision, pointer)
    end

    # The value of *value* (`mpf_set_si`).
    def self.from_i64(value : Int64, precision : Int32 = default_limb_precision) : Float
      return zero(precision) if value == 0
      pointer = Limbs.allocate(1)
      pointer[0] = value < 0 ? 0_u64 &- value.to_u64! : value.to_u64
      new(value < 0 ? -1 : 1, 1_i64, precision, pointer)
    end

    # The exact value of the finite double *value* (`mpf_set_d`): always two
    # limbs, the top one not zero, whatever the precision.
    def self.from_f64(value : Float64, precision : Int32 = default_limb_precision) : Float
      raise ArgumentError.new "Can only construct from a finite number" unless value.finite?
      bits = value.unsafe_as(UInt64)
      negative = bits >> 63 != 0
      biased = ((bits >> 52) & 0x7FF).to_i32
      fraction = bits & 0x000F_FFFF_FFFF_FFFF_u64
      return zero(precision) if biased == 0 && fraction == 0
      if biased == 0
        mantissa = fraction
        shift = -1074
      else
        mantissa = fraction | 0x0010_0000_0000_0000_u64
        shift = biased - 1075
      end
      # |value| = mantissa * 2 ** shift lies in [2 ** (top - 1), 2 ** top).
      top = shift + 64 - mantissa.leading_zeros_count
      exponent = (top + LIMB_BITS - 1) // LIMB_BITS
      # Two limbs below the limb point: mantissa * 2 ** (shift - 64 * (exponent - 2)).
      magnitude = mantissa.to_u128 << (shift - LIMB_BITS * (exponent - 2))
      pointer = Limbs.allocate(2)
      pointer[0] = magnitude.to_u64!
      pointer[1] = (magnitude >> 64).to_u64!
      new(negative ? -2 : 2, exponent.to_i64, precision, pointer)
    end

    # The value of the integer *value* (`mpf_set_z`): its top limbs, as many
    # as the precision plus one.
    def self.from_integer(value : Integer, precision : Int32 = default_limb_precision) : Float
      return zero(precision) if value.zero?
      limbs = value.limbs
      count = Math.min(limbs.size, precision + 1)
      copy(limbs.to_unsafe + (limbs.size - count), count, value.negative?, limbs.size.to_i64, precision)
    end

    # The quotient *numerator* / *denominator* (*denominator* positive),
    # truncated to the precision plus one limb (`mpf_set_q`).
    def self.from_rational(numerator : Integer, denominator : Integer, precision : Int32 = default_limb_precision) : Float
      return zero(precision) if numerator.zero?
      exponent = numerator.size.to_i64 - denominator.size + 1
      quotient_size = precision + 1
      zeros = quotient_size.to_i64 - exponent
      dividend = numerator.abs << (zeros * LIMB_BITS)
      quotient = dividend.tdiv(denominator)
      if quotient.size < quotient_size
        quotient_size -= 1
        exponent -= 1
      end
      place(quotient, quotient_size, numerator.negative?, exponent, precision)
    end

    # ---- Copies ----

    # The value truncated to the precision plus one limb (`mpf_set`).
    def set(precision : Int32 = Float.default_limb_precision) : Float
      return Float.zero(precision) if zero?
      count = Math.min(size, precision + 1)
      Float.copy(@limbs + (size - count), count, negative?, @exponent, precision)
    end

    # The negated value truncated as `set` truncates (`mpf_neg` into a fresh
    # variable).
    def neg(precision : Int32 = Float.default_limb_precision) : Float
      set(precision).negate
    end

    # The absolute value truncated as `set` truncates (`mpf_abs`).
    def abs(precision : Int32 = Float.default_limb_precision) : Float
      result = set(precision)
      result.negative? ? result.negate : result
    end

    # The negated value with its limbs and precision kept (`mpf_neg` in place).
    def negate : Float
      Float.new(-@size, @exponent, @precision, @limbs)
    end

    # ---- Addition and subtraction ----

    # `mpf_add`: both operands are truncated at the result's precision below
    # the higher one's top limb, then added exactly.
    def add(other : Float, precision : Int32 = Float.default_limb_precision) : Float
      return other.set(precision) if zero?
      return set(precision) if other.zero?
      return sub(other.negate, precision) if negative? != other.negative?
      u, v = self, other
      u, v = v, u if u.@exponent < v.@exponent
      up = u.@limbs
      usize = u.size
      vp = v.@limbs
      vsize = v.size
      uexp = u.@exponent
      ediff = uexp - v.@exponent
      if usize > precision
        up += usize - precision
        usize = precision
      end
      return Float.copy(up, usize, negative?, uexp, precision) if ediff >= precision
      shift = ediff.to_i32
      if vsize + shift > precision
        vp += vsize + shift - precision
        vsize = precision - shift
      end
      low = Math.min(uexp - usize, uexp - shift - vsize)
      count = (uexp - low).to_i32
      v_offset = (uexp - shift - vsize - low).to_i32
      sum = Limbs.allocate(count + 1)
      Limbs.zero(sum, count)
      Limbs.copy(sum + (uexp - usize - low).to_i32, up, usize)
      carry = Limbs.add(sum + v_offset, sum + v_offset, count - v_offset, vp, vsize)
      sum[count] = carry
      used = count + carry.to_i32
      Float.new(negative? ? -used : used, uexp + carry.to_i64, precision, sum)
    end

    # `mpf_sub`: as `add`, with the result's precision plus one limb, and
    # with the leading limbs that cancel skipped first.
    def sub(other : Float, precision : Int32 = Float.default_limb_precision) : Float
      return other.neg(precision) if zero?
      return set(precision) if other.zero?
      return add(other.negate, precision) if negative? != other.negative?
      negative = negative?
      u, v = self, other
      if u.@exponent < v.@exponent
        u, v = v, u
        negative = !negative
      end
      up = u.@limbs
      usize = u.size
      vp = v.@limbs
      vsize = v.size
      prec = precision + 1
      exp = u.@exponent
      ediff = exp - v.@exponent

      if ediff <= 1
        near = false
        if ediff == 0
          # Skip the leading limbs that are equal.
          while up[usize - 1] == vp[vsize - 1]
            usize -= 1
            vsize -= 1
            exp -= 1
            if usize == 0
              return Float.cancellation(vp, vsize, !negative, exp, prec, precision)
            end
            if vsize == 0
              return Float.cancellation(up, usize, negative, exp, prec, precision)
            end
          end
          if up[usize - 1] < vp[vsize - 1]
            up, vp = vp, up
            usize, vsize = vsize, usize
            negative = !negative
          end
          # x + 1 00000000 ... less x ffffffff ...
          if up[usize - 1] == vp[vsize - 1] &+ 1
            usize -= 1
            vsize -= 1
            exp -= 1
            near = true
          end
        else
          # 1 00000000 ... less 0 ffffffff ...
          if up[usize - 1] == 1 && vp[vsize - 1] == Limb::MAX && (usize < 2 || up[usize - 2] == 0)
            usize -= 1
            exp -= 1
            near = true
          end
        end
        return Float.near_cancellation(up, usize, vp, vsize, negative, exp, prec, precision) if near
      end

      if usize > prec
        up += usize - prec
        usize = prec
      end
      return Float.copy(up, usize, negative, exp, precision) if ediff >= prec
      shift = ediff.to_i32
      if vsize + shift > prec
        vp += vsize + shift - prec
        vsize = prec - shift
      end
      # Drop the zero limbs at the low end of each.
      while true
        return Float.copy(up, usize, negative, exp, precision) if vsize == 0
        break if vp[0] != 0
        vp += 1
        vsize -= 1
      end
      while true
        return Float.copy(vp, vsize, !negative, exp, precision) if usize == 0
        break if up[0] != 0
        up += 1
        usize -= 1
      end
      low = Math.min(exp - usize, exp - shift - vsize)
      width = (exp - low).to_i32
      v_offset = (exp - shift - vsize - low).to_i32
      difference = Limbs.allocate(width)
      Limbs.zero(difference, width)
      Limbs.copy(difference + (exp - usize - low).to_i32, up, usize)
      Limbs.sub(difference + v_offset, difference + v_offset, width - v_offset, vp, vsize)
      count = Limbs.normalize(difference, width)
      return Float.zero(precision) if count == 0
      Float.new(negative ? -count : count, low + count, precision, difference)
    end

    # The rest of one operand after every limb of the other cancelled: its
    # high zero limbs dropped, then truncated to *prec* limbs.
    protected def self.cancellation(pointer : Pointer(Limb), count : Int32, negative : Bool, exponent : Int64, prec : Int32, precision : Int32) : Float
      while count != 0 && pointer[count - 1] == 0
        count -= 1
        exponent -= 1
      end
      return zero(precision) if count == 0
      if count > prec
        pointer += count - prec
        count = prec
      end
      copy(pointer, count, negative, exponent, precision)
    end

    # `B ** exponent + U - V`, where U and V have their tops just below
    # limb *exponent*: the operands of a subtraction whose leading limbs
    # nearly cancel.
    protected def self.near_cancellation(up : Pointer(Limb), usize : Int32, vp : Pointer(Limb), vsize : Int32, negative : Bool, exponent : Int64, prec : Int32, precision : Int32) : Float
      # Skip 00000000 over ffffffff.
      while vsize != 0 && usize != 0 && up[usize - 1] == 0 && vp[vsize - 1] == Limb::MAX
        usize -= 1
        vsize -= 1
        exponent -= 1
      end
      if usize == 0
        while vsize != 0 && vp[vsize - 1] == Limb::MAX
          vsize -= 1
          exponent -= 1
        end
      elsif usize > prec - 1
        up += usize - (prec - 1)
        usize = prec - 1
      end
      if vsize > prec - 1
        vp += vsize - (prec - 1)
        vsize = prec - 1
      end
      width = Math.max(usize, vsize)
      low = exponent - width
      value = (Integer.new(1) << width * LIMB_BITS) +
              (integer_of(up, usize) << (width - usize) * LIMB_BITS) -
              (integer_of(vp, vsize) << (width - vsize) * LIMB_BITS)
      count = value.size
      place(value, count, negative, low + count, precision)
    end

    # `mpf_add_ui`.
    def add_ui(value : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      return Float.from_u64(value, precision) if zero?
      return negate.sub_ui(value, precision).negate if negative?
      usize = size
      uexp = @exponent
      if value == 0 || uexp > precision
        count = Math.min(usize, precision + 1)
        return Float.copy(@limbs + (usize - count), count, false, uexp, precision)
      end
      if uexp > 0
        units = uexp.to_i32
        if units > usize
          # uuuuuu0000. plus v.
          sum = (Float.integer_of(@limbs, usize) << (units - usize) * LIMB_BITS) + value
          Float.place(sum, units, false, uexp, precision)
        else
          # uuuuuu.uuuu plus v.
          up = @limbs
          if usize > precision
            up += usize - precision
            usize = precision
          end
          sum = Float.integer_of(up, usize) + (Integer.new(value) << (usize - units) * LIMB_BITS)
          carry = sum.size > usize ? 1 : 0
          Float.place(sum, usize + carry, false, uexp + carry, precision)
        end
      else
        # v. plus .0000uuuu
        gap = (0_i64 - uexp)
        return Float.from_u64(value, precision) if gap >= precision
        gap = gap.to_i32
        up = @limbs
        if usize + gap + 1 > precision
          up += usize + gap + 1 - precision
          usize = precision - gap - 1
        end
        sum = Float.integer_of(up, usize) + (Integer.new(value) << (usize + gap) * LIMB_BITS)
        Float.place(sum, usize + gap + 1, false, 1_i64, precision)
      end
    end

    # `mpf_sub_ui`.
    def sub_ui(value : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      return set(precision) if value == 0
      sub(Float.from_u64(value, precision), precision)
    end

    # ---- Multiplication ----

    # `mpf_mul`: each operand truncated to the precision, the exact product,
    # then its top precision-plus-one limbs.
    def mul(other : Float, precision : Int32 = Float.default_limb_precision) : Float
      return Float.zero(precision) if zero? || other.zero?
      usize = Math.min(size, precision)
      vsize = Math.min(other.size, precision)
      up = @limbs + (size - usize)
      vp = other.@limbs + (other.size - vsize)
      count = usize + vsize
      product = Limbs.allocate(count)
      if usize >= vsize
        Multiply.mul(product, up, usize, vp, vsize)
      else
        Multiply.mul(product, vp, vsize, up, usize)
      end
      adjust = product[count - 1] == 0 ? 1 : 0
      count -= adjust
      negative = negative? != other.negative?
      exponent = @exponent + other.@exponent - adjust
      if count > precision + 1
        return Float.copy(product + (count - precision - 1), precision + 1, negative, exponent, precision)
      end
      Float.new(negative ? -count : count, exponent, precision, product)
    end

    # `mpf_mul_ui`: the exact product of the value and *value*, with the
    # limbs below the precision dropped (truncating, carries included).
    def mul_ui(value : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      return Float.zero(precision) if value == 0 || zero?
      count = size
      product = Float.integer_of(@limbs, count) * value
      if count > precision
        product = product >> (count - precision) * LIMB_BITS
        count = precision
      end
      carry = product.size > count ? 1 : 0
      Float.place(product, count + carry, negative?, @exponent + carry, precision)
    end

    # ---- Division ----

    # `mpf_div`: a quotient of the precision plus one limbs, truncated.
    def div(other : Float, precision : Int32 = Float.default_limb_precision) : Float
      raise DivisionByZeroError.new if other.zero?
      return Float.zero(precision) if zero?
      Float.divide(@limbs, size, negative?, @exponent, other, precision)
    end

    # `mpf_ui_div`: *value* / *other*.
    def self.ui_div(value : UInt64, other : Float, precision : Int32 = default_limb_precision) : Float
      raise DivisionByZeroError.new if other.zero?
      return zero(precision) if value == 0
      limb = value
      divide(pointerof(limb), 1, false, 1_i64, other, precision)
    end

    # The quotient of the *usize* limbs at *up* (limb exponent *uexp*) by
    # *other*, with the precision plus one limbs.
    protected def self.divide(up : Pointer(Limb), usize : Int32, negative : Bool, uexp : Int64, other : Float, precision : Int32) : Float
      vsize = other.size
      exponent = uexp - other.@exponent + 1
      quotient_size = precision + 1
      zeros = quotient_size - (usize - vsize + 1)
      if zeros < 0
        up += -zeros
        usize += zeros
        zeros = 0
      end
      dividend = integer_of(up, usize) << zeros * LIMB_BITS
      quotient = dividend.tdiv(integer_of(other.@limbs, vsize))
      if quotient.size < quotient_size
        quotient_size -= 1
        exponent -= 1
      end
      place(quotient, quotient_size, negative != other.negative?, exponent, precision)
    end

    # `mpf_div_ui`.
    def div_ui(value : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      raise DivisionByZeroError.new if value == 0
      return Float.zero(precision) if zero?
      dividend_size = precision + 1
      usize = size
      up = @limbs
      if usize > dividend_size
        up += usize - dividend_size
        usize = dividend_size
      end
      dividend = Float.integer_of(up, usize) << (dividend_size - usize) * LIMB_BITS
      quotient = dividend.tdiv(Integer.new(value))
      count = dividend_size
      exponent = @exponent
      if quotient.size < count
        count -= 1
        exponent -= 1
      end
      Float.place(quotient, count, negative?, exponent, precision)
    end

    # ---- Powers and roots ----

    # `mpf_sqrt`: the integer square root of the top limbs, exactly the
    # precision in limbs. Raises `ArgumentError` for a negative value.
    def sqrt(precision : Int32 = Float.default_limb_precision) : Float
      raise ArgumentError.new("Square root of negative number") if negative?
      return Float.zero(precision) if zero?
      odd = (@exponent & 1).to_i32
      width = 2 * precision - odd
      exponent = (@exponent + odd).tdiv(2)
      usize = size
      up = @limbs
      if usize > width
        up += usize - width
        usize = width
      end
      root = (Float.integer_of(up, usize) << (width - usize) * LIMB_BITS).isqrt
      Float.place(root, precision, false, exponent, precision)
    end

    # `mpf_pow_ui`: square and multiply from the top bit of *power*, at the
    # result's precision widened by the bit length of *power*.
    def pow_ui(power : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      return Float.from_u64(1_u64, precision) if power == 0
      return set(precision) if power == 1
      bit = 63 - power.leading_zeros_count
      working = Float.limb_precision(Float.bit_precision(precision) + bit)
      result = set(working)
      while (bit -= 1) > 0
        result = result.mul(result, working)
        result = result.mul(self, working) if (power >> bit) & 1 != 0
      end
      if power & 1 != 0
        result = result.mul(result, working)
        result.mul(self, precision)
      else
        result.mul(result, precision)
      end
    end

    # `mpf_mul_2exp`.
    def mul_2exp(count : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      shift_left((count % LIMB_BITS).to_i32, (count // LIMB_BITS).to_i64!, precision)
    end

    # `mpf_div_2exp`.
    def div_2exp(count : UInt64, precision : Int32 = Float.default_limb_precision) : Float
      bits = (count % LIMB_BITS).to_i32
      limbs = (count // LIMB_BITS).to_i64!
      if bits == 0
        shift_left(0, 0_i64 &- limbs, precision)
      else
        shift_left(LIMB_BITS - bits, 0_i64 &- limbs &- 1, precision)
      end
    end

    # The value times `2 ** bits * B ** limbs` (*bits* below 64).
    private def shift_left(bits : Int32, limbs : Int64, precision : Int32) : Float
      return Float.zero(precision) if zero?
      if bits == 0
        count = Math.min(size, precision + 1)
        return Float.copy(@limbs + (size - count), count, negative?, @exponent &+ limbs, precision)
      end
      count = Math.min(size, precision)
      shifted = Float.integer_of(@limbs + (size - count), count) << bits
      carry = shifted.size > count ? 1 : 0
      Float.place(shifted, count + carry, negative?, @exponent &+ limbs &+ carry, precision)
    end

    # ---- Rounding to integers ----

    # `mpf_trunc`.
    def trunc(precision : Int32 = Float.default_limb_precision) : Float
      return Float.zero(precision) if zero? || @exponent <= 0
      count = Math.min(Math.min(size.to_i64, @exponent), precision.to_i64 + 1).to_i32
      Float.copy(@limbs + (size - count), count, negative?, @exponent, precision)
    end

    # `mpf_floor`.
    def floor(precision : Int32 = Float.default_limb_precision) : Float
      round_toward(-1, precision)
    end

    # `mpf_ceil`.
    def ceil(precision : Int32 = Float.default_limb_precision) : Float
      round_toward(1, precision)
    end

    # Rounds toward minus infinity (*direction* -1) or plus infinity (1).
    private def round_toward(direction : Int32, precision : Int32) : Float
      return Float.zero(precision) if zero?
      away = negative? == (direction < 0)
      if @exponent <= 0
        return Float.zero(precision) unless away
        return Float.from_i64(direction.to_i64, precision)
      end
      count = Math.min(Math.min(size.to_i64, @exponent), precision.to_i64 + 1).to_i32
      start = size - count
      if away && !Limbs.zero?(@limbs, start)
        kept = Float.integer_of(@limbs + start, count) + 1
        if kept.size > count
          return Float.place(Integer.new(1), 1, negative?, @exponent + 1, precision)
        end
        return Float.place(kept, count, negative?, @exponent, precision)
      end
      Float.copy(@limbs + start, count, negative?, @exponent, precision)
    end

    # Whether the value is an integer (`mpf_integer_p`).
    def integer? : Bool
      return true if zero?
      return false if @exponent <= 0
      start = 0
      while @limbs[start] == 0
        start += 1
      end
      size - start <= @exponent
    end

    # ---- Comparison ----

    # Compares exactly (`mpf_cmp`): -1, 0 or 1.
    def <=>(other : Float) : Int32
      own = sign
      their = other.sign
      return own <=> their if own != their || own == 0
      order = compare_magnitude(other)
      own < 0 ? -order : order
    end

    private def compare_magnitude(other : Float) : Int32
      return @exponent > other.@exponent ? 1 : -1 if @exponent != other.@exponent
      own_index = size - 1
      other_index = other.size - 1
      while own_index >= 0 && other_index >= 0
        own_limb = @limbs[own_index]
        other_limb = other.@limbs[other_index]
        return own_limb > other_limb ? 1 : -1 if own_limb != other_limb
        own_index -= 1
        other_index -= 1
      end
      return Limbs.zero?(@limbs, own_index + 1) ? 0 : 1 if own_index >= 0
      return Limbs.zero?(other.@limbs, other_index + 1) ? 0 : -1 if other_index >= 0
      0
    end

    # Compares with *value* exactly (`mpf_cmp_si`).
    def cmp_si(value : Int64) : Int32
      self <=> Float.from_i64(value, 2)
    end

    # Compares with *value* exactly (`mpf_cmp_ui`).
    def cmp_ui(value : UInt64) : Int32
      self <=> Float.from_u64(value, 2)
    end

    # Compares with the double *value* exactly (`mpf_cmp_d`): -1, 0 or 1, but
    # the signed limb count against a zero double, and the infinities lie
    # beyond every value.
    def cmp_d(value : Float64) : Int32
      return @size if value == 0
      if infinite = value.infinite?
        return -infinite
      end
      self <=> Float.from_f64(value, 2)
    end

    # Compares with the integer *value* exactly (`mpf_cmp_z`).
    def cmp_z(value : Integer) : Int32
      self <=> Float.from_integer(value, value.size + 1)
    end

    # ---- Conversions ----

    # The value truncated to an integer (`mpz_set_f`).
    def to_integer : Integer
      return Integer.zero if @exponent <= 0 || zero?
      if @exponent > size
        Float.integer_of(@limbs, size, negative?) << (@exponent - size) * LIMB_BITS
      else
        count = @exponent.to_i32
        Float.integer_of(@limbs + (size - count), count, negative?)
      end
    end

    # The limb just above the limb point (`mpf_get_ui`): the low 64 bits of
    # the magnitude's integer part.
    def get_ui : UInt64
      return 0_u64 if @exponent <= 0
      size >= @exponent ? @limbs[size - @exponent] : 0_u64
    end

    # `mpf_get_si`: the low 63 bits of the integer part, with the sign.
    def get_si : Int64
      return 0_i64 if @exponent <= 0
      limb = get_ui
      if @size > 0
        (limb & Int64::MAX.to_u64).to_i64
      elsif @size < 0
        -1_i64 - ((limb &- 1) & Int64::MAX.to_u64).to_i64
      else
        0_i64
      end
    end

    # The value as a double truncated toward zero (`mpf_get_d`); beyond the
    # double range it is an infinity of the value's sign.
    def to_f64 : Float64
      return 0.0 if zero?
      count = size
      mantissa = Float.integer_of(@limbs, count)
      length = mantissa.bit_length
      # |value| = mantissa * 2 ** scale, in [2 ** (top - 1), 2 ** top).
      scale = (@exponent - count) * LIMB_BITS
      top = scale + length
      result =
        if top > 1024
          Float64::INFINITY
        elsif top < -1073
          return 0.0
        else
          grid = Math.max(top - 53, -1074_i64)
          kept = mantissa >> (grid - scale)
          Math.ldexp(kept.to_u64!.to_f64, grid)
        end
      negative? ? -result : result
    end

    # ---- Strings ----

    # The decimal digits and the decimal exponent that
    # `mpf_get_str(nil, out exp, 10, 0, value)` returns: as many significant
    # digits as the precision allows, rounded to nearest at the last one,
    # without trailing zeros, with a leading `-` for a negative value; the
    # value is `0.DIGITS * 10 ** exponent`.
    def to_digits : {String, Int64}
      return {"", 0_i64} if zero?
      wanted = Float.digits_in_limbs(@precision - 1) + 2
      limbs_needed = Float.limbs_for_digits(wanted)
      up = @limbs
      usize = size
      if usize > limbs_needed
        up += usize - limbs_needed
        usize = limbs_needed
      end
      mantissa = Float.integer_of(up, usize)
      if @exponent <= limbs_needed
        more = (limbs_needed.to_i64 - @exponent).to_u64!
        power_of_ten = Float.digits_in_limbs(more)
        scale, ignored = Float.power_high_part(10_u64, power_of_ten, limbs_needed + 1)
        product = mantissa * scale
        offset = usize.to_i64 - @exponent - ignored
        integral = offset < 0 ? product << (0_i64 - offset) * LIMB_BITS : product >> offset * LIMB_BITS
        digits = integral.to_s
        exponent10 = digits.bytesize.to_i64 &- power_of_ten.to_i64!
      else
        less = (@exponent - limbs_needed).to_u64!
        power_of_ten = Float.digits_in_limbs(less)
        scale, ignored = Float.power_high_part(10_u64, power_of_ten, limbs_needed + 1)
        dividend_size = limbs_needed.to_i64 + (less.to_i64 - ignored)
        dividend = mantissa << (dividend_size - usize) * LIMB_BITS
        digits = dividend.tdiv(scale).to_s
        exponent10 = digits.bytesize.to_i64 &+ power_of_ten.to_i64!
      end
      bytes = digits.to_slice.dup
      computed = bytes.size
      count = wanted.to_i32
      if computed > count && bytes[count] >= '5'.ord
        # Round up at the last digit kept.
        computed = count
        index = count - 1
        while true
          if bytes[index] != '9'.ord
            bytes[index] += 1
            break
          end
          computed -= 1
          if index == 0
            bytes[0] = '1'.ord.to_u8
            computed = 1
            exponent10 &+= 1
            break
          end
          index -= 1
        end
      end
      count = computed if count > computed
      while count > 0 && bytes[count - 1] == '0'.ord
        count -= 1
      end
      text = String.build(count + 1) do |io|
        io << '-' if negative?
        io.write(bytes[0, count])
      end
      {text, exponent10}
    end

    # Parses *str* as `mpf_set_str(…, 10)` reads it, or returns nil where it
    # returns -1:
    #
    # * Whitespace (C's `isspace`) may lead the string and appear anywhere in
    #   the mantissa; a `-` may come first.
    # * At least one digit, possibly after a leading `.`; one `.` at most.
    # * An exponent after the last `@`, `e` or `E` (not the first byte): an
    #   optional sign and at least one digit, read up to the first non-digit.
    def self.parse?(text : String, precision : Int32 = default_limb_precision) : Float?
      bytes = text.to_slice
      nul = bytes.index(0_u8)
      bytes = bytes[0, nul] if nul
      index = 0
      while index < bytes.size && Radix.space?(bytes[index])
        index += 1
      end
      negative = false
      if index < bytes.size && bytes[index] === '-'
        negative = true
        index += 1
      end
      bytes = bytes[index..]
      return nil if bytes.empty?
      unless decimal_digit?(bytes[0])
        return nil unless bytes[0] === '.' && bytes.size > 1 && decimal_digit?(bytes[1])
      end

      # The exponent follows the last `@`, `e` or `E` past the first byte.
      mantissa_end = bytes.size
      exponent_start = nil
      (bytes.size - 1).downto(1) do |position|
        if bytes[position] === '@' || bytes[position] === 'e' || bytes[position] === 'E'
          exponent_start = position + 1
          mantissa_end = position
          break
        end
      end

      digits = String::Builder.new(mantissa_end)
      seen_nonzero = false
      dot_at = nil
      zeros_after_dot = 0_i64
      stored = 0_i64
      bytes[0, mantissa_end].each do |byte|
        next if Radix.space?(byte)
        if byte === '.'
          return nil if dot_at
          dot_at = stored
          next
        end
        return nil unless decimal_digit?(byte)
        seen_nonzero ||= byte != '0'.ord
        if seen_nonzero
          digits.write_byte(byte)
          stored += 1
        elsif dot_at
          zeros_after_dot += 1
        end
      end

      # mpf_set_str returns zero before it reads the exponent.
      return zero(precision) if stored == 0

      exponent10 = 0_i64
      if start = exponent_start
        position = start
        exponent_negative = false
        if position < bytes.size && (bytes[position] === '-' || bytes[position] === '+')
          exponent_negative = bytes[position] === '-'
          position += 1
        end
        return nil unless position < bytes.size && decimal_digit?(bytes[position])
        while position < bytes.size && decimal_digit?(bytes[position])
          exponent10 = exponent10 &* 10 &+ (bytes[position] - '0'.ord)
          position += 1
        end
        exponent10 = 0_i64 &- exponent10 if exponent_negative
      end
      if dot = dot_at
        exponent10 = exponent10 &- (stored - dot + zeros_after_dot)
      end

      prec = precision + 1
      mantissa = Integer.parse(digits.to_s, 10)
      mantissa_size = mantissa.size
      mantissa_adjust = 0_i64
      if mantissa_size > prec
        mantissa_adjust = (mantissa_size - prec).to_i64
        mantissa = mantissa >> mantissa_adjust * LIMB_BITS
        mantissa_size = prec
      end

      if exponent10 == 0
        return place(mantissa, mantissa_size, negative, mantissa_size.to_i64 + mantissa_adjust, precision)
      end
      divide = exponent10 < 0
      power = divide ? (0_i64 &- exponent10).to_u64! : exponent10.to_u64!
      scale, scale_adjust = power_high_part(10_u64, power, prec)
      scale_size = scale.size

      if divide
        if mantissa_size < scale_size
          mantissa = mantissa << (scale_size - mantissa_size) * LIMB_BITS
          mantissa_adjust -= scale_size - mantissa_size
          mantissa_size = scale_size
        end
        # Normalizing the divisor can carry the dividend into one more limb.
        shift = scale.limbs[scale_size - 1].leading_zeros_count
        if shift > 0 && mantissa.limbs[mantissa_size - 1] >> (LIMB_BITS - shift) != 0
          mantissa_size += 1
        end
        fraction_limbs = prec - (mantissa_size - scale_size)
        quotient = (mantissa << fraction_limbs * LIMB_BITS).tdiv(scale)
        top = quotient.size > prec ? 1 : 0
        exponent = top.to_i64 + (mantissa_size - scale_size) + (mantissa_adjust - scale_adjust)
        quotient = quotient >> LIMB_BITS if top == 1
        place(quotient, prec, negative, exponent, precision)
      else
        product = scale * mantissa
        count = product.size
        exponent = count.to_i64 + mantissa_adjust + scale_adjust
        if count > prec
          product = product >> (count - prec) * LIMB_BITS
          count = prec
        end
        place(product, count, negative, exponent, precision)
      end
    end

    private def self.decimal_digit?(byte : UInt8) : Bool
      '0'.ord <= byte <= '9'.ord
    end

    # GMP's `mp_bases[10]` constants: `log(2) / log(10)` as a 64-bit
    # fraction, and `log2(10) / 8` as a 64-bit fraction (both rounded down).
    private LOG_2_BASE_10 = 0x4d104d427de7fbcc_u64
    private LOG_10_BASE_2 = 0x6a4d3c25e68dc57f_u64

    # The decimal digits that *limbs* limbs hold, rounded down.
    protected def self.digits_in_limbs(limbs : Int) : UInt64
      ((LOG_2_BASE_10.to_u128 * (LIMB_BITS.to_u64 &* limbs.to_u64!)) >> 64).to_u64!
    end

    # The limbs that *digits* decimal digits need, rounded up with room.
    protected def self.limbs_for_digits(digits : UInt64) : Int32
      high = ((LOG_10_BASE_2.to_u128 * digits) >> 64).to_u64!
      (8_u64 &* high // LIMB_BITS + 2).to_i32
    end

    # The high limbs of `base ** power`: square and multiply from the top
    # bit, keeping at most *limit* limbs after each squaring (and at the
    # end). Returns the kept part and the count of limbs dropped below it,
    # so `base ** power` is about `kept * B ** dropped`.
    protected def self.power_high_part(base : UInt64, power : UInt64, limit : Int32) : {Integer, Int64}
      return {Integer.new(1), 0_i64} if power == 0
      result = Integer.new(base)
      dropped = 0_i64
      bit = 62 - power.leading_zeros_count
      while bit >= 0
        result = result.square
        dropped = dropped &* 2
        excess = result.size - limit
        if excess > 0
          dropped &+= excess
          result = result >> excess * LIMB_BITS
        end
        result = result * base if (power >> bit) & 1 != 0
        bit -= 1
      end
      excess = result.size - limit
      if excess > 0
        dropped &+= excess
        result = result >> excess * LIMB_BITS
      end
      {result, dropped}
    end

    # ---- Helpers ----

    # The integer whose magnitude is the *count* limbs at *pointer*.
    protected def self.integer_of(pointer : Pointer(Limb), count : Int, negative : Bool = false) : Integer
      Integer.from_limbs(Slice.new(pointer, count.to_i32, read_only: true), negative)
    end

    # A value with a copy of the *count* limbs at *pointer*.
    protected def self.copy(pointer : Pointer(Limb), count : Int32, negative : Bool, exponent : Int64, precision : Int32) : Float
      return zero(precision) if count == 0
      limbs = Limbs.allocate(count)
      Limbs.copy(limbs, pointer, count)
      new(negative ? -count : count, exponent, precision, limbs)
    end

    # A value whose *count* limbs hold *magnitude*, zero-filled above it.
    protected def self.place(magnitude : Integer, count : Int32, negative : Bool, exponent : Int64, precision : Int32) : Float
      return zero(precision) if count == 0
      source = magnitude.limbs
      limbs = Limbs.allocate(count)
      Limbs.copy(limbs, source.to_unsafe, source.size)
      Limbs.zero(limbs + source.size, count - source.size)
      new(negative ? -count : count, exponent, precision, limbs)
    end

    def inspect(io : IO) : Nil
      io << "Float(size=" << @size << ", exponent=" << @exponent << ", precision=" << @precision << ", limbs="
      limbs.reverse_each.join(io, ':') { |limb, inner| limb.to_s(inner, 16) }
      io << ')'
    end
  end
end
