{% if flag?(:use_libz) %}
  require "lib_z"
{% else %}
  require "crystal/mica/deflate/checksum"
{% end %}
require "./digest"

# Implements the Adler32 checksum algorithm.
#
# It runs on Mica's Adler-32, written in Crystal; build with `-Duse_libz` to
# use zlib's.
#
# NOTE: To use `Adler32`, you must explicitly import it with `require "digest/adler32"`
class Digest::Adler32 < ::Digest
  extend ClassMethods

  @digest : UInt32

  def initialize
    @digest = Adler32.initial
  end

  def self.initial : UInt32
    {% if flag?(:use_libz) %}
      LibZ.adler32(0, nil, 0).to_u32
    {% else %}
      1_u32
    {% end %}
  end

  def self.checksum(data) : UInt32
    update(data, initial)
  end

  def self.update(data, adler32 : UInt32) : UInt32
    update data.to_slice, adler32
  end

  def self.update(data : Bytes, adler32 : UInt32) : UInt32
    {% if flag?(:use_libz) %}
      LibZ.adler32(adler32, data, data.size).to_u32
    {% else %}
      Crystal::Mica::Deflate::Adler32.update(adler32, data)
    {% end %}
  end

  # Returns the Adler32 of two pieces of data joined, from *adler1* (the
  # Adler32 of the first), *adler2* (of the second) and *len*, the size of
  # the second.
  def self.combine(adler1 : UInt32, adler2 : UInt32, len : Int32) : UInt32
    {% if flag?(:use_libz) %}
      LibZ.adler32_combine(adler1, adler2, len).to_u32
    {% else %}
      # zlib's adler32_combine, including its answer for a negative *len*.
      return 0xFFFFFFFF_u32 if len < 0
      modulus = 65_521_u64
      remainder = len.to_u64 % modulus
      low = adler1.to_u64 & 0xFFFF
      high = (remainder * low) % modulus
      low += (adler2.to_u64 & 0xFFFF) + modulus - 1
      high += (adler1.to_u64 >> 16) + (adler2.to_u64 >> 16) + modulus - remainder
      low -= modulus if low >= modulus
      low -= modulus if low >= modulus
      high -= modulus << 1 if high >= modulus << 1
      high -= modulus if high >= modulus
      (low | (high << 16)).to_u32
    {% end %}
  end

  # :nodoc:
  def update_impl(data : Bytes) : Nil
    @digest = Adler32.update(data, @digest)
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
    @digest = Adler32.initial
  end

  # :nodoc:
  def digest_size : Int32
    4
  end
end
