module Regex::Mica::Regex
  # Compiles `Hir` into a `Program`, the byte-level Thompson NFA the
  # engines run.
  #
  # The construction runs backward: each node is compiled knowing the state
  # that follows it, so no edge is ever patched except the one back edge of
  # an unbounded loop. Repetitions are expanded here (`{n,m}` as n copies
  # and m − n nested optional copies, `{n,}` as n copies whose last one
  # loops). Classes become UTF-8 automata through `Utf8Sequences`, with
  # shared leading byte ranges, so a class emits at most the byte ranges the
  # size preflight counted for it.
  #
  # Like the front half, the compiler never recurses on the pattern's
  # structure (it keeps an explicit task stack), charges every allocation
  # to the `AllocationLedger` before making it, charges one operation per
  # task and per emitted state to the `Core::WorkMeter`, and checks
  # `CompileLimits#max_program_states` as it emits, and
  # `CompileLimits#max_pike_bytes` when it finishes.
  struct Compiler
    # What a task on the work stack does.
    private enum TaskKind
      # Compile `node` so that it continues at `next_state`; push its start.
      Compile
      # A child of a concatenation is compiled; compile the one before it.
      ConcatenationStep
      # Every branch of an alternation is compiled; join them with splits.
      AlternationFinish
      # A capture's child is compiled; add the opening slot save.
      CaptureFinish
      # An unbounded loop's body is compiled; close the loop split.
      LoopFinish
      # Compile the next optional copy of a bounded repetition.
      OptionalStep
      # An optional copy is compiled; put a split in front of it.
      OptionalFinish
      # Compile the next mandatory copy of a repetition.
      MandatoryStep
    end

    # The lists the compiler reuses, whose growth `grow` charges.
    private enum GrowingList
      Tasks
      Values
      TrieStates
      Visited
    end

    # One step of the compile. It names its node by address, so the task
    # list can sit outside the collector's heap: every node a task names
    # is part of the pattern's tree, which the compiler holds for as long
    # as it runs.
    private record Task, task_kind : TaskKind, node_address : UInt64, next_state : Int32, count : Int32 do
      def node : Hir::Node
        Compiler.node_at(node_address)
      end
    end

    # The node of the pattern's tree at *address* (see `Task`).
    protected def self.node_at(address : UInt64) : Hir::Node
      Pointer(Void).new(address).as(Hir::Node)
    end

    private NONE = -1

    # Compiles *pattern*, whose size preflight bounded its states by
    # *estimate*, under *limits*.
    def self.compile(pattern : Hir::Pattern, estimate : Int64, limits : CompileLimits, ledger : AllocationLedger,
                     meter : Core::WorkMeter) : Program
      compiler = new(pattern, estimate, limits, ledger, meter)
      begin
        compiler.compile
      rescue error
        # A limit or the deadline stopped the compile: the states and
        # transitions never reach a program, so they are freed here.
        compiler.free_program_lists
        raise error
      ensure
        compiler.release
      end
    end

    # The states and transitions go to the program, outside the
    # collector's heap (`OffHeapList`); the value stack, the trie states
    # and the visited marks are scratch, freed by `release`.
    @list_of_states : OffHeapList(Program::State)
    @list_of_transitions : OffHeapList(Program::Transition)
    @list_of_tasks : OffHeapList(Task)
    @list_of_values : OffHeapList(Int32)
    # The byte trie of the small class being compiled, reused for every
    # class, and the state of each of its nodes.
    @class_trie : ClassTrie
    @list_of_trie_states : OffHeapList(Int32)
    # The memoized class block instantiated last, and its set: the copies
    # of a repeated class share one set object, so the memo is asked once
    # per set rather than once per copy.
    @last_memo_set : CodePointSet? = nil
    @last_memo_block : ClassMemo::Block? = nil
    # The alternation merged into one class last, and its union.
    @last_merged_node : Hir::Alternation? = nil
    @last_merged_set : CodePointSet? = nil
    # The small class of the repetition being compiled, and its emitted
    # block once the first copy is built.
    @repeated_small_set : CodePointSet? = nil
    @repeated_small_block : ClassMemo::Block? = nil
    @high_water = StaticArray(Int32, 4).new(0)
    @list_of_visited = OffHeapList(Bool).new
    @list_of_class_blocks = OffHeapList(Program::ClassBlock).new
    # The shared tables the program's large classes use (see
    # `Program#list_of_shared_tables`); a `Sparse` state names one by its
    # position plus one, in a byte, so at most `MAX_SHARED_TABLES`.
    # Made with the first table or run: most programs have neither, and
    # share the program's empty lists (`Program::NO_SHARED_TABLES`,
    # `Program::NO_RUNS`).
    @list_of_shared_tables = Program::NO_SHARED_TABLES
    # For each shared table, its block's `ClassMemo::Block#entry_targets`
    # (an empty slice for a table without), made when the first table with
    # them is added (see `Program#sparse_target`).
    @list_of_entry_targets : Array(Slice(Int32))? = nil
    # The runs of class copies held as their block (`Program::ClassRun`),
    # in state order, and the states they stand for: state numbers count
    # them, `@list_of_states` does not hold them.
    @list_of_runs = Program::NO_RUNS
    @run_states = 0
    # The most states `@list_of_states` may hold: the preflight's bound,
    # charged to the ledger, less the runs found ahead.
    @physical_capacity : Int32
    # The room `@list_of_states` has now. It starts at the whole bound or
    # at `FIRST_STATE_ROOM` (see there), and doubles as the compiler
    # emits, up to `@physical_capacity`: the
    # bound counts every class at its largest and every optional copy of
    # a counted repetition, so a program often needs a small part of it.
    @state_room : Int32
    # The states of the runs `transitions_bound` found ahead (see
    # `class_run`).
    @run_states_ahead = 0_i64
    # The ASCII class whose run block (`run_block`) was built last, and the
    # block, so a run's two lookups build it once.
    @ascii_run_set : CodePointSet? = nil
    @ascii_run_block : {OffHeapList(Program::State), OffHeapList(Program::Transition), Int32}? = nil

    private def initialize(@pattern : Hir::Pattern, @estimate : Int64, @limits : CompileLimits,
                           @ledger : AllocationLedger, @meter : Core::WorkMeter)
      capacity = @estimate.clamp(1_i64, @limits.max_program_states).to_i32
      @ledger.charge_object(sizeof(Compiler), "the compiler", 0)
      @ledger.charge_array(capacity, sizeof(Program::State), "the program states", 0)
      # A program of few states has few transitions; it skips the bound
      # and grows its list as it emits. The bound's walk also finds the
      # runs ahead (a run is at least `RUN_MIN_STATES`).
      transition_bound = @estimate >= PRESIZE_MIN_STATES ? transitions_bound : 0_i64
      # The states in runs (`class_run`) are never written, so the list
      # starts without room for the runs found ahead; it grows to the full
      # bound, charged again, only when a run found ahead is emitted as
      # states after all (see `check_state_room`).
      @physical_capacity = Math.max(capacity - Math.min(@run_states_ahead, capacity.to_i64).to_i32, 1)
      @state_room = @physical_capacity <= WHOLE_ROOM_STATES ? @physical_capacity : FIRST_STATE_ROOM
      presized_transitions = PRESIZED_TRANSITIONS <= transition_bound <= @limits.max_program_states
      @ledger.charge_array(presized_transitions ? transition_bound : 0, sizeof(Program::Transition), "the program transitions", 0)
      @ledger.charge_array(0, sizeof(Task), "the compiler task stack", 0)
      @ledger.charge_array(0, sizeof(Int32), "the compiler value stack", 0)
      ClassTrie.charge_new(@ledger)
      @ledger.charge_array(0, sizeof(Int32), "the class trie", 0)
      # Every charge above may refuse the pattern, so the lists outside the
      # collector's heap are made only once all of them passed.
      @list_of_tasks = OffHeapList(Task).new
      @class_trie = ClassTrie.new
      @list_of_states = OffHeapList(Program::State).new(@state_room)
      @list_of_transitions = OffHeapList(Program::Transition).new(presized_transitions ? transition_bound.to_i32 : 0)
      @list_of_values = OffHeapList(Int32).new
      @list_of_trie_states = OffHeapList(Int32).new
    end

    # The states the state list starts with room for when the bound is
    # larger than `WHOLE_ROOM_STATES` (see `@state_room`); a list bound to
    # at most that many states gets its whole room at once, which costs
    # less than growing it.
    private FIRST_STATE_ROOM  =   64
    private WHOLE_ROOM_STATES = 2048

    # A program bound to have at least this many transitions gets its
    # transition list allocated once, at the bound, rather than grown.
    private PRESIZED_TRANSITIONS = 512_i64
    # Programs bound to fewer states than this never need the transition bound.
    private PRESIZE_MIN_STATES = 128_i64

    # An upper bound on the transitions the program's classes emit: each
    # class's transitions (a large class's memoized block exactly, a small
    # class's UTF-8 byte ranges, which its trie never exceeds) times the
    # copies its enclosing repetitions make (one more for an unbounded
    # repetition's fresh copy). Saturates rather than overflows.
    private def transitions_bound : Int64
      total = 0_i64
      @ledger.charge_array(0, sizeof({Hir::Node, Int64}), "the transition bound stack", 0)
      # Scratch outside the collector's heap: each entry names a node of
      # the pattern's tree by address (see `Task`).
      stack = OffHeapList({UInt64, Int64}).new
      begin
        push_bound_entry(pointerof(stack), @pattern.root, 1_i64)
        while entry = stack.pop?
          node = Compiler.node_at(entry[0])
          copies = entry[1]
          charge_work
          case node
          when Hir::Class
            total = Preflight.add(total, Preflight.multiply(class_transitions(node.code_point_set), copies))
          when Hir::LineBreak
            total = Preflight.add(total, Preflight.multiply(@@other_line_breaks.range_count.to_i64 * 4, copies))
          when Hir::Repetition
            maximum = node.maximum
            # A run's transitions sit in its table, not in the program's
            # list: an exact count (`x{n}`) adds none, and `x{n,m}` adds only
            # the copies no run holds.
            if copies == 1
              mandatory_run = run_ahead?(node)
              if maximum && node.child.is_a?(Hir::Class)
                emitted = (optional_run_ahead?(node) ? 0 : maximum - node.minimum) + (mandatory_run ? 0 : node.minimum)
                push_bound_entry(pointerof(stack), node.child, emitted.to_i64) if emitted > 0
                next
              end
            end
            repeated = if maximum
                         maximum.to_i64
                       else
                         # The fresh copy exists only for a body that can match
                         # the empty string (see `finish_loop`).
                         Math.max(node.minimum, 1).to_i64 + (consumes?(node.child, BOUND_DEPTH) ? 0 : 1)
                       end
            push_bound_entry(pointerof(stack), node.child, Preflight.multiply(copies, repeated))
          when Hir::Capture
            push_bound_entry(pointerof(stack), node.child, copies)
          when Hir::Concatenation
            node.list_of_children.each { |child| push_bound_entry(pointerof(stack), child, copies) }
          when Hir::Alternation
            node.list_of_branches.each { |branch| push_bound_entry(pointerof(stack), branch, copies) }
          end
        end
      ensure
        stack.free
      end
      total
    end

    # How deep `consumes?` looks before it answers false.
    private BOUND_DEPTH = 4

    # True when every match of *node* consumes a byte, looking at most
    # *depth* levels down (deeper, it answers false, which only widens the
    # bound). Over-allocating the transitions of `\w+` by a second copy of
    # `\w` doubled the bytes a small pattern allocated.
    private def consumes?(node : Hir::Node, depth : Int32) : Bool
      return false if depth == 0
      case node
      when Hir::Class, Hir::Literal, Hir::LineBreak
        true
      when Hir::Capture
        consumes?(node.child, depth - 1)
      when Hir::Concatenation
        node.list_of_children.any? { |child| consumes?(child, depth - 1) }
      when Hir::Alternation
        node.list_of_branches.all? { |branch| consumes?(branch, depth - 1) }
      when Hir::Repetition
        node.minimum > 0 && consumes?(node.child, depth - 1)
      else
        false
      end
    end

    # Pushes *node* with its *copies* on the list *stack* points to.
    private def push_bound_entry(stack : Pointer(OffHeapList({UInt64, Int64})), node : Hir::Node, copies : Int64) : Nil
      @ledger.charge_append(sizeof({Hir::Node, Int64}), "the transition bound stack", 0)
      list = stack.value
      list << {node.object_id, copies}
      stack.value = list
    end

    private def class_transitions(set : CodePointSet) : Int64
      # A memoized class's transitions stay in its shared table.
      return 0_i64 if ClassMemo.memoized?(set)
      return set.range_count.to_i64 if set.empty? || set.list_of_bounds[-1] < 0x80
      byte_ranges = 0_i64
      set.each_range { |first, last| byte_ranges += Utf8Sequences.count(first, last)[1] }
      byte_ranges
    end

    protected def compile : Program
      match_state = emit(Program::StateKind::Match)
      close_whole = emit_save(1, match_state)
      push_task(TaskKind::Compile, @pattern.root, close_whole)
      run_tasks
      body = @list_of_values.pop
      start = emit_save(0, body)
      workspace_charge = check_pike_bytes
      group_names = @pattern.list_of_group_names
      literal_set = LiteralSet.extract(@pattern, @meter)
      charge_literal_set(literal_set) if literal_set
      @ledger.charge_object(instance_sizeof(Program), "the program", 0)
      trim_states
      trim_transitions
      Program.new(@list_of_states, @list_of_transitions, start, @pattern.capture_count, group_names,
        @pattern.options, @limits.max_pike_bytes - workspace_charge, @pattern.source_end, literal_set,
        @list_of_class_blocks, @list_of_shared_tables, @list_of_runs, @list_of_entry_targets, @ledger.take_owned_blocks)
    end

    private def charge_literal_set(literal_set : LiteralSet) : Nil
      @ledger.charge_object(instance_sizeof(LiteralSet), "the literal set", 0)
      @ledger.charge_array(literal_set.list_of_literals.size, sizeof(Bytes), "the literal set", 0)
      literal_set.list_of_literals.each { |literal| @ledger.charge_string(literal.size, "a literal", 0) }
    end

    private def run_tasks : Nil
      while task = @list_of_tasks.pop?
        charge_work
        node = task.node
        case task.task_kind
        in .compile?
          compile_node(node, task.next_state)
        in .concatenation_step?
          start = @list_of_values.pop
          if task.count == 0
            push_value(start)
          else
            push_task(TaskKind::ConcatenationStep, node, NONE, task.count - 1)
            push_task(TaskKind::Compile, children_of(node)[task.count - 1], start)
          end
        in .alternation_finish?
          finish_alternation(task.count)
        in .capture_finish?
          capture = expect_node(node, Hir::Capture)
          push_value(emit_save(capture.capture_index * 2, @list_of_values.pop))
        in .loop_finish?
          finish_loop(expect_node(node, Hir::Repetition), task.count, task.next_state)
        in .optional_step?
          repetition = expect_node(node, Hir::Repetition)
          if task.count == 0
            push_task(TaskKind::MandatoryStep, node, NONE, repetition.minimum)
          else
            continuation = @list_of_values.pop
            push_task(TaskKind::OptionalFinish, node, task.next_state, task.count)
            push_task(TaskKind::Compile, repetition.child, continuation)
          end
        in .optional_finish?
          repetition = expect_node(node, Hir::Repetition)
          copy = @list_of_values.pop
          exit = task.next_state
          split = repetition.greedy? ? emit_split(copy, exit) : emit_split(exit, copy)
          push_value(split)
          push_task(TaskKind::OptionalStep, node, exit, task.count - 1)
        in .mandatory_step?
          if task.count > 0
            continuation = @list_of_values.pop
            push_task(TaskKind::MandatoryStep, node, NONE, task.count - 1)
            push_task(TaskKind::Compile, expect_node(node, Hir::Repetition).child, continuation)
          end
        end
      end
    end

    private def compile_node(node : Hir::Node, next_state : Int32) : Nil
      case node
      when Hir::Empty
        push_value(next_state)
      when Hir::Literal
        push_value(compile_literal(node.code_point, next_state))
      when Hir::Class
        push_value(compile_recorded_class(node.code_point_set, next_state))
      when Hir::Look
        push_value(emit_look(look_kind(node), next_state))
      when Hir::LineBreak
        push_value(compile_line_break(node.any_crlf?, next_state))
      when Hir::Concatenation
        count = node.list_of_children.size
        if count == 0
          push_value(next_state)
        else
          push_task(TaskKind::ConcatenationStep, node, NONE, count - 1)
          push_task(TaskKind::Compile, node.list_of_children[count - 1], next_state)
        end
      when Hir::Alternation
        if set = merged_class(node)
          push_value(compile_recorded_class(set, next_state))
          return
        end
        branches = node.list_of_branches
        push_task(TaskKind::AlternationFinish, node, NONE, branches.size)
        (branches.size - 1).downto(0) { |index| push_task(TaskKind::Compile, branches[index], next_state) }
      when Hir::Capture
        close = emit_save(node.capture_index * 2 + 1, next_state)
        push_task(TaskKind::CaptureFinish, node, NONE, 0)
        push_task(TaskKind::Compile, node.child, close)
      when Hir::Repetition
        compile_repetition(node, next_state)
      else
        raise SyntaxError.new("internal error: unknown Hir node #{node.class}", Core::Position.new(0_i64))
      end
    end

    private def children_of(node : Hir::Node) : Array(Hir::Node)
      expect_node(node, Hir::Concatenation).list_of_children
    end

    # Returns *node* as the *type* its task was pushed for; anything else is
    # a compiler defect, reported as one.
    private def expect_node(node : Hir::Node, type : T.class) : T forall T
      node.as?(T) || raise SyntaxError.new("internal error: expected a #{T}, got #{node.class}", Core::Position.new(0_i64))
    end

    # Joins the branches on the value stack (first branch deepest) with
    # splits that try them in order.
    private def finish_alternation(count : Int32) : Nil
      first = @list_of_values.size - count
      current = @list_of_values[-1]
      (count - 2).downto(0) do |index|
        current = emit_split(@list_of_values[first + index], current)
      end
      count.times { @list_of_values.pop }
      push_value(current)
    end

    private def compile_repetition(node : Hir::Repetition, next_state : Int32) : Nil
      maximum = node.maximum
      reserve_class_copies(node, maximum)
      if maximum.nil?
        loop_split = emit(Program::StateKind::Split)
        push_task(TaskKind::LoopFinish, node, next_state, loop_split)
        push_task(TaskKind::Compile, node.child, loop_split)
      elsif maximum == 0
        push_value(next_state)
      elsif single_item?(node.child)
        push_value(compile_counted_item(node, maximum, next_state))
      else
        push_value(next_state)
        push_task(TaskKind::OptionalStep, node, next_state, maximum - node.minimum)
      end
    end

    # True when *node* compiles in one step, without tasks of its own.
    private def single_item?(node : Hir::Node) : Bool
      node.is_a?(Hir::Literal) || node.is_a?(Hir::Class)
    end

    # Compiles `x{n,m}` for a literal or class *x* in a loop, emitting what
    # the `OptionalStep`, `OptionalFinish` and `MandatoryStep` tasks emit
    # for it, in the same order: the optional copies from the last back,
    # each behind a split to *next_state*, then the mandatory copies.
    # `[\w.%+-]{1,256}` is hundreds of copies, and a task round per copy
    # cost more than the copy.
    private def compile_counted_item(node : Hir::Repetition, maximum : Int32, next_state : Int32) : Int32
      child = node.child
      current = next_state
      optional_copies = maximum - node.minimum
      if child.is_a?(Hir::Class) && (run = class_run(child.code_point_set, optional_copies, current, optional: true,
           lazy: !node.greedy?))
        current = run
        optional_copies = 0
      end
      optional_copies.times do
        charge_work
        copy = compile_item(child, current)
        current = node.greedy? ? emit_split(copy, next_state) : emit_split(next_state, copy)
      end
      if child.is_a?(Hir::Class) && (run = class_run(child.code_point_set, node.minimum, current))
        return run
      end
      node.minimum.times do
        charge_work
        current = compile_item(child, current)
      end
      current
    end

    # The fewest states a run of class copies stands for (see
    # `Program::ClassRun`); fewer are emitted as states.
    private RUN_MIN_STATES = 32

    # A run's block: its states (targets relative to the block, `EXIT` for
    # the exit), the table its `Sparse` states read (targets relative to the
    # state, `Program::SHARED_EXIT` for the exit; empty when it has none),
    # and its entry. A large class has its memoized block; an ASCII class
    # its one byte state, as `compile_ascii_class` emits it, its ranges in
    # a table of the program's own. Nil for any other class.
    private def run_block(set : CodePointSet) : {OffHeapList(Program::State), OffHeapList(Program::Transition), Int32}?
      return nil if set.empty?
      if ClassMemo.memoized?(set)
        block = memo_block(set)
        table = block.shared_table || return nil
        return block.list_of_states.size < 2 ? nil : {block.list_of_states, table, block.entry}
      end
      return nil unless set.list_of_bounds[-1] < 0x80
      if set.same?(@ascii_run_set) && (cached = @ascii_run_block)
        return cached
      end
      built = ascii_run_block(set)
      @ascii_run_set = set
      @ascii_run_block = built
      built
    end

    #
    # The block's lists sit outside the collector's heap and belong to
    # this compilation (`AllocationLedger#own`): the program frees them.
    private def ascii_run_block(set : CodePointSet) : {OffHeapList(Program::State), OffHeapList(Program::Transition), Int32}
      bounds = set.list_of_bounds
      range_count = bounds.size // 2
      @ledger.charge_array(1, sizeof(Program::State), "a class run block", 0)
      @ledger.charge_array(range_count, sizeof(Program::Transition), "a class run table", 0) if range_count > 1
      list_of_states = OffHeapList(Program::State).new(1)
      table = OffHeapList(Program::Transition).new(range_count > 1 ? range_count : 0)
      if range_count == 1
        list_of_states << Program::State.new(Program::StateKind::ByteRange, bounds[0].to_u8, bounds[1].to_u8,
          ClassMemo::EXIT, NONE, 0)
      else
        range_count.times do |index|
          table << Program::Transition.new(bounds[index * 2].to_u8, bounds[index * 2 + 1].to_u8, Program::SHARED_EXIT)
        end
        list_of_states << Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, range_count, 0)
      end
      @ledger.own(ClassMemo::Block.new(list_of_states, table, 0))
      {list_of_states, table, 0}
    end

    # Emits *copies* copies of class *set* as a `Program::ClassRun`, the
    # first copy's exit leading to *next_state*, and returns the entry of
    # the last copy (the one a match reads first); nil when the class has
    # no run block (`run_block`), its table cannot be shared, or the copies
    # stand for fewer than `RUN_MIN_STATES` states. The run is checked,
    # charged and numbered as its copies emitted one by one would be
    # (`compile_recorded_class`, `instantiate_shared`), and it builds the
    # program they would (an ASCII class's ranges then sit in a table of
    # the program's own rather than in its transition list); only its
    # states are not written.
    #
    # With *optional*, the copies are the optional copies of `x{n,m}`,
    # each behind a split to *next_state* (see `Program::ClassRun`), and
    # the run returns its last split.
    private def class_run(set : CodePointSet, copies : Int32, next_state : Int32, *, optional : Bool = false,
                          lazy : Bool = false) : Int32?
      return nil if copies < 2
      block_states, table, entry = run_block(set) || return nil
      stride = block_states.size + (optional ? 1 : 0)
      return nil if copies.to_i64 * stride < RUN_MIN_STATES
      table_id = 0_u8
      unless table.empty?
        table_id = shared_table_id(table, ClassMemo.memoized?(set) ? memo_block(set) : nil) || return nil
      end
      added = copies.to_i64 * stride
      check_state_room(added.to_i32, written: false)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(added + copies)
      @ledger.charge_appends(copies, sizeof(Program::ClassBlock), "a class block", 0) if block_states.size > 1
      @ledger.charge_append(sizeof(Program::ClassRun), "a class run", 0)
      entry_targets = memo_block(set).entry_targets if ClassMemo.memoized?(set)
      run = Program::ClassRun.new(state_total, copies, block_states, table_id, entry, next_state, entry_targets,
        optional, lazy)
      @list_of_runs = [] of Program::ClassRun if @list_of_runs.same?(Program::NO_RUNS)
      @list_of_runs << run
      @run_states += run.size
      run.last_entry
    end

    private def compile_item(node : Hir::Node, next_state : Int32) : Int32
      if node.is_a?(Hir::Literal)
        compile_literal(node.code_point, next_state)
      elsif node.is_a?(Hir::Class)
        compile_recorded_class(node.code_point_set, next_state)
      else
        raise SyntaxError.new("internal error: #{node.class} is not a single item", Core::Position.new(0_i64))
      end
    end

    # Closes the loop of `{n,}`. The body on the value stack (the *consumed*
    # copy) returns to *loop_split*, which starts another iteration or exits
    # to *exit*.
    #
    # When the body can match the empty string, each iteration starts in a
    # second, *fresh* copy of the body: the same states, except that its
    # epsilon edges stay inside the fresh copy and its byte edges lead into
    # the consumed copy, and reaching its end goes to *exit* instead of back
    # to the loop. An iteration therefore loops again only after it consumed
    # a byte, and one that matched the empty string ends the repetition, which
    # is how PCRE2 ends a group repetition after an empty iteration. Whether
    # the iteration consumed anything is part of the state number, so the
    # engines' one-visit-per-state rule stays exact.
    private def finish_loop(node : Hir::Repetition, loop_split : Int32, exit : Int32) : Nil
      consumed_start = @list_of_values.pop
      first = loop_split + 1
      last = state_total
      fresh_start = consumed_start
      if nullable_body?(consumed_start, first, last, loop_split)
        fresh_start = copy_fresh_body(consumed_start, first, last, loop_split, exit)
      end
      preferred, other = node.greedy? ? {fresh_start, exit} : {exit, fresh_start}
      put_state(loop_split, Program::State.new(Program::StateKind::Split, 0_u8, 0_u8, preferred, other, 0))
      child = node.child
      if node.minimum == 0
        push_value(loop_split)
      elsif child.is_a?(Hir::Class) && (run = class_run(child.code_point_set, node.minimum - 1, fresh_start))
        # `\w{25,}`: the copies before the loop are one run.
        push_value(run)
      else
        push_value(fresh_start)
        push_task(TaskKind::MandatoryStep, node, NONE, node.minimum - 1)
      end
    end

    # Returns true when an epsilon path (splits, slot saves, assertions) leads
    # from *start* to *loop_split* through the body states *first*...*last*.
    private def nullable_body?(start : Int32, first : Int32, last : Int32, loop_split : Int32) : Bool
      return true if start == loop_split
      # A body that starts by reading a byte (a class, a literal) has no
      # epsilon path at all, so its states need no walk.
      return false if first <= start < last && state_at(start).kind.in?(Program::StateKind::ByteRange, Program::StateKind::Sparse)
      size = last - first
      grow(GrowingList::Visited, size, sizeof(Bool))
      # The lists are structs: read and write them through the fields, never
      # through a local copy, which would not see them grow.
      @list_of_visited.clear
      @list_of_visited.fill_to(size, false)
      base = @list_of_values.size
      push_value(start)
      found = false
      while @list_of_values.size > base
        current = @list_of_values.pop
        if current == loop_split
          found = true
          break
        end
        next unless first <= current < last
        next if @list_of_visited[current - first]
        @list_of_visited[current - first] = true
        charge_work
        state = state_at(current)
        case state.kind
        when .split?
          push_value(state.alternate)
          push_value(state.next_state)
        when .save?, .look?
          push_value(state.next_state)
        end
      end
      @list_of_values.truncate(base)
      found
    end

    # Emits the fresh copy of the body *first*...*last* and returns the copy
    # of *start*.
    private def copy_fresh_body(start : Int32, first : Int32, last : Int32, loop_split : Int32, exit : Int32) : Int32
      offset = state_total - first
      (first...last).each do |index|
        state = state_at(index)
        case state.kind
        when .split?
          add_state(state.copy_with(next_state: fresh_target(state.next_state, first, last, offset, loop_split, exit),
            alternate: fresh_target(state.alternate, first, last, offset, loop_split, exit)))
        when .save?, .look?
          add_state(state.copy_with(next_state: fresh_target(state.next_state, first, last, offset, loop_split, exit)))
        else
          # Byte states keep their targets in the consumed copy; match and
          # fail states have none.
          add_state(state)
        end
      end
      fresh_target(start, first, last, offset, loop_split, exit)
    end

    private def fresh_target(target : Int32, first : Int32, last : Int32, offset : Int32, loop_split : Int32,
                             exit : Int32) : Int32
      return target + offset if first <= target < last
      return exit if target == loop_split
      target
    end

    private def compile_literal(code_point : Int32, next_state : Int32) : Int32
      bytes = StaticArray(UInt8, 4).new(0_u8)
      length = Core::UTF8.encode(code_point, bytes.to_slice)
      current = next_state
      (length - 1).downto(0) do |index|
        current = emit_byte_range(bytes[index], bytes[index], current)
      end
      current
    end

    # `\R`: `\r\n`, a lone `\r` not followed by `\n` (so a later failure
    # never splits `\r\n`, as in PCRE2's atomic `\R`), or one of the other
    # line breaks.
    private def compile_line_break(any_crlf : Bool, next_state : Int32) : Int32
      line_feed = emit_byte_range(0x0A_u8, 0x0A_u8, next_state)
      lone = emit_look(Program::LookKind::NotBeforeLineFeed, next_state)
      after_return = emit_split(line_feed, lone)
      carriage_return = emit_byte_range(0x0D_u8, 0x0D_u8, after_return)
      others = any_crlf ? @@line_feed_only : @@other_line_breaks
      emit_split(carriage_return, compile_class(others, next_state))
    end

    # The line breaks of `\R` other than `\r`.
    Mica::Regex.static_object(other_line_breaks, CodePointSet, Slice(Int32).literal(0x0A, 0x0C, 0x85, 0x85, 0x2028, 0x2029))
    # The line breaks of `\R` under `(*BSR_ANYCRLF)` other than `\r`.
    Mica::Regex.static_object(line_feed_only, CodePointSet, Slice(Int32).literal(0x0A, 0x0A))

    # Compiles *set* (see `compile_class`) and records its states as a
    # `Program::ClassBlock` when they are more than one.
    private def compile_recorded_class(set : CodePointSet, next_state : Int32) : Int32
      first_state = state_total
      entry = compile_class(set, next_state)
      end_state = state_total
      if end_state - first_state > 1
        @ledger.charge_append(sizeof(Program::ClassBlock), "a class block", 0)
        @list_of_class_blocks << Program::ClassBlock.new(first_state, end_state, entry, next_state)
      end
      entry
    end

    # Compiles *set* into a byte automaton. A small set becomes its byte
    # trie, its UTF-8 sequences sharing their leading byte ranges, one state
    # per trie node (a `ByteRange` for one edge, a `Sparse` for several),
    # every last byte going to *next_state*. A large set becomes a copy of
    # its memoized minimal automaton (`ClassMemo`).
    private def compile_class(set : CodePointSet, next_state : Int32) : Int32
      return emit(Program::StateKind::Fail) if set.empty?
      return instantiate(memo_block(set), next_state) if ClassMemo.memoized?(set)
      return compile_class_from_trie(set, next_state) unless set.same?(@repeated_small_set)
      if block = @repeated_small_block
        return instantiate(block, next_state)
      end
      first_state = state_total
      first_transition = @list_of_transitions.size
      entry = compile_class_from_trie(set, next_state)
      @repeated_small_block = capture_block(first_state, first_transition, entry, next_state)
      entry
    end

    # The states and transitions emitted from *first_state* and
    # *first_transition* on, as a block relative to them whose exit is
    # *next_state*, charged before it is copied.
    private def capture_block(first_state : Int32, first_transition : Int32, entry : Int32,
                              next_state : Int32) : ClassMemo::Block
      state_count = state_total - first_state
      transition_count = @list_of_transitions.size - first_transition
      @ledger.charge_array(state_count, sizeof(Program::State), "a repeated class", 0)
      @ledger.charge_array(transition_count, sizeof(Program::Transition), "a repeated class", 0)
      list_of_states = OffHeapList(Program::State).new(state_count) do |offset|
        state = state_at(first_state + offset)
        state.copy_with(next_state: relative_target(state.next_state, first_state, next_state),
          argument: state.kind.sparse? ? state.argument - first_transition : state.argument)
      end
      list_of_transitions = OffHeapList(Program::Transition).new(transition_count) do |offset|
        transition = @list_of_transitions[first_transition + offset]
        transition.copy_with(target: relative_target(transition.target, first_state, next_state))
      end
      block = ClassMemo::Block.new(list_of_states, list_of_transitions, entry - first_state)
      @ledger.own(block)
      block
    end

    private def relative_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == next_state ? ClassMemo::EXIT : target - first_state
    end

    # Emits a memoized class block after the current states, its exit
    # leading to *next_state*, and returns its entry state. The block is
    # checked against the limits and charged as a whole, as emitting its
    # states one by one would check and charge them.
    private def instantiate(block : ClassMemo::Block, next_state : Int32) : Int32
      if table = block.shared_table
        if table_id = shared_table_id(table, block)
          return instantiate_shared(block, table_id, next_state)
        end
      end
      first_state = state_total
      first_transition = @list_of_transitions.size
      block_states = block.list_of_states
      block_transitions = block.list_of_transitions
      check_state_room(block_states.size)
      @ledger.charge(sizeof(Program::Transition).to_i64 * AllocationLedger::GROWTH_FACTOR * block_transitions.size,
        "a class transition", 0)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(block_states.size)
      reserve_transitions(block_transitions.size)
      # Copied whole (a memory copy), then relocated in place: a large
      # class is hundreds of states and over a thousand transitions, so
      # appending them one by one dominated compiling a pattern like `\w+`.
      @list_of_transitions.concat(block_transitions)
      transitions = @list_of_transitions.to_unsafe + first_transition
      block_transitions.size.times do |index|
        transition = transitions[index]
        transitions[index] = transition.copy_with(target: absolute_target(transition.target, first_state, next_state))
      end
      physical_first = @list_of_states.size
      @list_of_states.concat(block_states)
      states = @list_of_states.to_unsafe + physical_first
      block_states.size.times do |index|
        state = states[index]
        states[index] = state.copy_with(next_state: absolute_target(state.next_state, first_state, next_state),
          argument: state.kind.sparse? ? state.argument + first_transition : state.argument)
      end
      block.entry + first_state
    end

    private MAX_SHARED_TABLES = 255

    # The number a `Sparse` state uses for *table* (its position in the
    # program's shared tables, plus one), adding it the first time; nil
    # once `MAX_SHARED_TABLES` are in use, when the block is copied whole.
    private def shared_table_id(table : OffHeapList(Program::Transition), block : ClassMemo::Block? = nil) : UInt8?
      if index = @list_of_shared_tables.index { |shared| shared.to_unsafe == table.to_unsafe }
        return (index + 1).to_u8
      end
      return nil if @list_of_shared_tables.size >= MAX_SHARED_TABLES
      @ledger.charge_append(sizeof(OffHeapList(Program::Transition)), "a shared class table", 0)
      if entry_targets = block.try(&.entry_targets)
        @ledger.charge_array(0, sizeof(Slice(Int32)), "the shared tables' entry targets", 0) unless @list_of_entry_targets
        list_of_entry_targets = @list_of_entry_targets ||= [] of Slice(Int32)
        @ledger.charge_appends(@list_of_shared_tables.size + 1 - list_of_entry_targets.size, sizeof(Slice(Int32)),
          "the shared tables' entry targets", 0)
        while list_of_entry_targets.size < @list_of_shared_tables.size
          list_of_entry_targets << Slice(Int32).empty
        end
        list_of_entry_targets << entry_targets
      end
      @list_of_shared_tables = [] of OffHeapList(Program::Transition) if @list_of_shared_tables.same?(Program::NO_SHARED_TABLES)
      @list_of_shared_tables << table
      @list_of_shared_tables.size.to_u8
    end

    # Emits a memoized class block's states after the current ones, its
    # exit leading to *next_state*, with its `Sparse` states reading their
    # transitions from shared table *table_id* (one memory copy of the
    # states, relocated in place; no transitions are copied), and returns
    # its entry state.
    private def instantiate_shared(block : ClassMemo::Block, table_id : UInt8, next_state : Int32) : Int32
      first_state = state_total
      block_states = block.list_of_states
      check_state_room(block_states.size)
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(block_states.size)
      physical_first = @list_of_states.size
      @list_of_states.concat(block_states)
      states = @list_of_states.to_unsafe + physical_first
      block_states.size.times do |index|
        state = states[index]
        states[index] = if state.kind.sparse?
                          state.copy_with(low: table_id, next_state: next_state)
                        else
                          state.copy_with(next_state: absolute_target(state.next_state, first_state, next_state))
                        end
      end
      block.entry + first_state
    end

    # Marks a repeated small class to be copied rather than rebuilt. A
    # large (memoized) class needs nothing: its copies read its shared
    # table and add no transitions.
    private def reserve_class_copies(node : Hir::Repetition, maximum : Int32?) : Nil
      child = node.child
      set = if child.is_a?(Hir::Class)
              child.code_point_set
            elsif child.is_a?(Hir::Alternation)
              merged_class(child)
            end
      return unless set
      return if ClassMemo.memoized?(set)
      copies = maximum || Math.max(node.minimum, 1)
      if copies > 1 && !set.same?(@repeated_small_set)
        @repeated_small_set = set
        @repeated_small_block = nil
      end
    end

    # The one class an alternation of classes and single characters stands
    # for, when a branch is a large class: `(?:\p{Lu}|\p{Ll})` matches
    # exactly one code point of either set whichever branch is taken, so it
    # compiles as their union,
    # one automaton instead of two joined by a split. Nil for any other
    # alternation, or when the union could pass `max_class_ranges`. The
    # union is computed once per alternation node, so the copies of a
    # repetition share it.
    private def merged_class(node : Hir::Alternation) : CodePointSet?
      return @last_merged_set if node.same?(@last_merged_node)
      branches = node.list_of_branches
      return nil if branches.size < 2
      return nil unless branches.all? { |branch| branch.is_a?(Hir::Class) || branch.is_a?(Hir::Literal) }
      return nil unless branches.any? { |branch| branch.is_a?(Hir::Class) && ClassMemo.memoized?(branch.code_point_set) }
      @ledger.charge_array(branches.size, sizeof(CodePointSet), "a class union", 0)
      list_of_sets = Array(CodePointSet).new(branches.size)
      branches.each do |branch|
        if branch.is_a?(Hir::Class)
          list_of_sets << branch.code_point_set
        elsif branch.is_a?(Hir::Literal)
          @ledger.charge_object(instance_sizeof(CodePointSet), "a class union", 0)
          @ledger.charge_array(2, sizeof(Int32), "a class union", 0)
          list_of_sets << CodePointSet.from_bounds([branch.code_point, branch.code_point])
        end
      end
      return nil unless list_of_sets.sum(0_i64, &.range_count) <= @limits.max_class_ranges
      merged = ClassLowering.union_of(list_of_sets, @limits, @ledger, @meter, 0)
      @last_merged_node = node
      @last_merged_set = merged
      merged
    end

    # The memoized block of *set*, asking the memo once per set object.
    private def memo_block(set : CodePointSet) : ClassMemo::Block
      block = @last_memo_block
      return block if block && set.same?(@last_memo_set)
      block = ClassMemo.block_for(set, @ledger, @meter)
      @last_memo_set = set
      @last_memo_block = block
      block
    end

    # Makes room for *added* more transitions in one step (at least
    # doubling), rather than through the many smaller steps appending
    # them one by one would take. The growth stays within what
    # `AllocationLedger#charge_append` charged for them.
    private def reserve_transitions(added : Int32) : Nil
      size = @list_of_transitions.size
      return if @list_of_transitions.capacity - size >= added
      @list_of_transitions.reserve(Math.max(size + added, size * 2))
    end

    private def absolute_target(target : Int32, first_state : Int32, next_state : Int32) : Int32
      return target if target == NONE
      target == ClassMemo::EXIT ? next_state : target + first_state
    end

    private def compile_class_from_trie(set : CodePointSet, next_state : Int32) : Int32
      return compile_ascii_class(set, next_state) if set.list_of_bounds[-1] < 0x80
      trie = @class_trie
      trie.build(set, @ledger, @meter)
      # A set of surrogates only (`\p{Cs}`) has no UTF-8 sequences: like an
      # empty class, it never matches.
      return emit(Program::StateKind::Fail) if trie.empty?
      @list_of_trie_states.clear
      grow(GrowingList::TrieStates, trie.node_count, sizeof(Int32))
      @list_of_trie_states.fill_to(trie.node_count, NONE)
      # Children are created after their parents, so emitting from the
      # last node back reaches every child before its parent.
      (trie.node_count - 1).downto(0) do |node_index|
        @list_of_trie_states[node_index] = emit_trie_node(node_index, next_state)
      end
      @list_of_trie_states[0]
    end

    # Compiles a non-empty set of ASCII code points straight to the state
    # its trie would give: every range is a one-byte sequence, so the trie
    # is a root whose edges all end the class. One range is a `ByteRange`,
    # several a `Sparse` state, in range order. Case-insensitive literals
    # (`S` is `[Ss]`) take this path once per character.
    private def compile_ascii_class(set : CodePointSet, next_state : Int32) : Int32
      bounds = set.list_of_bounds
      range_count = bounds.size // 2
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(range_count)
      return emit_byte_range(bounds[0].to_u8, bounds[1].to_u8, next_state) if range_count == 1
      first_transition = @list_of_transitions.size
      range_count.times do |index|
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << Program::Transition.new(bounds[index * 2].to_u8, bounds[index * 2 + 1].to_u8, next_state)
      end
      add_state(Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, range_count, first_transition))
    end

    private def emit_trie_node(node_index : Int32, next_state : Int32) : Int32
      list_of_edges = @class_trie.list_of_edges
      first_edge, last_edge = @class_trie.list_of_nodes[node_index]
      if first_edge == last_edge
        edge = list_of_edges[first_edge]
        return emit_byte_range(edge.low, edge.high, trie_target(edge, next_state))
      end
      first_transition = @list_of_transitions.size
      count = 0
      edge_index = first_edge
      while edge_index != NONE
        edge = list_of_edges[edge_index]
        @ledger.charge_append(sizeof(Program::Transition), "a class transition", 0)
        @list_of_transitions << Program::Transition.new(edge.low, edge.high, trie_target(edge, next_state))
        count += 1
        edge_index = edge.next_sibling
      end
      add_state(Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, count, first_transition))
    end

    private def trie_target(edge : ClassTrie::Edge, next_state : Int32) : Int32
      edge.child == ClassTrie::LEAF ? next_state : @list_of_trie_states[edge.child]
    end

    private def look_kind(node : Hir::Look) : Program::LookKind
      ascii = node.ascii_word?
      case node.assertion_kind
      in .start_of_text?                then Program::LookKind::StartOfText
      in .start_of_line?                then Program::LookKind::StartOfLine
      in .end_of_text?                  then Program::LookKind::EndOfText
      in .end_of_text_or_final_newline? then Program::LookKind::EndOfTextOrFinalNewline
      in .end_of_line?                  then Program::LookKind::EndOfLine
      in .search_start?                 then Program::LookKind::SearchStart
      in .word_boundary?
        ascii ? Program::LookKind::WordBoundaryAscii : Program::LookKind::WordBoundary
      in .not_word_boundary?
        ascii ? Program::LookKind::NotWordBoundaryAscii : Program::LookKind::NotWordBoundary
      in .word_start?
        ascii ? Program::LookKind::WordStartAscii : Program::LookKind::WordStart
      in .word_end?
        ascii ? Program::LookKind::WordEndAscii : Program::LookKind::WordEnd
      end
    end

    private def emit(kind : Program::StateKind) : Int32
      add_state(Program::State.new(kind, 0_u8, 0_u8, NONE, NONE, 0))
    end

    private def emit_byte_range(low : UInt8, high : UInt8, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::ByteRange, low, high, next_state, NONE, 0))
    end

    private def emit_split(preferred : Int32, other : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Split, 0_u8, 0_u8, preferred, other, 0))
    end

    private def emit_save(slot : Int32, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Save, 0_u8, 0_u8, next_state, NONE, slot))
    end

    private def emit_look(kind : Program::LookKind, next_state : Int32) : Int32
      add_state(Program::State.new(Program::StateKind::Look, 0_u8, 0_u8, next_state, NONE, kind.value))
    end

    # Appends *state*, checking `max_program_states` first. The states
    # array was allocated with the preflight's bound, so passing that bound
    # would be a compiler defect, and it is reported as one.
    private def add_state(state : Program::State) : Int32
      check_state_room(1)
      charge_work
      @list_of_states << state
      state_total - 1
    end

    # Gives `@list_of_states` room for the preflight's whole bound, charged
    # as a new list: a run counted ahead (`run_ahead?`) was emitted
    # as states (its class's table could not be shared).
    private def grow_to_bound : Nil
      bound = @estimate.clamp(1_i64, @limits.max_program_states).to_i32
      return if @physical_capacity >= bound
      @ledger.charge_array(bound, sizeof(Program::State), "the program states", 0)
      @physical_capacity = bound
    end

    # Gives `@list_of_states` room for *needed* states: twice its room, at
    # least *needed*, at most the charged bound.
    private def make_state_room(needed : Int32) : Nil
      room = Math.min(Math.max(@state_room * 2, needed), @physical_capacity)
      @list_of_states.reserve(room)
      @state_room = room
    end

    # Moves the states into a list of exactly their number and frees the
    # list they were emitted into, which was allocated at the preflight's
    # bound (every class counted at its largest, every literal as a byte
    # state): its spare room would otherwise stay allocated, and count
    # toward the collector's next collection, for as long as the program
    # lives. The compiler alone holds the list, and never shifts it.
    private def trim_states : Nil
      spare = @state_room - @list_of_states.size
      return if spare < TRIM_MIN_SPARE_STATES || spare < @list_of_states.size // 4
      @list_of_states.trim
      @state_room = @list_of_states.size
    end

    # The same for the transitions, whose list a large program allocates
    # at the bound `transitions_bound` finds (see `initialize`).
    private def trim_transitions : Nil
      return if @list_of_transitions.size * 2 >= @list_of_transitions.capacity
      @list_of_transitions.trim
    end

    # Spare room in the state list below this many states (1 KiB), or below
    # a quarter of the states, is kept: copying the list costs more than
    # the room.
    private TRIM_MIN_SPARE_STATES = 64

    # Frees the scratch lists the program does not keep
    # (its stacks, its class trie, the trie's states and the visited
    # marks), once the program is built. The compiler is not used again;
    # it alone holds these lists, and never shifts them.
    protected def release : Nil
      @list_of_tasks.free
      @list_of_values.free
      @list_of_trie_states.free
      @list_of_visited.free
      @class_trie.release
    end

    # Frees the lists a program would have taken over, when the compile
    # stopped before it built one.
    protected def free_program_lists : Nil
      @list_of_states.free
      @list_of_transitions.free
      @list_of_class_blocks.free
    end

    # True when *node*, compiled once, will make a run (`class_run`) of its
    # copies: its mandatory copies (`x{n}`, `x{n,m}`), or all but the one
    # before the loop (`x{n,}`, see `finish_loop`). It then adds the states
    # the size preflight counted for them (`Preflight.set_states` per copy)
    # to `@run_states_ahead`. Called from `transitions_bound` for the
    # repetitions it counts once, so it never counts more than the runs the
    # compiler makes, unless a run's table cannot be shared.
    private def run_ahead?(node : Hir::Repetition) : Bool
      child = node.child
      return false unless child.is_a?(Hir::Class)
      copies = node.maximum ? node.minimum : node.minimum - 1
      return false if copies < 2
      set = child.code_point_set
      block_states, _, _ = run_block(set) || return false
      return false if copies.to_i64 * block_states.size < RUN_MIN_STATES
      @run_states_ahead += copies.to_i64 * Preflight.set_states(set, @ledger, @meter)
      true
    end

    # True when the optional copies of *node* (`x{n,m}`, a class) will be
    # an optional run (`class_run`), whose states, the size preflight's
    # count for each copy and its split, it then adds to
    # `@run_states_ahead`, as `run_ahead?` does for the mandatory copies.
    private def optional_run_ahead?(node : Hir::Repetition) : Bool
      child = node.child
      maximum = node.maximum
      return false unless maximum && child.is_a?(Hir::Class)
      copies = maximum - node.minimum
      return false if copies < 2
      set = child.code_point_set
      block_states, _, _ = run_block(set) || return false
      return false if copies.to_i64 * (block_states.size + 1) < RUN_MIN_STATES
      @run_states_ahead += copies.to_i64 * (Preflight.set_states(set, @ledger, @meter) + 1)
      true
    end

    # The number of states emitted so far, runs included (the next state's
    # number).
    @[AlwaysInline]
    private def state_total : Int32
      @list_of_states.size + @run_states
    end

    # Emitted state *index*, in a run or not.
    private def state_at(index : Int32) : Program::State
      @list_of_states[physical_index(index) || return run_state_at(index)]
    end

    # Replaces emitted state *index*, which is not in a run.
    private def put_state(index : Int32, state : Program::State) : Nil
      physical = physical_index(index) || raise SyntaxError.new("internal error: state #{index} is in a class run",
        Core::Position.new(0_i64))
      @list_of_states[physical] = state
    end

    # Where state *index* sits in `@list_of_states`, or nil when it is in a
    # run.
    private def physical_index(index : Int32) : Int32?
      offset = 0
      @list_of_runs.each do |run|
        break if index < run.first_state
        return nil if index < run.end_state
        offset += run.size
      end
      index - offset
    end

    private def run_state_at(index : Int32) : Program::State
      @list_of_runs.each { |run| return run.state_at(index) if run.first_state <= index < run.end_state }
      raise SyntaxError.new("internal error: state #{index} is in no class run", Core::Position.new(0_i64))
    end

    # Raises unless *added* more states fit under `max_program_states` and
    # within the preflight bound.
    private def check_state_room(added : Int32, written : Bool = true) : Nil
      count = state_total.to_i64 + added
      grow_to_bound if written && @list_of_states.size.to_i64 + added > @physical_capacity
      make_state_room(@list_of_states.size + added) if written && @list_of_states.size + added > @state_room
      limit = @limits.max_program_states
      if count > limit
        raise CompileLimitError.new("max_program_states", limit, "A program of #{count} states", Core::Position.new(0_i64))
      end
      if count > @estimate
        raise SyntaxError.new("internal error: the compiler emitted more states than the preflight bound #{@estimate}",
          Core::Position.new(0_i64))
      end
    end

    private def push_task(kind : TaskKind, node : Hir::Node, next_state : Int32, count : Int32 = 0) : Nil
      grow(GrowingList::Tasks, @list_of_tasks.size + 1, sizeof(Task))
      @list_of_tasks << Task.new(kind, node.object_id, next_state, count)
    end

    private def push_value(value : Int32) : Nil
      grow(GrowingList::Values, @list_of_values.size + 1, sizeof(Int32))
      @list_of_values << value
    end

    # Charges a reused list's growth only when it passes its largest size
    # so far, so pushing and popping costs the ledger nothing.
    private def grow(list : GrowingList, size : Int32, element_bytes : Int32) : Nil
      high_water = @high_water[list.value]
      return if size <= high_water
      @ledger.charge(element_bytes.to_i64 * AllocationLedger::GROWTH_FACTOR * (size - high_water), "a compiler list", 0)
      @high_water[list.value] = size
    end

    private def charge_work : Nil
      @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(1)
    end

    # Refuses a program whose Pike VM workspace passes `max_pike_bytes`,
    # and returns its charge (`PikeVM.workspace_charge`). The workspace is
    # the one a search holds: the capture layout (16·m·c + 32·m + 8·c
    # bytes) when the pattern has groups, the span layout (32·m) when it
    # has none. A search on a program with groups runs both phases in its
    # capture workspace, so no second workspace is ever alive beside it.
    private def check_pike_bytes : Int64
      states = state_total.to_i64
      slots = (@pattern.capture_count.to_i64 + 1) * 2
      captures = @pattern.capture_count > 0
      bytes = PikeVM.workspace_charge(states, slots, captures)
      limit = @limits.max_pike_bytes
      return bytes if bytes <= limit
      layout = captures ? "#{slots} slots" : "no captures"
      raise CompileLimitError.new("max_pike_bytes", limit,
        "A Pike VM workspace of #{bytes} bytes (#{states} states, #{layout})", Core::Position.new(0_i64))
    end
  end
end
