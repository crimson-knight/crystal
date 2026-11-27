# The engine is 64-bit only; 32-bit targets run the big types on GMP.
require "crystal/big_num/availability"
{% skip_file unless Crystal::BigNum::TARGET_SUPPORTED %}

require "big"
require "crystal/big_num"

# The G2a slice of the BigNum differential (BIGNUM.md 5.2): random operands,
# every G2a operation computed by `Crystal::BigNum::Integer` and by GMP through
# `BigInt`, compared limb for limb and sign for sign.
module IntegerOracle
  alias Integer = Crystal::BigNum::Integer
  alias Limb = Crystal::BigNum::Limb

  # The value of *value* as a `BigInt`, built from its limbs.
  def self.to_big(value : Integer) : BigInt
    limbs = value.limbs
    BigInt.new do |mpz|
      pointer = LibGMP.limbs_write(mpz, LibGMP::MpSize.new(limbs.size))
      pointer.copy_from(limbs.to_unsafe, limbs.size)
      LibGMP.limbs_finish(mpz, LibGMP::MpSize.new(value.negative? ? -limbs.size : limbs.size))
    end
  end

  # The magnitude limbs GMP holds for *value*.
  def self.gmp_limbs(value : BigInt) : Slice(Limb)
    Slice.new(LibGMP.limbs_read(value), LibGMP.size(value).to_i32, read_only: true)
  end

  # Whether *ours* and *theirs* have the same sign and the same limbs.
  def self.same?(ours : Integer, theirs : BigInt) : Bool
    ours.negative? == (theirs < 0) && ours.limbs == gmp_limbs(theirs)
  end

  # A random operand drawn as BIGNUM.md 5.2 says: sizes log-uniform from 0 to
  # 8,192 bits with 70% at or below 4,096, a share of edge shapes, both signs.
  def self.random_operand(random : Random) : Integer
    magnitude = random.rand < 0.25 ? edge_magnitude(random) : random_magnitude(random, random_bit_count(random))
    random.next_bool ? -magnitude : magnitude
  end

  def self.random_bit_count(random : Random) : Int32
    if random.rand < 0.7
      (Math.exp(random.rand * Math.log(4097.0)) - 1).to_i32
    else
      (Math.exp(Math.log(4097.0) + random.rand * (Math.log(8193.0) - Math.log(4097.0))) - 1).to_i32
    end
  end

  def self.random_magnitude(random : Random, bits : Int32) : Integer
    return Integer.zero if bits <= 0
    count = (bits + 63) // 64
    limbs = Slice(Limb).new(count) { random.rand(Limb) }
    top_bits = bits - (count - 1) * 64
    top = limbs[count - 1] & (top_bits == 64 ? Limb::MAX : (1_u64 << top_bits) - 1)
    limbs[count - 1] = top | (1_u64 << (top_bits - 1))
    Integer.from_limbs(limbs, false)
  end

  BOUNDARY_BITS = [1, 2, 63, 64, 65, 127, 128, 129, 191, 192, 193, 255, 256, 257, 4095, 4096, 4097]

  def self.edge_magnitude(random : Random) : Integer
    one = Integer.new(1)
    case random.rand(8)
    when 0 then Integer.zero
    when 1 then one
    when 2 # a power of two and its neighbors at a limb boundary
      power = one << BOUNDARY_BITS.sample(random)
      {power, power - 1, power + 1}.sample(random)
    when 3 # all-ones limbs
      count = random.rand(1..70)
      Integer.from_limbs(Slice(Limb).new(count, Limb::MAX), false)
    when 4 # sparse: a few bits set across a wide value
      value = Integer.zero
      random.rand(1..4).times { value = value | (one << random.rand(0..8192)) }
      value
    when 5 # a power of two at a random place, and its neighbors
      power = one << random.rand(0..8192)
      {power, power - 1, power + 1}.sample(random)
    when 6 # a top limb just above 2**63
      count = random.rand(1..64)
      limbs = Slice(Limb).new(count) { random.rand(Limb) }
      limbs[count - 1] = (1_u64 << 63) | random.rand(16_u64)
      Integer.from_limbs(limbs, false)
    else # one and two limbs, the inline layout's edges
      Integer.from_limbs(Slice(Limb).new(random.rand(1..3)) { {0_u64, 1_u64, Limb::MAX, 1_u64 << 63, random.rand(Limb)}.sample(random) }, false)
    end
  end

  # A random primitive integer of a random primitive type.
  def self.random_primitive(random : Random) : ::Int::Primitive
    case random.rand(10)
    when 0 then random.rand(Int8)
    when 1 then random.rand(UInt8)
    when 2 then random.rand(Int16)
    when 3 then random.rand(UInt32)
    when 4 then random.rand(Int32)
    when 5 then random.rand(Int64)
    when 6 then random.rand(UInt64)
    when 7 then {Int64::MIN, Int64::MAX, UInt64::MAX, 0_i64, -1_i64, Int128::MIN, UInt128::MAX}.sample(random)
    when 8 then random.rand(Int128)
    else        random.rand(UInt128)
    end
  end

  OPERATIONS = %w(new_primitive add sub add_primitive sub_primitive negate abs compare compare_primitive equal hash
    and or xor and_primitive or_primitive xor_primitive complement shift_left shift_right bit popcount trailing_zeros
    bit_length to_i64 to_u64 to_i128 to_u128 wrapping)

  # Runs *count* random operations from *seed* and returns how many ran per
  # operation and the first mismatches (operation, index and operands in hex).
  def self.run(count : Int, seed : UInt64) : {Hash(String, Int64), Array(String)}
    random = Random::PCG32.new(seed)
    counts = Hash(String, Int64).new(0_i64)
    list_of_mismatches = [] of String
    count.times do |index|
      operation = OPERATIONS.sample(random)
      a = random_operand(random)
      b = random_operand(random)
      primitive = random_primitive(random)
      if failure = check(operation, a, b, primitive, random)
        list_of_mismatches << "seed #{seed} index #{index} #{operation}: a=#{a.inspect} b=#{b.inspect} primitive=#{primitive} (#{primitive.class}) #{failure}" if list_of_mismatches.size < 20
        counts["mismatch"] += 1
      end
      counts[operation] += 1
    end
    {counts, list_of_mismatches}
  end

  def self.compare_values(ours : Integer, theirs : BigInt) : String?
    same?(ours, theirs) ? nil : "ours=#{ours.inspect} gmp=#{theirs.to_s(16)}"
  end

  def self.compare_plain(ours, theirs) : String?
    ours == theirs ? nil : "ours=#{ours.inspect} gmp=#{theirs.inspect}"
  end

  def self.check(operation : String, a : Integer, b : Integer, primitive : ::Int::Primitive, random : Random) : String?
    x = to_big(a)
    y = to_big(b)
    case operation
    when "new_primitive"     then compare_values(Integer.new(primitive), BigInt.new(primitive))
    when "add"               then compare_values(a + b, x + y)
    when "sub"               then compare_values(a - b, x - y)
    when "add_primitive"     then compare_values(a + primitive, x + primitive)
    when "sub_primitive"     then compare_values(a - primitive, x - primitive)
    when "negate"            then compare_values(-a, -x)
    when "abs"               then compare_values(a.abs, x.abs)
    when "compare"           then compare_plain({a <=> b, b <=> a, a <=> a}, {(x <=> y).sign, (y <=> x).sign, 0})
    when "compare_primitive" then compare_plain(a <=> primitive, (x <=> primitive).sign)
    when "equal"
      c = random.next_bool ? a : to_ours(x)
      compare_plain({a == b, a == c, a == primitive}, {x == y, true, x == primitive})
    when "hash"
      compare_plain({a.hash, a.hash_reduce}, {x.hash, Crystal::Hasher.reduce_num(x)})
    when "and"           then compare_values(a & b, x & y)
    when "or"            then compare_values(a | b, x | y)
    when "xor"           then compare_values(a ^ b, x ^ y)
    when "and_primitive" then compare_values(a & primitive, x & primitive)
    when "or_primitive"  then compare_values(a | primitive, x | primitive)
    when "xor_primitive" then compare_values(a ^ primitive, x ^ primitive)
    when "complement"    then compare_values(~a, ~x)
    when "shift_left"
      count = random_shift(random)
      compare_values(a << count, x << count)
    when "shift_right"
      count = random_shift(random)
      compare_values(a >> count, x >> count)
    when "bit"
      index = random.rand(0..(a.bit_length + 130))
      compare_plain({a.bit(index), a.bit(-1)}, {x.bit(index), x.bit(-1)})
    when "popcount"       then compare_plain(a.popcount, x.popcount)
    when "trailing_zeros" then compare_plain(a.trailing_zeros_count, x.trailing_zeros_count)
    when "bit_length"     then compare_plain(a.bit_length, x.bit_length)
    when "to_i64"
      c = small(a, random)
      z = to_big(c)
      compare_plain(c.to_i64?, Int64::MIN <= z <= Int64::MAX ? z.to_i64 : nil)
    when "to_u64"
      c = small(a, random)
      z = to_big(c)
      compare_plain(c.to_u64?, 0 <= z <= UInt64::MAX ? z.to_u64 : nil)
    when "to_i128"
      c = small(a, random)
      z = to_big(c)
      compare_plain(c.to_i128?, Int128::MIN <= z <= Int128::MAX ? z.to_i128 : nil)
    when "to_u128"
      c = small(a, random)
      z = to_big(c)
      compare_plain(c.to_u128?, 0 <= z <= UInt128::MAX ? z.to_u128 : nil)
    when "wrapping"
      compare_plain({a.to_u64!, a.to_i64!, a.to_u128!, a.to_i128!}, {x.to_u64!, x.to_i64!, x.to_u128!, x.to_i128!})
    else
      raise ArgumentError.new("unknown operation #{operation}")
    end
  end

  def self.to_ours(value : BigInt) : Integer
    Integer.from_limbs(gmp_limbs(value), value < 0)
  end

  # Shift counts weighted toward the limb boundaries.
  def self.random_shift(random : Random) : Int32
    random.next_bool ? random.rand(0..300) : random.rand(0..9000)
  end

  # A value near the 64- and 128-bit conversion edges, or *value* itself.
  def self.small(value : Integer, random : Random) : Integer
    case random.rand(4)
    when 0 then value
    when 1 then value >> (value.bit_length - random.rand(56..72)).clamp(0..)
    when 2 then value >> (value.bit_length - random.rand(120..136)).clamp(0..)
    else        Integer.new({Int64::MIN, Int64::MAX, UInt64::MAX, Int128::MIN, Int128::MAX, UInt128::MAX}.sample(random)) + random.rand(-2..2)
    end
  end
end
