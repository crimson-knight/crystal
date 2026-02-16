# WASM Standalone Fiber Test
#
# This is a standalone program (NOT a spec) that tests fiber spawning, yielding,
# and clean exit on the wasm32-wasi target. It exercises the fiber stack overflow
# fix by running a complete fiber lifecycle without the spec framework.
#
# Build: bin/crystal build spec/wasm32/standalone_fiber_test.cr -o wasm32_fiber_test.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# Run:   wasmtime run -W exceptions=y wasm32_fiber_test.wasm
#
# Expected output:
#   [main] starting
#   [main] spawned fiber
#   [fiber] running
#   [fiber] yielded back
#   [fiber] done
#   [main] after yields
#   [main] counter = 3
#   PASS: standalone fiber test

counter = 0
errors = [] of String

puts "[main] starting"

spawn do
  puts "[fiber] running"
  counter += 1
  Fiber.yield

  puts "[fiber] yielded back"
  counter += 1
  Fiber.yield

  puts "[fiber] done"
  counter += 1
end

puts "[main] spawned fiber"

# Yield enough times for the fiber to complete all its stages
5.times { Fiber.yield }

puts "[main] after yields"
puts "[main] counter = #{counter}"

# Verify results
if counter != 3
  errors << "expected counter to be 3, got #{counter}"
end

# Test multiple fibers interleaving
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

5.times { Fiber.yield }

if results != [1, 2, 3, 4]
  errors << "expected [1, 2, 3, 4], got #{results}"
end

# Test fiber with exception handling
exception_caught = false

spawn do
  begin
    raise "fiber exception"
  rescue ex
    exception_caught = true
  end
end

3.times { Fiber.yield }

unless exception_caught
  errors << "exception in fiber was not caught"
end

# Report results
if errors.empty?
  puts "PASS: standalone fiber test"
else
  errors.each { |e| puts "FAIL: #{e}" }
  exit 1
end
