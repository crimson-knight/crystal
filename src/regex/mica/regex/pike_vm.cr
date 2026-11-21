module Regex::Mica::Regex
  # The Pike VM: runs a `Program` over a haystack in one forward pass,
  # carrying every live thread in priority order, so it reports the
  # leftmost-first match (Perl and PCRE2 priority) with its captures.
  #
  # **Two layouts** (roadmap 6.2.1). A workspace is built for span searches
  # only, or for captures as well:
  #
  # - **span** (`captures: false`), 32·m bytes for m states: two sparse
  #   sets (a dense and a sparse `UInt32` array of m entries each, 16·m),
  #   the epsilon-closure stack (m one-word frames, 8·m) and two `Int32`
  #   tables of thread start positions (8·m). It finds group 0 only: a
  #   thread carries the position where it started, and its match ends
  #   where it reaches the match state (the group 0 close sits just before
  #   it).
  # - **captures** (`captures: true`), 16·m·c + 32·m + 8·c bytes for c
  #   capture slots: two slot tables (current and next step, m·c slots
  #   each), the two sparse sets, the closure stack (m two-word frames:
  #   each state pushes at most one frame per closure) and one scratch
  #   slot vector. It also runs span searches, carving the start tables
  #   out of its slot tables, so one workspace serves both phases of a
  #   search and only one is ever alive.
  #
  # Each layout is one pointer-free buffer plus this object;
  # `workspace_charge` is what the collector hands out for both, and the
  # compiler checks it against `CompileLimits#max_pike_bytes`.
  #
  # **Time.** O(m·c·(L + 1)) with captures, O(m·(L + 1)) for a span search
  # over L bytes: each position visits each state at most once (the
  # sparse sets), and adding a thread copies its parent's c slots (or its
  # one start position). Every visited state and stepped thread is charged
  # one operation, and every slot vector copy c operations (one for a
  # span search), to the `SearchMeter`.
  #
  # A workspace serves any number of searches in one call, one at a time.
  #
  # **Pool lease** (roadmap 6.2.1). A workspace's charge is reserved from
  # its `CachePool` before the buffer is allocated, and `SearchLimitError`
  # naming `cache_pool_max_bytes` is raised when the pool cannot supply it.
  # A workspace parked in an idle `SearchLease` between calls goes when the
  # pool evicts that lease (its buffer freed); `prepare` allocates it again,
  # reserving first, before the next search.
  #
  # WARNING: A workspace belongs to one fiber.
  class PikeVM
    # A slot that holds no position.
    UNSET = -1_i64

    # Returns the bytes the collector hands out for a workspace of
    # *program* in the span layout or (with *captures*) the capture
    # layout: the buffer, this object and its pool reservation (with its
    # finalizer record), each rounded up to the collector's granule
    # (`AllocationLedger.granules`).
    def self.workspace_charge(program : Program, captures : Bool) : Int64
      workspace_charge(program.state_count.to_i64, program.slot_count.to_i64, captures)
    end

    # :ditto:
    def self.workspace_charge(state_count : Int64, slot_count : Int64, captures : Bool) : Int64
      payload = if captures
                  Program.pike_workspace_bytes(state_count, slot_count)
                else
                  Program.span_workspace_bytes(state_count)
                end
      Preflight.add(Preflight.add(AllocationLedger.granules(payload), AllocationLedger.granules(instance_sizeof(PikeVM))),
        AllocationLedger.granules(instance_sizeof(CacheReservation)) + AllocationLedger::FINALIZER_BYTES)
    end

    # True when the workspace has the capture layout.
    getter? captures : Bool

    @state_count : Int32
    @slot_count : Int32
    @buffer : Pointer(Int64)
    @current_slots : Pointer(Int64)
    @next_slots : Pointer(Int64)
    @current_starts : Pointer(Int32)
    @next_starts : Pointer(Int32)
    @current_dense : Pointer(UInt32)
    @current_sparse : Pointer(UInt32)
    @next_dense : Pointer(UInt32)
    @next_sparse : Pointer(UInt32)
    @stack : Pointer(Int64)
    @scratch : Pointer(Int64)
    @current_size = 0
    @next_size = 0

    @reservation : CacheReservation
    @charge : Int64

    # Builds a workspace of *program*, reserving its charge from *pool*
    # first. Raises `SearchLimitError` naming `cache_pool_max_bytes` when
    # the pool cannot supply it.
    def initialize(@program : Program, @captures : Bool, pool : CachePool)
      @state_count = @program.state_count
      @slot_count = @captures ? @program.slot_count : 0
      @charge = PikeVM.workspace_charge(@program, @captures)
      @reservation = CacheReservation.new(pool)
      reserve_charge
      @buffer = Pointer(Int64).null
      @current_slots = @next_slots = Pointer(Int64).null
      @current_starts = @next_starts = Pointer(Int32).null
      @current_dense = @current_sparse = @next_dense = @next_sparse = Pointer(UInt32).null
      @stack = @scratch = Pointer(Int64).null
      allocate
    end

    private def reserve_charge : Nil
      return if @reservation.cover(@charge, step: 1_i64)
      pool = @reservation.pool
      raise SearchLimitError.new("cache_pool_max_bytes", pool.max_bytes,
        "A Pike VM workspace of #{@charge} bytes, with #{pool.reserved_bytes} bytes of the pool held,",
        Core::Position.new(0_i64))
    end

    # Makes the workspace ready for a search after the pool evicted it:
    # reserves its charge again (raising `SearchLimitError` when the pool
    # cannot supply it) and allocates the buffer.
    def prepare : Nil
      return unless @buffer.null?
      reserve_charge
      allocate
    end

    private def allocate : Nil
      states = @state_count
      slots_per_thread = @slot_count
      # In 8-byte words: 2·m·c slots (captures only), 4·m UInt32 set
      # entries (2·m words), the stack (2·m words with captures, m without),
      # c scratch slots, and in the span layout 2·m Int32 starts (m words).
      table_words = @captures ? 2_i64 * states * slots_per_thread : states.to_i64
      stack_words = @captures ? 2_i64 * states : states.to_i64
      words = table_words + 2_i64 * states + stack_words + slots_per_thread
      buffer = @buffer = Pointer(Int64).malloc(words)
      @current_slots = buffer
      @next_slots = buffer + states.to_i64 * slots_per_thread
      @current_starts = buffer.as(Pointer(Int32))
      @next_starts = @current_starts + states
      sets = (buffer + table_words).as(Pointer(UInt32))
      @current_dense = sets
      @current_sparse = sets + states
      @next_dense = sets + 2 * states
      @next_sparse = sets + 3 * states
      @stack = buffer + table_words + 2_i64 * states
      @scratch = @stack + stack_words
    end

    # Hands the buffer back to the collector and the charge back to the
    # pool. `Searcher` calls this before it builds a capture workspace in
    # place of a span one, so the two are never alive at once, and when a
    # call that keeps no workspace ends. `prepare` makes it usable again.
    def release : Nil
      GC.free(@buffer.as(Void*)) unless @buffer.null?
      @buffer = Pointer(Int64).null
      @reservation.release_all
    end

    # Searches *haystack* for the leftmost-first match that starts at a
    # character boundary in *start*..*end_bound* (only at *start* when
    # *anchored*) and reads no byte at or after *end_bound*; assertions see
    # the whole haystack. *search_start* is where `\G` holds. With
    # *earliest*, stops at the first match state reached (for `matches?`).
    # An unanchored search starts no thread after *first_line_end* (the
    # `CompileOptions::FirstLine` bound, `Int32::MAX` without it).
    #
    # With *want_captures* (which needs the capture layout), fills every
    # slot of *slots*; otherwise fills slots 0 and 1. Returns true on a
    # match.
    def search(haystack : Bytes, start : Int32, end_bound : Int32, search_start : Int32, anchored : Bool,
               end_anchored : Bool, earliest : Bool, meter : SearchMeter, slots : Slice(Int64),
               first_line_end : Int32, want_captures : Bool) : Bool
      raise ArgumentError.new("A span workspace cannot track captures") if want_captures && !@captures
      raise ArgumentError.new("The workspace was released") if @buffer.null?
      @current_size = 0
      @next_size = 0
      matched = false
      at = start
      while true
        # With no live thread, the search is over once it has a match or
        # may start no more threads: anchored past *start*, or past the
        # FirstLine bound. Reading on would advance uncharged.
        if @current_size == 0 && (matched || (at > start && (anchored || at > first_line_end)))
          break
        end
        if !matched && (at == start || (!anchored && boundary?(haystack, at) && at <= first_line_end))
          if want_captures
            @slot_count.times { |index| @scratch[index] = UNSET }
            closure(@program.start_state, at, haystack, search_start, meter, true)
          else
            span_closure(@program.start_state, at, at, haystack, search_start, meter, true)
          end
        end
        index = 0
        while index < @current_size
          state_index = @current_dense[index].to_i32
          index += 1
          meter.charge(1, at)
          state = @program.state_at(state_index, meter, at)
          target = -1
          case state.kind
          when .match?
            next if end_anchored && at != haystack.size
            if want_captures
              row = @current_slots + state_index.to_i64 * @slot_count
              @slot_count.times { |slot| slots[slot] = row[slot] }
            else
              slots[0] = @current_starts[state_index].to_i64
              slots[1] = at.to_i64
            end
            matched = true
            return true if earliest
            break
          when .byte_range?
            next if at >= end_bound
            byte = haystack.unsafe_fetch(at)
            next unless state.low <= byte <= state.high
            target = state.next_state
          when .sparse?
            next if at >= end_bound
            target = @program.sparse_target(state_index, state, haystack.unsafe_fetch(at))
            next if target < 0
          end
          next if target < 0
          if want_captures
            load_scratch(state_index, meter, at)
            closure(target, at + 1, haystack, search_start, meter, false)
          else
            meter.charge(1, at)
            span_closure(target, at + 1, @current_starts[state_index], haystack, search_start, meter, false)
          end
        end
        break if at >= end_bound
        swap_lists
        at += 1
      end
      matched
    end

    private def boundary?(haystack : Bytes, at : Int32) : Bool
      at >= haystack.size || haystack.unsafe_fetch(at) & 0xC0 != 0x80
    end

    # Copies the slots of the thread at *state_index* into the scratch
    # vector, the parent of the closure that follows.
    private def load_scratch(state_index : Int32, meter : SearchMeter, at : Int32) : Nil
      slots_per_thread = @slot_count
      meter.charge(slots_per_thread, at)
      @scratch.copy_from(@current_slots + state_index.to_i64 * slots_per_thread, slots_per_thread)
    end

    # Adds the epsilon closure of *state_index* at *at*, with the scratch
    # vector as its slots, to the current list (*seed*, a new thread at
    # this position, lowest priority) or to the next list. Depth-first in
    # priority order with an explicit stack: a split pushes its second
    # branch and follows its first, and a slot save pushes a frame that
    # restores the slot when the branch is done.
    private def closure(state_index : Int32, at : Int32, haystack : Bytes, search_start : Int32,
                        meter : SearchMeter, seed : Bool) : Nil
      dense = seed ? @current_dense : @next_dense
      sparse = seed ? @current_sparse : @next_sparse
      table = seed ? @current_slots : @next_slots
      size = seed ? @current_size : @next_size
      slots_per_thread = @slot_count
      depth = 0
      @stack[0] = state_index.to_i64
      depth += 1
      while depth > 0
        depth -= 1
        frame_state = @stack[depth * 2]
        if frame_state < 0
          # A restore frame: slot -(state + 1) gets its saved value back.
          @scratch[-(frame_state + 1)] = @stack[depth * 2 + 1]
          next
        end
        current = frame_state.to_i32
        while true
          member = sparse[current]
          break if member < size && dense[member] == current
          sparse[current] = size.to_u32
          dense[size] = current.to_u32
          size += 1
          meter.charge(1, at)
          state = @program.state_at(current, meter, at)
          case state.kind
          when .byte_range?, .sparse?, .match?
            meter.charge(slots_per_thread, at)
            (table + current.to_i64 * slots_per_thread).copy_from(@scratch, slots_per_thread)
            break
          when .split?
            @stack[depth * 2] = state.alternate.to_i64
            depth += 1
            current = state.next_state
          when .save?
            slot = state.argument
            if slot < slots_per_thread
              @stack[depth * 2] = -(slot.to_i64 + 1)
              @stack[depth * 2 + 1] = @scratch[slot]
              depth += 1
              @scratch[slot] = at.to_i64
            end
            current = state.next_state
          when .look?
            break unless Look.holds?(Program::LookKind.new(state.argument), haystack, at, search_start)
            current = state.next_state
          else
            break
          end
        end
      end
      if seed
        @current_size = size
      else
        @next_size = size
      end
    end

    # The span form of `closure`: every thread it adds carries
    # *thread_start*, the position its search began. Saves are passed
    # over, so the stack holds only one-word explore frames.
    private def span_closure(state_index : Int32, at : Int32, thread_start : Int32, haystack : Bytes,
                             search_start : Int32, meter : SearchMeter, seed : Bool) : Nil
      dense = seed ? @current_dense : @next_dense
      sparse = seed ? @current_sparse : @next_sparse
      starts = seed ? @current_starts : @next_starts
      size = seed ? @current_size : @next_size
      depth = 0
      @stack[0] = state_index.to_i64
      depth += 1
      while depth > 0
        depth -= 1
        current = @stack[depth].to_i32
        while true
          member = sparse[current]
          break if member < size && dense[member] == current
          sparse[current] = size.to_u32
          dense[size] = current.to_u32
          size += 1
          meter.charge(1, at)
          state = @program.state_at(current, meter, at)
          case state.kind
          when .byte_range?, .sparse?, .match?
            meter.charge(1, at)
            starts[current] = thread_start
            break
          when .split?
            @stack[depth] = state.alternate.to_i64
            depth += 1
            current = state.next_state
          when .save?
            current = state.next_state
          when .look?
            break unless Look.holds?(Program::LookKind.new(state.argument), haystack, at, search_start)
            current = state.next_state
          else
            break
          end
        end
      end
      if seed
        @current_size = size
      else
        @next_size = size
      end
    end

    private def swap_lists : Nil
      @current_slots, @next_slots = @next_slots, @current_slots
      @current_starts, @next_starts = @next_starts, @current_starts
      @current_dense, @next_dense = @next_dense, @current_dense
      @current_sparse, @next_sparse = @next_sparse, @current_sparse
      @current_size = @next_size
      @next_size = 0
    end
  end
end
