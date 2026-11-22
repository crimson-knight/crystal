require "./lib_llvm"

{% unless LibLLVM::IS_LT_150 %}
  # The BLAKE3 hash function that LLVM ships (LLVM 15 and later): a
  # cryptographic hash with a 256-bit result.
  #
  # ```
  # hasher = LLVM::Blake3.new
  # hasher.update("abc".to_slice)
  # hasher.hexfinal # => "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
  # ```
  class LLVM::Blake3
    def initialize
      @hasher = uninitialized LibLLVM::Blake3Hasher
      LibLLVM.blake3_hasher_init(pointerof(@hasher))
    end

    # Adds *data* to the hashed content.
    def update(data : Bytes) : self
      LibLLVM.blake3_hasher_update(pointerof(@hasher), data.to_unsafe.as(Void*), data.size)
      self
    end

    # The hash of everything added so far, as 64 lowercase hexadecimal digits.
    def hexfinal : String
      digest = uninitialized UInt8[LibLLVM::BLAKE3_OUT_LEN]
      LibLLVM.blake3_hasher_finalize(pointerof(@hasher), digest.to_unsafe, digest.size)
      digest.to_slice.hexstring
    end

    # The hash of *data*, as 64 lowercase hexadecimal digits.
    def self.hexdigest(data : Bytes) : String
      new.update(data).hexfinal
    end
  end
{% end %}
