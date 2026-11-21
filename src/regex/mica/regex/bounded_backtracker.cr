module Regex::Mica::Regex
  # The bounded backtracker (RE2's BitState): a depth-first search in
  # leftmost-first priority order that marks every (state, position) pair
  # it visits in a bitset and never visits one twice. A pair that was
  # visited and did not lead to a match cannot lead to one later, because
  # whether a state matches from a position does not depend on the
  # captures recorded on the way there.
  #
  # It runs only when the bitset is small and its memory fits: `fits?`
  # requires m × (L + 1) ≤ `MAX_VISITED_BITS` for m states over a span of
  # L bytes, and `allocation_charge` within the program's
  # `Program#backtracker_allowance` (what the Pike VM workspace leaves of
  # `CompileLimits#max_pike_bytes`).
  #
  # **Bounds.** Time O(m·(L + 1) + c): each pair is visited once and each
  # visit pushes at most one job (a second branch or a slot restore).
  # Memory: m·(L + 1)/8 bytes of bitset, a job stack of at most
  # m·(L + 1) + 1 entries of 16 bytes, and c slots; `allocation_charge`
  # counts them as the collector hands them out. The job stack grows as a
  # search needs it, in chunks that double in size (`FIRST_JOB_CHUNK`
  # entries, then twice as many, and so on), the last one cut so the stack
  # never holds more than m·(L + 1) + 1 entries for the longest span it has
  # searched. A chunk is never copied or moved, so the stack never holds
  # more than that bound plus one granule per chunk, and a search that
  # needs few jobs allocates few.
  #
  # **Capped searches over a large program.** A first search and a
  # backtracked match start (see "First searches" in docs/regex.md) stop
  # after a set number of visits. When such a search's bitset would not
  # fit (a program of thousands of states, as `\p{L}{50}` compiles to),
  # it marks visited pairs in a hash set instead (`fits_capped?`), which
  # holds at most `SPARSE_VISITS` pairs: the search then makes at most
  # that many visits, and its memory (the set and a job stack of at most
  # `SPARSE_VISITS` + 1 entries) is known before it starts
  # (`sparse_allocation_charge`). The pairs it visits, and so its result,
  # are the same as with the bitset.
  #
  # Each visit and each slot undo entry is charged one operation to the
  # `SearchMeter`.
  #
  # WARNING: A backtracker belongs to one fiber.
  class BoundedBacktracker
    # The largest visited bitset, in bits (256 Ki bits, 32 KiB).
    MAX_VISITED_BITS = 256_i64 * 1024
    # Entries in the first chunk of the job stack (512 bytes): a first
    # search of a short pattern pushes a few dozen jobs, and each byte it
    # allocates counts toward the collector's next collection.
    FIRST_JOB_CHUNK = 32_i64
    # The most chunks the job stack has: the doubling chunks reach
    # `MAX_VISITED_BITS` + 1 entries within 14, whatever was cut before.
    MAX_JOB_CHUNKS = 16

    # The most visits a search that marks pairs in a hash set makes (see
    # "Capped searches" above).
    SPARSE_VISITS = 16_384_i64
    # Slots in the hash set at its largest: twice `SPARSE_VISITS`, a power
    # of two, so the set is at most half full.
    SPARSE_SLOTS = 2_i64 * SPARSE_VISITS
    # A pair key (and one) in the hash set takes the low `SPARSE_KEY_BITS`
    # bits of its entry; the search's generation takes the bits above
    # (see `clear_sparse`).
    SPARSE_KEY_BITS  = 40
    SPARSE_KEY_LIMIT = 1_i64 << SPARSE_KEY_BITS
    # Generations wrap before they reach the entry's top bit.
    SPARSE_GENERATIONS = 1_u64 << (64 - SPARSE_KEY_BITS - 1)
    # Slots in the hash set when a search first needs it.
    FIRST_SPARSE_SLOTS = 1024

    # Returns true when a search of *program* over a span of *span_bytes*
    # bytes fits the bitset gate.
    def self.fits?(program : Program, span_bytes : Int32) : Bool
      return false unless visited_bits(program, span_bytes) <= MAX_VISITED_BITS
      allocation_charge(program, span_bytes) <= program.backtracker_allowance
    end

    # Returns true when a search of *program* over *span_bytes* bytes that
    # makes at most `visit_limit` visits (a first search or a backtracked
    # start) fits: within the bitset gate, or else with a hash set of
    # visited pairs within the program's backtracker allowance.
    def self.fits_capped?(program : Program, span_bytes : Int32) : Bool
      return true if fits?(program, span_bytes)
      visited_bits(program, span_bytes) < SPARSE_KEY_LIMIT &&
        sparse_allocation_charge(program) <= program.backtracker_allowance
    end

    # The most visits a capped search of *program* over *span_bytes* bytes
    # can make: one per (state, position) pair within the bitset gate, at
    # most `SPARSE_VISITS` with a hash set.
    def self.capped_visits(program : Program, span_bytes : Int32) : Int64
      return visited_bits(program, span_bytes) if fits?(program, span_bytes)
      SPARSE_VISITS
    end

    # Returns the bytes the collector hands out for a capped search that
    # marks visited pairs in a hash set: the set at its largest (and the
    # smaller sets it grew from), the job stack of `SPARSE_VISITS` + 1
    # entries, the slots and this object.
    def self.sparse_allocation_charge(program : Program) : Int64
      set = AllocationLedger.granules(SPARSE_SLOTS * 2 * sizeof(UInt64))
      jobs = AllocationLedger.granules((SPARSE_VISITS + 1) * sizeof(Job)) + (MAX_JOB_CHUNKS - 1) * AllocationLedger::GRANULE
      slots = AllocationLedger.granules(program.slot_count.to_i64 * sizeof(Int64))
      set + jobs + slots + AllocationLedger.granules(instance_sizeof(BoundedBacktracker))
    end

    # Returns the bytes the collector hands out for a backtracker of
    # *program* searching a span of *span_bytes* bytes: the bitset, the job
    # stack, the slots and this object, each rounded up to the collector's
    # granule (`AllocationLedger.granules`).
    def self.allocation_charge(program : Program, span_bytes : Int32) : Int64
      bits = visited_bits(program, span_bytes)
      bitset = AllocationLedger.granules((bits + 63) // 64 * 8)
      # Every chunk adds at most one granule to the entries it holds.
      jobs = AllocationLedger.granules((bits + 1) * sizeof(Job)) + (MAX_JOB_CHUNKS - 1) * AllocationLedger::GRANULE
      slots = AllocationLedger.granules(program.slot_count.to_i64 * sizeof(Int64))
      bitset + jobs + slots + AllocationLedger.granules(instance_sizeof(BoundedBacktracker))
    end

    private def self.visited_bits(program : Program, span_bytes : Int32) : Int64
      program.state_count.to_i64 * (span_bytes.to_i64 + 1)
    end

    # A job: explore *state* at *at*, or (when *state* is negative) restore
    # slot -(state + 1) to the value *at*.
    private record Job, state : Int32, at : Int64

    @slots : Slice(Int64)
    @visited : Slice(UInt64)
    # The visited pairs of a capped search whose bitset would not fit: an
    # open-addressing set, at most half full, of entries that hold
    # `pair key + 1` below the search's generation (see `clear_sparse`);
    # an entry of an earlier generation is empty.
    @sparse_visited = Slice(UInt64).empty
    @sparse_count = 0
    @sparse_generation = 0_u64
    @sparse = false
    # The job stack: @chunk_count chunks allocated, holding @job_capacity
    # entries in all; the jobs in use fill the chunks before @chunk_index
    # and the first @in_chunk entries of @chunk (chunk @chunk_index, of
    # @chunk_size entries).
    @list_of_chunks = StaticArray(Pointer(Job), MAX_JOB_CHUNKS).new(Pointer(Job).null)
    @list_of_chunk_sizes = StaticArray(Int64, MAX_JOB_CHUNKS).new(0_i64)
    @chunk_count = 0
    @job_capacity = 0_i64
    # The most jobs the current search may hold (m·(L + 1) + 1).
    @job_limit = 0_i64
    @job_count = 0_i64
    @chunk = Pointer(Job).null
    @chunk_index = -1
    @chunk_size = 0_i64
    @in_chunk = 0_i64
    # The most visits one search may make before it gives up (see
    # `gave_up?`); unlimited unless set.
    setter visit_limit : Int64 = Int64::MAX
    @visits_left = Int64::MAX
    # The fewest bytes a match reads from each state (see
    # `Program#list_of_min_bytes`), for a search that must end by its
    # bound: a pair whose state cannot reach a match before the bound is
    # dropped unvisited. Nil (the default) checks nothing.
    setter list_of_min_bytes : Array(Int32)? = nil
    # True when the last search reached `visit_limit` before it decided.
    getter? gave_up = false

    def initialize(program : Program, @slot_count : Int32)
      @program = program
      @slots = owned(OffHeap.slice(Int64, @slot_count, PikeVM::UNSET))
      @visited = Slice(UInt64).empty
    end

    # Every buffer sits outside the collector's heap (`OffHeap`), as
    # PCRE2's match data does. A lease's backtracker is reachable from its
    # own program, so an owner outside that cycle frees them (see
    # `OffHeapOwner`): each buffer is recorded there as it is made
    # (`owned`) and forgotten as it is freed (`disown`).
    @owner = OffHeapOwner.new

    private def owned(buffer : Slice(T)) : Slice(T) forall T
      @owner.track(buffer.to_unsafe)
      buffer
    end

    private def owned(buffer : Pointer(T)) : Pointer(T) forall T
      @owner.track(buffer)
      buffer
    end

    private def disown(buffer : Slice) : Nil
      disown(buffer.to_unsafe)
    end

    private def disown(buffer : Pointer) : Nil
      @owner.untrack(buffer)
      OffHeap.free(buffer)
    end

    # The program this backtracker searches; nil while it waits as a
    # pool's spare (see `CachePool#take_spare_backtracker`).
    @program : Program?

    # The most bytes a spare backtracker keeps between programs (see
    # `detach`): its bitset at its largest (`MAX_VISITED_BITS`, 32 KiB),
    # the first chunks of its job stack and a hash set of up to
    # `SPARE_SPARSE_SLOTS` pairs.
    SPARE_JOB_CHUNKS   =    5
    SPARE_SPARSE_SLOTS = 2048

    # Points this backtracker at *program* for its next searches, keeping
    # the buffers it already has (a spare taken from a `CachePool`).
    def attach(program : Program, slot_count : Int32) : Nil
      @program = program
      @slot_count = slot_count
      if @slots.size < slot_count
        disown(@slots)
        @slots = owned(OffHeap.slice(Int64, slot_count, PikeVM::UNSET))
      end
      @visit_limit = Int64::MAX
      # Another program numbers its states differently.
      @list_of_min_bytes = nil
    end

    # Lets go of the program and frees what a spare does not keep (the job
    # chunks past `SPARE_JOB_CHUNKS`, a hash set larger than
    # `SPARE_SPARSE_SLOTS`), so a spare holds at most
    # `spare_retained_bytes`, and no program.
    def detach : Nil
      @program = nil
      @list_of_min_bytes = nil
      while @chunk_count > SPARE_JOB_CHUNKS
        last = @chunk_count - 1
        disown(@list_of_chunks[last])
        @job_capacity -= @list_of_chunk_sizes[last]
        @list_of_chunks[last] = Pointer(Job).null
        @list_of_chunk_sizes[last] = 0_i64
        @chunk_count = last
      end
      if @sparse_visited.size > SPARE_SPARSE_SLOTS
        disown(@sparse_visited)
        @sparse_visited = Slice(UInt64).empty
      end
    end

    # The most bytes a detached backtracker holds (see `detach`).
    def self.spare_retained_bytes : Int64
      jobs = (FIRST_JOB_CHUNK << SPARE_JOB_CHUNKS) - FIRST_JOB_CHUNK
      MAX_VISITED_BITS // 8 + jobs * sizeof(Job) + SPARE_SPARSE_SLOTS * sizeof(UInt64)
    end

    # Searches like `PikeVM#search`, over *start*..*end_bound*, which must
    # satisfy `fits?`, with the same *first_line_end* bound. Fills *slots*
    # and returns true on a match.
    def search(haystack : Bytes, start : Int32, end_bound : Int32, search_start : Int32, anchored : Bool,
               end_anchored : Bool, meter : SearchMeter, slots : Slice(Int64),
               first_line_end : Int32) : Bool
      program = @program || raise Mica::Error.new("internal error: a spare backtracker searched before it was attached")
      span = end_bound - start
      columns = span + 1
      bits = program.state_count.to_i64 * columns
      if BoundedBacktracker.fits?(program, span)
        @sparse = false
        words = ((bits + 63) // 64).to_i32
        if @visited.size < words
          disown(@visited)
          @visited = owned(OffHeap.slice(UInt64, words, 0_u64))
        else
          @visited.fill(0_u64, 0, words)
        end
        # Each visit pushes at most one job, after the one each start pushes.
        limit_jobs(bits + 1)
        @visits_left = @visit_limit
      elsif @visit_limit != Int64::MAX && BoundedBacktracker.fits_capped?(program, span)
        @sparse = true
        clear_sparse
        limit_jobs(SPARSE_VISITS + 1)
        @visits_left = Math.min(@visit_limit, SPARSE_VISITS)
      else
        raise ArgumentError.new("A span of #{span} bytes does not fit the backtracker's bitset")
      end
      @gave_up = false
      at = start
      while at <= end_bound
        if at == start || (!anchored && boundary?(haystack, at) && at <= first_line_end)
          @slots.fill(PikeVM::UNSET)
          if explore_from(program, haystack, start, columns, at, end_bound, search_start, end_anchored, meter)
            @slot_count.times { |slot| slots[slot] = @slots[slot] }
            return true
          end
          return false if @gave_up
        end
        # No later position may start a thread: anchored, or past the
        # FirstLine bound. Reading on would advance uncharged.
        break if anchored || at >= first_line_end
        at += 1
      end
      false
    end

    private def explore_from(program : Program, haystack : Bytes, start : Int32, columns : Int32, from : Int32, end_bound : Int32,
                             search_start : Int32, end_anchored : Bool, meter : SearchMeter) : Bool
      clear_jobs
      push_job(program.start_state, from.to_i64)
      # While the program's runs are pending (a first search), the run the
      # last state read was found in: states first_state...end_state.
      runs_pending = program.runs_pending?
      run_slot = -1
      run_first = 0
      run_end = 0
      # Locals for the loop, so a visit does not reload them: the visited
      # bitset does not move during a search, and the visits left are
      # written back before every return and before `follow_run`, which
      # counts its own visits.
      sparse = @sparse
      visited_words = @visited.to_unsafe
      visits_left = @visits_left
      min_bytes = @list_of_min_bytes
      while @job_count > 0
        job = pop_job
        if job.state < 0
          @slots[-(job.state + 1)] = job.at
          next
        end
        if job.state >= STARTS_JOB
          @visits_left = visits_left
          current, at = take_from_starts(program, job, haystack, start, columns, end_bound, meter)
          visits_left = @visits_left
          return false if current == GAVE_UP
          next if current < 0
        else
          current = job.state
          at = job.at.to_i32
        end
        while true
          # A state whose fewest bytes to a match pass the bound fails
          # whatever it reads (the search reads nothing at or past it).
          break if min_bytes && end_bound - at < min_bytes.unsafe_fetch(current)
          bit = current.to_i64 * columns + (at - start)
          if sparse
            break unless mark_sparse?(bit)
          else
            word = bit >> 6
            mask = 1_u64 << (bit & 63)
            visited = visited_words + word
            break if visited.value & mask != 0
            visited.value |= mask
          end
          if (visits_left -= 1) < 0
            @visits_left = visits_left
            @gave_up = true
            return false
          end
          meter.charge(1, at)
          if runs_pending
            unless run_first <= current < run_end
              run_slot = program.pending_run_slot(current) { meter.charge(1, at) }
              meter.charge(1, at)
              if run_slot >= 0
                run = program.list_of_runs.unsafe_fetch(run_slot)
                run_first = run.first_state
                run_end = run.end_state
              else
                run_first = run_end = 0
              end
            end
            run = run_first <= current < run_end ? program.list_of_runs.unsafe_fetch(run_slot) : nil
            if run && !run.optional
              @visits_left = visits_left
              current, at = follow_run(program, run, current, at, haystack, start, columns, end_bound, meter)
              visits_left = @visits_left
              return false if current == GAVE_UP
              break if current < 0
              next
            end
            # An optional run (`x{n,m}`) splits after each copy, so its
            # states are walked one by one, as written states are.
            state = run ? run.state_at(current) : program.state_outside_runs(current, run_slot)
          else
            state = program.state_at(current, meter, at)
          end
          case state.kind
          when .byte_range?
            break unless at < end_bound
            byte = haystack.unsafe_fetch(at)
            break unless state.low <= byte <= state.high
            current = state.next_state
            at += 1
          when .sparse?
            break unless at < end_bound
            target = program.sparse_target(current, state, haystack.unsafe_fetch(at))
            break if target < 0
            current = target
            at += 1
          when .split?
            unless runs_pending
              body = program.state_at(state.next_state)
              if body.kind.byte_range? || body.kind.sparse?
                @visits_left = visits_left
                current, at = follow_byte_loop(program, current, state, body, at, haystack, start, columns,
                  end_bound, meter)
                visits_left = @visits_left
                return false if current == GAVE_UP
                break if current < 0
                next
              end
            end
            push_job(state.alternate, at.to_i64)
            current = state.next_state
          when .save?
            slot = state.argument
            if slot < @slot_count
              meter.charge(1, at)
              push_job(-(slot + 1), @slots[slot])
              @slots[slot] = at.to_i64
            end
            current = state.next_state
          when .look?
            break unless Look.holds?(Program::LookKind.new(state.argument), haystack, at, search_start)
            current = state.next_state
          when .match?
            break if end_anchored && at != haystack.size
            @visits_left = visits_left
            return true
          else
            break
          end
        end
      end
      @visits_left = visits_left
      false
    end

    # `follow_run`'s answer when the search reached its visit limit.
    private GAVE_UP = -2

    # Added to a state number, a job of starts: explore that state at each
    # position from the first to the last, the last first, as the jobs one
    # `Split` per position pushes would be taken (see `follow_byte_loop`).
    # The job's `at` holds the first position in its high 32 bits and the
    # last in its low ones.
    private STARTS_JOB = 1 << 30

    # Follows a `Split` (number *split_index*, its pair at *at* marked and
    # charged) whose preferred branch is *body*, a byte state, for as long
    # as the byte read leads back to the split: a greedy loop such as
    # `.*`. It visits the pairs the general loop would, in the same order
    # and with the same charges, but pushes the alternate at each position
    # it passes as one job of starts. Returns the state after the body,
    # with its position, when the body leaves the loop; -1 when the thread
    # ends (a byte the body does not take, a pair visited before, the end
    # of the span); `GAVE_UP` at the visit limit.
    private def follow_byte_loop(program : Program, split_index : Int32, split : Program::State, body : Program::State,
                                 at : Int32, haystack : Bytes, start : Int32, columns : Int32, end_bound : Int32,
                                 meter : SearchMeter) : {Int32, Int32}
      body_index = split.next_state
      body_bits = body_index.to_i64 * columns - start
      split_bits = split_index.to_i64 * columns - start
      first = at
      # The ASCII bytes known to lead back to the split, so a run of text
      # reads the body's ranges once per byte value rather than once per
      # position.
      staying = 0_u128
      # Visits are charged in windows the meter allows (`SearchMeter#readable`),
      # so it is checked at the same visit as a charge per visit would be.
      credit = 0
      uncharged = 0
      last = at
      next_state = -1
      # The fewest bytes to a match from the body and the split, when the
      # search prunes by them (see `list_of_min_bytes=`): a pair that cannot
      # reach a match before the bound ends the thread unvisited, as in the
      # general loop.
      body_min = 0
      split_min = 0
      if min_bytes = @list_of_min_bytes
        body_min = min_bytes.unsafe_fetch(body_index)
        split_min = min_bytes.unsafe_fetch(split_index)
      end
      while true
        break if end_bound - at < body_min
        break unless first_visit?(body_bits + at)
        if credit == 0
          meter.charge(uncharged, at) if uncharged > 0
          uncharged = 0
          credit = meter.readable(2 * (end_bound - at) + 2, at)
        end
        unless count_visit
          next_state = GAVE_UP
          break
        end
        credit -= 1
        uncharged += 1
        break unless at < end_bound
        byte = haystack.unsafe_fetch(at)
        target = if byte < 128 && (staying >> byte) & 1 == 1
                   split_index
                 else
                   byte_target(program, body_index, body, byte)
                 end
        unless target == split_index
          next_state = target
          break
        end
        staying |= 1_u128 << byte if byte < 128
        last = at
        at += 1
        break if end_bound - at < split_min
        break unless first_visit?(split_bits + at)
        if credit == 0
          meter.charge(uncharged, at) if uncharged > 0
          uncharged = 0
          credit = meter.readable(2 * (end_bound - at) + 2, at)
        end
        unless count_visit
          next_state = GAVE_UP
          break
        end
        credit -= 1
        uncharged += 1
        last = at
      end
      meter.charge(uncharged, at) if uncharged > 0
      return {GAVE_UP, at} if next_state == GAVE_UP
      push_starts(split.alternate, first, last)
      next_state < 0 ? {-1, at} : {next_state, at + 1}
    end

    # Takes the next start from a job of starts, leaving the rest on the
    # stack, and returns the pair to explore, not yet marked. When the
    # job's state is a byte state, the starts whose byte it does not take
    # are visited here (marked, counted and charged, as the general loop
    # would), and the pair returned is the one after the byte it takes.
    # Returns -1 when no start is left to explore and `GAVE_UP` at the
    # visit limit.
    private def take_from_starts(program : Program, job : Job, haystack : Bytes, start : Int32, columns : Int32,
                                 end_bound : Int32, meter : SearchMeter) : {Int32, Int32}
      state_index = job.state - STARTS_JOB
      first = (job.at >> 32).to_i32
      at = (job.at & 0xFFFF_FFFF).to_i32
      state = program.state_at(state_index)
      unless state.kind.byte_range? || state.kind.sparse?
        push_starts(state_index, first, at - 1) if at > first
        return {state_index, at}
      end
      state_bits = state_index.to_i64 * columns - start
      # The ASCII bytes the state is known not to take, and the visits
      # charged in windows, as in `follow_byte_loop`.
      refused = 0_u128
      credit = 0
      uncharged = 0
      target = -1
      # Starts too close to the bound to reach a match are dropped
      # unvisited, as the general loop drops them (see `list_of_min_bytes=`).
      state_min = 0
      if min_bytes = @list_of_min_bytes
        state_min = min_bytes.unsafe_fetch(state_index)
      end
      while at >= first
        if end_bound - at >= state_min && first_visit?(state_bits + at)
          if credit == 0
            meter.charge(uncharged, at) if uncharged > 0
            uncharged = 0
            credit = meter.readable(at - first + 1, at)
          end
          unless count_visit
            target = GAVE_UP
            break
          end
          credit -= 1
          uncharged += 1
          if at < end_bound
            byte = haystack.unsafe_fetch(at)
            unless byte < 128 && (refused >> byte) & 1 == 1
              target = byte_target(program, state_index, state, byte)
              break if target >= 0
              refused |= 1_u128 << byte if byte < 128
            end
          end
        end
        at -= 1
      end
      meter.charge(uncharged, at) if uncharged > 0
      return {GAVE_UP, at} if target == GAVE_UP
      return {-1, at} if target < 0
      push_starts(state_index, first, at - 1) if at > first
      {target, at + 1}
    end

    # Counts one visit against the search's visit limit; false (having
    # set `gave_up?`) when the limit is reached.
    @[AlwaysInline]
    private def count_visit : Bool
      return true if (@visits_left -= 1) >= 0
      @gave_up = true
      false
    end

    # Pushes the starts of *state* from *first* to *last* as one job.
    @[AlwaysInline]
    private def push_starts(state : Int32, first : Int32, last : Int32) : Nil
      push_job(state + STARTS_JOB, (first.to_i64 << 32) | last.to_i64)
    end

    # The target of byte state *state* (number *state_index*) for *byte*,
    # or -1.
    @[AlwaysInline]
    private def byte_target(program : Program, state_index : Int32, state : Program::State, byte : UInt8) : Int32
      if state.kind.byte_range?
        state.low <= byte <= state.high ? state.next_state : -1
      else
        program.sparse_target(state_index, state, byte)
      end
    end

    # Follows the class copies of *run* from *current* (a state of the run
    # whose pair at *at* is marked and charged) over the haystack, and
    # returns the state after the run with the position there, or -1 when
    # a byte leaves the class or the pair of a copy's entry was visited
    # before (`GAVE_UP` at the visit limit).
    #
    # A copy is a deterministic automaton over one UTF-8 sequence (its
    # `Sparse` ranges are disjoint), entered only at its entry, so a pair
    # inside a copy is reached from one entry pair alone: only the entry
    # pairs are marked, which keeps every visit at most once, and the
    # states are read from the run's block (no lookup of the run per
    # state). Each state read is one visit and one operation, as in
    # `explore_from`.
    private def follow_run(program : Program, run : Program::ClassRun, current : Int32, at : Int32, haystack : Bytes,
                           start : Int32, columns : Int32, end_bound : Int32, meter : SearchMeter) : {Int32, Int32}
      block = run.list_of_block_states
      block_size = block.size
      table = run.table_id == 0 ? program.transition_table : program.list_of_shared_tables.unsafe_fetch(run.table_id.to_i32 - 1).to_unsafe
      relative = current - run.first_state
      copy = relative.unsafe_div(block_size)
      copy_first = run.first_state + copy * block_size
      inner = relative - copy * block_size
      entry_targets = run.entry_targets
      while true
        return {-1, at} unless at < end_bound
        state = block.unsafe_fetch(inner)
        byte = haystack.unsafe_fetch(at)
        if state.kind.sparse?
          target = if entry_targets && inner == run.entry
                     entry_targets.unsafe_fetch(byte)
                   else
                     BoundedBacktracker.table_target(table, state.argument, state.alternate, byte)
                   end
          return {-1, at} if target == ClassMemo::NO_TRANSITION
          leaves = target == Program::SHARED_EXIT
          inner += target unless leaves
        elsif state.kind.byte_range?
          return {-1, at} unless state.low <= byte <= state.high
          target = state.next_state
          leaves = target == ClassMemo::EXIT
          inner = target unless leaves
        else
          return {-1, at}
        end
        at += 1
        if leaves
          return {run.exit, at} if copy == 0
          copy -= 1
          copy_first -= block_size
          inner = run.entry
          return {-1, at} unless first_visit?((copy_first + inner).to_i64 * columns + (at - start))
        end
        if (@visits_left -= 1) < 0
          @gave_up = true
          return {GAVE_UP, at}
        end
        meter.charge(1, at)
      end
    end

    # The target of the transition among *count* of *table* from *first*
    # that holds *byte*, or `ClassMemo::NO_TRANSITION`: a binary search over sorted,
    # disjoint ranges, as `Program#sparse_target`.
    @[AlwaysInline]
    protected def self.table_target(table : Pointer(Program::Transition), first : Int32, count : Int32, byte : UInt8) : Int32
      low = first
      high = first + count
      while low < high
        middle = (low + high) >> 1
        transition = table[middle]
        if transition.high < byte
          low = middle + 1
        elsif transition.low > byte
          high = middle
        else
          return transition.target
        end
      end
      ClassMemo::NO_TRANSITION
    end

    # Marks the pair *bit* visited; false when it already was.
    @[AlwaysInline]
    private def first_visit?(bit : Int64) : Bool
      return mark_sparse?(bit) if @sparse
      visited = @visited.to_unsafe + (bit >> 6)
      mask = 1_u64 << (bit & 63)
      return false if visited.value & mask != 0
      visited.value |= mask
      true
    end

    # Sets the most jobs a search may hold to *limit*. The stack is empty
    # between searches, so a last chunk cut short for a smaller limit is
    # freed, to be allocated again at the size this limit allows.
    private def limit_jobs(limit : Int64) : Nil
      @job_limit = limit
      last = @chunk_count - 1
      return unless last >= 0 && @job_capacity < limit && @list_of_chunk_sizes[last] < FIRST_JOB_CHUNK << last
      disown(@list_of_chunks[last])
      @job_capacity -= @list_of_chunk_sizes[last]
      @list_of_chunks[last] = Pointer(Job).null
      @list_of_chunk_sizes[last] = 0_i64
      @chunk_count = last
    end

    # Empties the hash set of visited pairs, allocating its first table the
    # first time. A search starts a new generation, which leaves every
    # entry of the earlier ones empty without writing the table (a capped
    # search over a short span marks a few hundred pairs, where clearing
    # a table the set grew to for a longer one writes up to 256 KiB); the
    # table is cleared only when the generations wrap.
    private def clear_sparse : Nil
      @sparse_count = 0
      @sparse_generation += 1
      if @sparse_visited.empty?
        @sparse_visited = owned(OffHeap.slice(UInt64, FIRST_SPARSE_SLOTS, 0_u64))
        @sparse_generation = 1_u64
      elsif @sparse_generation >= SPARSE_GENERATIONS
        @sparse_visited.fill(0_u64)
        @sparse_generation = 1_u64
      end
    end

    # Marks pair *bit* visited in the hash set; returns false when it
    # already was. The set doubles when it would pass half full; it never
    # holds more than `SPARSE_VISITS` pairs, as each pair is one visit.
    private def mark_sparse?(bit : Int64) : Bool
      generation = @sparse_generation
      key = (generation << SPARSE_KEY_BITS) | (bit.to_u64! &+ 1)
      mask = @sparse_visited.size - 1
      index = sparse_hash(key) & mask
      while (found = @sparse_visited.unsafe_fetch(index)) >> SPARSE_KEY_BITS == generation
        return false if found == key
        index = (index + 1) & mask
      end
      @sparse_visited[index] = key
      @sparse_count += 1
      grow_sparse if @sparse_count * 2 > @sparse_visited.size && @sparse_visited.size < SPARSE_SLOTS
      true
    end

    @[AlwaysInline]
    private def sparse_hash(key : UInt64) : Int32
      ((key &* 0x9E3779B97F4A7C15_u64) >> 40).to_i32!
    end

    private def grow_sparse : Nil
      old = @sparse_visited
      grown = owned(OffHeap.slice(UInt64, old.size * 2, 0_u64))
      mask = grown.size - 1
      generation = @sparse_generation
      old.each do |key|
        next unless key >> SPARSE_KEY_BITS == generation
        index = sparse_hash(key) & mask
        while grown.unsafe_fetch(index) != 0
          index = (index + 1) & mask
        end
        grown[index] = key
      end
      disown(old)
      @sparse_visited = grown
    end

    private def clear_jobs : Nil
      @job_count = 0_i64
      @chunk = Pointer(Job).null
      @chunk_index = -1
      @chunk_size = 0_i64
      @in_chunk = 0_i64
    end

    # Pushes a job, moving to the next chunk (allocating it the first time)
    # when the current one is full.
    @[AlwaysInline]
    private def push_job(state : Int32, at : Int64) : Nil
      next_chunk if @in_chunk == @chunk_size
      @chunk[@in_chunk] = Job.new(state, at)
      @in_chunk += 1
      @job_count += 1
    end

    # Pops the last job; the stack must not be empty.
    @[AlwaysInline]
    private def pop_job : Job
      if @in_chunk == 0
        @chunk_index -= 1
        @chunk = @list_of_chunks[@chunk_index]
        @chunk_size = @list_of_chunk_sizes[@chunk_index]
        @in_chunk = @chunk_size
      end
      @in_chunk -= 1
      @job_count -= 1
      @chunk[@in_chunk]
    end

    # Moves to the next chunk, allocating it when needed. Each visit pushes
    # at most one job, after the one each start pushes, so a stack that
    # would pass the search's limit is a defect, reported as one.
    private def next_chunk : Nil
      index = @chunk_index + 1
      if index == @chunk_count
        room = @job_limit - @job_capacity
        if room <= 0 || index >= MAX_JOB_CHUNKS
          raise Mica::Error.new("internal error: the backtracker pushed more than its #{@job_limit} jobs")
        end
        size = Math.min(FIRST_JOB_CHUNK << index, room)
        @list_of_chunks[index] = owned(OffHeap.pointer(Job, size))
        @list_of_chunk_sizes[index] = size
        @job_capacity += size
        @chunk_count += 1
      end
      @chunk_index = index
      @chunk = @list_of_chunks[index]
      @chunk_size = @list_of_chunk_sizes[index]
      @in_chunk = 0_i64
    end

    private def boundary?(haystack : Bytes, at : Int32) : Bool
      at >= haystack.size || haystack.unsafe_fetch(at) & 0xC0 != 0x80
    end
  end
end
