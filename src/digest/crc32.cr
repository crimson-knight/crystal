{% if flag?(:use_libz) %}
  require "lib_z"
{% else %}
  require "crystal/mica/deflate/checksum"
{% end %}
require "./digest"

# Implements the CRC32 checksum algorithm.
#
# It runs on Mica's CRC-32, written in Crystal; build with `-Duse_libz` to
# use zlib's.
#
# NOTE: To use `CRC32`, you must explicitly import it with `require "digest/crc32"`
class Digest::CRC32 < ::Digest
  extend ClassMethods

  @digest : UInt32

  def initialize
    @digest = CRC32.initial
  end

  def self.initial : UInt32
    {% if flag?(:use_libz) %}
      LibZ.crc32(0, nil, 0).to_u32
    {% else %}
      0_u32
    {% end %}
  end

  def self.checksum(data) : UInt32
    update(data, initial)
  end

  def self.update(data, crc32 : UInt32) : UInt32
    update data.to_slice, crc32
  end

  def self.update(data : Bytes, crc32 : UInt32) : UInt32
    {% if flag?(:use_libz) %}
      LibZ.crc32(crc32, data, data.size).to_u32
    {% else %}
      Crystal::Mica::Deflate::CRC32.update(crc32, data)
    {% end %}
  end

  # Returns the CRC32 of two pieces of data joined, from *crc1* (the CRC32 of
  # the first), *crc2* (of the second) and *len*, the size of the second.
  def self.combine(crc1 : UInt32, crc2 : UInt32, len : Int32) : UInt32
    {% if flag?(:use_libz) %}
      LibZ.crc32_combine(crc1, crc2, len).to_u32
    {% else %}
      # zlib's method: multiply *crc1* by x^(8 * len) modulo the polynomial,
      # with x^(2^k) squared up from x^8 for each bit of *len*.
      shift = 0x80000000_u32  # x^0
      square = 0x00800000_u32 # x^8
      remaining = len.to_u64
      while remaining != 0
        shift = multiply_modulo_polynomial(square, shift) if remaining.odd?
        remaining >>= 1
        square = multiply_modulo_polynomial(square, square)
      end
      multiply_modulo_polynomial(shift, crc1) ^ crc2
    {% end %}
  end

  {% unless flag?(:use_libz) %}
    # Multiplies two polynomials modulo the CRC-32 polynomial, in the
    # reflected bit order zlib uses (x^0 is the top bit).
    private def self.multiply_modulo_polynomial(left : UInt32, right : UInt32) : UInt32
      bit = 0x80000000_u32
      product = 0_u32
      loop do
        if left & bit != 0
          product ^= right
          break if left & (bit &- 1) == 0
        end
        bit >>= 1
        right = right.odd? ? (right >> 1) ^ 0xEDB88320_u32 : right >> 1
      end
      product
    end
  {% end %}

  # :nodoc:
  def update_impl(data : Bytes) : Nil
    @digest = CRC32.update(data, @digest)
  end

  # :nodoc:
  def final_impl(dst : Bytes) : Nil
    dst[0] = (@digest >> 24).to_u8!
    dst[1] = (@digest >> 16).to_u8!
    dst[2] = (@digest >> 8).to_u8!
    dst[3] = (@digest).to_u8!
  end

  # :nodoc:
  def reset_impl : Nil
    @digest = CRC32.initial
  end

  # :nodoc:
  def digest_size : Int32
    4
  end
end
