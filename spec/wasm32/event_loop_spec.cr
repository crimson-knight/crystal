{% skip_file unless flag?(:wasm32) %}

# WASM Event Loop tests - verify that the poll-based event loop
# operates correctly on the wasm32-wasi target.
#
# Build: bin/crystal build spec/wasm32/event_loop_spec.cr -o wasm32_event_loop_spec.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run wasm32_event_loop_spec.wasm

require "spec"

describe "WASM Event Loop" do
  describe "timer support" do
    it "sleep with zero duration does not hang" do
      # A zero-duration sleep should yield and return immediately
      sleep 0
    end

    it "sleep with small duration returns" do
      # Verify the event loop can handle a basic timed sleep
      sleep 0.001
    end
  end

  describe "Fiber.yield integration" do
    it "yield returns control and allows resumption" do
      executed = false
      fiber = Fiber.new("event-loop-test") do
        Fiber.yield
        executed = true
      end
      fiber.resume
      executed.should be_false
      fiber.resume
      executed.should be_true
    end
  end

  describe "cooperative scheduling" do
    it "fibers run cooperatively through the event loop" do
      order = [] of Int32
      f1 = Fiber.new("coop-1") do
        order << 1
        Fiber.yield
        order << 3
      end
      f2 = Fiber.new("coop-2") do
        order << 2
        Fiber.yield
        order << 4
      end

      f1.resume
      f2.resume
      f1.resume
      f2.resume

      order.should eq([1, 2, 3, 4])
    end

    it "many fibers can be scheduled without deadlock" do
      count = Atomic(Int32).new(0)
      fibers = Array(Fiber).new(10) do |i|
        Fiber.new("worker-#{i}") do
          count.add(1)
        end
      end
      fibers.each(&.resume)
      count.get.should eq(10)
    end
  end

  describe "event loop does not crash on idle" do
    it "can call Fiber.yield without pending events" do
      Fiber.yield
    end
  end
end
