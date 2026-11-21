module Regex::Mica::Regex
  # A one-pass DFA (roadmap 6.2.1), RE2's OnePass and Rust regex's
  # `onepass::DFA`: for a pattern where, at every point of a match, the next
  # byte alone decides which way the match goes, captures can be read in a
  # single pass with no thread lists and no backtracking.
  #
  # Each DFA state stands for one NFA state that a byte transition leads to
  # (or the start). Building it explores that state's epsilon closure in
  # priority order, collecting on each path the capture slots it saves and
  # the assertions it passes; each byte class may be reached by one path
  # only, and the match state too. Paths after the match state in priority
  # order are left out, as leftmost-first drops them. When two paths meet
  # the same byte class, the same NFA state, or the match state, the
  # pattern is not one-pass and `build` returns nil.
  #
  # It runs only in phase 2, over a span `[s, e)` the span search has
  # already found: from s it follows one transition per byte, checking the
  # path's assertions and writing its slots, and at e it takes the match
  # path. That is O(L + c) for L = e − s, each step charged to the meter.
  # Should a path not exist (it cannot when the span is a real match), it
  # reports failure and the search falls back to the bounded backtracker.
  class OnePassDFA
    # The most NFA states a program may have for a one-pass DFA to be
    # built. Building costs O(m) per DFA state, so this bounds it at
    # MAX_STATES² operations, once per expression.
    MAX_STATES = 1_500
    # The most capture slots (one bit each in a path's slot mask).
    MAX_SLOTS = 64

    # One path: the DFA state it leads to (-1 for the match path), the
    # slots it saves, and the assertions it passes (bit per `LookKind`).
    record Edge, target : Int32, slots : UInt64, looks : UInt32

    @byte_classes : ByteClasses
    @class_count : Int32
    # The tables are lists outside the collector's heap (the DFA of a
    # class over all of Unicode, `\d`, has tens of kilobytes of cells, and
    # a program's first search builds it), freed in `finalize`.
    @table : OffHeapList(Int32)
    @match_edges : OffHeapList(Int32)
    @list_of_edges : OffHeapList(Edge)

    # Builds the one-pass DFA of *program*, or returns nil when the program
    # is not one-pass or is too large.
    def self.build(program : Program, byte_classes : ByteClasses) : OnePassDFA?
      return nil if program.state_count > MAX_STATES || program.slot_count > MAX_SLOTS
      # The builder serves this call alone, from its stack frame.
      builder = Mica::Regex.stack_object(OnePassBuilder, program, byte_classes)
      begin
        builder.build
      ensure
        builder.release
      end
    end

    # The most cells the one-pass table of *program* can have: one row of
    # *byte_classes* per NFA state, the most DFA states it can have.
    def self.most_cells(program : Program, byte_classes : ByteClasses) : Int64
      program.state_count.to_i64 * byte_classes.class_count
    end

    # True when the one-pass table of *program* has at most
    # `OnePassBuilder::PRESIZED_TABLE_CELLS` cells, so building it, or
    # finding the program is not one-pass, costs little.
    def self.small?(program : Program, byte_classes : ByteClasses) : Bool
      most_cells(program, byte_classes) <= OnePassBuilder::PRESIZED_TABLE_CELLS
    end

    # For `search`: per table cell, the target state's row offset (state
    # times class count) shifted left by two, with `STEP_TAKES_EDGE` when
    # the edge has assertions or slots and `STEP_REACHES_MATCH` when the
    # target state has a match path; -1 where there is no edge. One load
    # per byte then finds the next state.
    @steps : OffHeapList(Int32)

    private STEP_TAKES_EDGE    = 1
    private STEP_REACHES_MATCH = 2

    # The assertions that hold only at the end of the haystack or just
    # before a line feed that ends it (`\z`, and `$` and `\Z`).
    private END_ONLY_LOOKS = (1_u32 << Program::LookKind::EndOfText.value) |
                             (1_u32 << Program::LookKind::EndOfTextOrFinalNewline.value)

    # True when no state left a byte path out below its match path, so
    # `search` never returns `LazyDFA::GAVE_UP` once it reads to the end.
    getter? decisive : Bool

    # Per state: true when every ASCII byte leads back to the state with no
    # assertion and no slot (`(?s:.)*`, `[^\n]*`), so `captures` steps over
    # a run of ASCII bytes there without reading the table.
    @list_of_ascii_loops : OffHeapList(Bool)

    # Per state: true when its match path has no assertion, so it holds
    # wherever the state is reached, and some byte leads back to it with no
    # edge work; `search` then reads a run of bytes
    # that lead back to the state with no edge work (`.*`) in one loop,
    # and the match ends where the run does.
    @list_of_match_loops : OffHeapList(Bool)
    # True when some state is a match loop (see `search`).
    @any_match_loop : Bool

    # The DFA takes the four lists over: it alone frees them.
    def initialize(@byte_classes : ByteClasses, @table : OffHeapList(Int32), @match_edges : OffHeapList(Int32),
                   @list_of_edges : OffHeapList(Edge), @list_of_shadows : OffHeapList(Bool))
      @class_count = @byte_classes.class_count
      @decisive = @list_of_shadows.none?
      @steps = OffHeapList(Int32).new(@table.size)
      @list_of_ascii_loops = OffHeapList(Bool).new(@match_edges.size)
      @list_of_match_loops = OffHeapList(Bool).new(@match_edges.size)
      @any_match_loop = false
      @table.each do |index|
        if index < 0
          @steps << -1
          next
        end
        edge = @list_of_edges[index]
        step = (edge.target * @class_count) << 2
        step |= STEP_TAKES_EDGE if edge.looks != 0 || edge.slots != 0
        step |= STEP_REACHES_MATCH if matches_before_end?(edge.target)
        @steps << step
      end
      @match_edges.size.times { |state| @list_of_ascii_loops << ascii_loop?(state) }
      @match_edges.each_with_index do |index, state|
        @list_of_match_loops << (index >= 0 && @list_of_edges[index].looks == 0 && loops_without_edge_work?(state))
      end
      @any_match_loop = @list_of_match_loops.any?
    end

    # Returns the tables to libc. The DFA refers to nothing that refers
    # back to it (its byte classes hold only bytes), so the collector
    # finalizes it once the plan that built it is gone.
    def finalize
      @table.free
      @match_edges.free
      @list_of_edges.free
      @list_of_shadows.free
      @steps.free
      @list_of_ascii_loops.free
      @list_of_match_loops.free
    end

    # :nodoc:
    # The tables `Static::BuildTheTables` writes into an application's
    # source: the steps, the edge index per cell, the match edge per state,
    # the edges and the ASCII-loop flag per state.
    def static_parts : {Array(Int32), Array(Int32), Array(Int32), Array(Edge), Array(Bool)}
      {@steps.to_a, @table.to_a, @match_edges.to_a, @list_of_edges.to_a, @list_of_ascii_loops.to_a}
    end

    # True when at least `WIDE_LOOP_BYTES` of the byte values lead from
    # *state* back to it with no assertion and no slot (`.*`, `[^"]*`): a
    # run there is likely long. A narrow loop (`\s+` between words) ends
    # within a byte or two, where the run costs more than it saves.
    #
    # It reads one cell per byte class, not per byte: the DFA is built on a
    # program's first search, and reading 256 cells per state there made
    # the first search of `(?:(a+)|(b+)|...|(z+))` over 60 KB take about
    # 43 us where per-class reads take about 35 us.
    private def loops_without_edge_work?(state : Int32) : Bool
      row = state * @class_count
      looping_bytes = 0
      @class_count.times do |class_index|
        step = @steps.unsafe_fetch(row + class_index)
        next unless step >= 0 && step & STEP_TAKES_EDGE == 0 && step >> 2 == row
        looping_bytes += @byte_classes.class_size(class_index)
      end
      looping_bytes >= WIDE_LOOP_BYTES
    end

    # See `loops_without_edge_work?`.
    private WIDE_LOOP_BYTES = 64

    private def ascii_loop?(state : Int32) : Bool
      row = state * @class_count
      class_of = @byte_classes.table
      (0...0x80).all? do |byte|
        step = @steps[row + class_of[byte]]
        step >= 0 && step & STEP_TAKES_EDGE == 0 && step >> 2 == row
      end
    end

    # Fills *slots* with the captures of the match `[start, finish)` of
    # *haystack*, which the span search found. Returns false when no path
    # reads the span (the caller then uses another engine).
    # True when *state* has a match path that can hold before the last
    # byte of the haystack, or one that left a byte path out (see
    # `search`): only these states stop the search's tight loop. A match
    # path that asserts `\z`, `$` or `\Z` holds only at the end or just
    # before a final line feed, and `search` checks every state's match
    # path at those two positions.
    private def matches_before_end?(state : Int32) : Bool
      index = @match_edges[state]
      return false if index < 0
      @list_of_shadows[state] || @list_of_edges[index].looks & END_ONLY_LOOKS == 0
    end

    def captures(haystack : Bytes, start : Int32, finish : Int32, search_start : Int32, slots : Slice(Int64),
                 meter : SearchMeter) : Bool
      slots.fill(PikeVM::UNSET)
      steps = @steps.to_unsafe
      class_of = @byte_classes.table
      bytes = haystack.to_unsafe
      row = 0
      at = start
      charged = start
      # Bytes before `allowed_end` are allowed by the meter
      # (`SearchMeter#readable`) and charged once read.
      allowed_end = start
      steps = @steps.to_unsafe
      class_of = @byte_classes.table
      bytes = haystack.to_unsafe
      while at < finish
        if at >= allowed_end
          meter.charge(at - charged, at)
          charged = at
          allowed_end = at + meter.readable(Math.min(finish - at, PrefilterScan::CHARGE_CHUNK), at)
        end
        bound = Math.min(finish, allowed_end)
        if @list_of_ascii_loops.unsafe_fetch(state_of(row))
          at = Core::ByteScan.skip_ascii(haystack, at, bound)
          next if at >= bound
        end
        # Steps with no slots or assertions in a tight loop, one table
        # load per byte: match paths matter only at *finish*.
        while at < bound
          step = steps[row &+ class_of[bytes[at]]]
          break unless step >= 0 && step & STEP_TAKES_EDGE == 0
          at &+= 1
          # A state that loops to itself: its row stays, so the loads no
          # longer wait on each other.
          if step >> 2 == row
            while at < bound && steps[row &+ class_of[bytes[at]]] == step
              at &+= 1
            end
          end
          row = step >> 2
        end
        next if at >= bound
        cell = row &+ class_of[bytes[at]]
        step = steps[cell]
        return false if step < 0
        return false unless take(@list_of_edges.unsafe_fetch(@table.unsafe_fetch(cell)), haystack, at, search_start, slots)
        row = step >> 2
        at &+= 1
      end
      meter.charge(finish - charged + 1, charged)
      index = @match_edges.unsafe_fetch(state_of(row))
      return false if index < 0
      take(@list_of_edges.unsafe_fetch(index), haystack, finish, search_start, slots)
    end

    # Searches *haystack* anchored at *start* for the leftmost-first match
    # (see `Searcher`'s one-pass search): from *start* it follows one
    # transition per byte, writing the path's slots into *scratch*, and at
    # each position whose state has a match path that holds, copies them
    # with the match path's into *slots*. Every byte edge of a state with a
    # match path ranks above it (the builder leaves out the paths after the
    # match), so the search goes on while a transition exists and the last
    # match recorded is the leftmost-first one.
    #
    # The paths the builder left out rank below a match path that the
    # search may find does not hold here (its assertion fails, as `$` does
    # before the end). Then a left-out path could still match, so when the
    # search ends with no match recorded after such a position, at a state
    # that left a byte path out, it returns `LazyDFA::GAVE_UP`, and the
    # caller searches another way. A state that left nothing out (as in
    # `\A[a-z]+\z`, whose bytes rank above the match) decides alone.
    #
    # Returns the match end, `LazyDFA::NO_MATCH` or `LazyDFA::GAVE_UP`, and
    # the bytes read. O(L + c·k) for L bytes read and k positions with a
    # match path. Without a *meter*, the caller has proved the work fits
    # the call's allowance (see `ShortSearch`).
    #
    # With *stop*, a search still undecided when it reaches byte *stop*
    # returns `LazyDFA::GAVE_UP` there. A search of a program with no group
    # but the match, without a meter, runs `search_span`.
    def search(haystack : Bytes, start : Int32, search_start : Int32, slots : Slice(Int64), scratch : Slice(Int64),
               meter : SearchMeter?, stop : Int32 = Int32::MAX) : {Int32, Int32}
      return search_span(haystack, start, search_start, slots, stop) if meter.nil? && slots.size == 2
      if @any_match_loop
        search_with_match_loops(haystack, start, search_start, slots, scratch, meter, stop)
      else
        search_without_match_loops(haystack, start, search_start, slots, scratch, meter, stop)
      end
    end

    # The two loops of `search`, made from one body: the search loop of a
    # pattern that runs it is tight enough that a branch it never takes
    # still slows it, so the match-loop run (see `@list_of_match_loops`) is
    # compiled only into the loop of the DFAs that have a looping match
    # state.
    {% for match_loops in [true, false] %}
      private def search_{{ (match_loops ? "with" : "without").id }}_match_loops(haystack : Bytes, start : Int32,
                                                                                 search_start : Int32,
                                                                                 slots : Slice(Int64),
                                                                                 scratch : Slice(Int64),
                                                                                 meter : SearchMeter?,
                                                                                 stop : Int32) : {Int32, Int32}
      # Slot counts are small: plain loops beat the `memset` and `memcpy`
      # calls of `fill` and `copy_from`.
      scratch.size.times { |index| scratch.unsafe_put(index, PikeVM::UNSET) }
      at = start
      charged = start
      size = haystack.size
      # Bytes before `allowed_end` are allowed by the meter
      # (`SearchMeter#readable`) and charged once read; without a meter the
      # caller proved the whole haystack fits.
      allowed_end = meter ? start : size
      found = LazyDFA::NO_MATCH
      undecided = false
      # Locals, so the loop does not reload them after each slot write.
      table = @table.to_unsafe
      steps = @steps.to_unsafe
      edges = @list_of_edges.to_unsafe
      class_of = @byte_classes.table
      bytes = haystack.to_unsafe
      row = 0
      reaches_match = @match_edges.unsafe_fetch(0) >= 0
      # The last match found is written to *slots* only when the scratch
      # slots are about to change or the search ends: until then it is the
      # scratch slots plus `pending_edge` written at `found`, so a run of
      # bytes that each reach a match (`\w+`) copies the slots once.
      pending_edge = -1
      while true
        if reaches_match || (at >= size - 1 && @match_edges.unsafe_fetch(state_of(row)) >= 0)
          edge_index = @match_edges.unsafe_fetch(state_of(row))
          edge = edges[edge_index]
          if holds?(edge, haystack, at, search_start)
            pending_edge = edge_index
            found = at
            undecided = false
            # In a state whose match path always holds
            # (`@list_of_match_loops`), a run of bytes that lead back to it
            # with no edge work (`.*`) ends a match at each byte with the
            # same slots: the run is read in one loop, within the bytes the
            # meter allowed, and the match ends where it stops.
            {% if match_loops %}
            if @list_of_match_loops.unsafe_fetch(state_of(row)) && at < allowed_end && at < stop && at < size
              run_end = match_loop_end(haystack, row, at, Math.min(Math.min(size, stop), allowed_end))
              if run_end > at
                found = at = run_end
                next
              end
            end
            {% end %}
          elsif @list_of_shadows.unsafe_fetch(state_of(row))
            undecided = true
          end
        end
        break if at >= size
        if at >= stop
          undecided = true
          break
        end
        if meter && at >= allowed_end
          meter.charge(at - charged, at)
          charged = at
          allowed_end = at + meter.readable(Math.min(Math.min(size, stop) - at, PrefilterScan::CHARGE_CHUNK), at)
        end
        bound = Math.min(Math.min(size, stop), allowed_end)
        # The common step (no edge work, no match path ahead) in a tight
        # loop up to the next bound, and short of the last byte, whose
        # position the check above must see: one table load per byte.
        tight_bound = Math.min(bound, size - 1)
        entered = at
        while at < tight_bound
          step = steps[row &+ class_of[bytes[at]]]
          break unless step >= 0 && step & (STEP_TAKES_EDGE | STEP_REACHES_MATCH) == 0
          reaches_match = false
          at &+= 1
          # A state that loops to itself (`.*`, `[^"]*`): its row stays,
          # so the loads no longer wait on each other. Where every ASCII
          # byte loops back with this very step (`ascii_loop?`), a run of
          # them is skipped eight bytes at a time.
          if step >> 2 == row
            if @list_of_ascii_loops.unsafe_fetch(state_of(row))
              at = Core::ByteScan.skip_ascii(haystack, at, tight_bound) if at < tight_bound
            end
            while at < tight_bound && steps[row &+ class_of[bytes[at]]] == step
              at &+= 1
            end
          end
          row = step >> 2
        end
        # The last byte's position, reached in the run, is checked above.
        next if at >= bound || (at > entered && at >= size - 1)
        cell = row &+ class_of[bytes[at]]
        step = steps[cell]
        break if step < 0
        if step & STEP_TAKES_EDGE != 0
          edge = edges[table[cell]]
          break unless holds?(edge, haystack, at, search_start)
          if pending_edge >= 0
            record_match(edges[pending_edge], found, scratch, slots)
            pending_edge = -1
          end
          write(edge, at, scratch)
        end
        row = step >> 2
        reaches_match = step & STEP_REACHES_MATCH != 0
        at &+= 1
      end
      record_match(edges[pending_edge], found, scratch, slots) if pending_edge >= 0
      meter.try(&.charge(at - charged + 1, charged))
      {undecided ? LazyDFA::GAVE_UP : found, at - start}
    end
    {% end %}

    # `search` for a program whose only group is the match (two slots),
    # called without a meter (the caller proved the work fits): the same
    # states, assertions, match paths and decisions, with no slot written
    # along the way. Every path saves slot 0 at its first step, so the match
    # starts at *start* and only its end is kept; *slots* are written once,
    # when the search returns a match. A run of bytes that loops back to its
    # state with no edge work, where no match path needs checking at each
    # byte (`\s*`, `.*`), is read in one loop, as in `search`. On the
    # candidate searches of `,\s*` over amber/csv this costs about 6 ns less
    # per call than `search` (24 ns against 31 ns).
    private def search_span(haystack : Bytes, start : Int32, search_start : Int32, slots : Slice(Int64),
                            stop : Int32) : {Int32, Int32}
      steps = @steps.to_unsafe
      table = @table.to_unsafe
      edges = @list_of_edges.to_unsafe
      class_of = @byte_classes.table
      bytes = haystack.to_unsafe
      size = haystack.size
      # A run stops short of the last byte, whose position the match check
      # must see (as in `search`), and of *stop*.
      run_bound = Math.min(size - 1, stop)
      row = 0
      at = start
      found = LazyDFA::NO_MATCH
      undecided = false
      reaches_match = @match_edges.unsafe_fetch(0) >= 0
      while true
        if reaches_match || (at >= size - 1 && @match_edges.unsafe_fetch(state_of(row)) >= 0)
          state = state_of(row)
          if holds?(edges[@match_edges.unsafe_fetch(state)], haystack, at, search_start)
            found = at
            undecided = false
          elsif @list_of_shadows.unsafe_fetch(state)
            undecided = true
          end
        end
        break if at >= size
        if at >= stop
          undecided = true
          break
        end
        cell = row &+ class_of[bytes[at]]
        step = steps[cell]
        break if step < 0
        break if step & STEP_TAKES_EDGE != 0 && !holds?(edges[table[cell]], haystack, at, search_start)
        reaches_match = step & STEP_REACHES_MATCH != 0
        at &+= 1
        if step >> 2 == row && step & STEP_TAKES_EDGE == 0 && (!reaches_match || @list_of_match_loops.unsafe_fetch(state_of(row)))
          if @list_of_ascii_loops.unsafe_fetch(state_of(row)) && at < run_bound
            at = Core::ByteScan.skip_ascii(haystack, at, run_bound)
          end
          while at < run_bound && steps[row &+ class_of[bytes[at]]] == step
            at &+= 1
          end
        end
        row = step >> 2
      end
      if found >= 0 && !undecided
        slots.unsafe_put(0, start.to_i64)
        slots.unsafe_put(1, found.to_i64)
      end
      {undecided ? LazyDFA::GAVE_UP : found, at - start}
    end

    # Where a run from *at* of bytes that lead back to the state at *row*
    # with no edge work stops, before *run_end*; *at* itself when the byte
    # there leaves the state (see `search`).
    @[AlwaysInline]
    private def match_loop_end(haystack : Bytes, row : Int32, at : Int32, run_end : Int32) : Int32
      steps = @steps.to_unsafe
      class_of = @byte_classes.table
      bytes = haystack.to_unsafe
      loop_step = steps[row &+ class_of[bytes[at]]]
      return at unless loop_step >= 0 && loop_step >> 2 == row && loop_step & STEP_TAKES_EDGE == 0
      at &+= 1
      if @list_of_ascii_loops.unsafe_fetch(state_of(row)) && at < run_end
        at = Core::ByteScan.skip_ascii(haystack, at, run_end)
      end
      while at < run_end && steps[row &+ class_of[bytes[at]]] == loop_step
        at &+= 1
      end
      at
    end

    # Writes the match that *edge* completes at *at* into *slots*: the
    # scratch slots, then the edge's own.
    @[AlwaysInline]
    private def record_match(edge : Edge, at : Int32, scratch : Slice(Int64), slots : Slice(Int64)) : Nil
      slots.size.times { |index| slots.unsafe_put(index, scratch.unsafe_fetch(index)) }
      write(edge, at, slots)
    end

    # The line and text ends, the assertions a match path most often
    # checks at every byte (`^.*$`), are tested here without a call.
    @[AlwaysInline]
    private def holds?(edge : Edge, haystack : Bytes, at : Int32, search_start : Int32) : Bool
      looks = edge.looks
      while looks != 0
        kind = Program::LookKind.new(looks.trailing_zeros_count.to_i32)
        held = case kind
               when .end_of_line? then at == haystack.size || haystack.unsafe_fetch(at) == Look::LINE_FEED
               when .end_of_text? then at == haystack.size
               else                    Look.holds?(kind, haystack, at, search_start)
               end
        return false unless held
        looks &= looks - 1
      end
      true
    end

    # The DFA state whose row starts at table offset *row* (a multiple of
    # the class count, never negative).
    @[AlwaysInline]
    private def state_of(row : Int32) : Int32
      row.unsafe_div(@class_count)
    end

    # Writes *at* into the slots *edge* saves. The builder keeps every
    # slot below the program's slot count, the size of *slots*.
    @[AlwaysInline]
    private def write(edge : Edge, at : Int32, slots : Slice(Int64)) : Nil
      saved = edge.slots
      while saved != 0
        slot = saved.trailing_zeros_count
        slots.unsafe_put(slot, at.to_i64)
        saved &= saved - 1
      end
    end

    private def take(edge : Edge, haystack : Bytes, at : Int32, search_start : Int32, slots : Slice(Int64)) : Bool
      looks = edge.looks
      while looks != 0
        kind = looks.trailing_zeros_count
        return false unless Look.holds?(Program::LookKind.new(kind.to_i32), haystack, at, search_start)
        looks &= looks - 1
      end
      saved = edge.slots
      while saved != 0
        slot = saved.trailing_zeros_count
        slots[slot] = at.to_i64
        saved &= saved - 1
      end
      true
    end
  end

  # :nodoc:
  # Builds a `OnePassDFA` (see there for the rules).
  class OnePassBuilder
    record Path, state : Int32, slots : UInt64, looks : UInt32

    # Every list is outside the collector's heap: the scratch ones
    # (`@dfa_state_of`, `@list_of_roots`, `@seen`, `@stack`) are freed by
    # `release`, and so are the DFA's four unless `build` handed them to a
    # DFA.
    @dfa_state_of : OffHeapList(Int32)
    @list_of_roots = OffHeapList(Int32).new
    @table : OffHeapList(Int32)
    @match_edges = OffHeapList(Int32).new
    @list_of_edges = OffHeapList(OnePassDFA::Edge).new
    # Per DFA state: true when it left out a byte path ranked below its
    # match path.
    @list_of_shadows = OffHeapList(Bool).new
    @seen : OffHeapList(Int32)
    # The paths `explore` has still to follow, reused for every DFA state.
    @stack = OffHeapList(Path).new
    # True once `build` has handed the table, the match edges, the edges
    # and the shadows to a DFA.
    @handed_over = false

    # A table of at most this many cells (one row per NFA state, the most
    # the DFA can have) counts as small (see `OnePassDFA.small?`).
    PRESIZED_TABLE_CELLS = 4096
    # The rows a table past `RESERVED_TABLE_CELLS` starts with room for.
    FIRST_TABLE_ROWS = 4
    # A table of at most this many cells at its largest (one row per NFA
    # state) reserves them all at once: libc hands out room that costs
    # nothing until it is written, the table then never moves as it
    # grows (moving a table of tens of kilobytes a few times cost a first
    # search more than building it), and `build` gives the unused room
    # back. A larger table grows from `FIRST_TABLE_ROWS`.
    RESERVED_TABLE_CELLS = 64 * 1024

    def initialize(@program : Program, @byte_classes : ByteClasses)
      @dfa_state_of = OffHeapList(Int32).new(@program.state_count, -1)
      @seen = OffHeapList(Int32).new(@program.state_count, -1)
      most_cells = OnePassDFA.most_cells(@program, @byte_classes)
      first_cells = Math.min(@program.state_count, FIRST_TABLE_ROWS) * @byte_classes.class_count
      @table = OffHeapList(Int32).new(most_cells <= RESERVED_TABLE_CELLS ? most_cells.to_i32 : first_cells)
    end

    # Frees the lists the DFA does not keep, once `build` is done: the
    # builder alone holds them.
    def release : Nil
      @dfa_state_of.free
      @seen.free
      @list_of_roots.free
      @stack.free
      unless @handed_over
        @table.free
        @match_edges.free
        @list_of_edges.free
        @list_of_shadows.free
      end
    end

    def build : OnePassDFA?
      root_of(@program.start_state)
      index = 0
      while index < @list_of_roots.size
        return nil unless explore(index)
        index += 1
      end
      # The DFA keeps the lists for as long as the program lives, so they
      # give back the room that growing left unused.
      @table.trim
      @match_edges.trim
      @list_of_edges.trim
      @list_of_shadows.trim
      @handed_over = true
      OnePassDFA.new(@byte_classes, @table, @match_edges, @list_of_edges, @list_of_shadows)
    end

    private def root_of(nfa_state : Int32) : Int32
      existing = @dfa_state_of[nfa_state]
      return existing if existing >= 0
      id = @list_of_roots.size
      @list_of_roots << nfa_state
      @dfa_state_of[nfa_state] = id
      add_table_row
      @match_edges << -1
      @list_of_shadows << false
      id
    end

    # Appends a row of empty cells to the table, growing it by half (at
    # least `FIRST_TABLE_ROWS` rows) rather than doubling it, so a large
    # table is never copied into twice its room.
    private def add_table_row : Nil
      class_count = @byte_classes.class_count
      if @table.size + class_count > @table.capacity
        @table.reserve(@table.size + Math.max(FIRST_TABLE_ROWS * class_count, @table.size // 2))
      end
      class_count.times { @table << -1 }
    end

    private def explore(dfa_state : Int32) : Bool
      class_count = @byte_classes.class_count
      @stack.clear
      @stack << Path.new(@list_of_roots[dfa_state], 0_u64, 0_u32)
      matched = false
      while path = @stack.pop?
        current = path.state
        slots = path.slots
        looks = path.looks
        while true
          return false if @seen[current] == dfa_state
          @seen[current] = dfa_state
          state = @program.state_at(current)
          case state.kind
          when .byte_range?
            @list_of_shadows[dfa_state] = true if matched
            if !matched && !add_edges(dfa_state, state.low, state.high, state.next_state, slots, looks, class_count)
              return false
            end
            break
          when .sparse?
            @list_of_shadows[dfa_state] = true if matched
            unless matched
              state.alternate.times do |offset|
                transition = @program.transition_at(current, state, offset)
                return false unless add_edges(dfa_state, transition.low, transition.high, transition.target, slots,
                                      looks, class_count)
              end
            end
            break
          when .match?
            return false if matched
            matched = true
            @match_edges[dfa_state] = @list_of_edges.size
            @list_of_edges << OnePassDFA::Edge.new(-1, slots, looks)
            break
          when .split?
            @stack << Path.new(state.alternate, slots, looks)
            current = state.next_state
          when .save?
            slots |= 1_u64 << state.argument
            current = state.next_state
          when .look?
            looks |= 1_u32 << state.argument
            current = state.next_state
          else
            break
          end
        end
      end
      true
    end

    private def add_edges(dfa_state : Int32, low : UInt8, high : UInt8, nfa_target : Int32, slots : UInt64,
                          looks : UInt32, class_count : Int32) : Bool
      target = root_of(nfa_target)
      edge_index = @list_of_edges.size
      @list_of_edges << OnePassDFA::Edge.new(target, slots, looks)
      (@byte_classes.class_of(low)..@byte_classes.class_of(high)).each do |class_index|
        cell = dfa_state * class_count + class_index
        return false if @table[cell] >= 0
        @table[cell] = edge_index
      end
      true
    end
  end
end
