{% skip_file unless flag?(:wasm32) %}

# WASM Linking tests - verify that library linking and symbol resolution
# work correctly on the wasm32-wasi target.
#
# Build: bin/crystal build spec/wasm32/linking_spec.cr -o wasm32_linking_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run -W exceptions=y wasm32_linking_spec.wasm

require "spec"

describe "WASM Linking" do
  describe "wasi-libc linkage" do
    it "links with wasi-libc successfully" do
      # If we get here without a link error, wasi-libc is linked correctly
      true.should be_true
    end

    it "basic memory allocation via malloc works" do
      ptr = Pointer(Int32).malloc(10)
      ptr[0] = 42
      ptr[0].should eq(42)
    end

    it "can use libc string operations" do
      s = "hello wasm"
      s.size.should eq(10)
      s.includes?("wasm").should be_true
    end
  end

  describe "stack configuration" do
    it "has a usable stack (recursion works)" do
      # Test that we have enough stack space for moderate recursion
      result = recursive_sum(100)
      result.should eq(5050)
    end

    it "handles deep but reasonable recursion" do
      # The linker sets --stack-first -z stack-size=8388608 (8MB)
      # which should handle a few thousand frames
      result = recursive_sum(1000)
      result.should eq(500500)
    end
  end

  describe "Crystal runtime linkage" do
    it "Crystal::VERSION is available" do
      Crystal::VERSION.should_not be_nil
      Crystal::VERSION.size.should be > 0
    end

    it "standard library types work" do
      arr = [1, 2, 3]
      arr.sum.should eq(6)

      hash = {"a" => 1, "b" => 2}
      hash["a"].should eq(1)
    end

    it "string interpolation works" do
      name = "WASM"
      result = "Hello, #{name}!"
      result.should eq("Hello, WASM!")
    end
  end

  describe "WASM-specific memory layout" do
    it "pointers are 32-bit" do
      sizeof(Pointer(Void)).should eq(4)
    end

    it "Int32 is 4 bytes" do
      sizeof(Int32).should eq(4)
    end

    it "Int64 is 8 bytes" do
      sizeof(Int64).should eq(8)
    end
  end

  describe "static data" do
    it "string literals are accessible" do
      s = "static string data"
      s.should eq("static string data")
    end

    it "constant arrays work" do
      arr = StaticArray(Int32, 3).new { |i| i + 1 }
      arr[0].should eq(1)
      arr[1].should eq(2)
      arr[2].should eq(3)
    end
  end
end

private def recursive_sum(n : Int32) : Int32
  return 0 if n <= 0
  n + recursive_sum(n - 1)
end
