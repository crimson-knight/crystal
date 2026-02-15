# WASM Exception Handling Tests — Phase 1 Verification
#
# These tests verify that Crystal's exception handling works correctly
# on the wasm32-wasi target. They serve as the acceptance criteria for
# Phase 1 of the WASM roadmap.
#
# Build: bin/crystal build spec/wasm32/exception_handling_spec.cr -o wasm32_eh_spec.wasm --target wasm32-wasi
# Run:   wasmtime run wasm32_eh_spec.wasm

require "spec"

describe "WASM Exception Handling" do
  describe "basic raise/rescue" do
    it "rescues a raised exception" do
      result = begin
        raise "test error"
        "not reached"
      rescue ex
        ex.message
      end
      result.should eq("test error")
    end

    it "rescues Exception" do
      result = begin
        raise Exception.new("hello from wasm")
        "not reached"
      rescue ex : Exception
        ex.message
      end
      result.should eq("hello from wasm")
    end

    it "does not enter rescue when no exception is raised" do
      rescued = false
      begin
        x = 1 + 2
      rescue
        rescued = true
      end
      rescued.should be_false
    end
  end

  describe "type dispatch" do
    it "dispatches to the correct rescue clause by type" do
      result = begin
        raise ArgumentError.new("bad arg")
      rescue ex : IndexError
        "index"
      rescue ex : ArgumentError
        "argument: #{ex.message}"
      rescue ex : Exception
        "generic"
      end
      result.should eq("argument: bad arg")
    end

    it "falls through to generic rescue when no type matches" do
      result = begin
        raise Exception.new("generic error")
      rescue ex : ArgumentError
        "argument"
      rescue ex : IndexError
        "index"
      rescue ex
        "generic: #{ex.message}"
      end
      result.should eq("generic: generic error")
    end

    it "handles DivisionByZeroError" do
      result = begin
        1 // 0
        "not reached"
      rescue ex : DivisionByZeroError
        "caught division by zero"
      end
      result.should eq("caught division by zero")
    end
  end

  describe "ensure blocks" do
    it "executes ensure after normal flow" do
      ensured = false
      begin
        x = 1
      ensure
        ensured = true
      end
      ensured.should be_true
    end

    it "executes ensure after exception" do
      ensured = false
      begin
        raise "error"
      rescue
        # caught
      ensure
        ensured = true
      end
      ensured.should be_true
    end

    it "executes ensure even when exception is not rescued" do
      ensured = false
      begin
        begin
          raise "error"
        ensure
          ensured = true
        end
      rescue
        # outer rescue
      end
      ensured.should be_true
    end
  end

  describe "nested exceptions" do
    it "handles nested begin/rescue" do
      result = begin
        begin
          raise "inner"
        rescue ex
          "inner caught: #{ex.message}"
        end
      rescue ex
        "outer caught: #{ex.message}"
      end
      result.should eq("inner caught: inner")
    end

    it "propagates exception from rescue block to outer handler" do
      result = begin
        begin
          raise "first"
        rescue
          raise "second"
        end
      rescue ex
        ex.message
      end
      result.should eq("second")
    end
  end

  describe "re-raise" do
    it "re-raises an exception" do
      result = begin
        begin
          raise "original"
        rescue ex
          raise ex
        end
      rescue ex
        ex.message
      end
      result.should eq("original")
    end

    it "re-raises with raise without argument" do
      result = begin
        begin
          raise "test"
        rescue
          raise
        end
      rescue ex
        ex.message
      end
      result.should eq("test")
    end
  end

  describe "overflow errors" do
    it "catches OverflowError on integer overflow" do
      result = begin
        x = Int32::MAX
        x + 1
        "not reached"
      rescue ex : OverflowError
        "overflow caught"
      end
      result.should eq("overflow caught")
    end
  end

  describe "nil assertion" do
    it "catches NilAssertionError" do
      result = begin
        x : String? = nil
        x.not_nil!
        "not reached"
      rescue ex : NilAssertionError
        "nil assertion caught"
      end
      result.should eq("nil assertion caught")
    end
  end

  describe "type cast" do
    it "catches TypeCastError" do
      result = begin
        x : Int32 | String = "hello"
        x.as(Int32)
        "not reached"
      rescue ex : TypeCastError
        "type cast caught"
      end
      result.should eq("type cast caught")
    end
  end
end
