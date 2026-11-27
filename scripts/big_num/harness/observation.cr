require "./gmp_oracle"
require "./subject"

module G2Harness
  # One side's exact result of an operation, reduced to something two sides
  # can be compared by. Integers keep their sign, limb count and limbs as
  # read from the value itself (never a printed form); scalars keep their
  # type and exact value; strings keep their bytes; a raised exception keeps
  # its class.
  struct Observation
    enum Kind
      Integer
      Scalar
      Text
      Raised
      Tuple
      Pending
    end

    getter kind : Kind
    getter? negative : Bool
    getter limbs : Array(UInt64)
    getter scalar : String
    getter parts : Array(Observation)

    def initialize(@kind, @negative = false, @limbs = [] of UInt64, @scalar = "", @parts = [] of Observation)
    end

    def self.integer(limbs : Slice(UInt64), negative : Bool, declared_size : Int32) : self
      list_of_limbs = limbs.to_a
      malformed = [] of String
      malformed << "declared size #{declared_size} but #{limbs.size} limbs" if declared_size != limbs.size
      malformed << "high zero limb" if !list_of_limbs.empty? && list_of_limbs.last == 0
      malformed << "negative zero" if list_of_limbs.empty? && negative
      new(Kind::Integer, negative: negative, limbs: list_of_limbs, scalar: malformed.join("; "))
    end

    def self.scalar(type_name : String, value : String) : self
      new(Kind::Scalar, scalar: "#{type_name}:#{value}")
    end

    def self.text(value : String) : self
      new(Kind::Text, scalar: value)
    end

    def self.raised(exception : Exception) : self
      new(Kind::Raised, scalar: exception.class.name)
    end

    def self.pending(message : String?) : self
      new(Kind::Pending, scalar: message || "NotImplementedError")
    end

    def self.tuple(parts : Array(Observation)) : self
      new(Kind::Tuple, parts: parts)
    end

    def pending? : Bool
      kind.pending? || parts.any?(&.pending?)
    end

    def ==(other : Observation) : Bool
      kind == other.kind && negative? == other.negative? && limbs == other.limbs &&
        scalar == other.scalar && parts == other.parts
    end

    # A near miss of this observation: the smallest change the comparator
    # must still see (the fault injector's planted bug).
    def near_miss : Observation
      case kind
      in .integer?
        changed = limbs.dup
        if changed.empty?
          changed << 1_u64
        else
          changed[0] ^= 1_u64
          while !changed.empty? && changed.last == 0
            changed.pop
          end
        end
        Observation.new(kind, negative: negative? && !changed.empty?, limbs: changed, scalar: scalar)
      in .scalar?, .text?, .raised?
        Observation.new(kind, scalar: scalar.empty? ? "\u0001" : scalar.byte_slice(0, scalar.bytesize - 1) + (scalar[-1] == 'x' ? 'y' : 'x'))
      in .tuple?
        Observation.tuple([parts.first.near_miss] + parts[1..])
      in .pending?
        self
      end
    end

    def to_s(io : IO) : Nil
      case kind
      in .integer?
        io << (negative? ? "-0x" : "0x")
        if limbs.empty?
          io << '0'
        else
          limbs.reverse_each.with_index do |limb, index|
            index == 0 ? limb.to_s(io, 16) : limb.to_s(io, 16, precision: 16)
          end
        end
        io << " (" << limbs.size << " limbs"
        io << "; MALFORMED: " << scalar unless scalar.empty?
        io << ')'
      in .scalar?
        io << scalar
      in .text?
        scalar.inspect(io)
      in .raised?
        io << "raise " << scalar
      in .tuple?
        io << '{'
        parts.join(io, ", ")
        io << '}'
      in .pending?
        io << "pending (" << scalar << ')'
      end
    end
  end

  # Observations of every result type an operation can produce.
  module Observe
    def self.of(value : BigInt) : Observation
      Observation.integer(GMPOracle.limbs(value), GMPOracle.negative?(value), value.to_unsafe.value._mp_size.abs)
    end

    def self.of(value : Bool) : Observation
      Observation.scalar("Bool", value.to_s)
    end

    def self.of(value : Nil) : Observation
      Observation.scalar("Nil", "nil")
    end

    def self.of(value : Float64) : Observation
      Observation.scalar("Float64", "0x#{value.unsafe_as(UInt64).to_s(16)} (#{value})")
    end

    def self.of(value : Int::Primitive) : Observation
      Observation.scalar("Int", value.to_s)
    end

    def self.of(value : String) : Observation
      Observation.text(value)
    end

    def self.of(value : Tuple) : Observation
      Observation.tuple(value.to_a.map { |part| of(part).as(Observation) })
    end

    # An engine-shaped integer: the contract's `limbs`, `negative?`, `size`.
    def self.of(value : ReferenceDouble) : Observation
      integer(value)
    end

    {% unless flag?(:g2_harness_without_engine) %}
      def self.of(value : ::Crystal::BigNum::Integer) : Observation
        integer(value)
      end
    {% end %}

    private def self.integer(value) : Observation
      Observation.integer(value.limbs, value.negative?, value.size)
    end
  end
end
