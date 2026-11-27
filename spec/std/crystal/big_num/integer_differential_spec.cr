# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "spec"

# GMP's `BigInt` is the oracle in these examples, and only `-Duse_gmp` keeps
# `BigInt` on GMP; the default build puts it on the engine under test.
{% if flag?(:use_gmp) %}
  require "./integer_oracle"

  describe "Crystal::BigNum::Integer against GMP" do
    it "agrees with BigInt on every G2a operation for random operands" do
      counts, list_of_mismatches = IntegerOracle.run(60_000, 20261127_u64)
      list_of_mismatches.should eq([] of String)
      IntegerOracle::OPERATIONS.each { |operation| counts[operation].should be > 0 }
    end

    it "notices a value that differs from GMP's" do
      value = Crystal::BigNum::Integer.new(1) << 200
      IntegerOracle.same?(value, IntegerOracle.to_big(value)).should be_true
      IntegerOracle.same?(value + 1, IntegerOracle.to_big(value)).should be_false
      IntegerOracle.same?(-value, IntegerOracle.to_big(value)).should be_false
    end
  end
{% else %}
  pending "Crystal::BigNum::Integer against GMP (GMP's BigInt is the oracle: run with -Duse_gmp)"
{% end %}
