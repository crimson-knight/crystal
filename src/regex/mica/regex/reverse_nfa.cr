module Regex::Mica::Regex
  # A program's NFA with every edge turned around, for the reverse lazy DFA
  # (roadmap 6.2.1): it starts at the program's match state, reads the
  # haystack backward from a match end, and accepts on reaching the
  # program's start state. Priority plays no part in reverse (the reverse
  # search wants every start, and keeps the leftmost), so it is a plain NFA.
  #
  # Each forward state keeps its number. Edges are stored compressed: for
  # node v, the epsilon edges into v's forward predecessors (with the
  # assertion that guarded the forward edge, or -1) and the byte edges, a
  # forward byte transition u -> v becoming v -> u on the same bytes.
  #
  # **Classes read backward.** A class compiles to a trie of UTF-8
  # sequences that share their leading bytes. Turned around, it would
  # branch at its last byte: a continuation byte read backward fits the
  # last byte of every sequence that allows it, so a reverse DFA state for
  # `\w` or `\p{L}` would hold hundreds of NFA states. Each recorded class
  # (`Program::ClassBlock`) is therefore rebuilt as a trie of its reversed
  # sequences (`ReversedClass`), as Rust regex compiles its
  # reverse NFA: its root is the class's exit, its leaves lead to the
  # class's entry, and the class's own states get no edges. A class whose
  # reversed trie would pass `REVERSED_NODES_PER_STATE` nodes per state of
  # the class keeps its turned-around edges, so building stays O(m).
  class ReverseNFA
    getter start_node : Int32
    getter accept_node : Int32
    @epsilon_offsets : Array(Int32)
    @epsilon_targets : Array(Int32)
    @epsilon_looks : Array(Int32)
    @byte_offsets : Array(Int32)
    @list_of_byte_edges : Array(Program::Transition)

    # The most reversed-trie nodes a class may take per state it compiled
    # to.
    REVERSED_NODES_PER_STATE = 8

    # With *reverse_classes*, each recorded class is read backward through
    # its `ReversedClass` (see the class description).
    def initialize(program : Program, reverse_classes : Bool = false)
      @accept_node = program.start_state
      @start_node = ReverseNFA.match_state(program)
      # The reversed classes' edges as {node, transition}; the forward
      # program's edges are counted, then placed, in two passes.
      list_of_class_edges = [] of {Int32, Program::Transition}
      reversed = Array(Bool).new(program.state_count, false)
      node_count = program.state_count
      if reverse_classes
        closed = ReverseNFA.closed_blocks(program)
        program.class_blocks.each_with_index do |block, index|
          next unless closed[index]
          node_count = ReverseNFA.reverse_class(program, block, node_count, list_of_class_edges, reversed)
        end
      end
      epsilon_counts = Array(Int32).new(node_count + 1, 0)
      byte_counts = Array(Int32).new(node_count + 1, 0)
      ReverseNFA.each_forward_edge(program) do |source, target, look, _, _|
        if look != BYTE_EDGE
          epsilon_counts[target + 1] += 1
        elsif !reversed[source]
          byte_counts[target + 1] += 1
        end
      end
      list_of_class_edges.each { |node, _| byte_counts[node + 1] += 1 }
      node_count.times do |index|
        epsilon_counts[index + 1] += epsilon_counts[index]
        byte_counts[index + 1] += byte_counts[index]
      end
      @epsilon_offsets = epsilon_counts.dup
      @byte_offsets = byte_counts.dup
      @epsilon_targets = Array(Int32).new(epsilon_counts[node_count], 0)
      @epsilon_looks = Array(Int32).new(epsilon_counts[node_count], 0)
      @list_of_byte_edges = Array(Program::Transition).new(byte_counts[node_count], Program::Transition.new(0_u8, 0_u8, 0))
      ReverseNFA.each_forward_edge(program) do |source, target, look, low, high|
        if look != BYTE_EDGE
          @epsilon_targets[epsilon_counts[target]] = source
          @epsilon_looks[epsilon_counts[target]] = look
          epsilon_counts[target] += 1
        elsif !reversed[source]
          @list_of_byte_edges[byte_counts[target]] = Program::Transition.new(low, high, source)
          byte_counts[target] += 1
        end
      end
      list_of_class_edges.each do |node, transition|
        @list_of_byte_edges[byte_counts[node]] = transition
        byte_counts[node] += 1
      end
    end

    # Adds the reversed class of *block* (`ReversedClass`) to
    # *list_of_byte_edges*, numbering its new nodes from *node_count*,
    # marks the class's states in *reversed* (their forward byte edges are
    # then left out), and returns the new node count. Leaves everything as
    # it was when the block is not a plain class or its reversed form
    # would be too large.
    protected def self.reverse_class(program : Program, block : Program::ClassBlock, node_count : Int32,
                                     list_of_byte_edges : Array({Int32, Program::Transition}),
                                     reversed : Array(Bool)) : Int32
      budget = REVERSED_NODES_PER_STATE * (block.end_state - block.first_state)
      reversed_class = ReversedClass.for(program, block, budget)
      return node_count unless reversed_class
      (block.first_state...block.end_state).each { |state| reversed[state] = true }
      reversed_class.list_of_edges.each do |node, low, high, target|
        source = node == 0 ? block.exit : node_count + node - 1
        destination = target == ReversedClass::ENTRY ? block.entry : node_count + target - 1
        list_of_byte_edges << {source, Program::Transition.new(low, high, destination)}
      end
      node_count + reversed_class.node_count - 1
    end

    # The node count a `ReverseNFA` of *program* with *reverse_classes*
    # would have, found without building it (the reversed classes come
    # from the process-wide memo after the first program that uses them);
    # counting stops once it passes *limit*.
    def self.widened_node_count(program : Program, limit : Int64) : Int64
      closed = closed_blocks(program)
      count = program.state_count.to_i64
      program.class_blocks.each_with_index do |block, index|
        next unless closed[index]
        budget = REVERSED_NODES_PER_STATE * (block.end_state - block.first_state)
        if reversed_class = ReversedClass.for(program, block, budget)
          count += reversed_class.node_count - 1
          break if count > limit
        end
      end
      count
    end

    # For each recorded class, whether nothing outside it leads into it
    # but to its entry (a repetition may copy a class's states rather than
    # compile it again; a copy that led into the original's inner states
    # would lose its paths once those states have no reverse edges).
    protected def self.closed_blocks(program : Program) : Array(Bool)
      blocks = program.class_blocks
      closed = Array(Bool).new(blocks.size, true)
      block_of = Array(Int32).new(program.state_count, -1)
      blocks.each_with_index do |block, index|
        (block.first_state...block.end_state).each { |state| block_of[state] = index }
      end
      each_forward_edge(program) do |source, target, _, _, _|
        index = block_of[target]
        next if index < 0 || block_of[source] == index || target == blocks[index].entry
        closed[index] = false
      end
      closed
    end

    # The number of nodes.
    def node_count : Int32
      @epsilon_offsets.size - 1
    end

    # Yields each epsilon edge out of *node*: the target and its assertion
    # (a `Program::LookKind` value, or -1).
    @[AlwaysInline]
    def each_epsilon(node : Int32, & : Int32, Int32 ->) : Nil
      (@epsilon_offsets.unsafe_fetch(node)...@epsilon_offsets.unsafe_fetch(node + 1)).each do |index|
        yield @epsilon_targets.unsafe_fetch(index), @epsilon_looks.unsafe_fetch(index)
      end
    end

    # True when *node* has byte edges.
    def consumes?(node : Int32) : Bool
      @byte_offsets.unsafe_fetch(node) < @byte_offsets.unsafe_fetch(node + 1)
    end

    # Yields the target of each byte edge out of *node* that holds *byte*.
    @[AlwaysInline]
    def each_byte_target(node : Int32, byte : UInt8, & : Int32 ->) : Nil
      (@byte_offsets.unsafe_fetch(node)...@byte_offsets.unsafe_fetch(node + 1)).each do |index|
        edge = @list_of_byte_edges.unsafe_fetch(index)
        yield edge.target if edge.low <= byte <= edge.high
      end
    end

    private BYTE_EDGE = -2

    # The program's match state.
    protected def self.match_state(program : Program) : Int32
      program.each_state { |state, index| return index if state.kind.match? }
      raise Mica::Error.new("internal error: the program has no match state")
    end

    protected def self.each_forward_edge(program : Program, & : Int32, Int32, Int32, UInt8, UInt8 ->) : Nil
      program.each_state do |state, source|
        case state.kind
        when .byte_range?
          yield source, state.next_state, BYTE_EDGE, state.low, state.high
        when .sparse?
          state.alternate.times do |offset|
            transition = program.transition_at(source, state, offset)
            yield source, transition.target, BYTE_EDGE, transition.low, transition.high
          end
        when .split?
          yield source, state.next_state, -1, 0_u8, 0_u8
          yield source, state.alternate, -1, 0_u8, 0_u8
        when .save?
          yield source, state.next_state, -1, 0_u8, 0_u8
        when .look?
          yield source, state.next_state, state.argument, 0_u8, 0_u8
        end
      end
    end
  end
end
