require "primitives"

# A loop LLVM vectorizes when the target has SIMD: scale and offset a Float32 buffer.
fun scale_buffer(dst : Float32*, src : Float32*, count : Int32) : Void
  index = 0
  while index < count
    (dst + index).value = (src + index).value * 2.0_f32 + 1.0_f32
    index &+= 1
  end
end
