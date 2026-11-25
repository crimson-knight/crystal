# Touches the standard library modules a typical wasm32-wasi program uses, so
# a 32-bit build reports any warning raised inside them (for example a
# `Pointer.new` call that receives a 32-bit `LibC::SizeT`).
require "json"
require "yaml"
require "uri"
require "base64"
require "string_scanner"
require "log"
require "csv"
require "set"

puts "a1b22".scan(/\d+/).size
puts "a1b22".gsub(/\d/) { |digit| digit * 2 }
puts "x=%05.2f %s %x %e %-6s|" % {3.14159, :ok, 255, 1.5e10, "pad"}
puts 1.23456789.round(3), 12345678901234_i64.format, Int32::MAX.to_s(16), "42".to_i

scores = {"a" => 1, "b" => 2}
puts scores.to_json, scores.to_yaml, scores.select { |_, score| score > 1 }
puts JSON.parse(%({"k": [1, 2]}))["k"].size
puts YAML.parse("k: [1, 2]")["k"].size

io = IO::Memory.new
io << "bytes" << 42
io.write_bytes(7_u32, IO::ByteFormat::LittleEndian)
puts io.to_s.bytesize
puts String.build { |builder| builder << 1 << 'c' << 2.5 }

puts Time.utc(2026, 11, 24).to_s("%Y-%m-%d"), Time.utc.to_unix, Time::Span.new(seconds: 3)
puts URI.parse("http://example.com/path?q=1").query_params["q"]
puts Base64.strict_encode("hi"), StringScanner.new("abc 12").scan(/\w+/)
puts CSV.parse("a,b\n1,2").size
puts Set{1, 2, 3}.size, [3, 1, 2].sort.join, Deque{1, 2}.shift, Path["a/b"].join("c")
puts "héllo".upcase, "héllo".to_slice.hexstring, Random.new(1).rand(10)
Log.info { "log" }

pointer_cell = Atomic(Pointer(UInt8)).new(Pointer(UInt8).null)
puts pointer_cell.swap(Pointer(UInt8).null).address
puts pointer_cell.max(Pointer(UInt8).null).address, pointer_cell.min(Pointer(UInt8).null).address
reference_cell = Atomic(String?).new(nil)
reference_cell.swap("x")
reference_cell.compare_and_set("x", "y")
counter = Atomic(Int32).new(0)
counter.add(1)

channel = Channel(Int32).new(1)
mutex = Mutex.new
spawn { mutex.synchronize { channel.send(1) } }
puts channel.receive
Fiber.yield
