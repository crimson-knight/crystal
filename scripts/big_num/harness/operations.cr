require "./observation"
require "./operand_source"
require "./reference_double"

module G2Harness
  # One operation run on both sides.
  record Trial, operation : String, oracle : Observation, subject : Observation, operands : Array(String) do
    def pending? : Bool
      subject.pending?
    end

    def difference? : Bool
      !pending? && oracle != subject
    end
  end

  # The operation classes of STDLIB_GMP_MAP.md section 5.1 for integers, each
  # computed by GMP's `BigInt` (the oracle) and by the subject type *T*
  # (`Crystal::BigNum::Integer`, or `ReferenceDouble` for the self-check).
  class Operations(T)
    LIST_OF_NAMES = %w(
      new_primitive new_float from_limbs parse parse_round_trip to_s size_in_base
      compare compare_primitive compare_float equal hash
      add add_primitive sub sub_primitive mul mul_primitive sqr square negate abs
      floor_div floor_div_primitive floor_mod floor_mod_primitive divmod divmod_primitive
      tdiv tdiv_primitive remainder remainder_primitive tdivmod tdivmod_primitive
      unsafe_floored_div unsafe_floored_div_primitive unsafe_floored_mod unsafe_floored_mod_primitive
      unsafe_floored_divmod unsafe_floored_divmod_primitive unsafe_truncated_div unsafe_truncated_div_primitive
      unsafe_truncated_mod unsafe_truncated_mod_primitive unsafe_truncated_divmod unsafe_truncated_divmod_primitive
      divexact divisible_by divisible_by_primitive remove pow factorial isqrt
      and or xor and_primitive or_primitive xor_primitive complement shift_left shift_right
      bit popcount trailing_zeros_count bit_length
      gcd gcd_primitive lcm lcm_primitive invert pow_mod
      to_i64_checked to_u64_checked to_i128_checked to_u128_checked
      to_i64_wrapping to_u64_wrapping to_i128_wrapping to_u128_wrapping to_f64
    )

    SMALL_FACTORS = [2, 3, 5, 7, 10, 11, 12, 16, 100, 1_000, 65_537, 1_000_000_007]

    # Operations whose subject result the fault injector replaces with a near miss.
    getter list_of_injected : Array(String)

    def initialize(@list_of_injected = [] of String)
    end

    # Runs *operation* with the operands drawn from *source*.
    def run(operation : String, source : OperandSource) : Trial
      ReferenceDouble.current_op = operation
      trial = perform(operation, source)
      if list_of_injected.includes?(operation) && !trial.pending?
        trial = trial.copy_with(subject: trial.subject.near_miss)
      end
      trial
    end

    # Evaluates *oracle* on the GMP values and *subject* on the subject
    # values built from the same operands.
    private macro check(operands, oracle, subject = nil)
      %values = {{operands}}
      %described = %values.map { |value| describe(value).as(String) }.to_a
%oracle = capture do
        with_values({% for name, index in operands %} oracle_value(%values[{{index}}]), {% end %}) do |{{operands.splat}}|
          {{oracle}}
        end
      end
      %subject = capture do
        with_values({% for name, index in operands %} subject_value(%values[{{index}}]), {% end %}) do |{{operands.splat}}|
          {{subject || oracle}}
        end
      end
      Trial.new(operation, %oracle, %subject, %described)
    end

    # Calls *method* on *receiver* when the subject defines it; a method the
    # engine does not define yet reads as pending, like a stub.
    private macro if_defined(receiver, method, call)
      if {{receiver}}.responds_to?({{method}})
        {{call}}
      else
        raise NotImplementedError.new("#{{{receiver}}.class}##{{{method}}} is not defined")
      end
    end

    # Calls *call* when the subject type has a *method* overload taking a
    # Float64 (class side when *class_side*); otherwise the operation reads as
    # pending. Float64 construction and comparison belong to G2d.
    private macro if_float_overload(class_side, method, call)
      {% found = false %}
      {% owner = class_side ? @type.type_vars[0].class : @type.type_vars[0] %}
      {% for definition in owner.methods %}
        {% if definition.name == method.id.stringify && definition.args.any? { |arg| arg.restriction.stringify.includes?("Float") } %}
          {% found = true %}
        {% end %}
      {% end %}
      {% if found %}
        {{call}}
      {% else %}
        raise NotImplementedError.new("#{T}#{{{method.id.stringify}}} has no Float64 overload")
      {% end %}
    end

    private def with_values(*values, &) : Observation
      Observe.of(yield *values)
    end

    private def capture(&) : Observation
      yield
    rescue exception : NotImplementedError
      Observation.pending(exception.message)
    rescue exception
      Observation.raised(exception)
    end

    private def oracle_value(value : Operand) : BigInt
      GMPOracle.from_limbs(value.limbs, value.negative)
    end

    private def oracle_value(value)
      value
    end

    private def subject_value(value : Operand) : T
      T.from_limbs(value.limbs, value.negative)
    end

    private def subject_value(value)
      value
    end

    private def describe(value : Operand) : String
      GMPOracle.from_limbs(value.limbs, value.negative).to_s(16) + " (#{value.limbs.size} limbs)"
    end

    private def describe(value : Float64) : String
      "Float64 0x#{value.unsafe_as(UInt64).to_s(16)} (#{value})"
    end

    private def describe(value : String) : String
      value.inspect
    end

    private def describe(value) : String
      "#{value.class} #{value}"
    end

    private def operand_from(value : BigInt) : Operand
      Operand.new(GMPOracle.limbs(value).dup, value < 0)
    end

    private def checked_i128(value) : Int128?
      value.to_i128
    rescue OverflowError
      nil
    end

    private def checked_i64(value) : Int64?
      value.to_i64
    rescue OverflowError
      nil
    end

    private def checked_u128(value) : UInt128?
      value.to_u128
    rescue OverflowError
      nil
    end

    private def checked_u64(value) : UInt64?
      value.to_u64
    rescue OverflowError
      nil
    end

    private def other_for(a : Operand, source : OperandSource) : Operand
      case source.rand(10)
      when 0 then a
      when 1 then a.negate
      else        source.operand
      end
    end

    private def nonzero(operand : Operand, source : OperandSource) : Operand
      operand.zero? ? source.random_of(1 + source.rand(64), source.sign) : operand
    end

    private def divisor(dividend : Operand, source : OperandSource) : Operand
      source.chance(0.02) ? Operand.new(Slice(UInt64).new(0), false) : source.divisor_for(dividend)
    end

    private def primitive_divisor(source : OperandSource)
      source.chance(0.05) ? 0 : source.primitive
    end

    # A string for `parse` in *base*: mostly valid digits in either case,
    # with the syntax `mpz_set_str` accepts around them (leading whitespace,
    # a sign, a base prefix, leading zeros, whitespace inside) and now and
    # then something it rejects or cuts short (an invalid byte, a space after
    # the sign, a NUL byte).
    private def digit_string(source : OperandSource, base : Int32) : String
      digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
      upper = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      spaces = [' ', '\t', '\n', '\v', '\f', '\r']
      effective = base == 0 ? 10 : base.clamp(2, 62)
      length = source.chance(0.05) ? source.rand(0..3) : Math.max(1, source.operand.bits * 3 // 10)
      String.build do |io|
        source.rand(1..3).times { io << source.sample(spaces) } if source.chance(0.1)
        io << source.sample(["-", "+", " ", "- ", "-+", "--"]) if source.chance(0.3)
        if base == 0 || source.chance(0.02)
          io << source.sample(["", "0x", "0X", "0b", "0B", "0", "0x ", "0 x", "00x"])
        end
        source.rand(1..5).times { io << (source.chance(0.8) ? '0' : source.sample(spaces)) } if source.chance(0.1)
        length.times do |index|
          if source.chance(0.002)
            io << source.sample(spaces + ['_'])
          elsif effective <= 36 && source.chance(0.5)
            io << upper[source.rand(effective)]
          else
            io << digits[source.rand(effective)]
          end
          io << '_' if index > 0 && source.chance(0.001)
        end
        if source.chance(0.05) # invalid digit for this base
          io << digits[Math.min(effective, 61)]
        end
        io << "!" if source.chance(0.01)
        io << ' ' if source.chance(0.005)
        if source.chance(0.01) # mpz_set_str stops at a NUL byte
          io << '\0' << source.sample(["", "12", "zz", " "])
        end
        source.rand(1..3).times { io << source.sample(spaces) } if source.chance(0.05)
      end
    end

    private def perform(operation : String, source : OperandSource) : Trial
      case operation
      when "new_primitive"
        p = source.primitive
        check({p}, BigInt.new(p), T.new(p))
      when "new_float"
        f = source.float
        check({f}, BigInt.new(f), if_float_overload(true, :new, T.new(f)))
      when "from_limbs"
        base = source.operand
        padded = Slice(UInt64).new(base.limbs.size + source.rand(3))
        padded.copy_from(base.limbs.to_unsafe, base.limbs.size)
        a = Operand.new(padded, base.negative || source.chance(0.1))
        check({a}, a, a)
      when "parse"
        base = source.chance(0.02) ? source.sample([1, 63, -1]) : source.sample([0, 2, 8, 10, 10, 10, 16, 16, 36, 62, source.rand(2..62)])
        s = digit_string(source, base)
        b = base
        check({s, b}, BigInt.new(s, b), T.parse(s.lchop('+').delete('_'), b))
      when "parse_round_trip"
        a = source.operand
        b = source.sample([2, 8, 10, 10, 16, 16, 36, 62, source.rand(2..36)])
        u = b != 62 && source.chance(0.5)
        s = oracle_value(a).to_s(b, upcase: u)
        s = " #{s[0, s.size // 2]} #{s[s.size // 2..]}\n" if source.chance(0.1)
        b = 0 if b == 10 && source.chance(0.2)
        check({s, b}, BigInt.new(s, b), T.parse(s.lchop('+').delete('_'), b))
      when "to_s"
        a = source.operand
        b = source.sample([2, 8, 10, 10, 16, 36, 62, source.rand(2..36)])
        u = b != 62 && source.chance(0.5)
        p = source.chance(0.8) ? 1 : source.rand(0..(a.bits // 2 + 20))
        check({a, b, u, p}, a.to_s(b, upcase: u, precision: p))
      when "size_in_base"
        a = source.operand
        b = source.rand(2..62)
        check({a, b}, LibGMP.sizeinbase(a, b).to_i64, a.size_in_base(b))
      when "compare"
        a = source.operand
        c = other_for(a, source)
        check({a, c}, (a <=> c).sign)
      when "compare_primitive"
        a = source.operand
        p = source.primitive
        check({a, p}, (a <=> p).sign)
      when "compare_float"
        a = source.operand
        f = source.chance(0.3) ? oracle_value(a).to_f64 : source.float
        check({a, f}, (a <=> f).try(&.sign), if_float_overload(false, :<=>, (a <=> f).try(&.sign)))
      when "equal"
        a = source.operand
        c = other_for(a, source)
        check({a, c}, a == c)
      when "hash"
        a = source.operand
        check({a}, a.hash)
      when "add"
        a, c = source.operand, source.operand
        check({a, c}, a + c)
      when "add_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a + p)
      when "sub"
        a = source.operand
        c = other_for(a, source)
        check({a, c}, a - c)
      when "sub_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a - p)
      when "mul"
        a, c = source.operand, source.operand
        check({a, c}, a * c)
      when "mul_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a * p)
      when "sqr"
        a = source.operand
        check({a}, a * a)
      when "square"
        a = source.operand
        check({a}, a * a, if_defined(a, :square, a.square))
      when "negate"
        a = source.operand
        check({a}, -a)
      when "abs"
        a = source.operand
        check({a}, a.abs)
      when "floor_div"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, a // d)
      when "floor_div_primitive"
        a, p = source.operand, primitive_divisor(source)
        check({a, p}, a // p)
      when "floor_mod"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, a % d)
      when "floor_mod_primitive"
        a, p = source.operand, primitive_divisor(source)
        # BigInt#%(Int) with a negative primitive returns -(a mod |p|)
        # (upstream: `BigInt.new(-5) % -3` is -1, `-5 % -3` is -2); GMP's
        # fdiv_r on the same value is the oracle, through a BigInt divisor.
        check({a, p}, a % BigInt.new(p), a % p)
      when "divmod"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, a.divmod(d))
      when "divmod_primitive"
        a, p = source.operand, primitive_divisor(source)
        check({a, p}, a.divmod(p))
      when "tdiv"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, a.tdiv(d))
      when "tdiv_primitive"
        a, p = source.operand, primitive_divisor(source)
        check({a, p}, a.tdiv(p))
      when "remainder"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, a.remainder(d))
      when "remainder_primitive"
        a, p = source.operand, primitive_divisor(source)
        check({a, p}, a.remainder(p))
      when "tdivmod"
        a = source.operand
        d = divisor(a, source)
        check({a, d}, {a.tdiv(d), a.remainder(d)}, a.tdivmod(d))
      when "tdivmod_primitive"
        a, p = source.operand, primitive_divisor(source)
        check({a, p}, {a.tdiv(p), a.remainder(p)}, a.tdivmod(p))
      when "unsafe_floored_div"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? a // d : a.unsafe_floored_div(d), a.unsafe_floored_div(d))
      when "unsafe_floored_div_primitive"
        a, d = source.operand, primitive_divisor(source)
        check({a, d}, d.zero? ? a // d : a.unsafe_floored_div(d), a.unsafe_floored_div(d))
      when "unsafe_floored_mod"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? a % d : a.unsafe_floored_mod(d), a.unsafe_floored_mod(d))
      when "unsafe_floored_mod_primitive"
        a, d = source.operand, primitive_divisor(source)
        # BigInt#unsafe_floored_mod(Int) with a negative primitive returns -(a mod |p|)
        # (upstream: `BigInt.new(-5) % -3` is -1, `-5 % -3` is -2); GMP's
        # fdiv_r on the same value is the oracle, through a BigInt divisor.
        check({a, d}, d.zero? ? a % d : a.unsafe_floored_mod(BigInt.new(d)), a.unsafe_floored_mod(d))
      when "unsafe_floored_divmod"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? a.divmod(d) : a.unsafe_floored_divmod(d), a.unsafe_floored_divmod(d))
      when "unsafe_floored_divmod_primitive"
        a, d = source.operand, primitive_divisor(source)
        check({a, d}, d.zero? ? a.divmod(d) : a.unsafe_floored_divmod(d), a.unsafe_floored_divmod(d))
      when "unsafe_truncated_div"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? a.tdiv(d) : a.unsafe_truncated_div(d), a.unsafe_truncated_div(d))
      when "unsafe_truncated_div_primitive"
        a, d = source.operand, primitive_divisor(source)
        check({a, d}, d.zero? ? a.tdiv(d) : a.unsafe_truncated_div(d), a.unsafe_truncated_div(d))
      when "unsafe_truncated_mod"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? a.remainder(d) : a.unsafe_truncated_mod(d), a.unsafe_truncated_mod(d))
      when "unsafe_truncated_mod_primitive"
        a, d = source.operand, primitive_divisor(source)
        check({a, d}, d.zero? ? a.remainder(d) : a.unsafe_truncated_mod(d), a.unsafe_truncated_mod(d))
      when "unsafe_truncated_divmod"
        # GMP's unsafe_* takes a zero divisor to a hardware fault; the
        # oracle answers a zero divisor with the raising variant instead.
        a = source.operand
        d = divisor(a, source)
        check({a, d}, d.zero? ? {a.tdiv(d), a.remainder(d)} : a.unsafe_truncated_divmod(d), a.unsafe_truncated_divmod(d))
      when "unsafe_truncated_divmod_primitive"
        a, d = source.operand, primitive_divisor(source)
        check({a, d}, d.zero? ? {a.tdiv(d), a.remainder(d)} : a.unsafe_truncated_divmod(d), a.unsafe_truncated_divmod(d))
      when "divexact"
        a = source.operand
        d = nonzero(divisor(a, source), source)
        a = operand_from(oracle_value(a).tdiv(oracle_value(d)) * oracle_value(d))
        check({a, d}, GMPOracle.divexact(a, d), if_defined(a, :divexact, a.divexact(d)))
      when "divisible_by"
        a = source.operand
        d = nonzero(divisor(a, source), source)
        if source.chance(0.3) # make it divisible
          a = operand_from(oracle_value(a) * oracle_value(d))
        end
        check({a, d}, a.divisible_by?(d))
      when "divisible_by_primitive"
        a, p = source.operand, source.primitive
        p = 7 if p == 0
        if source.chance(0.3)
          a = operand_from(oracle_value(a) * p)
        end
        check({a, p}, a.divisible_by?(p))
      when "remove"
        factor = source.chance(0.7) ? BigInt.new(source.sample(SMALL_FACTORS)) : oracle_value(source.random_of(2 + source.rand(190), false))
        factor = -factor if source.chance(0.2)
        multiplied = oracle_value(source.operand) * factor ** source.rand(0..40)
        a = operand_from(multiplied)
        f = operand_from(factor)
        check({a, f}, GMPOracle.remove(a, f), if_defined(a, :remove, a.remove(f)))
      when "pow"
        a = source.operand(source.chance(0.5) ? source.rand(0..130) : source.rand(0..2_048))
        limit = Math.max(1, 65_536 // Math.max(1, a.bits))
        e = source.chance(0.01) ? -1 : source.rand(0..Math.min(limit, 200))
        check({a, e}, a ** e)
      when "factorial"
        n = source.chance(0.9) ? source.rand(0..300) : source.rand(0..5_000)
        check({n}, GMPOracle.factorial(n.to_u64), if_defined(T, :factorial, T.factorial(n)))
      when "isqrt"
        a = source.operand.abs
        check({a}, Math.isqrt(a), if_defined(a, :isqrt, a.isqrt))
      when "and"
        a, c = source.operand, source.operand
        check({a, c}, a & c)
      when "or"
        a, c = source.operand, source.operand
        check({a, c}, a | c)
      when "xor"
        a, c = source.operand, source.operand
        check({a, c}, a ^ c)
      when "and_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a & p)
      when "or_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a | p)
      when "xor_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a ^ p)
      when "complement"
        a = source.operand
        check({a}, ~a)
      when "shift_left"
        a = source.operand
        n = source.chance(0.3) ? 64 * source.rand(0..8) + source.rand(-1..1) : source.rand(0..600)
        n = 0 if n < 0
        check({a, n}, a << n)
      when "shift_right"
        a = source.operand
        n = source.chance(0.3) ? 64 * source.rand(0..8) + source.rand(-1..1) : source.rand(0..(a.bits + 130))
        n = 0 if n < 0
        check({a, n}, a >> n)
      when "bit"
        a = source.operand
        i = source.rand(0..(a.bits + 130))
        check({a, i}, a.bit(i))
      when "popcount"
        a = source.operand
        check({a}, a.popcount)
      when "trailing_zeros_count"
        a = source.operand
        check({a}, a.trailing_zeros_count)
      when "bit_length"
        a = source.operand
        check({a}, a.bit_length)
      when "gcd"
        a, c = source.operand, source.operand
        if source.chance(0.4) # a shared factor
          shared = oracle_value(source.operand(source.rand(1..1_024)))
          a = operand_from(oracle_value(a) * shared)
          c = operand_from(oracle_value(c) * shared)
        end
        check({a, c}, a.gcd(c))
      when "gcd_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a.gcd(p).to_big_i, a.gcd(p))
      when "lcm"
        a, c = source.operand, source.operand
        check({a, c}, a.lcm(c))
      when "lcm_primitive"
        a, p = source.operand, source.primitive
        check({a, p}, a.lcm(p))
      when "invert"
        a = source.operand
        m = nonzero(source.chance(0.5) ? source.divisor_for(a) : source.operand, source)
        check({a, m}, GMPOracle.invert(a, m), if_defined(a, :invert, a.invert(m)))
      when "pow_mod"
        a = source.operand(source.rand(0..2_048))
        e = source.operand(source.chance(0.8) ? source.rand(0..256) : source.rand(0..2_048)).abs
        m = nonzero(source.operand(source.rand(1..2_048)), source)
        check({a, e, m}, GMPOracle.pow_mod(a, e, m), if_defined(a, :pow_mod, a.pow_mod(e, m)))
      when "to_i64_checked"
        a = source.chance(0.5) ? source.random_of(source.rand(0..66), source.sign) : source.operand
        check({a}, checked_i64(a), if_defined(a, :to_i64?, a.to_i64?))
      when "to_u64_checked"
        a = source.chance(0.5) ? source.random_of(source.rand(0..66), source.sign) : source.operand
        check({a}, checked_u64(a), if_defined(a, :to_u64?, a.to_u64?))
      when "to_i128_checked"
        a = source.chance(0.5) ? source.random_of(source.rand(0..130), source.sign) : source.operand
        check({a}, checked_i128(a), if_defined(a, :to_i128?, a.to_i128?))
      when "to_i128_wrapping"
        a = source.operand
        check({a}, a.to_i128!, if_defined(a, :to_i128!, a.to_i128!))
      when "to_i64_wrapping"
        a = source.operand
        check({a}, a.to_i64!, if_defined(a, :to_i64!, a.to_i64!))
      when "to_u128_checked"
        a = source.chance(0.5) ? source.random_of(source.rand(0..130), source.sign) : source.operand
        check({a}, checked_u128(a), if_defined(a, :to_u128?, a.to_u128?))
      when "to_u128_wrapping"
        a = source.operand
        check({a}, a.to_u128!, if_defined(a, :to_u128!, a.to_u128!))
      when "to_u64_wrapping"
        a = source.operand
        check({a}, a.to_u64!, if_defined(a, :to_u64!, a.to_u64!))
      when "to_f64"
        a = source.operand
        check({a}, a.to_f64)
      else
        raise ArgumentError.new("Unknown operation #{operation}")
      end
    end
  end
end
