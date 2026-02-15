# WASM Exception Handling Tests
#
# These tests verify that Crystal's exception handling works correctly
# on the wasm32-wasi target. They serve as the acceptance criteria for
# the WASM roadmap's exception handling support.
#
# Build: bin/crystal build spec/wasm32/exception_handling_spec.cr -o wasm32_eh_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run wasm32_eh_spec.wasm

require "spec"

# Custom exception class for testing user-defined exceptions
private class WasmTestError < Exception
  getter code : Int32

  def initialize(message : String, @code : Int32 = 0)
    super(message)
  end
end

# Another custom exception inheriting from a non-Exception base
private class WasmIOError < IO::Error
end

# Helper methods for testing method-level exception handling
private def method_that_raises(msg : String) : String
  raise msg
  "not reached"
end

private def method_with_rescue : String
  method_that_raises("from method")
rescue ex
  "rescued: #{ex.message}"
end

private def method_with_ensure(log : Array(String)) : String
  log << "body"
  raise "ensure test"
rescue ex
  log << "rescue"
  "rescued"
ensure
  log << "ensure"
end

private def deeply_nested_raise(depth : Int32) : String
  if depth <= 0
    raise "bottom"
  end
  deeply_nested_raise(depth - 1)
end

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

  describe "method-level exceptions" do
    it "rescues exception raised in a called method" do
      result = begin
        method_that_raises("test")
      rescue ex
        ex.message
      end
      result.should eq("test")
    end

    it "rescue inside a method works" do
      method_with_rescue.should eq("rescued: from method")
    end

    it "ensure runs in method context" do
      log = [] of String
      method_with_ensure(log).should eq("rescued")
      log.should eq(["body", "rescue", "ensure"])
    end
  end

  describe "custom exception classes" do
    it "catches a custom exception by type" do
      result = begin
        raise WasmTestError.new("custom", code: 42)
      rescue ex : WasmTestError
        "code=#{ex.code} msg=#{ex.message}"
      end
      result.should eq("code=42 msg=custom")
    end

    it "custom exception is caught by parent type" do
      result = begin
        raise WasmTestError.new("child")
      rescue ex : Exception
        "parent caught: #{ex.message}"
      end
      result.should eq("parent caught: child")
    end

    it "catches IO::Error subclass" do
      result = begin
        raise WasmIOError.new("io fail")
      rescue ex : IO::Error
        "io: #{ex.message}"
      end
      result.should eq("io: io fail")
    end
  end

  describe "exception in closures and blocks" do
    it "rescues exception raised inside a block" do
      result = begin
        [1, 2, 3].each do |i|
          raise "block error at #{i}" if i == 2
        end
        "not reached"
      rescue ex
        ex.message
      end
      result.should eq("block error at 2")
    end

    it "ensure runs when exception is raised in block" do
      ensured = false
      begin
        begin
          [1].each { |_| raise "in block" }
        ensure
          ensured = true
        end
      rescue
      end
      ensured.should be_true
    end

    it "rescues exception from a proc call" do
      p = ->{ raise "proc error"; 0 }
      result = begin
        p.call
        "not reached"
      rescue ex
        ex.message
      end
      result.should eq("proc error")
    end
  end

  describe "deeply nested exception propagation" do
    it "propagates through multiple call frames" do
      result = begin
        deeply_nested_raise(10)
      rescue ex
        ex.message
      end
      result.should eq("bottom")
    end

    it "propagates through deeply nested begin/rescue" do
      result = begin
        begin
          begin
            begin
              raise "deep"
            rescue ex : ArgumentError
              "wrong type"
            end
          rescue ex : IndexError
            "wrong type 2"
          end
        rescue ex
          ex.message
        end
      end
      result.should eq("deep")
    end
  end

  describe "ensure ordering with multiple handlers" do
    it "runs ensure blocks in correct LIFO order" do
      log = [] of String
      begin
        begin
          begin
            raise "test"
          ensure
            log << "inner"
          end
        ensure
          log << "middle"
        end
      rescue
      ensure
        log << "outer"
      end
      log.should eq(["inner", "middle", "outer"])
    end

    it "ensure runs even when rescue re-raises" do
      log = [] of String
      begin
        begin
          raise "original"
        rescue
          log << "rescue"
          raise "re-raised"
        ensure
          log << "ensure"
        end
      rescue ex
        log << "outer: #{ex.message}"
      end
      log.should eq(["rescue", "ensure", "outer: re-raised"])
    end
  end

  describe "exception message and inspect" do
    it "preserves exception message through rescue" do
      msg = "a" * 100
      result = begin
        raise msg
      rescue ex
        ex.message
      end
      result.should eq(msg)
    end

    it "exception class name is correct" do
      result = begin
        raise ArgumentError.new("test")
      rescue ex
        ex.class.name
      end
      result.should eq("ArgumentError")
    end
  end

  describe "index out of bounds" do
    it "catches IndexError on array access" do
      result = begin
        arr = [1, 2, 3]
        arr[10]
        "not reached"
      rescue ex : IndexError
        "index error caught"
      end
      result.should eq("index error caught")
    end
  end

  describe "KeyError" do
    it "catches KeyError on missing hash key" do
      result = begin
        h = {"a" => 1}
        h["b"]
        "not reached"
      rescue ex : KeyError
        "key error caught"
      end
      result.should eq("key error caught")
    end
  end
end
