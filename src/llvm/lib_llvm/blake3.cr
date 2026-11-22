require "./config"

{% unless LibLLVM::IS_LT_150 %}
  lib LibLLVM
    BLAKE3_OUT_LEN = 32

    # `llvm_blake3_hasher` of `llvm-c/blake3.h`: 1,912 bytes aligned to 8.
    # The hasher is only ever used through a pointer, so a little room to
    # spare costs nothing.
    struct Blake3Hasher
      state : UInt64[256]
    end

    fun blake3_hasher_init = llvm_blake3_hasher_init(hasher : Blake3Hasher*)
    fun blake3_hasher_update = llvm_blake3_hasher_update(hasher : Blake3Hasher*, input : Void*, input_len : LibC::SizeT)
    fun blake3_hasher_finalize = llvm_blake3_hasher_finalize(hasher : Blake3Hasher*, output : UInt8*, output_len : LibC::SizeT)
  end
{% end %}
