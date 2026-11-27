# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"

# GMP's `BigInt` is the oracle in these examples, and only `-Duse_gmp` keeps
# `BigInt` on GMP; the default build puts it on the engine under test.
{% if flag?(:use_gmp) %}
  require "../../../../scripts/big_num/harness/subject"
  require "../../../../scripts/big_num/harness/differential_run"
  require "../../../../scripts/big_num/harness/replay"

  private def run_double(operations : Array(String), count : Int64, plant : String? = nil, injected = [] of String) : G2Harness::Summary
    G2Harness::ReferenceDouble.plant = plant
    G2Harness::DifferentialRun(G2Harness::ReferenceDouble).new("double", 20_261_127_u64, 0_u64, count, operations,
      8_192, injected, nil, IO::Memory.new).perform
  ensure
    G2Harness::ReferenceDouble.plant = nil
  end

  describe "BigNum differential harness" do
    it "reports no difference when the subject is GMP itself" do
      summary = run_double(G2Harness::Operations::LIST_OF_NAMES, 6_600)
      summary.total_differences.should eq(0)
      summary.total_pending.should eq(0)
      summary.total_count.should eq(6_600)
    end

    it "flags a planted wrong answer in every operation class" do
      G2Harness::Operations::LIST_OF_NAMES.each do |operation|
        summary = run_double([operation], 60, plant: operation)
        summary.operations[operation].differences.should be > 0, failure_message: "#{operation}: planted bug not flagged"
      end
    end

    it "flags the fault injector's near miss in every operation class" do
      G2Harness::Operations::LIST_OF_NAMES.each do |operation|
        summary = run_double([operation], 20, injected: [operation])
        summary.operations[operation].differences.should eq(20), failure_message: "#{operation}: injected near miss not flagged"
      end
    end

    it "replays one index exactly" do
      G2Harness.replay("double", "mul", 7_u64, 123_u64, 8_192).should eq("same")
      G2Harness.replay("double", "mul", 7_u64, 123_u64, 8_192, injected: true).should contain("subject:")
    end

    it "counts a stub (NotImplementedError) as pending, never as a pass or a difference" do
      oracle = G2Harness::Observe.of(BigInt.new(5))
      stub = G2Harness::Observation.pending("Crystal::BigNum::Integer#isqrt (G2e)")
      trial = G2Harness::Trial.new("isqrt", oracle, stub, ["5"])
      trial.pending?.should be_true
      trial.difference?.should be_false
    end
  end
{% else %}
  pending "the BigNum differential harness (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
