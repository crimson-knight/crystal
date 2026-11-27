# Differential test of `Crystal::BigNum::Integer` against GMP (BIGNUM.md 5.2).
#
# Build from the fork's root:
#   CRYSTAL_PATH=$PWD/src crystal-alpha build --release -Duse_gmp scripts/big_num/differential.cr -o bin/big_num_differential
# Run:
#   bin/big_num_differential --seed 1 --count 100000 [--ops add,mul] [--max-bits 8192] [--json out.json]
# See scripts/big_num/README.md for the planted-bug check and the sharded runs.
require "option_parser"
require "./harness/subject"
require "./harness/differential_run"
require "./harness/replay"

module G2Harness
  # The command line of the differential binary.
  class DifferentialCommand
    @subject : String = "engine"
    @seed : UInt64 = 1
    @first_index : UInt64 = 0
    @count : Int64 = 10_000
    @max_bits : Int32 = 8_192
    @list_of_operations : Array(String) = Operations::LIST_OF_NAMES.dup
    @list_of_injected : Array(String) = [] of String
    @plant : String? = nil
    @json_path : String? = nil
    @reproducer_directory : String? = "tmp/big_num/reproducers"
    @list_requested : Bool = false

    def initialize(arguments : Array(String))
      OptionParser.parse(arguments) do |parser|
        parser.banner = "usage: big_num_differential [options]"
        parser.on("--subject NAME", "engine (default) or double (GMP-backed stand-in)") { |value| @subject = value }
        parser.on("--seed N", "PCG32 seed (default 1)") { |value| @seed = value.to_u64 }
        parser.on("--first-index N", "first operation index (default 0)") { |value| @first_index = value.to_u64 }
        parser.on("--count N", "operations to run (default 10000)") { |value| @count = value.to_i64 }
        parser.on("--ops LIST", "comma-separated operations to run (default all)") { |value| @list_of_operations = operation_names(value) }
        parser.on("--max-bits N", "largest operand size in bits (default 8192)") { |value| @max_bits = value.to_i }
        parser.on("--inject LIST", "fault injector: replace the subject's result with a near miss for these operations") { |value| @list_of_injected = operation_names(value) }
        parser.on("--plant OP", "planted bug: the double subject returns a wrong answer for OP") { |value| @plant = value }
        parser.on("--json PATH", "write the summary JSON here (default: standard output)") { |value| @json_path = value }
        parser.on("--reproducers DIR", "write one-line reproducer specs here (default tmp/big_num/reproducers)") { |value| @reproducer_directory = value }
        parser.on("--list", "print the operation names and exit") { @list_requested = true }
        parser.on("-h", "--help", "show this help") do
          STDOUT.puts parser
          exit
        end
      end
    end

    private def operation_names(value : String) : Array(String)
      names = value.split(',').map(&.strip).reject(&.empty?)
      unknown = names - Operations::LIST_OF_NAMES
      raise ArgumentError.new("Unknown operations: #{unknown.join(", ")}") unless unknown.empty?
      names
    end

    def perform : Int32
      if @list_requested
        STDOUT.puts Operations::LIST_OF_NAMES.join('\n')
        return 0
      end
      ReferenceDouble.plant = @plant
      summary = Subject.dispatch(@subject) { run(subject_type) }
      json = summary.to_pretty_json
      if path = @json_path
        File.write(path, json + "\n")
      else
        STDOUT.puts json
      end
      STDERR.puts "seed=#{summary.seed} count=#{summary.total_count} differences=#{summary.total_differences} pending=#{summary.total_pending} subject=#{summary.subject} gmp=#{summary.gmp_version} #{summary.elapsed_seconds.round(1)}s"
      summary.total_differences == 0 ? 0 : 1
    end

    private def run(type : T.class) : Summary forall T
      DifferentialRun(T).new(@subject, @seed, @first_index, @count, @list_of_operations, @max_bits,
        @list_of_injected, @reproducer_directory, STDERR).perform
    end
  end
end

exit G2Harness::DifferentialCommand.new(ARGV).perform
