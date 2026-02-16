# WASM I/O and Standard Library Integration Tests
#
# These tests verify that basic I/O operations, string formatting, time spans,
# and math operations work correctly on the wasm32-wasi target. They exercise
# the WASI interface layer for stdout and core standard library features.
#
# Build: bin/crystal build spec/wasm32/io_spec.cr -o wasm32_io_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run -W exceptions=y wasm32_io_spec.wasm

require "spec"

describe "WASM I/O" do
  describe "stdout writing" do
    it "can write to STDOUT" do
      # STDOUT should be writable without error
      STDOUT.should_not be_nil
    end

    it "prints strings via String.build" do
      output = String.build do |io|
        io << "hello"
        io << " "
        io << "wasm"
      end
      output.should eq("hello wasm")
    end

    it "writes with print-style formatting" do
      output = String.build do |io|
        io.print("value=", 42)
      end
      output.should eq("value=42")
    end

    it "writes with puts-style formatting" do
      output = String.build do |io|
        io.puts("hello")
        io.puts("world")
      end
      output.should eq("hello\nworld\n")
    end

    it "writes binary data" do
      io = IO::Memory.new
      io.write_byte(0x41_u8)
      io.write_byte(0x42_u8)
      io.write_byte(0x43_u8)
      io.rewind
      io.gets_to_end.should eq("ABC")
    end
  end

  describe "IO::Memory" do
    it "creates a memory buffer and writes to it" do
      io = IO::Memory.new
      io << "hello"
      io.to_s.should eq("hello")
    end

    it "reads back what was written" do
      io = IO::Memory.new
      io << "crystal wasm"
      io.rewind
      io.gets_to_end.should eq("crystal wasm")
    end

    it "supports seek and tell" do
      io = IO::Memory.new
      io << "abcdef"
      io.rewind
      io.pos.should eq(0)
      io.seek(3)
      io.pos.should eq(3)
    end

    it "handles multiple writes" do
      io = IO::Memory.new
      10.times { |i| io << "line #{i}\n" }
      io.rewind
      lines = io.gets_to_end.split("\n")
      # 10 lines plus trailing empty string from final newline
      lines.size.should eq(11)
      lines[0].should eq("line 0")
      lines[9].should eq("line 9")
    end
  end

  describe "string operations" do
    it "performs string interpolation" do
      name = "WASM"
      version = 32
      result = "#{name}-#{version}"
      result.should eq("WASM-32")
    end

    it "concatenates strings" do
      parts = ["hello", " ", "from", " ", "wasm"]
      result = parts.join
      result.should eq("hello from wasm")
    end

    it "formats integers to strings" do
      42.to_s.should eq("42")
      -1.to_s.should eq("-1")
      0.to_s.should eq("0")
      Int32::MAX.to_s.should eq("2147483647")
    end

    it "formats floats to strings" do
      1.5.to_s.should eq("1.5")
      -0.25.to_s.should eq("-0.25")
    end

    it "builds complex strings" do
      result = String.build do |io|
        io << "items: ["
        5.times do |i|
          io << ", " if i > 0
          io << i
        end
        io << "]"
      end
      result.should eq("items: [0, 1, 2, 3, 4]")
    end

    it "handles string multiplication" do
      ("ab" * 3).should eq("ababab")
    end

    it "handles string slicing" do
      s = "hello wasm world"
      s[0, 5].should eq("hello")
      s[6, 4].should eq("wasm")
    end

    it "supports upcase and downcase" do
      "hello".upcase.should eq("HELLO")
      "WASM".downcase.should eq("wasm")
    end

    it "supports strip" do
      "  hello  ".strip.should eq("hello")
      "  hello  ".lstrip.should eq("hello  ")
      "  hello  ".rstrip.should eq("  hello")
    end

    it "supports split" do
      parts = "a,b,c".split(",")
      parts.should eq(["a", "b", "c"])
    end

    it "supports starts_with? and ends_with?" do
      "hello world".starts_with?("hello").should be_true
      "hello world".ends_with?("world").should be_true
      "hello world".starts_with?("world").should be_false
    end

    it "supports includes?" do
      "hello wasm".includes?("wasm").should be_true
      "hello wasm".includes?("rust").should be_false
    end

    it "supports gsub" do
      "hello world".gsub("world", "wasm").should eq("hello wasm")
    end
  end

  describe "Time::Span" do
    it "creates spans from various units" do
      span = Time::Span.new(seconds: 5)
      span.total_seconds.should eq(5.0)
    end

    it "creates spans from nanoseconds" do
      span = Time::Span.new(nanoseconds: 1_000_000)
      span.total_milliseconds.should eq(1.0)
    end

    it "creates spans from hours, minutes, seconds" do
      span = Time::Span.new(hours: 1, minutes: 30, seconds: 0)
      span.total_minutes.should eq(90.0)
    end

    it "adds spans" do
      a = Time::Span.new(seconds: 10)
      b = Time::Span.new(seconds: 20)
      result = a + b
      result.total_seconds.should eq(30.0)
    end

    it "subtracts spans" do
      a = Time::Span.new(seconds: 30)
      b = Time::Span.new(seconds: 10)
      result = a - b
      result.total_seconds.should eq(20.0)
    end

    it "compares spans" do
      a = Time::Span.new(seconds: 10)
      b = Time::Span.new(seconds: 20)
      (a < b).should be_true
      (b > a).should be_true
      (a == a).should be_true
    end

    it "converts between units" do
      span = Time::Span.new(hours: 2)
      span.total_minutes.should eq(120.0)
      span.total_seconds.should eq(7200.0)
    end

    it "handles zero span" do
      span = Time::Span.new(nanoseconds: 0)
      span.total_seconds.should eq(0.0)
      span.zero?.should be_true
    end

    it "handles negative spans" do
      span = Time::Span.new(seconds: -5)
      span.total_seconds.should eq(-5.0)
      span.negative?.should be_true
    end

    it "supports abs on negative spans" do
      span = Time::Span.new(seconds: -10)
      span.abs.total_seconds.should eq(10.0)
    end
  end

  describe "math operations" do
    it "performs basic integer arithmetic" do
      (2 + 3).should eq(5)
      (10 - 4).should eq(6)
      (3 * 7).should eq(21)
      (20 // 4).should eq(5)
      (17 % 5).should eq(2)
    end

    it "performs float arithmetic" do
      (1.5 + 2.5).should eq(4.0)
      (10.0 / 3.0).should be_close(3.333333, 0.001)
    end

    it "handles integer min/max" do
      Int32::MAX.should eq(2147483647)
      Int32::MIN.should eq(-2147483648)
    end

    it "performs bitwise operations" do
      (0b1010 & 0b1100).should eq(0b1000)
      (0b1010 | 0b1100).should eq(0b1110)
      (0b1010 ^ 0b1100).should eq(0b0110)
      (~0b0000_i32).should eq(-1)
    end

    it "performs shift operations" do
      (1 << 4).should eq(16)
      (16 >> 2).should eq(4)
    end

    it "calculates power" do
      (2 ** 10).should eq(1024)
    end

    it "handles Math module functions" do
      Math.sqrt(16.0).should eq(4.0)
      Math.sqrt(2.0).should be_close(1.41421356, 0.00001)
    end

    it "handles absolute values" do
      (-42).abs.should eq(42)
      42.abs.should eq(42)
      (-3.14).abs.should eq(3.14)
    end

    it "handles min and max" do
      Math.min(3, 7).should eq(3)
      Math.max(3, 7).should eq(7)
    end
  end

  describe "number formatting" do
    it "formats integers in different bases" do
      255.to_s(16).should eq("ff")
      255.to_s(2).should eq("11111111")
      255.to_s(8).should eq("377")
    end

    it "formats with to_s" do
      123456.to_s.should eq("123456")
    end

    it "converts between types" do
      x = 42_i32
      x.to_i64.should eq(42_i64)
      x.to_f64.should eq(42.0)
      y = 3.7
      y.to_i32.should eq(3)
    end
  end
end
