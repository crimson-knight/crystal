# Wrapper-level differential: the public `BigInt` API in the default (pure)
# build against the same program built with `-Duse_gmp`.
#
# Build both from the fork's root and compare their output:
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release scripts/big_num/wrapper_differential.cr -o bin/wrapper_pure
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release -Duse_gmp scripts/big_num/wrapper_differential.cr -o bin/wrapper_gmp
#   bin/wrapper_pure --seed 1 --count 1000000 > pure.txt
#   bin/wrapper_gmp --seed 1 --count 1000000 > gmp.txt
#   cmp pure.txt gmp.txt
# Each output line is `<index> <operation> <FNV-1a 64 of the printed result>`;
# `--show 17,42` prints the full results of those indices instead. A result
# is printed with its type, so a different return type is a difference too;
# a raised exception prints its class and message.
#
# Operands come from the harness's `OperandSource` (limbs and a sign, which
# need no BigInt), so both builds see the same values. Zero divisors go only
# to the checked methods: the `unsafe_*` methods with a zero divisor are the
# one intended difference (DivisionByZeroError here, a crash in GMP).
require "big"
require "option_parser"
require "./harness/operand_source"

module G2Harness
  class WrapperDifferential
    alias Primitive = Int8 | Int16 | Int32 | Int64 | Int128 | UInt8 | UInt16 | UInt32 | UInt64 | UInt128

    LIST_OF_OPERATIONS = %w(
      add add_primitive sub sub_primitive negate abs mul mul_primitive
      floor_div floor_div_primitive tdiv tdiv_primitive mod mod_primitive
      remainder remainder_primitive divmod divmod_primitive
      unsafe_floored_div unsafe_floored_div_primitive unsafe_truncated_div unsafe_truncated_div_primitive
      unsafe_floored_mod unsafe_floored_mod_primitive unsafe_truncated_mod unsafe_truncated_mod_primitive
      unsafe_floored_divmod unsafe_floored_divmod_primitive unsafe_truncated_divmod unsafe_truncated_divmod_primitive
      divisible_by divisible_by_primitive factor_by complement bit
      and and_primitive or or_primitive xor xor_primitive shift_right shift_left unsafe_shr pow
      gcd gcd_primitive lcm lcm_primitive bit_length to_s to_s_io digits popcount trailing_zeros_count
      next_power_of_two to_primitive_checked to_primitive_wrapping to_float
      compare compare_primitive compare_float equal_primitive
      primitive_compare primitive_arithmetic primitive_gcd_lcm float_compare
      parse parse_garbage new_float from_digits factorial isqrt sqrt pw2ceil divide_float
      to_big_f to_big_r to_big_d hasher_reduce sign_parity succ_pred random_below random_range
      rational_new decimal_new
    )

    @seed : UInt64 = 1
    @count : Int64 = 10_000
    @first_index : Int64 = 0
    @max_bits : Int32 = 8_192
    @list_of_shown : Array(Int64)? = nil

    def initialize(arguments : Array(String))
      OptionParser.parse(arguments) do |parser|
        parser.banner = "usage: wrapper_differential [options]"
        parser.on("--seed N", "PCG32 seed (default 1)") { |value| @seed = value.to_u64 }
        parser.on("--count N", "operations to run (default 10000)") { |value| @count = value.to_i64 }
        parser.on("--first-index N", "first operation index (default 0)") { |value| @first_index = value.to_i64 }
        parser.on("--max-bits N", "largest operand size in bits (default 8192)") { |value| @max_bits = value.to_i }
        parser.on("--show LIST", "print the full results of these indices") { |value| @list_of_shown = value.split(',').map(&.to_i64) }
        parser.on("--list", "print the operation names and exit") do
          STDOUT.puts LIST_OF_OPERATIONS.join('\n')
          exit
        end
      end
    end

    def perform : Nil
      output = STDOUT
      shown = @list_of_shown
      last = @first_index + @count
      index = @first_index
      while index < last
        if shown.nil? || shown.includes?(index)
          random = Random::PCG32.new(@seed, index.to_u64)
          source = OperandSource.new(random, @max_bits)
          name = LIST_OF_OPERATIONS[random.rand(LIST_OF_OPERATIONS.size)]
          text = begin
            run(name, source, random)
          rescue error : Exception
            "raise #{error.class}: #{error.message}"
          end
          if shown
            output << index << ' ' << name << ' ' << text << '\n'
          else
            output << index << ' ' << name << ' ' << fnv(text).to_s(16) << '\n'
          end
        end
        index += 1
      end
      output.flush
    end

    private def fnv(text : String) : UInt64
      hash = 0xcbf29ce484222325_u64
      text.each_byte do |byte|
        hash ^= byte
        hash &*= 0x100000001b3_u64
      end
      hash
    end

    # A BigInt from an operand, through the hexadecimal parser in both
    # builds (a value the parser gets wrong shows up in every operation).
    private def big(operand : Operand) : BigInt
      return BigInt.new if operand.zero?
      String.build do |io|
        io << '-' if operand.negative
        operand.limbs.reverse_each.with_index do |limb, position|
          io << (position == 0 ? limb.to_s(16) : limb.to_s(16).rjust(16, '0'))
        end
      end.to_big_i(16)
    end

    private def value(source : OperandSource) : BigInt
      big(source.operand)
    end

    private def nonzero(source : OperandSource) : BigInt
      result = value(source)
      result.zero? ? BigInt.new(source.rand(2) == 0 ? 7 : -7) : result
    end

    private def divisor(source : OperandSource, dividend : BigInt) : BigInt
      return BigInt.new if source.chance(0.02)
      bits = dividend.bit_length
      big(source.divisor_for(Operand.new(limbs_of(dividend), dividend < 0)))
    end

    private def limbs_of(number : BigInt) : Slice(UInt64)
      magnitude = number.abs
      count = (magnitude.bit_length + 63) // 64
      Slice(UInt64).new(count) { |index| (magnitude >> (index * 64)).to_u64! }
    end

    # A primitive: a small value of either sign 40% of the time (the
    # negative-divisor paths), else the harness's typed primitive.
    private def primitive(source : OperandSource, random : Random) : Primitive
      if source.chance(0.4)
        small = random.rand(-300..300)
        case random.rand(5)
        when 0 then small.to_i8!
        when 1 then small.to_i16
        when 2 then small
        when 3 then small.to_i64
        else        small.to_i128
        end
      else
        source.primitive
      end
    end

    private def nonzero_primitive(source : OperandSource, random : Random) : Primitive
      result = primitive(source, random)
      result.zero? ? -3 : result
    end

    private def show(number : BigInt) : String
      "BigInt:#{number.to_s(16)}"
    end

    private def show(pair : Tuple(BigInt, BigInt)) : String
      "{#{show(pair[0])}, #{show(pair[1])}}"
    end

    private def show(pair : Tuple(BigInt, UInt64)) : String
      "{#{show(pair[0])}, #{pair[1]}}"
    end

    private def show(number : Float64) : String
      "Float64:#{number}:#{number.unsafe_as(UInt64).to_s(16)}"
    end

    private def show(number : Float32) : String
      "Float32:#{number}:#{number.unsafe_as(UInt32).to_s(16)}"
    end

    private def show(other) : String
      "#{other.class}:#{other.inspect}"
    end

    private def run(name : String, source : OperandSource, random : Random) : String
      case name
      when "add"           then show(value(source) + value(source))
      when "add_primitive" then show(value(source) + primitive(source, random))
      when "sub"           then show(value(source) - value(source))
      when "sub_primitive" then show(value(source) - primitive(source, random))
      when "negate"        then show(-value(source))
      when "abs"           then show(value(source).abs)
      when "mul"           then show(value(source) * value(source))
      when "mul_primitive" then show(value(source) * primitive(source, random))
      when "floor_div"
        a = value(source)
        show(a // divisor(source, a))
      when "floor_div_primitive" then show(value(source) // primitive(source, random))
      when "tdiv"
        a = value(source)
        show(a.tdiv(divisor(source, a)))
      when "tdiv_primitive" then show(value(source).tdiv(primitive(source, random)))
      when "mod"
        a = value(source)
        show(a % divisor(source, a))
      when "mod_primitive" then show(value(source) % primitive(source, random))
      when "remainder"
        a = value(source)
        show(a.remainder(divisor(source, a)))
      when "remainder_primitive" then show(value(source).remainder(primitive(source, random)))
      when "divmod"
        a = value(source)
        show(a.divmod(divisor(source, a)))
      when "divmod_primitive" then show(value(source).divmod(primitive(source, random)))
      when "unsafe_floored_div"
        a = value(source)
        show(a.unsafe_floored_div(nonzero_divisor(source, a)))
      when "unsafe_floored_div_primitive" then show(value(source).unsafe_floored_div(nonzero_primitive(source, random)))
      when "unsafe_truncated_div"
        a = value(source)
        show(a.unsafe_truncated_div(nonzero_divisor(source, a)))
      when "unsafe_truncated_div_primitive" then show(value(source).unsafe_truncated_div(nonzero_primitive(source, random)))
      when "unsafe_floored_mod"
        a = value(source)
        show(a.unsafe_floored_mod(nonzero_divisor(source, a)))
      when "unsafe_floored_mod_primitive" then show(value(source).unsafe_floored_mod(nonzero_primitive(source, random)))
      when "unsafe_truncated_mod"
        a = value(source)
        show(a.unsafe_truncated_mod(nonzero_divisor(source, a)))
      when "unsafe_truncated_mod_primitive" then show(value(source).unsafe_truncated_mod(nonzero_primitive(source, random)))
      when "unsafe_floored_divmod"
        a = value(source)
        show(a.unsafe_floored_divmod(nonzero_divisor(source, a)))
      when "unsafe_floored_divmod_primitive" then show(value(source).unsafe_floored_divmod(nonzero_primitive(source, random)))
      when "unsafe_truncated_divmod"
        a = value(source)
        show(a.unsafe_truncated_divmod(nonzero_divisor(source, a)))
      when "unsafe_truncated_divmod_primitive" then show(value(source).unsafe_truncated_divmod(nonzero_primitive(source, random)))
      when "divisible_by"
        a = value(source)
        b = source.chance(0.3) ? nonzero_divisor(source, a) * value_small(source) : nonzero_divisor(source, a)
        show(source.chance(0.3) ? (a * b).divisible_by?(b) : a.divisible_by?(b))
      when "divisible_by_primitive"
        p = nonzero_primitive(source, random)
        a = value(source)
        show(source.chance(0.4) ? (a * p).divisible_by?(p) : a.divisible_by?(p))
      when "factor_by"
        factor = case random.rand(4)
                 when 0 then random.rand(2..1000).to_i64 * (random.rand(2) == 0 ? 1 : -1)
                 when 1 then [1, -1, 2, -2, 10, 3].sample(random)
                 when 2 then UInt64::MAX - random.rand(1000).to_u64
                 else        random.rand(2..50).to_i32
                 end
        a = value(source)
        a *= BigInt.new(factor) ** random.rand(0..40) unless factor.abs == 1
        show(a.factor_by(factor))
      when "complement" then show(~value(source))
      when "bit"
        a = value(source)
        index = case random.rand(4)
                when 0 then random.rand(-10..(a.bit_length + 70))
                when 1 then random.rand(0..9000)
                when 2 then (BigInt.new(2) ** 70) * (random.rand(2) == 0 ? 1 : -1)
                else        [UInt64::MAX, Int64::MAX, -1, 0].sample(random)
                end
        show(a.bit(index))
      when "and"             then show(value(source) & value(source))
      when "and_primitive"   then show(value(source) & primitive(source, random))
      when "or"              then show(value(source) | value(source))
      when "or_primitive"    then show(value(source) | primitive(source, random))
      when "xor"             then show(value(source) ^ value(source))
      when "xor_primitive"   then show(value(source) ^ primitive(source, random))
      when "shift_right"     then show(value(source) >> random.rand(0..9000))
      when "shift_left"      then show(value(source) << random.rand(0..9000))
      when "unsafe_shr"      then show(value(source).unsafe_shr(random.rand(0..9000)))
      when "pow"
        a = value(source)
        bits = Math.max(a.bit_length, 1)
        exponent = random.rand(10) == 0 ? -random.rand(1..5) : random.rand(0..Math.max(1, 16_384 // bits))
        show(a ** exponent)
      when "gcd"           then show(value(source).gcd(value(source)))
      when "gcd_primitive" then show(value(source).gcd(primitive(source, random)))
      when "lcm"           then show(value(source).lcm(value(source)))
      when "lcm_primitive" then show(value(source).lcm(primitive(source, random)))
      when "bit_length"    then show(value(source).bit_length)
      when "to_s"
        a = value(source)
        base = random.rand(4) == 0 ? [1, 37, 0, 64].sample(random) : random.rand(2..37).clamp(2, 36)
        base = 62 if random.rand(8) == 0
        precision = random.rand(3) == 0 ? random.rand(-1..3000) : 1
        a = BigInt.new if random.rand(10) == 0
        show(a.to_s(base, precision: precision, upcase: random.rand(3) == 0))
      when "to_s_io"
        a = value(source)
        io = IO::Memory.new
        base = random.rand(8) == 0 ? 62 : random.rand(2..36)
        a.to_s(io, base, precision: random.rand(0..200), upcase: random.rand(2) == 0 && base != 62)
        a.to_s(io)
        a.inspect(io)
        show(io.to_s)
      when "digits"
        a = value(source)
        show(a.digits(random.rand(2..36)))
      when "popcount"             then show(value(source).popcount)
      when "trailing_zeros_count" then show(value(source).trailing_zeros_count)
      when "next_power_of_two"    then show(value(source).next_power_of_two)
      when "to_primitive_checked"
        a = source.chance(0.5) ? big(source.random_of(random.rand(0..130), source.sign)) : value(source)
        results = [] of String
        {% for type in %w(i i8 i16 i32 i64 i128 u u8 u16 u32 u64 u128) %}
          results << (begin
            show(a.to_{{ type.id }})
          rescue error : OverflowError
            "OverflowError"
          end)
        {% end %}
        results.join(' ')
      when "to_primitive_wrapping"
        a = value(source)
        results = [] of String
        {% for type in %w(i i8 i16 i32 i64 i128 u u8 u16 u32 u64 u128) %}
          results << show(a.to_{{ type.id }}!)
        {% end %}
        results.join(' ')
      when "to_float"
        a = value(source)
        [show(a.to_f), show(a.to_f32), show(a.to_f64), show(a.to_f!), show(a.to_f32!), show(a.to_f64!)].join(' ')
      when "compare"
        a = value(source)
        b = source.chance(0.2) ? a + random.rand(-1..1) : value(source)
        show({a <=> b, a == b, a < b, a > b})
      when "compare_primitive"
        a = source.chance(0.5) ? big(source.random_of(random.rand(0..130), source.sign)) : value(source)
        p = primitive(source, random)
        show({a <=> p, a == p, a < p, a >= p})
      when "compare_float"
        a = value(source)
        f = source.chance(0.3) ? a.to_f64 + [0.0, 0.5, -0.5].sample(random) : source.float
        show({a <=> f, a == f, a < f, a <=> f.to_f32})
      when "equal_primitive"
        p = primitive(source, random)
        show({BigInt.new(p) == p, BigInt.new(p) <=> p, BigInt.new(p).to_s, p.to_big_i.hash == BigInt.new(p).hash})
      when "primitive_compare"
        p = primitive(source, random)
        a = source.chance(0.5) ? BigInt.new(primitive(source, random)) : value(source)
        show({p <=> a, p == a, p < a})
      when "primitive_arithmetic"
        p = primitive(source, random)
        a = value(source)
        show({p + a, p - a, p * a, p &+ a, p &- a, p &* a}) + " " + (a.zero? ? "zero" : show(p % a))
      when "primitive_gcd_lcm"
        p = primitive(source, random)
        a = value(source)
        show({p.gcd(a), p.lcm(a)})
      when "float_compare"
        f = source.float
        a = value(source)
        show({f <=> a, f == a, f.to_f32 <=> a})
      when "parse"
        a = value(source)
        base = random.rand(6) == 0 ? 62 : random.rand(2..36)
        text = a.to_s(base, upcase: random.rand(2) == 0 && base != 62)
        text = text.insert(random.rand(0..text.size), '_') if random.rand(4) == 0
        text = "+" + text if random.rand(8) == 0 && !text.starts_with?('-')
        show({BigInt.new(text, base), text.to_big_i(base)})
      when "parse_garbage"
        chars = "0123456789abcdefxyzXYZ_+- \t\n.e"
        text = String.build { |io| random.rand(0..30).times { io << chars[random.rand(chars.size)] } }
        base = random.rand(2..36)
        show(BigInt.new(text, base))
      when "new_float"
        f = source.float
        show({BigInt.new(f), f.to_big_i, BigInt.new(f.to_f32)})
      when "from_digits"
        base = random.rand(4) == 0 ? random.rand(-1..1) : random.rand(2..300)
        digits = Array(Int32).new(random.rand(0..200)) { random.rand(Math.max(base, 2)) }
        digits << base if random.rand(10) == 0
        digits << -1 if random.rand(10) == 0
        show(BigInt.from_digits(digits, base))
      when "factorial"
        n = random.rand(10) == 0 ? -random.rand(1..5) : random.rand(0..3000)
        show(n.to_big_i.factorial)
      when "isqrt"
        a = value(source)
        show(Math.isqrt(source.chance(0.9) ? a.abs : a))
      when "sqrt"   then show(Math.sqrt(value(source).abs).to_s)
      when "pw2ceil" then show(Math.pw2ceil(value(source)))
      when "divide_float"
        a = value(source)
        b = source.chance(0.1) ? BigInt.new : value(source)
        show((a / b).to_s)
      when "to_big_f" then show(value(source).to_big_f.to_s)
      when "to_big_r" then show(value(source).to_big_r.to_s)
      when "to_big_d" then show(value(source).to_big_d.to_s)
      when "hasher_reduce"
        a = value(source)
        show({Crystal::Hasher.reduce_num(a), Crystal::Hasher.reduce_num(-a)})
      when "sign_parity"
        a = value(source)
        show({a.sign, a.even?, a.odd?, a.zero?, a.positive?, a.negative?})
      when "succ_pred"
        a = value(source)
        show({a.succ, a.pred, a.abs2, a.clone})
      when "random_below"
        a = nonzero(source).abs
        show(Random::PCG32.new(random.rand(UInt64)).rand(a))
      when "random_range"
        a = value(source)
        b = a + value(source).abs
        show(Random::PCG32.new(random.rand(UInt64)).rand(a..b))
      when "rational_new"
        a = value(source)
        b = nonzero(source)
        show(BigRational.new(a, b).to_s)
      when "decimal_new"
        a = value(source)
        show(BigDecimal.new(a, random.rand(0_u64..40_u64)).to_s)
      else
        raise "unknown operation #{name}"
      end
    end

    private def nonzero_divisor(source : OperandSource, dividend : BigInt) : BigInt
      result = divisor(source, dividend)
      result.zero? ? BigInt.new(-5) : result
    end

    private def value_small(source : OperandSource) : BigInt
      big(source.random_of(source.rand(1..200), source.sign))
    end
  end
end

G2Harness::WrapperDifferential.new(ARGV).perform
