{% skip_file unless flag?(:wasm32) %}

# WASM GC tests - verify garbage collection works on WASM
# These tests verify that memory is managed correctly when
# Boehm GC is available on the WASM target.

describe "WASM GC" do
  it "handles sustained allocation without OOM" do
    # Allocate many small objects - GC should collect them
    1000.times do
      s = "hello" * 20
      s.size.should eq(100)
    end
  end

  it "collects unreferenced objects" do
    # Create objects that become unreferenced
    10.times do
      arr = Array(String).new
      100.times { arr << "test string" }
    end
    # If GC works, we shouldn't run out of memory
  end

  it "GC.collect does not crash" do
    GC.collect
  end
end
