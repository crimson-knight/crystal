# Wrapper-level differential for `BigDecimal`: the public API Grant uses, in
# the default (pure) build against the same program built with `-Duse_gmp`.
#
# Build both from the fork's root and compare their output:
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release scripts/big_num/decimal_differential.cr -o bin/decimal_pure
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release -Duse_gmp scripts/big_num/decimal_differential.cr -o bin/decimal_gmp
#   bin/decimal_pure --seed 1 --count 1000000 > pure.txt
#   bin/decimal_gmp --seed 1 --count 1000000 > gmp.txt
#   cmp pure.txt gmp.txt
# Each output line is `<index> <operation> <FNV-1a 64 of the printed result>`;
# `--show 17,42` prints the full results of those indices instead (the
# one-line reproducer for a difference). Every BigDecimal result prints its
# internal value and scale as well as its `to_s`, so a representation that
# prints alike but differs is a difference too; a raised exception prints
# its class and message.
#
# Operands are decimal strings drawn from `Random::PCG32.new(seed, index)`,
# so both builds see the same values: NUMERIC(38,10), DECIMAL(65,30) and
# 1,000-digit NUMERIC shapes, random scales, edge values (zero, powers of
# ten, nines, halves for the rounding modes), both signs.
require "big"
require "big/json"
require "json"
require "option_parser"

module DecimalDifferential
  LIST_OF_OPERATIONS = %w(
    parse parse_forms parse_garbage to_s equal compare add sub mul
    round_ties_away round_modes trunc ceil_floor abs to_i64 to_f64
    json_round_trip div new_int new_float
  )

  LIST_OF_MODES = [
    Number::RoundingMode::TIES_EVEN, Number::RoundingMode::TIES_AWAY,
    Number::RoundingMode::TO_ZERO, Number::RoundingMode::TO_POSITIVE,
    Number::RoundingMode::TO_NEGATIVE,
  ]

  # Draws operand texts from one operation's random stream.
  class Operands
    def initialize(@random : Random::PCG32)
    end

    def below(limit : Int32) : Int32
      @random.rand(limit)
    end

    def chance(probability : Float64) : Bool
      @random.rand < probability
    end

    def digits(count : Int32, leading_nonzero : Bool = false) : String
      String.build(count) do |io|
        count.times do |position|
          io << (position == 0 && leading_nonzero ? 1 + below(9) : below(10))
        end
      end
    end

    # The canonical text `[-]int.frac` of a value with *integer_digits* and
    # *fraction_digits*; the last fraction digit is sometimes 5 or 0 so the
    # rounding ties and the normalization are reached.
    def text(integer_digits : Int32, fraction_digits : Int32) : String
      sign = chance(0.5) ? "-" : ""
      integer = integer_digits == 0 ? "0" : digits(integer_digits, true)
      return "#{sign}#{integer}" if fraction_digits == 0
      fraction = digits(fraction_digits)
      case below(6)
      when 0 then fraction = fraction[0, fraction.size - 1] + "5"
      when 1 then fraction = fraction[0, fraction.size - 1] + "0"
      end
      "#{sign}#{integer}.#{fraction}"
    end

    # An operand text at one of the shapes.
    def shape_text : String
      case below(100)
      when 0...30 # NUMERIC(38,10)
        scale = below(11)
        text(below(39 - scale), scale)
      when 30...55 # DECIMAL(65,30)
        scale = below(31)
        text(below(66 - scale), scale)
      when 55...63 # NUMERIC with up to 1,000 digits
        total = 1 + below(1_000)
        scale = below(total + 1)
        text(total - scale, scale)
      when 63...88 # random scale, including more places than digits
        total = 1 + below(60)
        scale = below(80)
        integer_digits = scale >= total ? 0 : total - scale
        fraction = scale >= total ? "0" * (scale - total) + digits(total, true) : digits(scale)
        sign = chance(0.5) ? "-" : ""
        integer = integer_digits == 0 ? "0" : digits(integer_digits, true)
        scale == 0 ? "#{sign}#{integer}" : "#{sign}#{integer}.#{fraction}"
      else
        edge_text
      end
    end

    def edge_text : String
      sign = chance(0.5) ? "-" : ""
      case below(9)
      when 0 then "#{sign}0" + (chance(0.5) ? "." + "0" * below(12) : "")
      when 1 then "#{sign}1" + "0" * below(40)
      when 2 then "#{sign}0." + "0" * below(40) + "1"
      when 3 then "#{sign}" + "9" * (1 + below(65))
      when 4 then "#{sign}0." + "9" * (1 + below(40))
      when 5 then "#{sign}#{digits(1 + below(30), true)}.5"
      when 6 then "#{sign}#{digits(1 + below(20), true)}." + "0" * below(20) + "5"
      when 7 then "#{sign}#{Int64::MAX - below(3)}" + (chance(0.5) ? ".9" : "")
      else        "#{sign}#{UInt64::MAX}.#{digits(below(10))}"
      end
    end

    # The same value written another way BigDecimal accepts: a `+`, `_`
    # separators, a leading `.`, leading zeros, or an exponent.
    def respelled(canonical : String) : String
      negative = canonical.starts_with?('-')
      body = negative ? canonical[1..] : canonical
      integer, _, fraction = body.partition('.')
      sign = negative ? "-" : (chance(0.3) ? "+" : "")
      case below(6)
      when 0 # leading `.` when the integer part is zero
        integer == "0" && !fraction.empty? ? "#{sign}.#{fraction}" : "#{sign}#{body}"
      when 1 # underscores between digits
        "#{sign}#{integer.chars.each_slice(3).map(&.join).join('_')}" + (fraction.empty? ? "" : ".#{fraction}")
      when 2 # leading zeros
        "#{sign}#{"0" * (1 + below(4))}#{body}"
      else # mantissa and exponent: digits shifted by the exponent
        digits = integer + fraction
        shift = below(digits.size + 1)
        mantissa = shift == 0 ? digits : "#{digits[0, digits.size - shift]}.#{digits[digits.size - shift..]}"
        mantissa = "0#{mantissa}" if mantissa.starts_with?('.')
        exponent = shift - fraction.size
        letter = chance(0.5) ? 'e' : 'E'
        explicit = exponent >= 0 && chance(0.5) ? "+" : ""
        "#{sign}#{mantissa}#{letter}#{explicit}#{exponent}"
      end
    end

    def garbage : String
      list_of_pieces = ["", "-", "+", ".", "e", "E", "_", "1", "5", "0", "-1", ".5", "1.", "e5", "1e", "1e+", "1e-",
                        "1.e5", "--1", "+-1", "-+1", "1.2.3", "1e5.0", "1e5e5", " 1", "1 ", "a", "0x10", "NaN",
                        "Infinity", "1e18446744073709551616", "1e0000000000000000000007", "1__0", "_1", "1_",
                        "-.", "-e5", ".e5", "1e+-5", "１"]
      if chance(0.5)
        list_of_pieces[below(list_of_pieces.size)]
      else
        String.build do |io|
          (1 + below(5)).times { io << list_of_pieces[below(list_of_pieces.size)] }
        end
      end
    end
  end

  class Runner
    @seed : UInt64 = 1
    @count : Int64 = 10_000
    @first_index : Int64 = 0
    @list_of_shown : Array(Int64)? = nil

    def initialize(arguments : Array(String))
      OptionParser.parse(arguments) do |parser|
        parser.banner = "usage: decimal_differential [options]"
        parser.on("--seed N", "PCG32 seed (default 1)") { |value| @seed = value.to_u64 }
        parser.on("--count N", "operations to run (default 10000)") { |value| @count = value.to_i64 }
        parser.on("--first-index N", "first operation index (default 0)") { |value| @first_index = value.to_i64 }
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
          operands = Operands.new(Random::PCG32.new(@seed, index.to_u64))
          name = LIST_OF_OPERATIONS[operands.below(LIST_OF_OPERATIONS.size)]
          text = begin
            run(name, operands)
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

    # A result with its representation: value, scale and printed text.
    private def show(number : BigDecimal) : String
      "BigDecimal(#{number.value}, #{number.scale}) #{number}"
    end

    private def decimal(operands : Operands) : BigDecimal
      BigDecimal.new(operands.shape_text)
    end

    private def run(name : String, operands : Operands) : String
      case name
      when "parse"
        text = operands.shape_text
        "#{text} => #{show(BigDecimal.new(text))}"
      when "parse_forms"
        text = operands.respelled(operands.shape_text)
        "#{text} => #{show(BigDecimal.new(text))}"
      when "parse_garbage"
        text = operands.garbage
        # a valid exponent of 10,000 or more takes long to expand in both builds
        return "#{text.inspect} => skipped" if text.delete('_') =~ /[eE]\+?0*[1-9][0-9]{4}/
        "#{text.inspect} => #{show(BigDecimal.new(text))}"
      when "to_s"
        number = decimal(operands)
        # `to_s(io)` and `to_s` must agree, and both normalize
        "#{number.value} #{number.scale} #{number.to_s} #{String.build { |io| number.to_s(io) }} #{show(number)}"
      when "equal"
        left = decimal(operands)
        # the same value re-read from its text, with extra fraction zeros
        # when the text is plain (`12.3` and `12.300`)
        printed = left.to_s
        padding = printed.includes?('e') || operands.chance(0.5) ? "" : "0" * (1 + operands.below(5))
        right = operands.chance(0.4) ? BigDecimal.new(printed + padding) : decimal(operands)
        right = BigDecimal.new(left.value * BigInt.new(10) ** 3, left.scale + 3) if operands.chance(0.2)
        "#{left == right} #{right == left} #{left != right}"
      when "compare"
        left = decimal(operands)
        right = operands.chance(0.3) ? left + BigDecimal.new(operands.chance(0.5) ? "0" : "1e-#{operands.below(40)}") : decimal(operands)
        "#{left <=> right} #{right <=> left} #{left < right} #{left >= right}"
      when "add"
        show(decimal(operands) + decimal(operands))
      when "sub"
        show(decimal(operands) - decimal(operands))
      when "mul"
        show(decimal(operands) * decimal(operands))
      when "round_ties_away"
        number = decimal(operands)
        digits = operands.below(31)
        "#{digits} #{show(number.round(digits, mode: :ties_away))}"
      when "round_modes"
        number = decimal(operands)
        digits = operands.below(31)
        mode = LIST_OF_MODES[operands.below(LIST_OF_MODES.size)]
        "#{digits} #{mode} #{show(number.round(digits, mode: mode))} #{show(number.round(mode))}"
      when "trunc"
        number = decimal(operands)
        "#{show(number.trunc)} #{number == number.trunc}"
      when "ceil_floor"
        number = decimal(operands)
        "#{show(number.ceil)} #{show(number.floor)} #{show(number.round_even)} #{show(number.round_away)} #{show(number.round)}"
      when "abs"
        number = decimal(operands)
        "#{show(number.abs)} #{number.abs <= BigDecimal.new(Int64::MAX)}"
      when "to_i64"
        decimal(operands).to_i64.to_s
      when "to_f64"
        decimal(operands).to_f64.to_s
      when "json_round_trip"
        number = decimal(operands)
        json = {"amount" => number}.to_json
        back = Hash(String, BigDecimal).from_json(json)["amount"]
        "#{json} #{show(back)} #{back == number}"
      when "div"
        left = decimal(operands)
        right = operands.chance(0.02) ? BigDecimal.new(0) : decimal(operands)
        right = BigDecimal.new(operands.chance(0.5) ? "3" : "0.25") if operands.chance(0.2)
        show(left / right)
      when "new_int"
        value = operands.chance(0.5) ? operands.below(Int32::MAX).to_i64 * (operands.chance(0.5) ? 1 : -1) : Int64::MIN + operands.below(3)
        show(BigDecimal.new(value))
      when "new_float"
        value = decimal(operands).to_f64
        "#{value} #{show(BigDecimal.new(value))} #{show(BigDecimal.new(value.to_s))}"
      else
        raise ArgumentError.new("unknown operation #{name}")
      end
    end
  end
end

DecimalDifferential::Runner.new(ARGV).perform
