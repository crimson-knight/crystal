module Regex::Mica::Regex
  # A compiled pattern: a byte-level Thompson NFA with UTF-8 automata for
  # its classes, as RE2 and Rust regex build it. `Compiler` emits it from
  # `Hir`; `PikeVM` and `BoundedBacktracker` run it.
  #
  # States are numbered from 0. Every class and literal is a path of byte
  # states that consumes one whole UTF-8 sequence, so a thread only ever
  # rests between characters when it reaches an assertion, a split or the
  # match state.
  #
  # The program has no unanchored `(?s:.)*?` prefix (the size preflight
  # counts one, so the emitted count stays below the estimate): the engines
  # start a new thread at each character boundary instead, which also keeps
  # searches from starting inside a multibyte character.
  class Program
    # What a state does.
    enum StateKind : UInt8
      # Consumes one byte in `low..high`, then goes to `next_state`.
      ByteRange
      # Consumes one byte in one of its transitions (sorted, disjoint
      # ranges; `argument` is the first index in its table, `alternate`
      # the count) and goes to that transition's target. `low` names the
      # table: 0 is `list_of_transitions`, whose targets are state
      # numbers; n is shared table n - 1 (`list_of_shared_tables`), whose
      # targets are relative to the state (`SHARED_EXIT` is `next_state`).
      # Read transitions through `transition_at` and `sparse_target`,
      # which resolve both.
      Sparse
      # Goes to `next_state` first, then to `alternate` (leftmost-first
      # priority).
      Split
      # Records the position in capture slot `argument`, then goes on.
      Save
      # Goes on only when the assertion `argument` (a `LookKind`) holds.
      Look
      # The pattern has matched.
      Match
      # Never matches (an empty class).
      Fail
    end

    # The assertions a `Look` state checks. The word assertions come in a
    # Unicode form (PCRE2's UCP `\w`, letters, numbers, `Mn` and `Pc` plus
    # underscore) and an ASCII form (`(?aW)`).
    enum LookKind
      StartOfText
      StartOfLine
      EndOfText
      EndOfTextOrFinalNewline
      EndOfLine
      WordBoundary
      NotWordBoundary
      WordStart
      WordEnd
      WordBoundaryAscii
      NotWordBoundaryAscii
      WordStartAscii
      WordEndAscii
      SearchStart
      # The next byte is not a line feed: the second half of `\R`'s lone
      # `\r` branch, which makes `\r\n` atomic as PCRE2 matches it.
      NotBeforeLineFeed
    end

    # One state. Field use depends on `kind` (see `StateKind`).
    record State, kind : StateKind, low : UInt8, high : UInt8, next_state : Int32, alternate : Int32,
      argument : Int32

    # One range of a `Sparse` state.
    record Transition, low : UInt8, high : UInt8, target : Int32

    # The states one class compiled to: `first_state` up to (not including)
    # `end_state`, only byte states, entered at `entry` and left to `exit`
    # (see `ReverseNFA`).
    record ClassBlock, first_state : Int32, end_state : Int32, entry : Int32, exit : Int32

    # *copies* copies of one class, one after another from *first_state*,
    # held as the class's block (a large class's `ClassMemo::Block`, shared
    # with every program, or an ASCII class's one byte state) rather than
    # as states: `x{n}` (`\p{L}{256}` is 256 copies of about 300 states).
    # Copy k starts at `first_state + k * stride`; copy 0 leads to *exit*,
    # and each later copy to the entry of the copy before it, as the
    # compiler emits a counted item from the last copy back. Its `Sparse`
    # states read shared table *table_id*. A copy's states are exactly the
    # ones `Compiler#instantiate_shared` would have emitted (see `state_at`).
    #
    # An *optional* run holds the optional copies of `x{n,m}`
    # (`[\w.]{1,256}` has 255): each copy is the class's block followed by
    # one `Split` state, so its stride is one more than the block. The
    # split enters the copy's block (first, unless the repetition is
    # *lazy*) or leaves to *exit*, and a copy's block leads to the split of
    # the copy before it (copy 0's to *exit*): the states
    # `Compiler#compile_counted_item` emits for those copies one by one, in
    # the same order and numbering.
    #
    # *entry_targets*, for a large class's block, is its entry's target
    # for each byte (`ClassMemo::Block#entry_targets`).
    record ClassRun, first_state : Int32, copies : Int32, list_of_block_states : OffHeapList(State), table_id : UInt8,
      entry : Int32, exit : Int32, entry_targets : Slice(Int32)? = nil, optional : Bool = false, lazy : Bool = false do
      # The states one copy takes: the block, and an optional copy's split.
      @[AlwaysInline]
      def stride : Int32
        list_of_block_states.size + (optional ? 1 : 0)
      end

      # The states the run stands for.
      def size : Int32
        copies * stride
      end

      # The number after the run's last state.
      def end_state : Int32
        first_state + size
      end

      # The state a match reads first: the entry of the last copy emitted,
      # or an optional run's last split.
      def last_entry : Int32
        return first_state + size - 1 if optional
        first_state + (copies - 1) * list_of_block_states.size + entry
      end

      # Where copy *copy*, which starts at *copy_first*, leaves its block to.
      @[AlwaysInline]
      def block_exit(copy : Int32, copy_first : Int32) : Int32
        return exit if copy == 0
        optional ? copy_first - 1 : copy_first - stride + entry
      end

      # State *index*, which must lie in the run.
      def state_at(index : Int32) : State
        step = stride
        block_size = list_of_block_states.size
        relative = index - first_state
        copy = relative // step
        copy_first = first_state + copy * step
        inner = relative - copy * step
        if inner == block_size
          into = copy_first + entry
          preferred, other = lazy ? {exit, into} : {into, exit}
          return State.new(StateKind::Split, 0_u8, 0_u8, preferred, other, 0)
        end
        state = list_of_block_states.unsafe_fetch(inner)
        exit_target = block_exit(copy, copy_first)
        return state.copy_with(low: table_id, next_state: exit_target) if state.kind.sparse?
        target = state.next_state
        target = if target == ClassMemo::EXIT
                   exit_target
                 elsif target != ClassMemo::NONE
                   target + copy_first
                 else
                   target
                 end
        state.copy_with(next_state: target)
      end

      # The class blocks of the run's copies, in emission order.
      def each_class_block(& : ClassBlock ->) : Nil
        block_size = list_of_block_states.size
        # A class of one state is not recorded (see `list_of_class_blocks`).
        return if block_size < 2
        step = stride
        copies.times do |copy|
          copy_first = first_state + copy * step
          yield ClassBlock.new(copy_first, copy_first + block_size, copy_first + entry, block_exit(copy, copy_first))
        end
      end
    end

    # The states not in a `ClassRun`, in order. The program's state and
    # transition lists sit outside the collector's heap (`OffHeapList`),
    # as PCRE2 keeps its compiled code, and `finalize` frees them.
    @list_of_physical_states : OffHeapList(State)
    # Every state and class block, once built (see `list_of_states`): for
    # a program without runs, the physical states and the recorded blocks
    # themselves. `@materialized` is set with release ordering after both
    # lists are written and read with acquire, so a thread that sees it set
    # sees them fully built: on ARM64 a plain store could reach another
    # core before the lists' contents.
    @materialized = Atomic(Bool).new(false)
    @all_states = OffHeapList(State).new
    @all_blocks = OffHeapList(ClassBlock).new
    # The class blocks the compiler recorded outside runs.
    @list_of_recorded_blocks : OffHeapList(ClassBlock)
    # The program's runs, in state order.
    getter list_of_runs : Array(ClassRun)
    # The states of the runs before each run (`run_state_at` turns a state
    # number past a run into an index in `@list_of_physical_states`).
    @list_of_run_offsets : OffHeapList(Int32)
    # The most runs one `run_state_at` reads (see `run_reads_per_state`).
    @run_reads_per_state : Int32
    @state_count : Int32
    # Guards `materialize` (made only for a program with runs).
    @materialize_mutex : Mutex? = nil
    # The ranges of every `Sparse` state.
    @list_of_transitions : OffHeapList(Transition)
    # The state every search starts from.
    getter start_state : Int32
    # Capturing groups (group 0, the whole match, not included).
    getter capture_count : Int32
    # Named groups in pattern order.
    getter list_of_group_names : Array(Ast::GroupName)
    # The options the pattern was compiled with.
    getter options : CompileOptions
    # The bytes a `BoundedBacktracker` may take: `CompileLimits#max_pike_bytes`
    # less the charge of the Pike VM workspace a search holds beside it
    # (`PikeVM.workspace_charge`, capture layout when the program has
    # groups). The two together stay within `max_pike_bytes`.
    getter backtracker_allowance : Int64
    # How the source text ends (see `Ast::SourceEnd`), for `Expression#to_s`.
    getter source_end : Ast::SourceEnd
    # The literals every match starts with (see `LiteralSet`), or nil.
    getter literal_set : LiteralSet?
    # The transition tables of the large classes the program uses, shared
    # with every program that uses them (`ClassMemo::Block`), so a copy
    # of `\w` emits its states but none of its transitions. Never changed.
    getter list_of_shared_tables : Array(OffHeapList(Transition))

    # For shared table n - 1, its block's entry targets
    # (`ClassMemo::Block#entry_targets`; empty, or past the list, for a
    # table without), or nil when no table has them: `sparse_target` reads
    # an entry state's target with one load instead of a binary search.
    # Never changed.
    @list_of_entry_targets : Array(Slice(Int32))?

    # The shared tables and runs of every program that has none (never
    # changed: a compiler that adds one starts a list of its own).
    Mica::Regex.static_constant(NO_SHARED_TABLES, Array(OffHeapList(Transition)))
    Mica::Regex.static_constant(NO_RUNS, Array(ClassRun))

    # The target in a shared table that stands for the state's
    # `next_state` (the state after the class).
    SHARED_EXIT = Int32::MIN

    # *list_of_states* holds every state outside *list_of_runs*.
    def initialize(list_of_states : OffHeapList(State), @list_of_transitions : OffHeapList(Transition), @start_state : Int32,
                   @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName), @options : CompileOptions,
                   @backtracker_allowance : Int64, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed,
                   @literal_set : LiteralSet? = nil,
                   list_of_class_blocks : OffHeapList(ClassBlock) = OffHeapList(ClassBlock).new,
                   @list_of_shared_tables : Array(OffHeapList(Transition)) = NO_SHARED_TABLES,
                   @list_of_runs : Array(ClassRun) = NO_RUNS,
                   @list_of_entry_targets : Array(Slice(Int32))? = nil,
                   @list_of_owned_blocks : Array(ClassMemo::Block)? = nil)
      @list_of_physical_states = list_of_states
      @list_of_recorded_blocks = list_of_class_blocks
      @state_count = list_of_states.size + @list_of_runs.sum(&.size)
      offset = 0
      @list_of_run_offsets = OffHeapList(Int32).new(@list_of_runs.size)
      @list_of_runs.each do |run|
        @list_of_run_offsets << offset
        offset += run.size
      end
      # A binary search over the runs, then the run it found.
      @run_reads_per_state = @list_of_runs.empty? ? 0 : @list_of_runs.size.bit_length + 1
      # The program is reachable from its own plan, so its lists are freed
      # by an owner outside that cycle (see `OffHeapOwner`). The lists and
      # the blocks the memo did not keep (an ASCII class's run block, a
      # repeated class), which the runs and tables above read, are freed
      # with the program; nothing reads them without holding the program.
      @owner.track(@list_of_physical_states.to_unsafe)
      @owner.track(@list_of_transitions.to_unsafe)
      @owner.track(@list_of_recorded_blocks.to_unsafe)
      @owner.track(@list_of_run_offsets.to_unsafe)
      @list_of_owned_blocks.try(&.each { |block| block.each_buffer { |buffer| @owner.track(buffer) } })
      if @list_of_runs.empty?
        @all_states = list_of_states
        @all_blocks = list_of_class_blocks
        @materialized.set(true, :release)
      else
        @materialize_mutex = Mutex.new
      end
    end

    @owner = OffHeapOwner.new

    # Every state, indexed by number, as a new array (for specs and
    # diagnostics; the engines read `state_at`). A program with runs
    # (`ClassRun`) builds its full list on first use, which the plan
    # makes (its first searches read states through `state_at` and build
    # nothing).
    def list_of_states : Array(State)
      materialized_states.to_a
    end

    # The ranges of every `Sparse` state, as a new array (for specs).
    def list_of_transitions : Array(Transition)
      @list_of_transitions.to_a
    end

    # The classes of more than one state, in emission order, as a new
    # array (for specs; built with the states).
    def list_of_class_blocks : Array(ClassBlock)
      class_blocks.to_a
    end

    # :nodoc:
    # Every state, built on first use. The list sits outside the
    # collector's heap and is freed with the program: read it only while
    # holding the program.
    def materialized_states : OffHeapList(State)
      @materialized.get(:acquire) ? @all_states : materialize
    end

    # :nodoc:
    # The class blocks (see `list_of_class_blocks`), with the same rule as
    # `materialized_states`.
    def class_blocks : OffHeapList(ClassBlock)
      materialize unless @materialized.get(:acquire)
      @all_blocks
    end

    # :nodoc:
    # The first of the program's own transitions, with the same rule as
    # `materialized_states`.
    def transition_table : Pointer(Transition)
      @list_of_transitions.to_unsafe
    end

    # :nodoc:
    # The number of the program's own transitions.
    def transition_count : Int32
      @list_of_transitions.size
    end

    # State *index*, read without building `list_of_states`. Before the
    # states are built, a read finds the run that holds *index* by a binary
    # search over the runs: at most `run_reads_per_state` runs read.
    @[AlwaysInline]
    def state_at(index : Int32) : State
      if @materialized.get(:acquire)
        @all_states.unsafe_fetch(index)
      else
        run_state_at(index) { }
      end
    end

    # State *index*, as `state_at`, charging *meter* one operation for each
    # run the read looks at, before it looks (at haystack byte *at*). Once
    # the states are built a read is one array load and charges nothing.
    # The engines that may run before the plan builds the states (the
    # first searches' backtracker, and the Pike VM and backtracker a
    # `Searcher` forces) read through this, so the meter bounds the
    # lookups as it bounds the visits.
    @[AlwaysInline]
    def state_at(index : Int32, meter : SearchMeter, at : Int32) : State
      if @materialized.get(:acquire)
        @all_states.unsafe_fetch(index)
      else
        run_state_at(index) { meter.charge(1, at) }
      end
    end

    # The most operations one metered `state_at` charges while the runs
    # are pending: the binary search's reads plus the run it found (0
    # for a program without runs).
    def run_reads_per_state : Int32
      @run_reads_per_state
    end

    # :nodoc:
    # True while the program's runs have not been built into
    # `list_of_states` (for specs).
    def runs_pending? : Bool
      !@materialized.get(:acquire)
    end

    # Yields every state with its number, in order, without building
    # `list_of_states`: a run's states are worked out from its block.
    def each_state(& : State, Int32 ->) : Nil
      if @materialized.get(:acquire)
        @all_states.each_with_index { |state, index| yield state, index }
        return
      end
      index = 0
      physical = 0
      @list_of_runs.each do |run|
        while index < run.first_state
          yield @list_of_physical_states.unsafe_fetch(physical), index
          physical += 1
          index += 1
        end
        while index < run.end_state
          yield run.state_at(index), index
          index += 1
        end
      end
      while physical < @list_of_physical_states.size
        yield @list_of_physical_states.unsafe_fetch(physical), index
        physical += 1
        index += 1
      end
    end

    # Yields the kind and byte range of every state, with how many states
    # share them: a run's copies are alike in both, so each state of its
    # block is yielded once, with the run's copy count (other fields of a
    # run's state, its targets and its table, are those of the block, not
    # of a copy). Reads each physical state and each run's block once,
    # without building `list_of_states`.
    def each_distinct_state(& : State, Int32 ->) : Nil
      if @materialized.get(:acquire)
        @all_states.each { |state| yield state, 1 }
        return
      end
      @list_of_physical_states.each { |state| yield state, 1 }
      @list_of_runs.each do |run|
        run.list_of_block_states.each do |state|
          yield state.kind.sparse? ? state.copy_with(low: run.table_id) : state, run.copies
        end
        # An optional run's splits (their targets are those of the first copy).
        yield run.state_at(run.first_state + run.stride - 1), run.copies if run.optional
      end
    end

    # Finds the last run that starts at or before *index* by a binary
    # search (the runs are in state order), yielding before each run it
    # reads: at most `run_reads_per_state` yields.
    private def run_state_at(index : Int32, & : ->) : State
      slot = pending_run_slot(index) { yield }
      return @list_of_physical_states[index] if slot < 0
      yield
      run = @list_of_runs.unsafe_fetch(slot)
      return run.state_at(index) if index < run.end_state
      state_outside_runs(index, slot)
    end

    # :nodoc:
    # The index in `list_of_runs` of the last run that starts at or before
    # state *index* (-1 when none does), found by a binary search that
    # yields before each run it reads. The state is in that run when it is
    # before the run's `end_state`; otherwise read it with
    # `state_outside_runs`.
    def pending_run_slot(index : Int32, & : ->) : Int32
      low = 0
      high = @list_of_runs.size
      while low < high
        middle = (low + high) >> 1
        yield
        if @list_of_runs.unsafe_fetch(middle).first_state <= index
          low = middle + 1
        else
          high = middle
        end
      end
      low - 1
    end

    # :nodoc:
    # State *index*, which lies in no run, given the `pending_run_slot` of
    # the runs before it.
    def state_outside_runs(index : Int32, run_slot : Int32) : State
      return @list_of_physical_states[index] if run_slot < 0
      @list_of_physical_states[index - @list_of_run_offsets.unsafe_fetch(run_slot) - @list_of_runs.unsafe_fetch(run_slot).size]
    end

    # Builds every state and class block from the physical states and the
    # runs, once; threads racing here wait for the first.
    private def materialize : OffHeapList(State)
      mutex = @materialize_mutex || raise Mica::Error.new("internal error: a program without runs has every state")
      mutex.synchronize do
        return @all_states if @materialized.get(:acquire)
        states = OffHeapList(State).new(@state_count)
        blocks = OffHeapList(ClassBlock).new(@list_of_recorded_blocks.size + @list_of_runs.sum(&.copies))
        physical = 0
        recorded = 0
        @list_of_runs.each do |run|
          while states.size < run.first_state
            states << @list_of_physical_states[physical]
            physical += 1
          end
          (run.first_state...run.end_state).each { |index| states << run.state_at(index) }
          while recorded < @list_of_recorded_blocks.size && @list_of_recorded_blocks[recorded].first_state < run.first_state
            blocks << @list_of_recorded_blocks[recorded]
            recorded += 1
          end
          run.each_class_block { |block| blocks << block }
        end
        while physical < @list_of_physical_states.size
          states << @list_of_physical_states[physical]
          physical += 1
        end
        while recorded < @list_of_recorded_blocks.size
          blocks << @list_of_recorded_blocks[recorded]
          recorded += 1
        end
        @owner.track(states.to_unsafe)
        @owner.track(blocks.to_unsafe)
        @all_states = states
        @all_blocks = blocks
        @materialized.set(true, :release)
        states
      end
    end

    # Published through an atomic, so a thread that sees the plan sees it
    # fully built.
    @plan = Atomic(SearchPlan?).new(nil)
    # Single searches run on the backtracker so far (see `FirstSearch`),
    # or `FIRST_SEARCHES_ENDED`.
    @first_searches = Atomic(Int32).new(0)

    # Set by `end_first_searches`: past `FirstSearch::SEARCHES`, so one load
    # answers `first_searches_left?`, and apart from any count.
    private FIRST_SEARCHES_ENDED = Int32::MAX // 2

    # :nodoc:
    # True while this program may still run first searches (one relaxed
    # load, so a program past them pays nothing more per search).
    def first_searches_left? : Bool
      @first_searches.get(:relaxed) < FirstSearch::SEARCHES
    end

    # :nodoc:
    # Counts one more first search (see `FirstSearch`) and returns true
    # while the program has had fewer than `FirstSearch::SEARCHES`, so
    # exactly that many return true, however threads race.
    def count_first_search : Bool
      return false if @first_searches.get(:relaxed) >= FirstSearch::SEARCHES
      @first_searches.add(1, :relaxed) < FirstSearch::SEARCHES
    end

    # :nodoc:
    # The first searches this program ran (at most `FirstSearch::SEARCHES`;
    # none after `end_first_searches`).
    def first_search_count : Int32
      count = @first_searches.get(:relaxed)
      count >= FIRST_SEARCHES_ENDED ? 0 : Math.min(count, FirstSearch::SEARCHES)
    end

    # :nodoc:
    # True once `end_first_searches` ran.
    def first_searches_ended? : Bool
      @first_searches.get(:relaxed) >= FIRST_SEARCHES_ENDED
    end

    # :nodoc:
    # Ends this program's first searches without counting any, so its next
    # single searches take the plan's engines and a plan built after this
    # finds every match start with its reverse DFA (for the specs of those
    # engines).
    def end_first_searches : Nil
      @first_searches.set(FIRST_SEARCHES_ENDED, :relaxed)
    end

    # :nodoc:
    # The engines and caches of this program's searches (built on the first
    # search, see `SearchPlan`).
    @[AlwaysInline]
    def plan : SearchPlan
      @plan.get(:acquire) || build_plan
    end

    # Threads racing here may each build a plan; the first to publish
    # wins and the others drop theirs, so building takes no lock (and the
    # program no mutex object).
    private def build_plan : SearchPlan
      built = SearchPlan.new(self)
      _, published = @plan.compare_and_set(nil, built)
      published ? built : plan
    end

    # The ASCII bytes every match contains (see
    # `StartFilter.required_bytes`), found on first use.
    @required_bytes = Atomic(UInt64).new(RequiredBytes::NOT_FOUND)

    # The fewest bytes a match can read from each state (`UNREACHABLE` when
    # no match is reachable), found once, on first use, for a program of at
    # most `MIN_BYTES_MAX_STATES` states; nil for a larger one.
    @list_of_min_bytes = Atomic(Array(Int32)?).new(nil)

    # The most states a program may have for `list_of_min_bytes`: finding
    # them reads every state and transition once, which a short capture
    # pass of a larger program would not repay.
    MIN_BYTES_MAX_STATES = 1024
    # How many requests for `list_of_min_bytes` answer nil before it is
    # found, so a program read once (a cold search) never finds it.
    MIN_BYTES_AFTER = 16
    @min_bytes_requests = Atomic(Int32).new(0)
    # `list_of_min_bytes` for a state from which no match is reachable.
    UNREACHABLE = Int32::MAX // 2

    # :nodoc:
    # The fewest bytes any match reads from each state on, or nil for a
    # program of more than `MIN_BYTES_MAX_STATES` states. A search that
    # must end by a bound (a capture pass over a known span) drops a
    # thread at a state whose fewest bytes do not fit before the bound:
    # an alternative such as `\w{14}` over a 7-byte span fails at once
    # instead of after reading seven bytes. One breadth-first pass over the
    # reversed edges from the match states, byte edges weighing one and
    # the others none: O(states + transitions).
    def list_of_min_bytes : Array(Int32)?
      return nil if state_count > MIN_BYTES_MAX_STATES
      if found = @list_of_min_bytes.get(:acquire)
        return found
      end
      # A pattern whose groups are read a few times does not pay for the
      # pass: it is made on the `MIN_BYTES_AFTER`th request.
      return nil if @min_bytes_requests.add(1, :relaxed) < MIN_BYTES_AFTER
      found = find_min_bytes
      # Threads racing here find the same lengths; the first to publish wins.
      @list_of_min_bytes.compare_and_set(nil, found)
      @list_of_min_bytes.get(:acquire) || found
    end

    private def find_min_bytes : Array(Int32)
      count = state_count
      # The reversed edges, grouped by target (counted, then placed).
      list_of_edge_counts = Array(Int32).new(count + 1, 0)
      each_edge { |_, target, _| list_of_edge_counts[target + 1] += 1 }
      count.times { |index| list_of_edge_counts[index + 1] += list_of_edge_counts[index] }
      list_of_edge_starts = list_of_edge_counts.dup
      list_of_sources = Array(Int32).new(list_of_edge_counts[count], 0)
      list_of_weights = Array(Int32).new(list_of_edge_counts[count], 0)
      each_edge do |source, target, weight|
        place = list_of_edge_starts[target]
        list_of_sources[place] = source
        list_of_weights[place] = weight
        list_of_edge_starts[target] = place + 1
      end
      min_bytes = Array(Int32).new(count, UNREACHABLE)
      queue = Deque(Int32).new
      each_state do |state, index|
        if state.kind.match?
          min_bytes[index] = 0
          queue.push(index)
        end
      end
      # 0-1 breadth-first search: a state reached over an edge of weight
      # zero goes to the front, so states leave the queue in order of
      # their distance.
      while target = queue.shift?
        distance = min_bytes[target]
        (list_of_edge_counts[target]...list_of_edge_counts[target + 1]).each do |place|
          source = list_of_sources[place]
          weight = list_of_weights[place]
          next unless distance + weight < min_bytes[source]
          min_bytes[source] = distance + weight
          weight == 0 ? queue.unshift(source) : queue.push(source)
        end
      end
      min_bytes
    end

    # Yields each edge of the program as source, target and weight (1 for
    # an edge that reads a byte, 0 otherwise).
    private def each_edge(& : Int32, Int32, Int32 ->) : Nil
      each_state do |state, index|
        case state.kind
        when .byte_range?
          yield index, state.next_state, 1
        when .sparse?
          state.alternate.times { |offset| yield index, transition_at(index, state, offset).target, 1 }
        when .split?
          yield index, state.next_state, 0
          yield index, state.alternate, 0
        when .save?, .look?
          yield index, state.next_state, 0
        end
      end
    end

    # :nodoc:
    # The ASCII bytes every match contains, rarest first (see
    # `StartFilter.required_bytes`; found once, on first use).
    def list_of_required_bytes : RequiredBytes
      if found = required_bytes_found?
        return found
      end
      found = StartFilter.required_bytes(self)
      # Threads racing here find the same bytes, so each publishes the
      # same word.
      @required_bytes.set(found.packed, :release)
      found
    end

    # The required bytes once some search found them, or nil.
    private def required_bytes_found? : RequiredBytes?
      packed = @required_bytes.get(:acquire)
      packed == RequiredBytes::NOT_FOUND ? nil : RequiredBytes.new(packed)
    end

    # :nodoc:
    # The required bytes when a first search (see `FirstSearch`) of
    # *span_bytes* bytes should check them, or nil: once they are found,
    # always; before that, only when finding them (one pass over the
    # states and sparse transitions) costs no more than about a few passes
    # over the span, so a short first search of a large program does not
    # pay for the analysis.
    #
    # With *meter*, the analysis charges it as it goes (one operation for
    # each state and transition it reads, and for each run a state read
    # looks at, see `state_at`), at haystack byte *at*, so it stops on the
    # call's allowance or deadline before it reads more: at most
    # `required_bytes_analysis_bound(span_bytes)` operations.
    def required_bytes_for_first_search(span_bytes : Int32, meter : SearchMeter? = nil,
                                        at : Int32 = 0) : RequiredBytes?
      if found = required_bytes_found?
        return found
      end
      # A large program with runs reads each state through its runs, which
      # costs more than the first search it serves.
      return nil if runs_pending? && state_count >= FirstSearch::LARGE_PROGRAM_STATES
      allowance = REQUIRED_BYTES_BASE_EDGES + REQUIRED_BYTES_EDGES_PER_BYTE * span_bytes
      return nil unless edges_within?(allowance, meter, at)
      found = StartFilter.required_bytes(self, meter, at)
      # Threads racing here find the same bytes, so each publishes the
      # same word.
      @required_bytes.set(found.packed, :release)
      found
    end

    # :nodoc:
    # The most operations `required_bytes_for_first_search` charges for a
    # span of *span_bytes* bytes: the edges (states and transitions) it
    # allows, counted once, read once more in the first pass, and read
    # again by each of the analysis's candidates
    # (`StartFilter::MAX_REQUIRED_CANDIDATES`), a state read costing its
    # run lookups too (`run_reads_per_state`); nothing once the bytes are
    # found.
    def required_bytes_analysis_bound(span_bytes : Int32) : Int64
      return 0_i64 if required_bytes_found?
      edges = REQUIRED_BYTES_BASE_EDGES + REQUIRED_BYTES_EDGES_PER_BYTE * span_bytes
      reads = 2_i64 + @run_reads_per_state
      edges * (2_i64 + StartFilter::MAX_REQUIRED_CANDIDATES * reads)
    end

    # True when the states plus the sparse transitions they read (in the
    # program's own list and in shared tables) number at most
    # *allowance*. Stops counting once past it. With *meter*, charges one
    # operation for each state it reads, before reading it (a run's block
    # is read once for all its copies, see `each_distinct_state`).
    private def edges_within?(allowance : Int64, meter : SearchMeter? = nil, at : Int32 = 0) : Bool
      edges = state_count.to_i64 + @list_of_transitions.size
      return false if edges > allowance
      return true if @list_of_shared_tables.empty?
      each_distinct_state do |state, copies|
        meter.charge(1, at) if meter
        next unless state.kind.sparse? && state.low != 0
        edges += state.alternate.to_i64 * copies
        return false if edges > allowance
      end
      true
    end

    # See `required_bytes_for_first_search`.
    REQUIRED_BYTES_BASE_EDGES     = 256_i64
    REQUIRED_BYTES_EDGES_PER_BYTE =   4_i64

    # :nodoc:
    # True once a search has built the plan (for specs).
    def plan_built? : Bool
      !@plan.get.nil?
    end

    # Returns the number of states (m in the bounds).
    def state_count : Int32
      @state_count
    end

    # Returns the capture slots of a full match (c in the bounds): two per
    # group, group 0 included.
    def slot_count : Int32
      (@capture_count + 1) * 2
    end

    # Returns the bytes of a span-layout Pike VM workspace (no captures):
    # two sparse sets (16·m), the one-word closure stack (8·m) and two
    # `Int32` start tables (8·m), 32·m in all.
    def self.span_workspace_bytes(state_count : Int64) : Int64
      Preflight.multiply(32_i64, state_count)
    end

    # Returns the bytes of a Pike VM workspace for *slot_count* slots: two
    # slot tables (16·m·c), two sparse sets (16·m), the epsilon-closure
    # stack (16·m) and one scratch slot vector (8·c), all in one buffer.
    def self.pike_workspace_bytes(state_count : Int64, slot_count : Int64) : Int64
      Preflight.add(Preflight.add(Preflight.multiply(Preflight.multiply(16_i64, state_count), slot_count),
        Preflight.multiply(32_i64, state_count)), Preflight.multiply(8_i64, slot_count))
    end

    # The transitions `sparse_target` reads in order before it searches
    # the rest by halves.
    SPARSE_LINEAR_READS = 4

    # Returns the target of the transition of Sparse state *state* (number
    # *state_index*) that holds *byte*, or -1. The ranges are sorted and
    # disjoint. At the entry state of a large class the target for each
    # byte is one load. Otherwise the first `SPARSE_LINEAR_READS` are read
    # in order, as they hold the low bytes (ASCII text, the common case) and
    # an in-order read predicts well; the rest are searched by halves.
    def sparse_target(state_index : Int32, state : State, byte : UInt8) : Int32
      table_index = state.low.to_i32 - 1
      if (lookups = @list_of_entry_targets) && 0 <= table_index < lookups.size
        targets = lookups.unsafe_fetch(table_index)
        if targets.size > ClassMemo::ENTRY_FIRST_SLOT && targets.unsafe_fetch(ClassMemo::ENTRY_FIRST_SLOT) == state.argument
          target = targets.unsafe_fetch(byte)
          return target == ClassMemo::NO_TRANSITION ? -1 : resolve(state_index, state, target)
        end
      end
      table = table_of(state)
      low = state.argument
      high = state.argument + state.alternate
      linear_end = Math.min(high, low + SPARSE_LINEAR_READS)
      while low < linear_end
        transition = table[low]
        if byte <= transition.high
          return byte >= transition.low ? resolve(state_index, state, transition.target) : -1
        end
        low += 1
      end
      while low < high
        middle = (low + high) >> 1
        transition = table[middle]
        if transition.high < byte
          low = middle + 1
        elsif transition.low > byte
          high = middle
        else
          return resolve(state_index, state, transition.target)
        end
      end
      -1
    end

    # Returns transition *offset* of Sparse state *state* (number
    # *state_index*), its target a state number.
    def transition_at(state_index : Int32, state : State, offset : Int32) : Transition
      unless 0 <= offset < state.alternate
        raise IndexError.new("Transition #{offset} of a state of #{state.alternate}")
      end
      transition = table_of(state)[state.argument + offset]
      return transition if state.low == 0
      transition.copy_with(target: resolve(state_index, state, transition.target))
    end

    # Yields the byte range of every transition the program's states can
    # take, in its own list and in each shared table.
    def each_transition_range(& : UInt8, UInt8 ->) : Nil
      @list_of_transitions.each { |transition| yield transition.low, transition.high }
      @list_of_shared_tables.each do |table|
        table.each { |transition| yield transition.low, transition.high }
      end
    end

    @[AlwaysInline]
    # The first transition of the table *state* reads (its own list or a
    # shared table).
    private def table_of(state : State) : Pointer(Transition)
      state.low == 0 ? @list_of_transitions.to_unsafe : @list_of_shared_tables[state.low.to_i32 - 1].to_unsafe
    end

    @[AlwaysInline]
    private def resolve(state_index : Int32, state : State, target : Int32) : Int32
      return target if state.low == 0
      target == SHARED_EXIT ? state.next_state : state_index + target
    end

    # Writes the program one state per line, for specs and diagnostics.
    def to_s(io : IO) : Nil
      each_state do |state, index|
        io << index << ": " << state.kind
        case state.kind
        when .byte_range?
          io << " " << state.low.to_s(16) << '-' << state.high.to_s(16) << " -> " << state.next_state
        when .sparse?
          state.alternate.times do |offset|
            transition = transition_at(index, state, offset)
            io << ' ' << transition.low.to_s(16) << '-' << transition.high.to_s(16) << "->" << transition.target
          end
        when .split?
          io << ' ' << state.next_state << ", " << state.alternate
        when .save?
          io << " slot " << state.argument << " -> " << state.next_state
        when .look?
          io << ' ' << LookKind.new(state.argument) << " -> " << state.next_state
        end
        io << '\n'
      end
    end
  end
end
