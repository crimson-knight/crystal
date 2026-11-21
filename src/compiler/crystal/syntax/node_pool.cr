module Crystal
  # Typed pools for the node classes with the most instances.
  #
  # A pool hands out consecutive slots for the instances of one class from
  # chunks it gets from the collector (`GC.malloc`), so the collector scans
  # every node exactly as it scans one it allocated itself. A reference to a
  # pooled node is an ordinary reference that points inside a chunk: identity,
  # `object_id`, `same?` and `dup` are unchanged. The collector follows
  # interior pointers, so a chunk lives as long as any node in it is
  # reachable, and is freed whole once none is.
  #
  # Each pool starts a new chunk when a compiler stage begins
  # (`NodePool.start_stage`), so nodes of one class made in one stage sit next
  # to each other and nodes of different stages never share a chunk.
  #
  # A pool keeps no list of its chunks: only the collector frees them. That is
  # what keeps freeing safe. A slot is never handed out twice, so a node that
  # dies inside a chunk that lives on leaves a hole the collector cannot
  # reuse, and whatever the dead node points at stays reachable until the
  # chunk goes. Whether whole chunks die often enough to pay for that is what
  # the experiment in notes/typed-arena.md measures.
  #
  # * `CRYSTAL_NODE_POOLS=1` turns the pools on (off by default).
  # * `CRYSTAL_NODE_POOL_CHUNK_KB=N` sets the chunk size (default 256).
  # * `CRYSTAL_NODE_POOL_SHARED=1` makes all pooled classes share one pool, so
  #   nodes sit in the order they were made whatever their class (a def's
  #   cloned body is then contiguous, in the order a visitor walks it).
  # * `CRYSTAL_NODE_POOL_TRACE=1` counts, per pool and stage, the chunks
  #   started and the chunks the collector freed, and prints them to standard
  #   error when a stage ends.
  module NodePool
    DEFAULT_CHUNK_KB = 256

    # A chunk is this much smaller than a whole number of collector blocks,
    # because the collector adds a byte to every request.
    CHUNK_SLACK_BYTES = 64

    MAX_STAGE_COUNT = 8

    # The stages whose nodes get chunks of their own. Everything before type
    # inference (parsing, top-level declarations) shares the first chunks.
    STAGES_WITH_THEIR_OWN_CHUNKS = {"Semantic (main)", "Semantic (cleanup)", "Semantic (release)", "Codegen (crystal)"}

    class_property? enabled : Bool = ENV["CRYSTAL_NODE_POOLS"]? == "1"
    class_getter? traced : Bool = ENV["CRYSTAL_NODE_POOL_TRACE"]? == "1"
    class_property? shared : Bool = ENV["CRYSTAL_NODE_POOL_SHARED"]? == "1"
    class_getter chunk_bytes : Int32 = begin
      chunk_kb = ENV["CRYSTAL_NODE_POOL_CHUNK_KB"]?.try(&.to_i?) || DEFAULT_CHUNK_KB
      chunk_kb = DEFAULT_CHUNK_KB if chunk_kb < 16
      chunk_kb * 1024 - CHUNK_SLACK_BYTES
    end

    # True while the node being made is one codegen reads; false for a node
    # only type inference reads. A class with two pools picks by it.
    class_property? allocating_for_codegen : Bool = false

    class_getter list_of_pools = [] of Pool

    # The one pool every pooled class uses when `shared?`.
    class_getter shared_pool : Pool { Pool.new("shared", 8) }
    class_getter list_of_stage_names = ["start"]

    # Makes every pool start a new chunk: nodes made from here on belong to
    # stage *name*.
    def self.start_stage(name : String) : Nil
      return unless enabled?
      return if list_of_stage_names.size >= MAX_STAGE_COUNT

      list_of_stage_names << name
      list_of_pools.each &.start_stage(list_of_stage_names.size - 1)
    end

    # Prints, per pool and stage, the chunks started and the chunks the
    # collector has freed so far.
    def self.print_trace(stage_name : String?) : Nil
      return unless enabled? && traced?

      {% unless flag?(:gc_none) || flag?(:wasm32) %}
        LibGC.invoke_finalizers
      {% end %}
      started_bytes = 0_i64
      freed_bytes = 0_i64
      list_of_pools.each do |pool|
        list_of_stage_names.each_with_index do |name, stage|
          started = pool.started_chunk_count(stage)
          next if started == 0
          freed = pool.freed_chunk_count(stage)
          started_bytes += started.to_i64 * chunk_bytes
          freed_bytes += freed.to_i64 * chunk_bytes
          STDERR.printf("node-pool at=%s pool=%s made_in=%s slot_bytes=%d chunks_started=%d chunks_freed=%d started_mb=%.1f freed_mb=%.1f\n",
            (stage_name || "?").gsub(' ', '_'), pool.name, name.gsub(' ', '_'), pool.slot_bytes, started, freed,
            started.to_i64 * chunk_bytes / 1e6, freed.to_i64 * chunk_bytes / 1e6)
        end
      end
      STDERR.printf("node-pool at=%s total started_mb=%.1f freed_mb=%.1f held_mb=%.1f\n",
        (stage_name || "?").gsub(' ', '_'), started_bytes / 1e6, freed_bytes / 1e6, (started_bytes - freed_bytes) / 1e6)
    end

    # The pool of one node class (or of one kind of node of that class).
    class Pool
      getter name : String
      getter slot_bytes : Int32

      @cursor : Pointer(UInt8) = Pointer(UInt8).null
      @chunk_end : Pointer(UInt8) = Pointer(UInt8).null
      @stage : Int32 = 0
      @index : Int32

      # Counters live outside the collector's heap so the finalizer of a
      # chunk can write them while a collection is finishing.
      @started_chunk_counts : Pointer(Int32)
      @freed_chunk_counts : Pointer(Int32)

      def initialize(@name : String, instance_bytes : Int32)
        @slot_bytes = (instance_bytes + 7) & ~7
        @started_chunk_counts = LibC.malloc(MAX_STAGE_COUNT * sizeof(Int32)).as(Pointer(Int32))
        @started_chunk_counts.clear(MAX_STAGE_COUNT)
        @freed_chunk_counts = LibC.malloc(MAX_STAGE_COUNT * sizeof(Int32)).as(Pointer(Int32))
        @freed_chunk_counts.clear(MAX_STAGE_COUNT)
        @index = NodePool.list_of_pools.size
        @stage = NodePool.list_of_stage_names.size - 1
        NodePool.list_of_pools << self
      end

      # The memory for the next instance: zeroed, *bytes* long (a multiple
      # of 8).
      @[AlwaysInline]
      def next_slot(bytes : Int32 = @slot_bytes) : Pointer(UInt8)
        slot = @cursor
        following = slot + bytes
        if following > @chunk_end
          slot = start_chunk
          following = slot + bytes
        end
        @cursor = following
        slot
      end

      def start_stage(stage : Int32) : Nil
        @stage = stage
        @cursor = @chunk_end = Pointer(UInt8).null
      end

      def started_chunk_count(stage : Int32) : Int32
        @started_chunk_counts[stage]
      end

      def freed_chunk_count(stage : Int32) : Int32
        @freed_chunk_counts[stage]
      end

      @[NoInline]
      private def start_chunk : Pointer(UInt8)
        chunk_bytes = NodePool.chunk_bytes
        chunk = GC.malloc(chunk_bytes.to_u64).as(Pointer(UInt8))
        @chunk_end = chunk + chunk_bytes
        @started_chunk_counts[@stage] += 1
        {% unless flag?(:gc_none) || flag?(:wasm32) %}
          if NodePool.traced?
            LibGC.register_finalizer(chunk.as(Void*),
              ->(_chunk : Void*, counter : Void*) { counter.as(Pointer(Int32)).value += 1 },
              (@freed_chunk_counts + @stage).as(Void*), nil, nil)
          end
        {% end %}
        chunk
      end
    end
  end

  abstract class ASTNode
    # Makes the instances of this class come from a typed pool when
    # `NodePool.enabled?`. Subclasses keep the collector's own allocation.
    macro allocates_from_node_pool
      NODE_POOL = ::Crystal::NodePool::Pool.new({{ @type.name.stringify }}, instance_sizeof({{ @type }}))

      def self.allocate : self
        if ::Crystal::NodePool.enabled?
          pool = ::Crystal::NodePool.shared? ? ::Crystal::NodePool.shared_pool : NODE_POOL
          pre_initialize(pool.next_slot(NODE_POOL.slot_bytes))
        else
          pre_initialize(::GC.malloc(instance_sizeof({{ @type }}).to_u64))
        end
      end
    end

    # Like `allocates_from_node_pool`, with a second pool for the instances
    # only type inference reads (made while
    # `NodePool.allocating_for_codegen?` is false).
    macro allocates_from_two_node_pools
      NODE_POOL = ::Crystal::NodePool::Pool.new({{ @type.name.stringify }}, instance_sizeof({{ @type }}))
      INFERENCE_NODE_POOL = ::Crystal::NodePool::Pool.new({{ @type.name.stringify + "(inference)" }}, instance_sizeof({{ @type }}))

      def self.allocate : self
        if ::Crystal::NodePool.enabled?
          pool = ::Crystal::NodePool.allocating_for_codegen? ? NODE_POOL : INFERENCE_NODE_POOL
          pool = ::Crystal::NodePool.shared_pool if ::Crystal::NodePool.shared?
          pre_initialize(pool.next_slot(NODE_POOL.slot_bytes))
        else
          pre_initialize(::GC.malloc(instance_sizeof({{ @type }}).to_u64))
        end
      end
    end
  end
end
