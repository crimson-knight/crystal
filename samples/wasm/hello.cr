# Crystal WASM Hello World
#
# Compile:
#   crystal build samples/wasm/hello.cr -o hello.wasm \
#     --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
#
# Run (CLI):
#   wasmtime run -W exceptions=y hello.wasm
#
# Run (Browser):
#   See samples/wasm/index.html

puts "Hello from Crystal WASM!"
puts "Crystal version: #{Crystal::VERSION}"
puts "Target: wasm32-wasi"
puts "Math: 1 + 1 = #{1 + 1}"
puts "Strings: #{"Hello" + " " + "World"}"

# Exception handling works via native WASM EH instructions
begin
  raise "test exception from WASM"
rescue ex
  puts "Caught: #{ex.message}"
end

# Complex data structures work
arr = [10, 20, 30, 40, 50]
puts "Array sum: #{arr.sum}"
puts "Array map: #{arr.map { |x| x * 2 }}"

# Hash works
h = {"name" => "Crystal", "target" => "wasm32"}
puts "Hash: #{h}"

# Regex works (PCRE2 compiled for WASM)
if "hello world" =~ /(\w+)\s(\w+)/
  puts "Regex match: #{$1}, #{$2}"
end

# GC works (Boehm GC compiled for WASM)
items = Array(String).new
100.times { |i| items << "item_#{i}" }
GC.collect
puts "GC ok, #{items.size} items survived collection"

puts "All systems go!"
