require "digest/digest"

# Implements the SHA-256 digest algorithm (FIPS 180-4) without OpenSSL.
#
# The compiler uses it to check the SHA-256 of the external tools it runs
# (see the wasm32 post-link step), so it works where no OpenSSL is linked.
# Programs should use `Digest::SHA256`, which is faster.
class Crystal::Digest::SHA256 < ::Digest
  extend ::Digest::ClassMethods

  private ROUND_CONSTANTS = StaticArray[
    0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32, 0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
    0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32, 0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
    0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32, 0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
    0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32, 0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
    0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32, 0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
    0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32, 0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
    0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32, 0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
    0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32, 0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
  ]

  # The working variables a to h keep the names FIPS 180-4 gives them.
  @hash_state = uninitialized UInt32[8]
  @message_block = StaticArray(UInt8, 64).new(0_u8)
  @message_block_index = 0
  @message_bit_length = 0_u64

  def initialize
    reset
  end

  private def reset_impl : Nil
    @message_block_index = 0
    @message_bit_length = 0_u64
    @hash_state[0] = 0x6a09e667_u32
    @hash_state[1] = 0xbb67ae85_u32
    @hash_state[2] = 0x3c6ef372_u32
    @hash_state[3] = 0xa54ff53a_u32
    @hash_state[4] = 0x510e527f_u32
    @hash_state[5] = 0x9b05688c_u32
    @hash_state[6] = 0x1f83d9ab_u32
    @hash_state[7] = 0x5be0cd19_u32
  end

  private def update_impl(data : Bytes) : Nil
    data.each do |byte|
      @message_block[@message_block_index] = byte
      @message_block_index += 1
      @message_bit_length &+= 8
      process_message_block if @message_block_index == 64
    end
  end

  private def final_impl(dst : Bytes) : Nil
    pad_message
    8.times do |word_index|
      word = @hash_state[word_index]
      4.times do |byte_index|
        dst[word_index * 4 + byte_index] = (word >> (8 * (3 - byte_index))).to_u8!
      end
    end
  end

  private def process_message_block : Nil
    schedule = uninitialized UInt32[64]

    16.times do |round|
      schedule[round] = (@message_block[round * 4].to_u32 << 24) |
                        (@message_block[round * 4 + 1].to_u32 << 16) |
                        (@message_block[round * 4 + 2].to_u32 << 8) |
                        @message_block[round * 4 + 3].to_u32
    end

    (16...64).each do |round|
      small_sigma0 = schedule[round - 15].rotate_right(7) ^ schedule[round - 15].rotate_right(18) ^ (schedule[round - 15] >> 3)
      small_sigma1 = schedule[round - 2].rotate_right(17) ^ schedule[round - 2].rotate_right(19) ^ (schedule[round - 2] >> 10)
      schedule[round] = small_sigma1 &+ schedule[round - 7] &+ small_sigma0 &+ schedule[round - 16]
    end

    a = @hash_state[0]
    b = @hash_state[1]
    c = @hash_state[2]
    d = @hash_state[3]
    e = @hash_state[4]
    f = @hash_state[5]
    g = @hash_state[6]
    h = @hash_state[7]

    64.times do |round|
      big_sigma1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25)
      choice = (e & f) ^ (~e & g)
      temp1 = h &+ big_sigma1 &+ choice &+ ROUND_CONSTANTS[round] &+ schedule[round]
      big_sigma0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22)
      majority = (a & b) ^ (a & c) ^ (b & c)
      temp2 = big_sigma0 &+ majority

      h = g
      g = f
      f = e
      e = d &+ temp1
      d = c
      c = b
      b = a
      a = temp1 &+ temp2
    end

    @hash_state[0] &+= a
    @hash_state[1] &+= b
    @hash_state[2] &+= c
    @hash_state[3] &+= d
    @hash_state[4] &+= e
    @hash_state[5] &+= f
    @hash_state[6] &+= g
    @hash_state[7] &+= h

    @message_block_index = 0
  end

  private def pad_message : Nil
    bit_length = @message_bit_length

    @message_block[@message_block_index] = 0x80_u8
    @message_block_index += 1
    if @message_block_index > 56
      while @message_block_index < 64
        @message_block[@message_block_index] = 0_u8
        @message_block_index += 1
      end
      process_message_block
    end

    while @message_block_index < 56
      @message_block[@message_block_index] = 0_u8
      @message_block_index += 1
    end

    8.times do |byte_index|
      @message_block[56 + byte_index] = (bit_length >> (8 * (7 - byte_index))).to_u8!
    end

    process_message_block
  end

  def digest_size : Int32
    32
  end
end
