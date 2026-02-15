# WASM Garbage Collection Tests
#
# These tests verify that Boehm GC works correctly on the wasm32-wasi target
# with the --spill-pointers post-link transformation. They serve as the
# acceptance criteria for the WASM roadmap's Phase 2 GC support.
#
# Build: bin/crystal build spec/wasm32/gc_spec.cr -o wasm32_gc_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run -W exceptions=y wasm32_gc_spec.wasm

require "spec"

describe "WASM Garbage Collection" do
  describe "basic allocation" do
    it "allocates arrays" do
      arr = [1, 2, 3, 4, 5]
      arr.size.should eq(5)
      arr.sum.should eq(15)
    end

    it "allocates strings" do
      s = "hello, wasm gc!"
      s.size.should eq(15)
      s.should eq("hello, wasm gc!")
    end

    it "allocates hashes" do
      h = {"a" => 1, "b" => 2}
      h["a"].should eq(1)
      h.size.should eq(2)
    end
  end

  describe "multiple allocations" do
    it "handles many small allocations" do
      results = [] of String
      10.times do |i|
        results << "item_#{i}"
      end
      results.size.should eq(10)
      results[0].should eq("item_0")
      results[9].should eq("item_9")
    end

    it "handles string building" do
      s = String.build do |io|
        100.times { |i| io << i << "," }
      end
      s.should contain("0,1,2,")
      s.should contain("99,")
    end
  end

  describe "GC.collect" do
    it "does not crash" do
      GC.collect
    end

    it "can be called multiple times" do
      3.times { GC.collect }
    end

    it "collects after allocations" do
      100.times { |i| _ = "temporary_#{i}" }
      GC.collect
    end
  end

  describe "GC.stats" do
    it "returns valid heap size" do
      stats = GC.stats
      stats.heap_size.should be > 0_u64
    end

    it "returns valid total bytes" do
      stats = GC.stats
      stats.total_bytes.should be > 0_u64
    end

    it "heap grows under allocation pressure" do
      stats_before = GC.stats
      # Create significant allocation pressure
      100.times do |i|
        _ = (0..50).map { |j| "item_#{i}_#{j}" }
      end
      stats_after = GC.stats
      stats_after.total_bytes.should be >= stats_before.total_bytes
    end
  end

  describe "allocation pressure" do
    it "survives moderate pressure" do
      200.times { |i| _ = "hello_#{i}" }
      GC.collect
      stats = GC.stats
      stats.heap_size.should be > 0_u64
    end

    it "survives pressure with periodic collection" do
      100.times do |i|
        arr = (0..10).map { |j| "item_#{i}_#{j}" }
        GC.collect if i % 50 == 0
      end
    end

    it "allocated objects remain accessible" do
      items = [] of String
      50.times do |i|
        items << "persistent_#{i}"
      end
      GC.collect
      items.size.should eq(50)
      items[0].should eq("persistent_0")
      items[49].should eq("persistent_49")
    end
  end

  describe "GC with exceptions" do
    it "handles exception during GC-managed allocation" do
      result = begin
        arr = [1, 2, 3]
        raise "gc exception test"
        "not reached"
      rescue ex
        ex.message
      end
      result.should eq("gc exception test")
    end

    it "GC works after exception handling" do
      begin
        raise "test"
      rescue
      end
      # Allocations should still work
      arr = (0..100).map { |i| "post_exception_#{i}" }
      arr.size.should eq(101)
      GC.collect
    end

    it "allocations in rescue blocks work" do
      result = begin
        raise "error"
      rescue ex
        s = "rescued: #{ex.message}"
        s
      end
      result.should eq("rescued: error")
    end
  end

  describe "GC enable/disable" do
    it "can disable and re-enable GC" do
      GC.disable
      # Allocations still work with GC disabled
      10.times { |i| _ = "disabled_#{i}" }
      GC.enable
      GC.collect
    end
  end
end
