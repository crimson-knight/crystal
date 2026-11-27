require "json"
require "./operations"

module G2Harness
  # Per-operation tally in the summary JSON.
  struct OperationTally
    include JSON::Serializable

    property count : Int64 = 0
    property differences : Int64 = 0
    property pending : Int64 = 0
    # Operations where GMP itself raised (invalid input, division by zero): the
    # subject must raise the same exception class.
    property oracle_raised : Int64 = 0

    def initialize
    end
  end

  # One difference, as printed and as recorded in the summary JSON.
  struct Mismatch
    include JSON::Serializable

    getter operation : String
    getter seed : UInt64
    getter index : UInt64
    getter list_of_operands : Array(String)
    getter oracle : String
    getter subject : String
    getter reproducer : String?

    def initialize(@operation, @seed, @index, @list_of_operands, @oracle, @subject, @reproducer)
    end
  end

  # The summary a differential run writes.
  struct Summary
    include JSON::Serializable

    getter subject : String
    getter seed : UInt64
    getter first_index : UInt64
    getter count : Int64
    getter max_bits : Int32
    getter list_of_injected : Array(String)
    getter gmp_version : String
    getter crystal_version : String
    getter target : String
    getter operations : Hash(String, OperationTally)
    getter total_count : Int64
    getter total_differences : Int64
    getter total_pending : Int64
    getter elapsed_seconds : Float64
    getter list_of_mismatches : Array(Mismatch)

    def initialize(@subject, @seed, @first_index, @count, @max_bits, @list_of_injected, @operations, @elapsed_seconds, @list_of_mismatches)
      @gmp_version = GMPOracle.version
      @crystal_version = Crystal::VERSION
      @target = {{ flag?(:aarch64) ? "aarch64" : (flag?(:x86_64) ? "x86_64" : "other") }} + "-" + {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : "other") }}
      @total_count = @operations.values.sum(&.count)
      @total_differences = @operations.values.sum(&.differences)
      @total_pending = @operations.values.sum(&.pending)
    end
  end

  # Runs operations `first_index ... first_index + count` of one seed against
  # the subject *T*, operation `index % list_of_operations.size` at each
  # index, each index with its own `Random::PCG32.new(seed, index)` so any
  # one can be replayed alone.
  class DifferentialRun(T)
    MISMATCHES_KEPT = 50

    def initialize(@subject_name : String, @seed : UInt64, @first_index : UInt64, @count : Int64,
                   @list_of_operations : Array(String), @max_bits : Int32,
                   @list_of_injected : Array(String), @reproducer_directory : String?, @output : IO)
    end

    def perform : Summary
      operations = Operations(T).new(@list_of_injected)
      tallies = @list_of_operations.to_h { |name| {name, OperationTally.new} }
      mismatches = [] of Mismatch
      started = Time.instant
      @count.times do |offset|
        index = @first_index + offset.to_u64
        name = @list_of_operations[index % @list_of_operations.size]
        trial = operations.run(name, OperandSource.new(Random::PCG32.new(@seed, index), @max_bits))
        tally = tallies[name]
        tally.count += 1
        tally.pending += 1 if trial.pending?
        tally.oracle_raised += 1 if trial.oracle.kind.raised?
        if trial.difference?
          tally.differences += 1
          mismatch = record_mismatch(trial, index, tally.differences)
          mismatches << mismatch if mismatches.size < MISMATCHES_KEPT
        end
        tallies[name] = tally
      end
      Summary.new(@subject_name, @seed, @first_index, @count, @max_bits, @list_of_injected,
        tallies, (Time.instant - started).total_seconds, mismatches)
    end

    private def record_mismatch(trial : Trial, index : UInt64, ordinal : Int64) : Mismatch
      reproducer = ordinal <= 3 ? write_reproducer(trial.operation, index) : nil
      @output.puts "DIFFERENCE seed=#{@seed} index=#{index} operation=#{trial.operation} max_bits=#{@max_bits}"
      trial.operands.each_with_index { |operand, position| @output.puts "  operand #{position}: #{operand}" }
      @output.puts "  gmp:     #{trial.oracle}"
      @output.puts "  subject: #{trial.subject}"
      @output.puts "  reproducer: #{reproducer}" if reproducer
      Mismatch.new(trial.operation, @seed, index, trial.operands, trial.oracle.to_s, trial.subject.to_s, reproducer)
    end

    # A spec file whose single example replays this one index.
    private def write_reproducer(operation : String, index : UInt64) : String?
      directory = @reproducer_directory
      return nil unless directory
      Dir.mkdir_p(directory)
      path = Path[directory, "#{operation}_#{@seed}_#{index}_spec.cr"].expand
      replay = Path[__DIR__, "replay"].expand.relative_to(path.parent)
      injected = @list_of_injected.includes?(operation) ? ", injected: true" : ""
      File.write(path, %(require "spec"; require "./#{replay}"; it("#{operation} seed=#{@seed} index=#{index}") { G2Harness.replay(#{@subject_name.inspect}, #{operation.inspect}, #{@seed}_u64, #{index}_u64, #{@max_bits}#{injected}).should eq("same") }\n))
      path.to_s
    end
  end
end
