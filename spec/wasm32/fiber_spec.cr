{% skip_file unless flag?(:wasm32) %}

# WASM Fiber tests - verify fiber/concurrency works on WASM via Asyncify

describe "WASM Fibers" do
  it "basic spawn and yield" do
    done = false
    spawn do
      done = true
    end
    Fiber.yield
    done.should be_true
  end

  it "channel send and receive" do
    ch = Channel(Int32).new
    spawn do
      ch.send(42)
    end
    ch.receive.should eq(42)
  end

  it "multiple fibers" do
    results = [] of Int32
    3.times do |i|
      spawn do
        results << i
      end
    end
    3.times { Fiber.yield }
    results.sort.should eq([0, 1, 2])
  end
end
