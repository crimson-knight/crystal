module Crystal::InferPersist
  # A set of object addresses with a rank for each: the writer's record of
  # which objects it has reached, and the number each one gets in the file.
  #
  # Objects start on 16-byte boundaries, so one bit per 16 bytes of address
  # space marks an object. Bits live in chunks of 1 MiB of address space,
  # made when an address in them is first marked, so the set costs about
  # 8 KiB per MiB of heap (about 50 MB for a 6 GB heap) instead of a hash
  # table entry per object (more than 1 GB for 60 million objects).
  #
  # Numbers are ranks in address order: `#freeze` counts the marked bits once,
  # after which `#rank` is the number of marked addresses below an address.
  class AddressSet
    private CHUNK_SHIFT   = 20
    private GRANULE_SHIFT =  4
    private WORDS         = (1 << (CHUNK_SHIFT - GRANULE_SHIFT)) // 64

    class Chunk
      getter bits = Slice(UInt64).new(WORDS)
      # The rank of the first bit of each word, after `AddressSet#freeze`.
      property ranks = Slice(UInt32).empty
    end

    @chunks = {} of UInt64 => Chunk
    @list_of_chunk_keys = [] of UInt64
    getter size = 0
    getter? frozen = false

    # Whether *address* can be held: 16-byte aligned.
    def self.aligned?(address : UInt64) : Bool
      address & ((1_u64 << GRANULE_SHIFT) - 1) == 0
    end

    # Marks *address*; returns whether it was not marked before.
    def add?(address : UInt64) : Bool
      raise "BUG: AddressSet is frozen" if @frozen
      chunk = chunk_for(address, create: true).not_nil!
      word_index, bit = position(address)
      word = chunk.bits[word_index]
      return false if word & bit != 0
      chunk.bits[word_index] = word | bit
      @size += 1
      true
    end

    def includes?(address : UInt64) : Bool
      chunk = chunk_for(address, create: false) || return false
      word_index, bit = position(address)
      chunk.bits[word_index] & bit != 0
    end

    # Fixes the ranks. No address can be added after this.
    def freeze : Nil
      @list_of_chunk_keys = @chunks.keys.sort!
      rank = 0_u32
      @list_of_chunk_keys.each do |key|
        chunk = @chunks[key]
        ranks = Slice(UInt32).new(WORDS)
        WORDS.times do |index|
          ranks[index] = rank
          rank += chunk.bits[index].popcount.to_u32
        end
        chunk.ranks = ranks
      end
      @frozen = true
    end

    # The rank of a marked *address*, or `nil` when it is not marked.
    def rank?(address : UInt64) : Int32?
      chunk = chunk_for(address, create: false) || return nil
      word_index, bit = position(address)
      word = chunk.bits[word_index]
      return nil if word & bit == 0
      (chunk.ranks[word_index] + (word & (bit &- 1)).popcount).to_i32
    end

    # Yields every marked address in increasing order (by rank).
    def each(& : UInt64 ->) : Nil
      @list_of_chunk_keys.each do |key|
        chunk = @chunks[key]
        base = key << CHUNK_SHIFT
        WORDS.times do |index|
          word = chunk.bits[index]
          while word != 0
            bit_index = word.trailing_zeros_count
            word &= word &- 1
            yield base + ((index.to_u64 * 64 + bit_index) << GRANULE_SHIFT)
          end
        end
      end
    end

    private def chunk_for(address : UInt64, create : Bool) : Chunk?
      key = address >> CHUNK_SHIFT
      if create
        @chunks[key] ||= Chunk.new
      else
        @chunks[key]?
      end
    end

    private def position(address : UInt64) : {Int32, UInt64}
      granule = (address & ((1_u64 << CHUNK_SHIFT) - 1)) >> GRANULE_SHIFT
      {(granule >> 6).to_i32, 1_u64 << (granule & 63)}
    end
  end
end
