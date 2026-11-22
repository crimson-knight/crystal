module Regex::Mica::Regex
  # The states and transitions one `LazyDFA` has built so far, leased to one
  # search at a time (roadmap 6.2.4). Its memory is reserved from a
  # `CachePool` before it is used, it never holds more than the pool's
  # `max_cache_bytes`, and it clears itself when it would.
  #
  # The table holds `stride` entries per state: the next state's entry
  # (`entry_of`), or -1 when that transition has not been built yet. State 0 is the dead
  # state and state 1 the dead state that reports a match first; both stay
  # in every generation of the cache.
  #
  # WARNING: A cache belongs to one search at a time.
  class DFACache
    # The transition table (see the class description).
    getter transition_table : OffHeapList(Int32)
    # One byte of `LazyDFA::MARK_*` bits per state.
    getter list_of_marks : OffHeapList(UInt8)
    # How many times the cache has been cleared.
    getter clears = 0
    # True once a clear found the searches building a state for fewer than
    # `LazyDFA::MINIMUM_BYTES_PER_STATE` bytes read: the unanchored DFA
    # thrashes on this program, so a searcher prefers
    # `LazyDFA#find_from_each_start` where the program allows it, trying
    # the unanchored DFA again now and then (`retry?`).
    getter? thrashing = false
    # States built and bytes read since the cache was made (see
    # `judge_retry`).
    getter states_built = 0_i64
    getter bytes_read = 0_i64
    @searches_since_thrash = 0
    # Set by an unanchored forward search for the length of its DFA run: a
    # clear that finds the cache thrashing gives up at once, rather than
    # after `LazyDFA::MAX_CLEARS`, when this plan can search from each
    # start instead (`SearchPlan#short_match`, asked only then).
    setter hands_over_to : SearchPlan? = nil
    # The most NFA states one state built so far held, and how many states
    # built held more than `SearchPlan::WIDE_REVERSE_KEY`.
    getter widest_key = 0
    getter wide_states = 0
    @retry_interval = FIRST_RETRY_INTERVAL
    getter dfa : LazyDFA

    # Searches between retries of the unanchored DFA once it thrashes; the
    # interval doubles, up to `LAST_RETRY_INTERVAL`, each time a retry
    # thrashes again.
    FIRST_RETRY_INTERVAL = 256
    LAST_RETRY_INTERVAL  = 1 << 20
    # The fewest states a retry builds before its rate can count as
    # thrashing.
    RETRY_STATES = 32
    # The keys of the states, one after another, and where each begins
    # (one entry more than there are states): a state costs no allocation
    # of its own, only growth of these lists (see `key_of`).
    @list_of_key_values : OffHeapList(Int32)
    @list_of_key_starts : OffHeapList(Int32)
    # The states by key: an open-addressing table of state ids (`NO_STATE`
    # where empty), a power of two in size, never more than half full.
    @list_of_state_slots : OffHeapList(Int32)
    @start_entries : OffHeapList(Int32)
    @builder : DFABuilder
    @bytes_used = 0_i64
    @reservation : CacheReservation
    @bytes_since_clear = 0_i64
    @states_since_clear = 0
    @generation = 0

    # Returns a new cache for *dfa*, its fixed parts (the builder's scratch
    # space, the start-state table and the two dead states) reserved from
    # *pool* before they are allocated, or nil when the pool cannot supply
    # them or they do not fit under its `max_cache_bytes`.
    #
    # The block returns the scratch space the cache builds states in, and
    # runs only once the reservation succeeds, so a refused cache allocates
    # nothing. A lease's forward and reverse caches share one builder
    # (`SearchLease#builder`), as they never build at the same time. Each
    # cache still reserves the scratch space as its own, so the pool's
    # count stays an upper bound.
    def self.reserve?(dfa : LazyDFA, pool : CachePool, & : -> DFABuilder) : DFACache?
      reservation = CacheReservation.new(pool)
      return nil unless reservation.cover(initial_bytes(dfa), ceiling: pool.max_cache_bytes)
      new(dfa, pool, reservation, yield)
    end

    # The bytes a new cache takes before its first state is built.
    def self.initial_bytes(dfa : LazyDFA) : Int64
      fixed_bytes_of(dfa) + 2 * state_bytes_of(dfa, 1)
    end

    protected def self.fixed_bytes_of(dfa : LazyDFA) : Int64
      DFABuilder::BYTES_PER_STATE.to_i64 * dfa.node_count + 4_i64 * dfa.start_slot_count + 256
    end

    protected def self.state_bytes_of(dfa : LazyDFA, key_size : Int32) : Int64
      # Table row, mark, key array (header and elements), hash entry and the
      # key list slot.
      4_i64 * dfa.stride + 1 + 32 + 4_i64 * key_size + 48 + 8
    end

    # The states a new cache has room for before its lists grow: the two
    # dead states, a start state or two, and the few states a short
    # pattern builds on its first search.
    private FIRST_STATES = 8
    # The most entries the transition table starts with room for: a DFA
    # with Unicode word assertions has a stride of a hundred or more.
    private FIRST_TABLE_ENTRIES = 256
    # An empty slot of `@list_of_state_slots`.
    private NO_STATE = -1

    protected def initialize(@dfa : LazyDFA, @pool : CachePool, @reservation : CacheReservation, @builder : DFABuilder)
      @transition_table = OffHeapList(Int32).new(Math.min(FIRST_STATES * @dfa.stride, FIRST_TABLE_ENTRIES))
      @list_of_marks = OffHeapList(UInt8).new(FIRST_STATES)
      @list_of_key_values = OffHeapList(Int32).new(FIRST_STATES * 2)
      @list_of_key_starts = OffHeapList(Int32).new(FIRST_STATES + 1)
      @list_of_key_starts << 0
      @list_of_state_slots = OffHeapList(Int32).new(FIRST_STATES * 2, NO_STATE)
      @start_entries = OffHeapList(Int32).new(@dfa.start_slot_count, -1)
      growing_lists.each { |list| @owner.track(list) }
      @owner.track(@start_entries.to_unsafe)
      reset_states
    end

    # The tables sit outside the collector's heap. The cache is reachable
    # from its own program (through the plan's leases and its DFA), so an
    # owner outside that cycle frees them (see `OffHeapOwner`); every
    # growth that moves a list is recorded there (`add_state`).
    @owner = OffHeapOwner.new

    # The lists that grow, as `add_state` records them before and after.
    private def growing_lists : StaticArray(Pointer(Void), 5)
      StaticArray[@transition_table.to_unsafe.as(Void*), @list_of_marks.to_unsafe.as(Void*),
        @list_of_key_values.to_unsafe.as(Void*), @list_of_key_starts.to_unsafe.as(Void*),
        @list_of_state_slots.to_unsafe.as(Void*)]
    end

    # Bytes the builder's scratch space and the cache's fixed parts take.
    private def fixed_bytes : Int64
      DFACache.fixed_bytes_of(@dfa)
    end

    # Records *count* bytes read by the search, for the thrash rule.
    @[AlwaysInline]
    def note_bytes(count : Int32) : Nil
      @bytes_since_clear += count
      @bytes_read += count
    end

    # Counts a search made from each start because the cache thrashes, and
    # returns true (forgetting the thrashing) once the retry interval has
    # passed, so that search tries the unanchored DFA again; the caller
    # then reports how it went to `judge_retry`.
    def retry? : Bool
      @searches_since_thrash += 1
      return false if @searches_since_thrash < @retry_interval
      @thrashing = false
      @searches_since_thrash = 0
      true
    end

    # Judges a retry of the unanchored DFA that started when `states_built`
    # was *states_before* and `bytes_read` was *bytes_before*: when it
    # built at least `RETRY_STATES` states at fewer than
    # `LazyDFA::MINIMUM_BYTES_PER_STATE` bytes each, the cache thrashes
    # again and the next retry waits twice as long.
    def judge_retry(states_before : Int64, bytes_before : Int64) : Nil
      built = @states_built - states_before
      return if built < RETRY_STATES
      return if @bytes_read - bytes_before >= LazyDFA::MINIMUM_BYTES_PER_STATE.to_i64 * built
      @thrashing = true
      @retry_interval = Math.min(@retry_interval * 2, LAST_RETRY_INTERVAL)
    end

    # Gives every byte the cache reserved back to the pool. Its lease is
    # being evicted and drops the cache (see `SearchLease`), so nothing is
    # rebuilt: the lease reserves a new cache when it is next used.
    def evict : Nil
      @reservation.release_all
    end

    # Returns the entry (see `entry_of`) of the start state for *flags*,
    # building the state when needed, or `LazyDFA::GAVE_UP`. The table
    # keeps entries rather than ids, so a search that starts often (an
    # anchored try at each prefilter candidate) pays one load for its start.
    def start_entry(dfa : LazyDFA, flags : Int32, meter : SearchMeter) : Int32
      slot = dfa.start_slot(flags)
      cached = @start_entries.unsafe_fetch(slot)
      return cached if cached >= 0
      id = intern(dfa.start_key(flags, @builder), meter)
      return id if id < 0
      entry = entry_of(id)
      @start_entries[slot] = entry
      entry
    end

    # Returns the id of the start state for *flags* (see `start_entry`),
    # or `LazyDFA::GAVE_UP`.
    def start_state(dfa : LazyDFA, flags : Int32, meter : SearchMeter) : Int32
      entry = start_entry(dfa, flags, meter)
      entry < 0 ? entry : (entry & LazyDFA::ROW_MASK) // dfa.stride
    end

    # Builds the transition of *state* on *symbol*, records it, and returns
    # the next state (or `LazyDFA::GAVE_UP`). Building may clear the cache;
    # the transition is then not recorded, as *state* no longer exists.
    def transition(dfa : LazyDFA, state : Int32, symbol : Int32, meter : SearchMeter) : Int32
      key = dfa.next_key(key_of(state), symbol, @builder, meter)
      return LazyDFA::GAVE_UP unless key
      generation = @generation
      id = intern(key, meter)
      return id if id < 0
      if generation == @generation
        @transition_table[state * dfa.stride + symbol] = entry_of(id)
        mark_ascii_loop(dfa, state, meter) if id == state
      end
      id
    end

    # Flags the entries of *state*'s own row on the ASCII symbols with
    # `LazyDFA::ASCII_LOOP` once every one of them leads back to *state*,
    # and *state* is neither dead nor a start state, so `LazyDFA#find_end`
    # steps over a run of ASCII bytes there without reading the table (in a
    # match state, as `.*` makes, each byte of the run ends a match).
    # Forward only (the reverse DFA has no ASCII symbols listed).
    #
    # The ASCII symbols the search has not met in *state* yet (the control
    # bytes of English text) are built here when the built ones all lead
    # back: each costs one `LazyDFA#next_key`, charged to *meter*, and is
    # recorded only when it leads back too, so no state is added. At most
    # 128 such keys per state, once per cache generation.
    private def mark_ascii_loop(dfa : LazyDFA, state : Int32, meter : SearchMeter) : Nil
      return if @list_of_marks.unsafe_fetch(state) & (LazyDFA::MARK_DEAD | LazyDFA::MARK_START) != 0
      symbols = dfa.list_of_ascii_symbols
      return if symbols.empty?
      row = state * dfa.stride
      symbols.each do |symbol|
        entry = @transition_table.unsafe_fetch(row + symbol)
        return unless entry < 0 || entry & LazyDFA::ROW_MASK == row
      end
      key = key_of(state)
      symbols.each do |symbol|
        next unless @transition_table.unsafe_fetch(row + symbol) < 0
        next_key = dfa.next_key(key, symbol, @builder, meter)
        return unless next_key == key
        @transition_table[row + symbol] = entry_of(state)
      end
      entry = entry_of(state) | LazyDFA::ASCII_LOOP
      symbols.each { |symbol| @transition_table[row + symbol] = entry }
    end

    # The table entry for state *id*: its row offset (`id * stride`), with
    # `LazyDFA::SPECIAL` set for a match or dead state and
    # `LazyDFA::START_ENTRY` for a start state.
    @[AlwaysInline]
    def entry_of(id : Int32) : Int32
      offset = id &* @dfa.stride
      marks = @list_of_marks.unsafe_fetch(id)
      offset |= LazyDFA::SPECIAL if marks & (LazyDFA::MARK_MATCH | LazyDFA::MARK_DEAD) != 0
      offset |= LazyDFA::START_ENTRY if marks & LazyDFA::MARK_START != 0
      offset
    end

    # The key of state *id*: a view of `@list_of_key_values`, valid until the next
    # state is added.
    @[AlwaysInline]
    private def key_of(id : Int32) : Slice(Int32)
      first = @list_of_key_starts.unsafe_fetch(id)
      Slice.new(@list_of_key_values.to_unsafe + first, @list_of_key_starts.unsafe_fetch(id + 1) - first)
    end

    # The number of states the cache holds.
    private def state_count : Int32
      @list_of_key_starts.size - 1
    end

    # The id of the state with *key*, adding the state when it is new (or
    # `LazyDFA::GAVE_UP`). *key* is the builder's key, which a new state
    # copies.
    private def intern(key : Slice(Int32), meter : SearchMeter) : Int32
      mask = @list_of_state_slots.size - 1
      slot = DFACache.key_hash(key) & mask
      while (id = @list_of_state_slots.unsafe_fetch(slot)) != NO_STATE
        return id if key_of(id) == key
        slot = (slot + 1) & mask
      end
      cost = state_bytes(key.size)
      if @bytes_used + cost > @pool.max_cache_bytes
        return LazyDFA::GAVE_UP unless clear(meter)
        return LazyDFA::GAVE_UP if @bytes_used + cost > @pool.max_cache_bytes
      end
      return LazyDFA::GAVE_UP unless reserve(@bytes_used + cost)
      @widest_key = key.size if key.size > @widest_key
      @wide_states += 1 if key.size > SearchPlan::WIDE_REVERSE_KEY
      add_state(key, cost)
    end

    # A hash of *key* for `@list_of_state_slots` (FNV-1a over the entries).
    protected def self.key_hash(key : Slice(Int32)) : Int32
      hash = 0x811C9DC5_u32
      key.each { |value| hash = (hash ^ value.to_u32!) &* 0x01000193_u32 }
      (hash ^ (hash >> 16)).to_i32! & Int32::MAX
    end

    private def add_state(key : Slice(Int32), cost : Int64) : Int32
      before = growing_lists
      id = state_count
      @list_of_key_values.concat(key)
      @list_of_key_starts << @list_of_key_values.size
      place(id)
      # The dead states lead only to the dead state (entry 0 | SPECIAL).
      @transition_table.fill_to(@transition_table.size + @dfa.stride, id <= LazyDFA::DEAD_MATCH ? LazyDFA::SPECIAL : -1)
      mark = 0_u8
      mark |= LazyDFA::MARK_MATCH if key.unsafe_fetch(0) & LazyDFA::MATCH_BEHIND != 0
      mark |= LazyDFA::MARK_DEAD if id <= LazyDFA::DEAD_MATCH
      mark |= LazyDFA::MARK_START if @dfa.start_like?(key)
      @list_of_marks << mark
      @bytes_used += cost
      @states_since_clear += 1
      @states_built += 1
      after = growing_lists
      before.each_with_index { |list, index| @owner.retrack(list, after[index]) }
      id
    end

    # Records state *id* in `@list_of_state_slots`, doubling the table first when
    # it would pass half full.
    private def place(id : Int32) : Nil
      grow_slots if (id + 1) * 2 > @list_of_state_slots.size
      put_slot(id, @list_of_state_slots.size - 1)
    end

    private def put_slot(id : Int32, mask : Int32) : Nil
      slot = DFACache.key_hash(key_of(id)) & mask
      while @list_of_state_slots.unsafe_fetch(slot) != NO_STATE
        slot = (slot + 1) & mask
      end
      @list_of_state_slots[slot] = id
    end

    private def grow_slots : Nil
      size = @list_of_state_slots.size * 2
      @list_of_state_slots.fill(NO_STATE)
      (size - @list_of_state_slots.size).times { @list_of_state_slots << NO_STATE }
      # The newest state is placed by the caller.
      (state_count - 1).times { |id| put_slot(id, size - 1) }
    end

    private def reserve(bytes : Int64) : Bool
      @reservation.cover(bytes, ceiling: @pool.max_cache_bytes)
    end

    # Clears the cache, charging one operation per state discarded. Returns
    # false when the cache is thrashing (see `LazyDFA`), at the first clear
    # that finds it so when the search can go on from each start
    # (`hands_over_to`).
    private def clear(meter : SearchMeter) : Bool
      meter.charge(state_count, 0)
      @clears += 1
      sparse = @bytes_since_clear < LazyDFA::MINIMUM_BYTES_PER_STATE.to_i64 * @states_since_clear
      @thrashing = true if sparse
      thrashing = sparse && (@clears > LazyDFA::MAX_CLEARS || hands_over?)
      @transition_table.clear
      @list_of_marks.clear
      @list_of_key_values.clear
      @list_of_key_starts.clear
      @list_of_key_starts << 0
      @list_of_state_slots.fill(NO_STATE)
      reset_states
      !thrashing
    end

    private def hands_over? : Bool
      plan = @hands_over_to
      !plan.nil? && !plan.short_match.nil?
    end

    private def reset_states : Nil
      @generation += 1
      @bytes_used = fixed_bytes
      @bytes_since_clear = 0_i64
      @start_entries.fill(-1)
      if state_count == 0
        # Not the builder's key: a clear can run while `intern` holds it.
        dead = StaticArray[0]
        add_state(dead.to_slice, state_bytes(1))
        dead[0] = LazyDFA::MATCH_BEHIND
        add_state(dead.to_slice, state_bytes(1))
      end
      @states_since_clear = 0
    end

    private def state_bytes(key_size : Int32) : Int64
      DFACache.state_bytes_of(@dfa, key_size)
    end
  end

  # :nodoc:
  # Scratch space for building DFA states: a stamped set of visited NFA
  # states, the closure stack, the consuming states in priority order, and
  # the key being built with its own stamped set.
  class DFABuilder
    # A state is visited (or a target) in the current build when its stamp
    # equals the current generation, so starting a build is one increment,
    # and each set takes 4 bytes per NFA state.
    @visited_stamps : OffHeapList(UInt32)
    @visit_generation = 0_u32
    @target_stamps : OffHeapList(UInt32)
    @target_generation = 0_u32
    @stack = OffHeapList(Int32).new
    @outputs = OffHeapList(Int32).new
    @key = OffHeapList(Int32).new

    # The bytes of the two stamp tables per NFA state.
    BYTES_PER_STATE = 8

    def initialize(state_count : Int32)
      @visited_stamps = OffHeapList(UInt32).new(state_count, 0_u32)
      @target_stamps = OffHeapList(UInt32).new(state_count, 0_u32)
    end

    # Returns the scratch lists to libc once the builder is unreachable.
    def finalize
      @visited_stamps.free
      @target_stamps.free
      @stack.free
      @outputs.free
      @key.free
    end

    # The most NFA states (or reverse NFA nodes) a DFA built here may have.
    def node_capacity : Int32
      @visited_stamps.size
    end

    def reset : Nil
      @visit_generation = DFABuilder.next_generation(@visited_stamps, @visit_generation)
      @stack.clear
      @outputs.clear
    end

    # The generation after *generation* for *stamps*, clearing them when
    # the counter wraps around.
    protected def self.next_generation(stamps : OffHeapList(UInt32), generation : UInt32) : UInt32
      generation &+= 1
      return generation unless generation == 0
      stamps.fill(0_u32)
      1_u32
    end

    def push(state : Int32) : Nil
      @stack << state
    end

    def pop? : Int32?
      @stack.pop?
    end

    def clear_stack : Nil
      @stack.clear
    end

    # Marks *state* visited; false when it already was.
    def visit(state : Int32) : Bool
      return false if @visited_stamps.unsafe_fetch(state) == @visit_generation
      @visited_stamps.unsafe_put(state, @visit_generation)
      true
    end

    def output(state : Int32) : Nil
      @outputs << state
    end

    def each_output(& : Int32 ->) : Nil
      @outputs.each { |state| yield state }
    end

    def begin_targets(flags : Int32) : Nil
      @key.clear
      @key << flags
      @target_generation = DFABuilder.next_generation(@target_stamps, @target_generation)
    end

    def add_target(state : Int32) : Nil
      return if @target_stamps.unsafe_fetch(state) == @target_generation
      @target_stamps.unsafe_put(state, @target_generation)
      @key << state
    end

    # The key built so far: the flags, then the targets in the order added.
    # It is the builder's own list, valid until the next build.
    def targets : Slice(Int32)
      Slice.new(@key.to_unsafe, @key.size)
    end

    # The key with its targets sorted in place (reverse states have no
    # priority), with no copy.
    def sorted_targets : Slice(Int32)
      Slice.new(@key.to_unsafe + 1, @key.size - 1).sort! if @key.size > 2
      targets
    end
  end
end
