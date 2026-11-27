# Differential of `Crystal::BigNum::Float` against GMP's `mpf` (BIGNUM.md
# 5.2, relay piece G3a). Built with `-Duse_gmp`, so GMP's `mpf` functions and
# the engine sit in one binary; each operation runs on both from the same
# operands and the results are compared at the representation level
# (mantissa limbs, signed size, limb exponent, precision), with digit strings
# compared byte for byte and comparisons, doubles and integers compared
# exactly.
#
#   CRYSTAL_PATH=lib:$PWD/src crystal build --release -Duse_gmp \
#     scripts/big_num/float_differential.cr -o float_differential
#   ./float_differential --seed 1 --count 1000000 [--start 0] [--ops add,sub]
#
# Operation *index* of a run draws everything from `Random::PCG32.new(seed,
# index)`, so `--seed S --start I --count 1` replays one operation. A
# difference prints that reproducer line with both results.
require "big"
require "crystal/big_num"
require "./harness/operand_source"

{% unless flag?(:use_gmp) %}
  {% raise "The float differential compares against GMP: build it with -Duse_gmp" %}
{% end %}

lib LibGMPFloatHarness
  fun mpz_set_f = __gmpz_set_f(rop : LibGMP::MPZ*, op : LibGMP::MPF*)
  fun mpf_set_str = __gmpf_set_str(rop : LibGMP::MPF*, str : UInt8*, base : LibC::Int) : LibC::Int
end

module FloatDifferential
  alias Engine = Crystal::BigNum::Float
  alias EngineInteger = Crystal::BigNum::Integer

  # A float drawn for both sides: GMP's struct and the engine's value hold
  # the same limbs, size, exponent and precision.
  record Pair, gmp : LibGMP::MPF, engine : Engine

  OPERATIONS = %w(
    set neg abs add sub add_ui sub_ui mul mul_ui div div_ui ui_div sqrt pow_ui
    mul_2exp div_2exp floor ceil trunc set_d set_si set_ui set_z set_q set_str
    get_str get_d get_si get_ui cmp cmp_d cmp_si cmp_ui cmp_z integer_p
    to_integer exact_binary
  )

  # Precision in bits: 64 two times in five, else log-uniform 1 to 4,096.
  def self.precision_bits(source : G2Harness::OperandSource) : UInt64
    return 64_u64 if source.chance(0.4)
    (Math.exp(source.rand(1_000_000) / 1_000_000.0 * Math.log(4096.0)).to_i.clamp(1, 4096)).to_u64
  end

  # GMP's struct with *limb_precision* (allocated for one limb more).
  def self.gmp_init(limb_precision : Int32) : LibGMP::MPF
    LibGMP.mpf_init2(out mpf, Engine.bit_precision(limb_precision))
    raise "mpf_init2 precision #{mpf._mp_prec} != #{limb_precision}" unless mpf._mp_prec == limb_precision
    mpf
  end

  # A random float: mantissa limbs per the operand source (up to 8,192 bits,
  # edge shapes, both signs, zero limbs at either end), an exponent near the
  # limb point, far from it, or very far, and an operand precision that
  # holds the limbs.
  def self.random_pair(source : G2Harness::OperandSource) : Pair
    operand = source.operand
    limbs = operand.limbs
    count = limbs.size
    while count > 0 && limbs[count - 1] == 0
      count -= 1
    end
    limbs = limbs[0, count]
    limb_precision = Math.max(count - source.rand(2), 2)
    limb_precision = Math.max(limb_precision, Engine.limb_precision(precision_bits(source))) if source.chance(0.5)
    exponent = case source.rand(10)
               when 0 then source.rand(-3_000_000..3_000_000).to_i64
               when 1 then (source.rand(-1_000_000..1_000_000).to_i64 << 20)
               else        (count + source.rand(-8..8)).to_i64
               end
    exponent = 0_i64 if count == 0
    negative = operand.negative && count > 0
    gmp = gmp_init(limb_precision)
    gmp._mp_d.copy_from(limbs.to_unsafe, count) if count > 0
    gmp._mp_size = negative ? -count : count
    gmp._mp_exp = exponent
    Pair.new(gmp, Engine.from_parts(limbs, negative, exponent, limb_precision))
  end

  def self.gmp_integer(operand : G2Harness::Operand) : LibGMP::MPZ
    count = operand.limbs.size
    while count > 0 && operand.limbs[count - 1] == 0
      count -= 1
    end
    LibGMP.init2(out mpz, (count + 1) * 64)
    if count > 0
      target = LibGMP.limbs_write(pointerof(mpz), count)
      target.copy_from(operand.limbs.to_unsafe, count)
    end
    LibGMP.limbs_finish(pointerof(mpz), operand.negative ? -count : count)
    mpz
  end

  def self.engine_integer(operand : G2Harness::Operand) : EngineInteger
    EngineInteger.from_limbs(operand.limbs, operand.negative)
  end

  def self.integer_from_mpz(mpz : LibGMP::MPZ) : EngineInteger
    size = mpz._mp_size
    EngineInteger.from_limbs(Slice.new(mpz._mp_d, size.abs, read_only: true), size < 0)
  end

  def self.describe(mpf : LibGMP::MPF) : String
    count = mpf._mp_size.abs
    limbs = (0...count).map { |index| mpf._mp_d[index] }
    describe_parts(mpf._mp_size, mpf._mp_exp.to_i64, mpf._mp_prec, limbs)
  end

  def self.describe(value : Engine) : String
    describe_parts(value.signed_size, value.exponent, value.precision, value.limbs.to_a)
  end

  def self.describe_parts(size, exponent, precision, limbs : Array(UInt64)) : String
    "{size=#{size} exp=#{exponent} prec=#{precision} limbs=#{limbs.reverse.map(&.to_s(16)).join(':')}}"
  end

  def self.same?(mpf : LibGMP::MPF, value : Engine) : Bool
    return false unless mpf._mp_size == value.signed_size && mpf._mp_prec == value.precision
    return true if value.zero? && mpf._mp_exp == 0 && value.exponent == 0
    return false unless mpf._mp_exp == value.exponent
    value.limbs.each_with_index { |limb, index| return false unless mpf._mp_d[index] == limb }
    true
  end

  # A decimal string for `mpf_set_str`: the digits of a random float, random
  # decimal text, or text with whitespace, signs, exponents and junk.
  def self.random_string(source : G2Harness::OperandSource) : String
    case source.rand(6)
    when 0
      pair = random_pair(source)
      mpf = pair.gmp
      digits = String.new(LibGMP.mpf_get_str(nil, out exponent, 10, 0, pointerof(mpf)))
      negative = digits.starts_with?('-')
      digits = digits.lchop('-')
      digits = "0" if digits.empty?
      "#{negative ? "-" : ""}0.#{digits}e#{exponent}"
    when 1, 2
      String.build do |io|
        io << ' ' if source.chance(0.1)
        io << '-' if source.chance(0.4)
        integral = source.rand(0..60)
        fraction = source.rand(0..60)
        io << "0" * source.rand(0..3) if source.chance(0.2)
        integral.times { io << source.rand(10) }
        if fraction > 0 || integral == 0
          io << '.'
          io << "0" * source.rand(0..20) if source.chance(0.3)
          Math.max(fraction, integral == 0 ? 1 : 0).times { io << source.rand(10) }
        end
        if source.chance(0.6)
          io << source.sample(['e', 'E'])
          io << source.sample(["", "+", "-"])
          io << (source.chance(0.2) ? source.rand(0..9999) : source.rand(0..400))
        end
      end
    when 3
      operand = source.operand(source.rand(0..3000))
      String.build do |io|
        io << '-' if operand.negative
        text = EngineInteger.from_limbs(operand.limbs, false).to_s
        point = source.rand(0..text.size)
        io << text[0, point]
        io << '.' << text[point..] if source.chance(0.7)
        io << 'e' << source.rand(-5000..5000) if source.chance(0.5)
      end
    when 4
      alphabet = ['0', '1', '9', '.', 'e', 'E', '-', '+', ' ', '\t', 'x', '@', '5']
      String.build { |io| source.rand(0..12).times { io << source.sample(alphabet) } }
    else
      String.build do |io|
        io << source.sample(["", " ", "  \n", "-", "- "])
        io << source.rand(0..999_999)
        io << source.sample(["", ".", ".5", ".000", " 5", "_5"])
        io << source.sample(["", "e", "e5", "e-5", "E+12", "e5x", "e 5", "e99999999999999999999", "e-12345678901234"])
        io << source.sample(["", " ", "x"])
      end
    end
  end

  def self.random_double(source : G2Harness::OperandSource) : Float64
    loop do
      value = source.float
      return value if value.finite?
    end
  end

  # Runs operation *name*; returns nil when both sides agree, else a
  # description of the difference.
  def self.run(name : String, source : G2Harness::OperandSource) : String?
    bits = precision_bits(source)
    precision = Engine.limb_precision(bits)
    result = gmp_init(precision)
    rp = pointerof(result)
    case name
    when "set", "neg", "abs", "floor", "ceil", "trunc", "sqrt"
      pair = random_pair(source)
      up = pair.gmp
      engine = pair.engine
      if name == "sqrt" && engine.negative?
        up._mp_size = -up._mp_size
        engine = engine.negate
      end
      case name
      when "set"   then LibGMP.mpf_set(rp, pointerof(up)); ours = engine.set(precision)
      when "neg"   then LibGMP.mpf_neg(rp, pointerof(up)); ours = engine.neg(precision)
      when "abs"   then LibGMP.mpf_abs(rp, pointerof(up)); ours = engine.abs(precision)
      when "floor" then LibGMP.mpf_floor(rp, pointerof(up)); ours = engine.floor(precision)
      when "ceil"  then LibGMP.mpf_ceil(rp, pointerof(up)); ours = engine.ceil(precision)
      when "trunc" then LibGMP.mpf_trunc(rp, pointerof(up)); ours = engine.trunc(precision)
      else              LibGMP.mpf_sqrt(rp, pointerof(up)); ours = engine.sqrt(precision)
      end
      check(result, ours, [describe(up)])
    when "add", "sub", "mul", "div"
      if source.chance(0.25)
        left, right = cancelling_pair(source)
      else
        left = random_pair(source)
        right = source.chance(0.3) ? near(left, source) : random_pair(source)
      end
      return nil if name == "div" && right.engine.zero?
      up = left.gmp
      vp = right.gmp
      case name
      when "add" then LibGMP.mpf_add(rp, pointerof(up), pointerof(vp)); ours = left.engine.add(right.engine, precision)
      when "sub" then LibGMP.mpf_sub(rp, pointerof(up), pointerof(vp)); ours = left.engine.sub(right.engine, precision)
      when "mul" then LibGMP.mpf_mul(rp, pointerof(up), pointerof(vp)); ours = left.engine.mul(right.engine, precision)
      else            LibGMP.mpf_div(rp, pointerof(up), pointerof(vp)); ours = left.engine.div(right.engine, precision)
      end
      check(result, ours, [describe(up), describe(vp)])
    when "add_ui", "sub_ui", "mul_ui", "div_ui", "ui_div", "pow_ui"
      pair = random_pair(source)
      up = pair.gmp
      value = source.primitive.to_u64!
      value = source.rand(0..40).to_u64 if source.chance(0.3)
      case name
      when "add_ui" then LibGMP.mpf_add_ui(rp, pointerof(up), value); ours = pair.engine.add_ui(value, precision)
      when "sub_ui" then LibGMP.mpf_sub_ui(rp, pointerof(up), value); ours = pair.engine.sub_ui(value, precision)
      when "mul_ui" then LibGMP.mpf_mul_ui(rp, pointerof(up), value); ours = pair.engine.mul_ui(value, precision)
      when "div_ui"
        value = 1_u64 if value == 0
        LibGMP.mpf_div_ui(rp, pointerof(up), value); ours = pair.engine.div_ui(value, precision)
      when "ui_div"
        return nil if pair.engine.zero?
        LibGMP.mpf_ui_div(rp, value, pointerof(up)); ours = Engine.ui_div(value, pair.engine, precision)
      else
        value = source.chance(0.8) ? source.rand(0..300).to_u64 : source.rand(0..2_000_000).to_u64
        return nil if value > 300 && precision > 20
        LibGMP.mpf_pow_ui(rp, pointerof(up), value); ours = pair.engine.pow_ui(value, precision)
      end
      check(result, ours, [describe(up), value.to_s])
    when "mul_2exp", "div_2exp"
      pair = random_pair(source)
      up = pair.gmp
      count = source.chance(0.7) ? source.rand(0..300).to_u64 : source.rand(Int32::MAX).to_u64 &* source.rand(0..4096).to_u64
      if name == "mul_2exp"
        LibGMP.mpf_mul_2exp(rp, pointerof(up), count); ours = pair.engine.mul_2exp(count, precision)
      else
        LibGMP.mpf_div_2exp(rp, pointerof(up), count); ours = pair.engine.div_2exp(count, precision)
      end
      check(result, ours, [describe(up), count.to_s])
    when "set_d"
      value = random_double(source)
      LibGMP.mpf_set_d(rp, value)
      check(result, Engine.from_f64(value, precision), [value.unsafe_as(UInt64).to_s(16)])
    when "set_si"
      value = source.primitive.to_i64!
      LibGMP.mpf_init_set_si(rp, value)
      result._mp_prec == Engine.default_limb_precision || return "set_si default precision"
      check(result, Engine.from_i64(value, Engine.default_limb_precision), [value.to_s])
    when "set_ui"
      value = source.primitive.to_u64!
      LibGMP.mpf_init_set_ui(rp, value)
      check(result, Engine.from_u64(value, Engine.default_limb_precision), [value.to_s])
    when "set_z"
      operand = source.operand
      mpz = gmp_integer(operand)
      LibGMP.mpf_set_z(rp, pointerof(mpz))
      check(result, Engine.from_integer(engine_integer(operand), precision), [operand.inspect])
    when "set_q"
      numerator = source.operand
      denominator = source.chance(0.3) ? source.divisor_for(numerator) : source.operand
      return nil if denominator.zero?
      rational = BigRational.new(BigInt.new(gmp_integer(numerator)), BigInt.new(gmp_integer(denominator)))
      LibGMP.mpf_set_q(rp, rational.to_unsafe)
      mpq = rational.to_unsafe.value
      ours = Engine.from_rational(integer_from_mpz(mpq._mp_num), integer_from_mpz(mpq._mp_den), precision)
      check(result, ours, [rational.to_s])
    when "set_str"
      text = random_string(source)
      status = LibGMPFloatHarness.mpf_set_str(rp, text, 10)
      ours = begin
        Engine.parse?(text, precision)
      rescue error
        return "set_str of #{text.inspect} raised #{error.message}"
      end
      if status == -1 || ours.nil?
        return status == -1 && ours.nil? ? nil : "set_str validity: gmp #{status}, ours #{ours.inspect} for #{text.inspect}"
      end
      check(result, ours, [text.inspect])
    when "get_str"
      pair = random_pair(source)
      up = pair.gmp
      theirs = String.new(LibGMP.mpf_get_str(nil, out exponent, 10, 0, pointerof(up)))
      digits, ours_exponent = begin
        pair.engine.to_digits
      rescue error
        return "get_str of #{describe(up)} raised #{error.message}"
      end
      return nil if theirs == digits && exponent == ours_exponent
      "get_str of #{describe(up)}: gmp #{theirs}e#{exponent}, ours #{digits}e#{ours_exponent}"
    when "get_d", "get_si", "get_ui", "integer_p", "to_integer", "exact_binary"
      pair = random_pair(source)
      up = pair.gmp
      case name
      when "get_d"
        theirs = LibGMP.mpf_get_d(pointerof(up)).unsafe_as(UInt64)
        ours = pair.engine.to_f64.unsafe_as(UInt64)
      when "get_si"
        theirs = LibGMP.mpf_get_si(pointerof(up)).to_i64
        ours = pair.engine.get_si
      when "get_ui"
        theirs = LibGMP.mpf_get_ui(pointerof(up)).to_u64
        ours = pair.engine.get_ui
      when "integer_p"
        theirs = LibGMP.mpf_integer_p(pointerof(up)) != 0
        ours = pair.engine.integer?
      when "to_integer"
        return nil if pair.engine.exponent > 4096
        LibGMP.init(out truncated)
        LibGMPFloatHarness.mpz_set_f(pointerof(truncated), pointerof(up))
        theirs = integer_from_mpz(truncated).to_s(16)
        ours = pair.engine.to_integer.to_s(16)
      else
        return nil if pair.engine.exponent.abs > 4096
        LibGMP.mpq_init(out exact)
        LibGMP.mpq_set_f(pointerof(exact), pointerof(up))
        theirs = "#{integer_from_mpz(exact._mp_num).to_s(16)}/#{integer_from_mpz(exact._mp_den).to_s(16)}"
        mantissa, exponent = pair.engine.exact_binary
        if exponent >= 0
          ours = "#{(mantissa << exponent).to_s(16)}/1"
        else
          ours = "#{mantissa.to_s(16)}/#{(EngineInteger.new(1) << -exponent).to_s(16)}"
        end
      end
      theirs == ours ? nil : "#{name} of #{describe(up)}: gmp #{theirs}, ours #{ours}"
    when "cmp", "cmp_d", "cmp_si", "cmp_ui", "cmp_z"
      left = random_pair(source)
      up = left.gmp
      case name
      when "cmp"
        right = source.chance(0.4) ? near(left, source) : random_pair(source)
        vp = right.gmp
        theirs = LibGMP.mpf_cmp(pointerof(up), pointerof(vp))
        ours = left.engine <=> right.engine
        operand = describe(vp)
      when "cmp_d"
        value = source.float
        return nil if value.nan?
        theirs = LibGMP.mpf_cmp_d(pointerof(up), value)
        ours = left.engine.cmp_d(value)
        operand = value.unsafe_as(UInt64).to_s(16)
      when "cmp_si"
        value = source.primitive.to_i64!
        theirs = LibGMP.mpf_cmp_si(pointerof(up), value)
        ours = left.engine.cmp_si(value)
        operand = value.to_s
      when "cmp_ui"
        value = source.primitive.to_u64!
        theirs = LibGMP.mpf_cmp_ui(pointerof(up), value)
        ours = left.engine.cmp_ui(value)
        operand = value.to_s
      else
        integer = source.chance(0.5) && left.engine.exponent <= 4096 ? left.engine.to_integer : engine_integer(source.operand)
        compared = gmp_integer(G2Harness::Operand.new(integer.limbs, integer.negative?))
        theirs = LibGMP.mpf_cmp_z(pointerof(up), pointerof(compared))
        ours = left.engine.cmp_z(integer)
        operand = integer.to_s(16)
      end
      theirs == ours ? nil : "#{name} of #{describe(up)} and #{operand}: gmp #{theirs}, ours #{ours}"
    else
      raise "unknown operation #{name}"
    end
  end

  # A float close to *pair*: the same value, or one or two limbs changed,
  # or the exponent moved by one, so subtraction cancels.
  def self.near(pair : Pair, source : G2Harness::OperandSource) : Pair
    limbs = pair.engine.limbs.to_a
    return random_pair(source) if limbs.empty?
    exponent = pair.engine.exponent
    case source.rand(5)
    when 0 # same
    when 1
      index = source.rand(limbs.size)
      limbs[index] = source.sample([0_u64, 1_u64, UInt64::MAX, limbs[index] &+ 1, limbs[index] &- 1, source.random_of(64, false).limbs[0]])
    when 2 # 1 00000 over 0 fffff
      limbs = limbs.map { UInt64::MAX }
      limbs << 0_u64 if source.chance(0.5)
      exponent -= 1 if source.chance(0.5)
    when 3
      limbs.pop if limbs.size > 1
    else
      limbs.unshift(source.sample([0_u64, source.random_of(64, false).limbs[0]]))
    end
    while !limbs.empty? && limbs.last == 0
      limbs.pop
    end
    negative = source.chance(0.8) ? pair.engine.negative? : !pair.engine.negative?
    limb_precision = Math.max(limbs.size - 1, 2)
    gmp = gmp_init(limb_precision)
    gmp._mp_d.copy_from(limbs.to_unsafe, limbs.size) unless limbs.empty?
    gmp._mp_size = negative ? -limbs.size : limbs.size
    gmp._mp_exp = limbs.empty? ? 0_i64 : exponent
    Pair.new(gmp, Engine.from_parts(Slice.new(limbs.to_unsafe, limbs.size), negative, gmp._mp_exp.to_i64, limb_precision))
  end

  # Two floats of one sign whose difference cancels many leading limbs:
  # x+1 00000000 ... over x ffffffff ... at one exponent, or 1 00000000 ...
  # over ffffffff ... one limb lower, with random tails of random lengths.
  def self.cancelling_pair(source : G2Harness::OperandSource) : {Pair, Pair}
    run = source.rand(0..70)
    top = source.chance(0.5) ? 0_u64 : source.random_of(64, false).limbs[0] >> 1
    one_lower = top == 0 && source.chance(0.5)
    upper = [] of UInt64
    lower = [] of UInt64
    source.rand(0..40).times { upper << tail_limb(source) }
    source.rand(0..40).times { lower << tail_limb(source) }
    run.times { upper << 0_u64; lower << UInt64::MAX }
    if one_lower
      upper << 1_u64
    else
      upper << top + 1
      lower << top if top != 0 || source.chance(0.5)
    end
    exponent = source.rand(-5..5).to_i64
    negative = source.sign
    upper_exponent = one_lower || lower.last? != top || top != 0 ? exponent : exponent
    left = pair_of(upper, negative, upper_exponent, source)
    right = pair_of(lower, negative, one_lower ? exponent - 1 : exponent, source)
    source.chance(0.5) ? {left, right} : {right, left}
  end

  def self.tail_limb(source : G2Harness::OperandSource) : UInt64
    source.sample([0_u64, 1_u64, UInt64::MAX, source.random_of(64, false).limbs[0]])
  end

  def self.pair_of(limbs : Array(UInt64), negative : Bool, exponent : Int64, source : G2Harness::OperandSource) : Pair
    while !limbs.empty? && limbs.last == 0
      limbs.pop
    end
    limb_precision = Math.max(limbs.size - source.rand(2), 2)
    gmp = gmp_init(limb_precision)
    gmp._mp_d.copy_from(limbs.to_unsafe, limbs.size) unless limbs.empty?
    gmp._mp_size = negative ? -limbs.size : limbs.size
    gmp._mp_exp = limbs.empty? ? 0_i64 : exponent
    Pair.new(gmp, Engine.from_parts(Slice.new(limbs.to_unsafe, limbs.size), negative, gmp._mp_exp.to_i64, limb_precision))
  end

  def self.check(result : LibGMP::MPF, ours : Engine, operands : Array(String)) : String?
    return nil if same?(result, ours)
    "operands #{operands.join(", ")}: gmp #{describe(result)}, ours #{describe(ours)}"
  end

  def self.main(arguments : Array(String)) : Int32
    seed = 1_u64
    count = 1_000_000_i64
    start = 0_i64
    names = OPERATIONS
    max_shown = 20
    trace = ENV["FLOAT_DIFFERENTIAL_TRACE"]? == "1"
    arguments.each_slice(2) do |(flag, value)|
      case flag
      when "--seed"  then seed = value.to_u64
      when "--count" then count = value.to_i64
      when "--start" then start = value.to_i64
      when "--ops"   then names = value.split(',')
      when "--show"  then max_shown = value.to_i
      else                abort "unknown flag #{flag}"
      end
    end
    # 64 bits is GMP's own default; keep both defaults equal.
    LibGMP.mpf_set_default_prec(64)
    Engine.default_precision = 64
    counts = Hash(String, Int64).new(0_i64)
    differences = Hash(String, Int64).new(0_i64)
    shown = 0
    started = Time.instant
    start.upto(start + count - 1) do |index|
      random = Random::PCG32.new(seed, index.to_u64)
      source = G2Harness::OperandSource.new(random)
      name = names[random.rand(names.size)]
      counts[name] += 1
      STDERR.puts "#{index} #{name}" if trace
      message = begin
        run(name, source)
      rescue error
        "raised #{error.class}: #{error.message} #{error.backtrace?.try(&.first(6).join(" | "))}"
      end
      if message
        differences[name] += 1
        if shown < max_shown
          shown += 1
          STDOUT.puts "DIFF --seed #{seed} --start #{index} --count 1 #{name}: #{message[0, 2000]}"
        end
      end
    end
    elapsed = Time.instant - started
    STDOUT.puts "gmp #{String.new(LibGMPHarnessVersion.gmp_version)}, seed #{seed}, start #{start}, operations #{count}, seconds #{elapsed.total_seconds.round(1)}"
    names.sort.each do |name|
      STDOUT.puts "#{name.ljust(14)} #{counts[name].to_s.rjust(9)} differences #{differences[name]}"
    end
    total = differences.values.sum
    STDOUT.puts "TOTAL operations #{counts.values.sum} differences #{total}"
    total == 0 ? 0 : 1
  end
end

lib LibGMPHarnessVersion
  $gmp_version = __gmp_version : UInt8*
end

exit FloatDifferential.main(ARGV)
