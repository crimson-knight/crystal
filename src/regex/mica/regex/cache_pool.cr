require "weak_ref"

module Regex::Mica::Regex
  # Accounts for the memory of every lazy-DFA cache and Pike VM workspace
  # in the process (roadmap 6.2.1 and 6.2.4): a cap on the bytes they hold
  # together, kept with an atomic counter, and the list of its members,
  # from which idle ones are reclaimed, least recently used first, when the
  # cap is reached.
  #
  # **Lazy-DFA caches.** Each cache also has its own ceiling
  # (`max_cache_bytes`, 2 MiB by default); a cache that reaches it clears
  # itself and starts over (see `LazyDFA`). A cache grows in
  # `RESERVATION_BYTES` steps, each reserved here first. When a reservation
  # does not fit, idle members are evicted, and when none is left to evict
  # the search runs on the Pike VM instead, which is slower but stays
  # within its bound.
  #
  # **Pike VM workspaces** are the second lease type. Each is charged its
  # `PikeVM.workspace_charge` (bounded by `CompileLimits#max_pike_bytes`,
  # not by `max_cache_bytes`) before its buffer is allocated. When the pool
  # cannot supply one even after evicting every idle member, the search
  # raises `SearchLimitError` naming `cache_pool_max_bytes`: it never
  # allocates past the cap and never returns a wrong answer.
  #
  # The default pool is the one deliberate piece of global state in
  # Mica::Regex, because a process memory cap cannot be per object. An
  # application sets it once, at its boundary, with
  # `Mica::Regex.configure_cache_pool`. Callers that need isolation build
  # their own pool and pass it to `Expression.new`.
  #
  # ```
  # Mica::Regex.configure_cache_pool(max_bytes: 32_i64 * 1024 * 1024)
  # ```
  class CachePool
    # The default cap of the process-wide pool.
    DEFAULT_MAX_BYTES = 64_i64 * 1024 * 1024
    # The default ceiling of one cache.
    DEFAULT_MAX_CACHE_BYTES = 2_i64 * 1024 * 1024
    # The step in which a cache reserves memory.
    RESERVATION_BYTES = 64_i64 * 1024
    # The smallest member-list size at which `register` drops the
    # references of collected members.
    PRUNE_FLOOR = 1024

    # The cap on the bytes all members of this pool hold.
    getter max_bytes : Int64
    # The ceiling of one cache.
    getter max_cache_bytes : Int64
    @reserved = Atomic(Int64).new(0_i64)
    @mutex : Mutex
    @list_of_members : Array(WeakRef(PoolMember))
    # The member-list size at which `register` next drops the references
    # of collected members (see `register`).
    @prune_at = PRUNE_FLOOR
    # Collected members `register` dropped since `reserve` last looked, so
    # `reserve` still knows to collect garbage before it gives up.
    @pruned_since_reserve = 0
    # Counts hand-backs, to order idle members by their last use.
    @clock = Atomic(Int64).new(0_i64)

    def self.new(max_bytes : Int64 = DEFAULT_MAX_BYTES, max_cache_bytes : Int64 = DEFAULT_MAX_CACHE_BYTES) : self
      new(max_bytes, max_cache_bytes, Mutex.new, [] of WeakRef(PoolMember))
    end

    # :nodoc:
    # Builds a pool around the lock and the member list it is given (the
    # process-wide pool gets static ones).
    def initialize(@max_bytes : Int64, @max_cache_bytes : Int64, @mutex : Mutex,
                   @list_of_members : Array(WeakRef(PoolMember)))
      raise ArgumentError.new("max_bytes must be positive") unless @max_bytes > 0
      raise ArgumentError.new("max_cache_bytes must be positive") unless @max_cache_bytes > 0
    end

    # The pool every program starts with, its lock and its member list are
    # static objects, so a program that links Mica starts with the same
    # collector heap as one that does not.
    Mica::Regex.static_object(first_default_mutex, Mutex)
    Mica::Regex.static_object(first_default_members, Array(WeakRef(PoolMember)))
    Mica::Regex.static_object(first_default, CachePool, DEFAULT_MAX_BYTES, DEFAULT_MAX_CACHE_BYTES, @@first_default_mutex,
      @@first_default_members)

    # Held in an atomic so a pool configured on one thread is seen whole
    # by every other.
    @@default = Atomic(CachePool).new(@@first_default)

    # The process-wide pool every expression uses unless it is given one.
    def self.default : CachePool
      @@default.get
    end

    # :nodoc:
    # Replaces the default pool (see `Mica::Regex.configure_cache_pool`).
    def self.default=(pool : CachePool) : CachePool
      @@default.set(pool)
      pool
    end

    # One backtracker kept between programs for their first searches (see
    # `FirstSearch`), which have no lease: a program compiled and searched
    # once then reuses its bitset and job stack instead of allocating them.
    # A spare holds no program and at most
    # `BoundedBacktracker.spare_retained_bytes` (about 60 KiB); it is
    # outside the pool's cap, as the backtracker a lease keeps is.
    @spare_backtracker = Atomic(BoundedBacktracker?).new(nil)

    # :nodoc:
    # Takes the spare backtracker, if one is waiting (one atomic exchange,
    # so two threads never share it), attached to *program*.
    def take_spare_backtracker(program : Program) : BoundedBacktracker?
      backtracker = @spare_backtracker.swap(nil)
      backtracker.try(&.attach(program, program.slot_count))
      backtracker
    end

    # :nodoc:
    # Keeps *backtracker*, detached from its program, as the spare.
    def keep_spare_backtracker(backtracker : BoundedBacktracker) : Nil
      backtracker.detach
      @spare_backtracker.set(backtracker)
    end

    # Returns the bytes reserved now by every member of the pool.
    def reserved_bytes : Int64
      @reserved.get
    end

    # Reserves *bytes* for a member. Evicts idle members (least recently
    # used first) when the cap would be passed; returns false when that is
    # not enough.
    #
    # Members the collector has freed give their bytes back from a
    # finalizer, which runs only after a collection. A process that makes
    # and drops many expressions between collections can fill the pool
    # with bytes no live member holds, so when the pool finds freed members
    # and still has no room, it collects garbage once and tries again.
    def reserve(bytes : Int64) : Bool
      return true if try_reserve(bytes)
      freed = @mutex.synchronize do
        count = prune_collected_members + @pruned_since_reserve
        @pruned_since_reserve = 0
        count
      end
      return true if reserve_by_evicting(bytes)
      return false unless freed > 0
      GC.collect
      try_reserve(bytes)
    end

    # Evicts idle members, least recently used first, until *bytes* fit.
    private def reserve_by_evicting(bytes : Int64) : Bool
      @mutex.synchronize do
        list_of_candidates = [] of PoolMember
        @list_of_members.each do |reference|
          member = reference.value
          list_of_candidates << member if member
        end
        list_of_candidates.sort_by!(&.last_used_tick)
        list_of_candidates.each do |member|
          next unless member.evict_if_idle
          return true if try_reserve(bytes)
        end
      end
      try_reserve(bytes)
    end

    # Reserves *bytes* for *what* (a Pike VM workspace), or raises
    # `SearchLimitError` naming `cache_pool_max_bytes` when the pool cannot
    # supply them.
    def reserve!(bytes : Int64, what : String) : Nil
      return if reserve(bytes)
      raise SearchLimitError.new("cache_pool_max_bytes", @max_bytes,
        "#{what} of #{bytes} bytes, with #{reserved_bytes} bytes of the pool held,", Core::Position.new(0_i64))
    end

    # Gives back *bytes* a member had reserved.
    def release(bytes : Int64) : Nil
      @reserved.add(-bytes) if bytes > 0
    end

    # :nodoc:
    # Records a new member of this pool, so it can be evicted when idle.
    #
    # Every lease registers, and a reference stays in the list after its
    # member is collected, so the list is pruned here as well as in
    # `reserve`: once it reaches `@prune_at`, the references of collected
    # members are dropped and `@prune_at` becomes twice the size that
    # remains (at least `PRUNE_FLOOR`). The list therefore never holds
    # more than `PRUNE_FLOOR` or twice the members that were alive (or not
    # yet collected) at the last prune, whatever the number of expressions
    # ever compiled, and each registration costs amortized constant time.
    def register(member : PoolMember) : Nil
      @mutex.synchronize do
        if @list_of_members.size >= @prune_at
          @pruned_since_reserve += prune_collected_members
          @prune_at = Math.max(PRUNE_FLOOR, @list_of_members.size * 2)
        end
        @list_of_members << WeakRef(PoolMember).new(member)
      end
    end

    # :nodoc:
    # The number of references the member list holds now, live or not
    # (for the leak specs).
    def member_count : Int32
      @mutex.synchronize { @list_of_members.size }
    end

    # Drops the references of collected members and returns how many it
    # dropped. The list is compacted in place, so a prune allocates
    # nothing; its buffer stays at the size the list last reached, which
    # `register` bounds. The caller holds `@mutex`.
    private def prune_collected_members : Int32
      count = @list_of_members.size
      @list_of_members.reject!(&.value.nil?)
      count - @list_of_members.size
    end

    # :nodoc:
    # The next tick of the pool clock (see `PoolMember#note_use`).
    #
    # The clock advances with a relaxed load and store rather than an
    # atomic add, which would cost a search more than the rest of its
    # hand-back: two threads that hand back at once may share a tick, and
    # then tie for eviction order. The ordering stays exact on one thread.
    def tick : Int64
      tick = @clock.get(:relaxed) &+ 1
      @clock.set(tick, :relaxed)
      tick
    end

    private def try_reserve(bytes : Int64) : Bool
      current = @reserved.get
      loop do
        return false if current + bytes > @max_bytes
        current, swapped = @reserved.compare_and_set(current, current + bytes)
        return true if swapped
      end
    end
  end

  # :nodoc:
  # Memory a `CachePool` accounts for and may reclaim while no search holds
  # it: a `SearchLease`, with its lazy-DFA caches (`DFACache`) and the Pike
  # VM workspace (`PikeVM`) it keeps between calls.
  #
  # Who holds a member is decided by where it sits, not by a flag of its
  # own: an idle member waits in a slot its owner shares (a `SearchPlan`'s
  # hot slot or idle list), and whoever takes it out of that slot (a search
  # or the pool's evictor) holds it alone until it puts it back. A search
  # therefore takes and returns a member with one atomic operation each.
  # An evicted member stays usable: it rebuilds what it needs, reserving
  # again, when next used.
  abstract class PoolMember
    @last_used_tick = Atomic(Int64).new(0_i64)

    # Drops the memory the member holds and gives its bytes back to the
    # pool, when no search holds the member. Returns true when it did.
    abstract def evict_if_idle : Bool

    # The pool tick of the member's last hand-back.
    def last_used_tick : Int64
      @last_used_tick.get(:relaxed)
    end

    # Records that the member was handed back at pool tick *tick*.
    def note_use(tick : Int64) : Nil
      @last_used_tick.set(tick, :relaxed)
    end
  end

  # :nodoc:
  # The bytes one `PoolMember` has reserved from its pool. It is a separate
  # object, referring to nothing but the pool, so its finalizer can give
  # the bytes back when the member is collected without a finalization
  # cycle (the member itself is reachable from its own program).
  class CacheReservation
    getter bytes = 0_i64
    getter pool : CachePool

    def initialize(@pool : CachePool)
    end

    # Reserves enough to hold *total* bytes in all, in steps of at least
    # *step* bytes (`CachePool::RESERVATION_BYTES` for a lazy-DFA cache,
    # 1 for a Pike VM workspace, which reserves its exact charge), never
    # holding more than *ceiling* bytes (a lazy-DFA cache's
    # `max_cache_bytes`); false when *total* is over *ceiling* or the pool
    # refuses.
    def cover(total : Int64, step minimum_step : Int64 = CachePool::RESERVATION_BYTES,
              ceiling : Int64 = Int64::MAX) : Bool
      return true if total <= @bytes
      return false if total > ceiling
      step = Math.min(Math.max(minimum_step, total - @bytes), ceiling - @bytes)
      return false unless @pool.reserve(step)
      @bytes += step
      true
    end

    def release_all : Nil
      @pool.release(@bytes)
      @bytes = 0_i64
    end

    def finalize
      @pool.release(@bytes)
    end
  end

  # Replaces the process-wide `CachePool` with one capped at *max_bytes*,
  # each cache at *max_cache_bytes*. Call it once, at the application
  # boundary, before expressions are searched.
  def self.configure_cache_pool(*, max_bytes : Int64,
                                max_cache_bytes : Int64 = CachePool::DEFAULT_MAX_CACHE_BYTES) : CachePool
    CachePool.default = CachePool.new(max_bytes, max_cache_bytes)
  end
end
