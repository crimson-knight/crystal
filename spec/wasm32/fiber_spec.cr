# WASM Fiber/Concurrency Tests
#
# These tests verify that cooperative fiber switching works correctly on the
# wasm32-wasi target using Binaryen's Asyncify pass. They serve as the
# acceptance criteria for the WASM roadmap's Phase 3 Fiber support.
#
# Build: bin/crystal build spec/wasm32/fiber_spec.cr -o wasm32_fiber_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run -W exceptions=y wasm32_fiber_spec.wasm

require "spec"

describe "WASM Fiber/Concurrency" do
  describe "basic spawn and yield" do
    it "spawns a fiber and yields to it" do
      counter = 0
      spawn { counter = 42 }
      Fiber.yield
      counter.should eq(42)
    end

    it "yields back to main fiber" do
      order = [] of Int32
      order << 1
      spawn do
        order << 2
      end
      Fiber.yield
      order << 3
      order.should eq([1, 2, 3])
    end
  end

  describe "multiple fibers" do
    it "runs two fibers interleaved" do
      results = [] of Int32

      spawn do
        results << 1
        Fiber.yield
        results << 3
      end

      spawn do
        results << 2
        Fiber.yield
        results << 4
      end

      4.times { Fiber.yield }

      results.should eq([1, 2, 3, 4])
    end

    it "handles multiple yields per fiber" do
      counter = 0

      spawn do
        counter += 1 # 1
        Fiber.yield
        counter += 10 # 11
        Fiber.yield
        counter += 100 # 111
      end

      3.times { Fiber.yield }
      Fiber.yield # extra yield for cleanup

      counter.should eq(111)
    end
  end

  describe "stress test" do
    it "runs many fibers" do
      n = 10
      results = Array(Int32).new(n, 0)

      n.times do |i|
        spawn do
          results[i] += 1
          Fiber.yield
          results[i] += 1
          Fiber.yield
          results[i] += 1
        end
      end

      (n * 4).times { Fiber.yield }

      results.all? { |v| v == 3 }.should be_true
    end
  end

  describe "channels" do
    it "sends and receives on unbuffered channel" do
      ch = Channel(Int32).new
      spawn { ch.send(42) }
      ch.receive.should eq(42)
    end

    it "sends and receives on buffered channel" do
      ch = Channel(Int32).new(1)
      spawn do
        ch.send(42)
        ch.send(100)
      end
      ch.receive.should eq(42)
      ch.receive.should eq(100)
    end

    # NOTE: Unbuffered channel with multiple sequential sends/receives
    # currently deadlocks due to a scheduler limitation in the WASM
    # cooperative fiber switching model. This will be addressed in a
    # future scheduler improvement.
  end

  describe "fibers with exceptions" do
    it "handles exceptions in spawned fibers" do
      result = ""
      spawn do
        begin
          raise "fiber error"
        rescue ex
          result = ex.message || ""
        end
      end
      Fiber.yield
      Fiber.yield
      result.should eq("fiber error")
    end

    it "exceptions in one fiber don't affect others" do
      results = [] of String

      spawn do
        begin
          raise "boom"
        rescue
          results << "caught"
        end
      end

      spawn do
        results << "ok"
      end

      3.times { Fiber.yield }

      results.should contain("caught")
      results.should contain("ok")
    end
  end

  describe "fibers with GC" do
    it "GC works across fiber switches" do
      results = [] of String

      spawn do
        10.times { |i| results << "item_#{i}" }
        GC.collect
      end

      Fiber.yield
      Fiber.yield

      results.size.should eq(10)
      results[0].should eq("item_0")
    end

    # NOTE: GC.collect combined with channel send/Fiber.yield in spawned
    # fibers can cause data corruption due to incomplete stack scanning
    # of asyncify shadow stacks. This will be addressed when precise
    # GC root tracking is implemented for WASM fibers.
  end
end
