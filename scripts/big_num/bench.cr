# Benchmark of `Crystal::BigNum::Integer` against GMP's `BigInt` (BIGNUM.md 5.3).
#
# One binary calls both: each round times every selected row on our engine
# and on GMP, alternating which side goes first, and the reported time is the
# median of the rounds (6 by default). Build it --release from the fork's root:
#   CRYSTAL_PATH=$PWD/src <compiler> build --release scripts/big_num/bench.cr -o bin/big_num_bench
#   bin/big_num_bench [--ops add,mul] [--bits 64,128] [--rounds 6] [--json out.json] [--markdown out.md]
require "option_parser"
require "json"
require "./harness/subject"
require "./harness/operand_source"

module G2Harness
  # One measured row of the bench.
  struct BenchRow
    include JSON::Serializable

    getter operation : String
    getter bits : Int32
    getter iterations : Int64
    getter ours_ns : Float64?
    getter gmp_ns : Float64
    # GMP time / our time: at or above 1.00 our engine is at least as fast.
    getter ratio : Float64?
    getter status : String
    getter list_of_ours_rounds_ns : Array(Float64)
    getter list_of_gmp_rounds_ns : Array(Float64)

    def initialize(@operation, @bits, @iterations, @ours_ns, @gmp_ns, @status, @list_of_ours_rounds_ns, @list_of_gmp_rounds_ns)
      ours = @ours_ns
      @ratio = ours ? @gmp_ns / ours : nil
    end
  end

  # A row's two closures: the same operation on GMP and on our engine. Each
  # returns a value folded into a sink so the work cannot be optimized away.
  record BenchCase, operation : String, bits : Int32, gmp : Proc(UInt64), ours : Proc(UInt64)

  class Bench
    LIST_OF_OPERATIONS = %w(add sub mul mul_unbalanced mul_primitive sqr divmod divmod_limb to_s_10 to_s_16 parse_10
      gcd isqrt pow pow_mod shift and compare hash) + DIVISION_OPERATIONS + NUMBER_THEORY_OPERATIONS
    # Division rows (G2c): GMP's tdiv/fdiv quotient, remainder and both, of a
    # negative dividend of the row's size by a positive divisor of one limb
    # (`_limb`), of half the dividend's size (`_half`), or one limb shorter
    # than the dividend (`_short`; 32 bits for a 64-bit dividend).
    DIVISION_OPERATIONS = %w(tdiv_q tdiv_r tdiv_qr fdiv_q fdiv_r fdiv_qr).flat_map do |kind|
      %w(limb half short).map { |shape| "#{kind}_#{shape}" }
    end
    # Number theory rows (G2e): lcm, invert (operands nudged until an
    # inverse exists; gcd, lcm and invert cycle through ROTATING_PAIRS
    # distinct pairs), factorial of the largest n whose result fits the row's
    # bits, and the removal of every factor 10 from a value of the row's size
    # ending in about bits / 16 decimal zeros (BigDecimal's normalization).
    NUMBER_THEORY_OPERATIONS   = %w(lcm invert factorial remove_10)
    LIST_OF_BITS_UNDER_THE_BAR = [64, 128, 192, 256, 512, 1_024, 2_048, 4_096]
    LIST_OF_BITS_REPORTED      = [8_192, 32_768, 131_072, 1_048_576]
    # Rows that take minutes per operation on GMP itself above these sizes.
    LARGEST_BITS = {"pow_mod" => 8_192}

    @@sink = 0_u64
    @@live = true

    def self.live? : Bool
      @@live
    end

    def self.sink : UInt64
      @@sink
    end

    def initialize(@rounds : Int32, @target_ns : Float64, @output : IO)
    end

    private def operand(source : OperandSource, bits : Int32) : Operand
      source.dense_of(bits)
    end

    private def gmp_of(operand : Operand) : BigInt
      GMPOracle.from_limbs(operand.limbs, operand.negative)
    end

    private def ours_of(operand : Operand) : Crystal::BigNum::Integer
      Crystal::BigNum::Integer.from_limbs(operand.limbs, operand.negative)
    end

    private def fold(value : BigInt) : UInt64
      limbs = GMPOracle.limbs(value)
      limbs.empty? ? 0_u64 : limbs[0]
    end

    # The low limb read in place: `#limbs` copies an inline value into a
    # fresh Slice, an allocation the GMP side does not pay.
    private def fold(value : Crystal::BigNum::Integer) : UInt64
      value.zero? ? 0_u64 : value.to_u64!
    end

    private def fold(value : Tuple) : UInt64
      fold(value[0]) &+ fold(value[1])
    end

    private def fold(value : String) : UInt64
      value.bytesize.to_u64
    end

    private def fold(value : ::Int) : UInt64
      value.to_u64!
    end

    private def fold(value : Nil) : UInt64
      0_u64
    end

    # Builds the row's closures from operands drawn the same way for both sides.
    private macro row(gmp_expression, ours_expression = nil)
      %gmp_a, %gmp_b, %gmp_c = gmp_of(a), gmp_of(b), gmp_of(c)
      %ours_a, %ours_b, %ours_c = ours_of(a), ours_of(b), ours_of(c)
      BenchCase.new(operation, bits,
        ->{ x, y, z = %gmp_a, %gmp_b, %gmp_c; fold({{gmp_expression}}) },
        # The `live?` branch keeps the closure typed UInt64 while the engine method
        # is a stub that only raises.
        ->{ x, y, z = %ours_a, %ours_b, %ours_c; Bench.live? ? fold({{ours_expression || gmp_expression}}) : 0_u64 })
    end

    # Distinct operand pairs a rotating row cycles through, so that neither
    # side runs one pair over and over (a repeated pair lets the branch
    # predictor learn a data-dependent loop's exact path).
    ROTATING_PAIRS = 1_024

    # *ROTATING_PAIRS* pairs of operands of *bits* bits; with *invertible*
    # the first is positive and nudged until it has an inverse modulo the
    # second.
    private def list_of_pairs(source : OperandSource, bits : Int32, invertible : Bool = false) : Array({Operand, Operand})
      Array.new(ROTATING_PAIRS) do
        first = operand(source, bits)
        second = operand(source, bits)
        if invertible
          second = Operand.new(second.limbs, false)
          modulus = gmp_of(second)
          base = gmp_of(first)
          while GMPOracle.invert(base, modulus).nil?
            base += 1
          end
          first = Operand.new(GMPOracle.limbs(base).dup, base < 0)
        end
        {first, second}
      end
    end

    # A row whose closures take the next of *pairs* on each call (the same
    # sequence on both sides).
    private macro rotating_row(pairs, gmp_expression, ours_expression = nil)
      %gmp = {{pairs}}.map { |pair| {gmp_of(pair[0]), gmp_of(pair[1])} }
      %ours = {{pairs}}.map { |pair| {ours_of(pair[0]), ours_of(pair[1])} }
      %gmp_index = 0
      %ours_index = 0
      BenchCase.new(operation, bits,
        ->{ x, y = %gmp.unsafe_fetch(%gmp_index & (ROTATING_PAIRS - 1)); %gmp_index &+= 1; fold({{gmp_expression}}) },
        ->{ x, y = %ours.unsafe_fetch(%ours_index & (ROTATING_PAIRS - 1)); %ours_index &+= 1; Bench.live? ? fold({{ours_expression || gmp_expression}}) : 0_u64 })
    end

    def bench_case(operation : String, bits : Int32) : BenchCase
      source = OperandSource.new(Random::PCG32.new(20_261_127_u64, bits.to_u64), Int32::MAX)
      a = operand(source, bits)
      b = operand(source, bits)
      c = operand(source, Math.max(1, bits // 4))
      case operation
      when "add"            then row(x + y)
      when "sub"            then row(x - y)
      when "mul"            then row(x * y)
      when "mul_unbalanced" then row(x * z)
      when "mul_primitive"
        factor = source.dense_of(64).limbs[0] >> 1
        row(x * factor)
      when "sqr" then row(x * x, x.square)
      when "divmod"
        a = operand(source, bits * 2)
        row(x.divmod(y))
      when "divmod_limb"
        divisor = source.dense_of(64).limbs[0]
        row(x.divmod(divisor))
      when .in?(DIVISION_OPERATIONS)
        kind, _, shape = operation.rpartition('_')
        divisor_bits = case shape
                       when "limb" then 64
                       when "half" then Math.max(32, bits // 2)
                       else             bits > 64 ? bits - 64 : 32
                       end
        a = Operand.new(a.limbs, true)
        b = source.dense_of(divisor_bits)
        case kind
        when "tdiv_q"  then row(x.unsafe_truncated_div(y))
        when "tdiv_r"  then row(x.unsafe_truncated_mod(y))
        when "tdiv_qr" then row(x.unsafe_truncated_divmod(y))
        when "fdiv_q"  then row(x.unsafe_floored_div(y))
        when "fdiv_r"  then row(x.unsafe_floored_mod(y))
        else                row(x.unsafe_floored_divmod(y))
        end
      when "to_s_10" then row(x.to_s(10))
      when "to_s_16" then row(x.to_s(16))
      when "parse_10"
        text = gmp_of(a).to_s
        row(BigInt.new(text, 10), Crystal::BigNum::Integer.parse(text, 10))
      when "gcd"    then rotating_row(list_of_pairs(source, bits), x.gcd(y))
      when "isqrt"  then row(Math.isqrt(x), x.isqrt)
      when "lcm"    then rotating_row(list_of_pairs(source, bits), x.lcm(y))
      when "invert" then rotating_row(list_of_pairs(source, bits, invertible: true), GMPOracle.invert(x, y), x.invert(y))
      when "factorial"
        n = 1_u64
        while GMPOracle.factorial(n + 1).bit_length <= bits
          n += 1
        end
        row(GMPOracle.factorial(n), Crystal::BigNum::Integer.factorial(n))
      when "remove_10"
        zeros = Math.max(1, bits // 16)
        power = BigInt.new(10) ** zeros
        head_bits = Math.max(1, bits - power.bit_length)
        head = gmp_of(source.dense_of(head_bits))
        while head.divisible_by?(10)
          head += 1
        end
        a = Operand.new(GMPOracle.limbs(head * power).dup, false)
        b = Operand.new(Slice[10_u64], false)
        row(GMPOracle.remove(x, y), x.remove(y))
      when "pow"
        c = operand(source, Math.max(1, bits // 5))
        row(z ** 5)
      when "pow_mod"
        c = operand(source, bits)
        b = Operand.new(b.limbs, false)
        row(GMPOracle.pow_mod(x, z, y), ours_pow_mod(x, z, y))
      when "shift" then row((x << 37) >> 91)
      when "and"   then row(x & y)
      when "compare"
        b = Operand.new(a.limbs.dup.tap { |limbs| limbs[0] ^= 1 }, false)
        row(x <=> y)
      when "hash" then row(x.hash)
      else
        raise ArgumentError.new("Unknown bench operation #{operation}")
      end
    end

    # The internal pow_mod is G2e's; until it exists the row reads pending.
    private def ours_pow_mod(base : Crystal::BigNum::Integer, exponent, modulus)
      if base.responds_to?(:pow_mod)
        base.pow_mod(exponent, modulus)
      else
        raise NotImplementedError.new("Crystal::BigNum::Integer#pow_mod is not defined")
      end
    end

    # Iterations so one timing takes about the target time on GMP.
    private def calibrate(work : Proc(UInt64)) : Int64
      iterations = 1_i64
      loop do
        elapsed = time(work, iterations)
        return iterations if elapsed >= @target_ns / 4 || iterations >= 1_i64 << 40
        iterations *= elapsed > 0 ? Math.max(2_i64, (@target_ns / elapsed).to_i64) : 1_000_i64
      end
    end

    private def time(work : Proc(UInt64), iterations : Int64) : Float64
      sink = 0_u64
      started = Time.instant
      iterations.times { sink &+= work.call }
      elapsed = (Time.instant - started).total_nanoseconds
      @@sink &+= sink
      elapsed
    end

    private def median(list : Array(Float64)) : Float64
      sorted = list.sort
      middle = sorted.size // 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    end

    def perform(list_of_operations : Array(String), list_of_bits : Array(Int32)) : Array(BenchRow)
      cases = [] of BenchCase
      list_of_operations.each do |operation|
        list_of_bits.each do |bits|
          next if (limit = LARGEST_BITS[operation]?) && bits > limit
          cases << bench_case(operation, bits)
        end
      end
      iterations = cases.map { |bench_case| calibrate(bench_case.gmp) }
      pending = cases.map do |bench_case|
        begin
          bench_case.ours.call
          false
        rescue NotImplementedError
          true
        end
      end
      ours_rounds = cases.map { [] of Float64 }
      gmp_rounds = cases.map { [] of Float64 }
      @rounds.times do |round|
        cases.each_with_index do |bench_case, index|
          count = iterations[index]
          if round.even?
            ours_rounds[index] << time(bench_case.ours, count) / count unless pending[index]
            gmp_rounds[index] << time(bench_case.gmp, count) / count
          else
            gmp_rounds[index] << time(bench_case.gmp, count) / count
            ours_rounds[index] << time(bench_case.ours, count) / count unless pending[index]
          end
        end
        @output.puts "round #{round + 1} of #{@rounds} done"
      end
      cases.map_with_index do |bench_case, index|
        ours = pending[index] ? nil : median(ours_rounds[index])
        status = if ours.nil?
                   "pending"
                 elsif bench_case.bits > 4_096
                   "reported"
                 elsif median(gmp_rounds[index]) / ours >= 1.0
                   "pass"
                 else
                   "below"
                 end
        BenchRow.new(bench_case.operation, bench_case.bits, iterations[index], ours, median(gmp_rounds[index]),
          status, ours_rounds[index], gmp_rounds[index])
      end
    end

    def self.markdown(rows : Array(BenchRow), io : IO) : Nil
      io.puts "| operation | bits | ours ns/op | GMP ns/op | GMP / ours | status |"
      io.puts "|---|---:|---:|---:|---:|---|"
      rows.each do |row|
        ours = row.ours_ns.try { |value| value.round(1).to_s } || "pending"
        ratio = row.ratio.try { |value| "%.2f" % value } || "-"
        io.puts "| #{row.operation} | #{row.bits} | #{ours} | #{row.gmp_ns.round(1)} | #{ratio} | #{row.status} |"
      end
    end
  end
end

list_of_operations = G2Harness::Bench::LIST_OF_OPERATIONS.dup
list_of_bits = G2Harness::Bench::LIST_OF_BITS_UNDER_THE_BAR + G2Harness::Bench::LIST_OF_BITS_REPORTED
rounds = 6
target_ms = 20.0
json_path = nil
markdown_path = nil
OptionParser.parse do |parser|
  parser.banner = "usage: big_num_bench [options]"
  parser.on("--ops LIST", "rows' operations, comma-separated (default all: #{list_of_operations.join(",")})") do |value|
    list_of_operations = value.split(',').map(&.strip)
    unknown = list_of_operations - G2Harness::Bench::LIST_OF_OPERATIONS
    raise ArgumentError.new("Unknown bench operations: #{unknown.join(", ")}") unless unknown.empty?
  end
  parser.on("--bits LIST", "operand sizes in bits, comma-separated, or 'bar' (64..4096) or 'reported' (8192..1048576)") do |value|
    list_of_bits = case value
                   when "bar"      then G2Harness::Bench::LIST_OF_BITS_UNDER_THE_BAR
                   when "reported" then G2Harness::Bench::LIST_OF_BITS_REPORTED
                   else                 value.split(',').map(&.strip.to_i)
                   end
  end
  parser.on("--rounds N", "interleaved rounds; the median is reported (default 6)") { |value| rounds = value.to_i }
  parser.on("--target-ms N", "time per measurement on GMP (default 20)") { |value| target_ms = value.to_f }
  parser.on("--json PATH", "write the rows as JSON") { |value| json_path = value }
  parser.on("--markdown PATH", "write the rows as a markdown table") { |value| markdown_path = value }
  parser.on("-h", "--help", "show this help") do
    puts parser
    exit
  end
end

rows = G2Harness::Bench.new(rounds, target_ms * 1_000_000, STDERR).perform(list_of_operations, list_of_bits)
if path = json_path
  File.write(path, {gmp_version: G2Harness::GMPOracle.version, crystal_version: Crystal::VERSION, rounds: rounds, list_of_rows: rows}.to_pretty_json + "\n")
end
if path = markdown_path
  File.open(path, "w") { |file| G2Harness::Bench.markdown(rows, file) }
end
G2Harness::Bench.markdown(rows, STDOUT)
STDERR.puts "sink #{G2Harness::Bench.sink}"
