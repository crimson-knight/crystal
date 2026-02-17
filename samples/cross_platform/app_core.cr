# Crystal Cross-Platform Demo - Shared Core
#
# This file compiles for ALL targets with --prelude=empty:
#   macOS, iOS (device + simulator), Android, WASM, Linux
#
# It exports pure C-compatible functions that platform-specific
# shells (AppKit, UIKit, JNI) call into.

fun __crystal_raise_overflow : NoReturn
  while true
  end
end

# Platform detection at compile time
@[NoInline]
fun crystal_get_platform_id : Int32
  {% if flag?(:macos) %}
    1 # macOS
  {% elsif flag?(:ios) %}
    2 # iOS
  {% elsif flag?(:android) %}
    3 # Android
  {% elsif flag?(:wasm32) %}
    4 # WASM
  {% elsif flag?(:linux) %}
    5 # Linux
  {% else %}
    0 # Unknown
  {% end %}
end

@[NoInline]
fun crystal_add(a : Int32, b : Int32) : Int32
  a &+ b
end

@[NoInline]
fun crystal_multiply(a : Int32, b : Int32) : Int32
  a &* b
end

@[NoInline]
fun crystal_fibonacci(n : Int32) : Int64
  return n.to_i64 if n <= 1
  a = 0_i64
  b = 1_i64
  i = 2
  while i <= n
    c = a &+ b
    a = b
    b = c
    i = i &+ 1
  end
  b
end

@[NoInline]
fun crystal_factorial(n : Int32) : Int64
  result = 1_i64
  i = 2
  while i <= n
    result = result &* i.to_i64
    i = i &+ 1
  end
  result
end

# Power function (works with empty prelude)
@[NoInline]
fun crystal_power(base : Int32, exp : Int32) : Int64
  result = 1_i64
  b = base.to_i64
  i = 0
  while i < exp
    result = result &* b
    i = i &+ 1
  end
  result
end
