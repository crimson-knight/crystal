# Benchmark of `BigDecimal` at the shapes databases hand Grant: NUMERIC(38,10),
# DECIMAL(65,30) and a 1,000-digit NUMERIC.
#
# The same source is built twice, once on the pure engine (default) and once
# on GMP (`-Duse_gmp`), and a driver runs the two binaries in alternation, one
# round per process, taking the median of the rounds for each build:
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release scripts/big_num/decimal_bench.cr -o bin/decimal_bench_pure
#   CRYSTAL_PATH=lib:$PWD/src <compiler> build --release -Duse_gmp scripts/big_num/decimal_bench.cr -o bin/decimal_bench_gmp
#   bin/decimal_bench_pure [--ops parse,to_s] [--shapes numeric_38_10] [--target-ms 200]
# Each output line is `<build> <operation> <shape> <iterations> <ns per operation>`.
# Operands are the same in both builds: decimal strings drawn from a fixed
# splitmix64 sequence, both signs, every digit position used.
require "big"
require "option_parser"

module DecimalBench
  BUILD = {% if flag?(:use_gmp) %} "gmp" {% else %} "pure" {% end %}

  # A column shape: digits before and after the decimal point.
  record Shape, name : String, integer_digits : Int32, fraction_digits : Int32

  LIST_OF_SHAPES = [
    Shape.new("numeric_38_10", 28, 10),
    Shape.new("decimal_65_30", 35, 30),
    Shape.new("numeric_1000", 500, 500),
  ]

  LIST_OF_OPERATIONS = %w(parse to_s add mul round_2_ties_away equal)

  # Operations measured only at the first two shapes (the brief's table).
  LIST_OF_OPERATIONS_AT_EVERY_SHAPE = %w(parse to_s)

  POOL_SIZE = 64

  # Deterministic splitmix64, so both builds draw the same operands.
  class Draw
    def initialize(@state : UInt64)
    end

    def next_u64 : UInt64
      @state &+= 0x9E3779B97F4A7C15_u64
      mixed = @state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9_u64
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB_u64
      mixed ^ (mixed >> 31)
    end

    def below(limit : Int32) : Int32
      (next_u64 % limit.to_u64).to_i32
    end

    def digits(count : Int32, leading_nonzero : Bool) : String
      String.build(count) do |io|
        count.times do |index|
          digit = below(10)
          digit = 1 + below(9) if index == 0 && leading_nonzero
          io << digit
        end
      end
    end
  end

  # A full-width value of *shape*: every integer and fraction digit present.
  def self.text_of(shape : Shape, draw : Draw) : String
    sign = draw.below(2) == 0 ? "-" : ""
    "#{sign}#{draw.digits(shape.integer_digits, true)}.#{draw.digits(shape.fraction_digits, false)}"
  end

  class Runner
    @@sink = 0_u64

    def self.sink : UInt64
      @@sink
    end

    def initialize(@target_ns : Float64)
    end

    def measure(shape : Shape, operation : String) : {Int64, Float64}
      draw = Draw.new(0x6463_u64 &+ shape.integer_digits.to_u64 &* 1_000_u64 &+ shape.fraction_digits.to_u64)
      list_of_texts = Array.new(POOL_SIZE) { DecimalBench.text_of(shape, draw) }
      list_of_decimals = list_of_texts.map { |text| BigDecimal.new(text) }
      # The same values with two more zeros of scale, as a database returns
      # `12.30` for a value Crystal printed as `12.3`.
      list_of_padded = list_of_texts.map { |text| BigDecimal.new(text + "00") }
      work = case operation
             when "parse"
               ->(index : Int32) { BigDecimal.new(list_of_texts[index]).scale }
             when "to_s"
               ->(index : Int32) { list_of_decimals[index].to_s.bytesize.to_u64 }
             when "add"
               ->(index : Int32) { (list_of_decimals[index] + list_of_decimals[(index + 1) % POOL_SIZE]).scale }
             when "mul"
               ->(index : Int32) { (list_of_decimals[index] * list_of_decimals[(index + 1) % POOL_SIZE]).scale }
             when "round_2_ties_away"
               ->(index : Int32) { list_of_decimals[index].round(2, mode: :ties_away).scale }
             when "equal"
               ->(index : Int32) { list_of_decimals[index] == list_of_padded[index] ? 1_u64 : 0_u64 }
             else
               raise ArgumentError.new("unknown operation #{operation}")
             end
      iterations = calibrate(work)
      {iterations, time(work, iterations) / iterations}
    end

    private def calibrate(work : Proc(Int32, UInt64)) : Int64
      iterations = 64_i64
      loop do
        elapsed = time(work, iterations)
        return (iterations * @target_ns / elapsed).to_i64.clamp(64_i64, 1_i64 << 40) if elapsed >= @target_ns / 8
        iterations *= 8
      end
    end

    private def time(work : Proc(Int32, UInt64), iterations : Int64) : Float64
      sink = 0_u64
      index = 0
      started = Time.instant
      iterations.times do
        sink &+= work.call(index)
        index = index == POOL_SIZE - 1 ? 0 : index + 1
      end
      elapsed = (Time.instant - started).total_nanoseconds
      @@sink &+= sink
      elapsed
    end
  end

  def self.perform(arguments : Array(String)) : Nil
    list_of_operations = LIST_OF_OPERATIONS
    list_of_shape_names = LIST_OF_SHAPES.map(&.name)
    target_ms = 200.0
    OptionParser.parse(arguments) do |parser|
      parser.banner = "usage: decimal_bench [options]"
      parser.on("--ops LIST", "operations (default all)") { |value| list_of_operations = value.split(',') }
      parser.on("--shapes LIST", "shapes (default all)") { |value| list_of_shape_names = value.split(',') }
      parser.on("--target-ms N", "time per row in milliseconds (default 200)") { |value| target_ms = value.to_f }
    end
    runner = Runner.new(target_ms * 1_000_000)
    LIST_OF_SHAPES.each do |shape|
      next unless list_of_shape_names.includes?(shape.name)
      list_of_operations.each do |operation|
        next if shape.name == "numeric_1000" && !LIST_OF_OPERATIONS_AT_EVERY_SHAPE.includes?(operation)
        iterations, ns = runner.measure(shape, operation)
        STDOUT.puts "#{BUILD} #{operation} #{shape.name} #{iterations} #{ns.round(2)}"
        STDOUT.flush
      end
    end
    STDERR.puts "sink #{Runner.sink}"
  end
end

DecimalBench.perform(ARGV)
