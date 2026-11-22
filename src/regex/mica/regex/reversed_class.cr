module Regex::Mica::Regex
  # :nodoc:
  # A class's UTF-8 automaton read backward, for `ReverseNFA`. Forward, a
  # class is a trie of UTF-8 sequences sharing their leading bytes; turned
  # around, a continuation byte read backward fits the last byte of every
  # sequence that allows it, so a reverse DFA state for `\w` or `\p{L}`
  # would hold hundreds of NFA states. A `ReversedClass` holds the class's
  # reversed sequences made deterministic instead (a trie of the reversed
  # sequences, then the subset construction over it, then minimized), as
  # Rust regex compiles its reverse NFA: each node's edges have disjoint
  # byte ranges, so reading a byte backward reaches one node, and the
  # class's entry where a sequence may begin.
  #
  # Node 0 is the class's exit; `ENTRY` stands for its entry. Built from a
  # block's shape (its states with targets relative to the block), so every
  # copy of a class (`\w{12}` has twelve) and every program that uses it
  # shares one, memoized process-wide (at most `MAX_ENTRIES`).
  class ReversedClass
    ENTRY = -1
    # The most memo entries kept; later classes are built per program.
    MAX_ENTRIES = 256

    # The edges as {node, low, high, target}.
    getter list_of_edges : Array({Int32, UInt8, UInt8, Int32})
    getter node_count : Int32

    def initialize(@list_of_edges : Array({Int32, UInt8, UInt8, Int32}), @node_count : Int32)
    end

    # Static objects, so a program that never reverses a class pays nothing
    # for them.
    Mica::Regex.static_object(mutex, Mutex)
    Mica::Regex.static_object(memo, Hash(Array(Int32), ReversedClass?))

    # Returns the reversed class of *block*, or nil when the block is not a
    # plain class (only byte states, every edge inside the block or to its
    # exit) or the reversed class would pass *budget* nodes.
    def self.for(program : Program, block : Program::ClassBlock, budget : Int32) : ReversedClass?
      shape = shape_of(program, block)
      return nil unless shape
      @@mutex.synchronize do
        return @@memo[shape] if @@memo.has_key?(shape)
      end
      reversed_class = build(shape, block.entry - block.first_state, budget)
      @@mutex.synchronize { @@memo[shape] = reversed_class if @@memo.size < MAX_ENTRIES }
      reversed_class
    end

    # The words that describe *block*: per state its kind, then for each
    # edge its low byte, high byte and target (relative to the block's
    # first state, `EXIT` for the exit). Nil when the block is not a plain
    # class.
    private def self.shape_of(program : Program, block : Program::ClassBlock) : Array(Int32)?
      shape = Array(Int32).new((block.end_state - block.first_state) * 4)
      (block.first_state...block.end_state).each do |index|
        state = program.state_at(index)
        if state.kind.byte_range?
          shape << 1
          return nil unless add_edge(shape, state.low, state.high, state.next_state, block)
        elsif state.kind.sparse?
          shape << 2 << state.alternate
          state.alternate.times do |offset|
            transition = program.transition_at(index, state, offset)
            return nil unless add_edge(shape, transition.low, transition.high, transition.target, block)
          end
        else
          return nil
        end
      end
      shape
    end

    private EXIT = -1

    private def self.add_edge(shape : Array(Int32), low : UInt8, high : UInt8, target : Int32,
                              block : Program::ClassBlock) : Bool
      relative = if target == block.exit
                   EXIT
                 elsif block.first_state <= target < block.end_state
                   target - block.first_state
                 else
                   return false
                 end
      shape << low.to_i32 << high.to_i32 << relative
      true
    end

    # Builds the reversed class of the block with *shape*, entered at state
    # *entry* (relative), or nil past *budget* nodes.
    private def self.build(shape : Array(Int32), entry : Int32, budget : Int32) : ReversedClass?
      offsets = state_offsets(shape)
      trie = Trie.new
      ranges = StaticArray(Int32, 8).new(0)
      return nil unless walk(shape, offsets, entry, 0, ranges, trie, budget)
      determinize(trie, budget)
    end

    # Where each state's words start in *shape*.
    private def self.state_offsets(shape : Array(Int32)) : Array(Int32)
      offsets = [] of Int32
      at = 0
      while at < shape.size
        offsets << at
        at += shape[at] == 1 ? 4 : 2 + 3 * shape[at + 1]
      end
      offsets
    end

    # Walks every path from *state* (at *depth*, after the ranges in
    # *ranges*) to the exit and adds each, reversed, to *trie*. False when
    # a path is longer than 4 bytes or the trie passes *budget* nodes.
    private def self.walk(shape : Array(Int32), offsets : Array(Int32), state : Int32, depth : Int32,
                          ranges : StaticArray(Int32, 8), trie : Trie, budget : Int32) : Bool
      return false if depth >= 4
      at = offsets[state]
      edge_count = shape[at] == 1 ? 1 : shape[at + 1]
      first_edge = shape[at] == 1 ? at + 1 : at + 2
      edge_count.times do |edge|
        word = first_edge + 3 * edge
        ranges[2 * depth] = shape[word]
        ranges[2 * depth + 1] = shape[word + 1]
        target = shape[word + 2]
        if target == EXIT
          trie.add_reversed(ranges, depth + 1)
          return false if trie.size > budget
        else
          return false unless walk(shape, offsets, target, depth + 1, ranges, trie, budget)
        end
      end
      true
    end

    # The trie of reversed sequences: node 0 is the root, and each node's
    # edges are {low, high, child}, child `ENTRY` where a sequence ends.
    class Trie
      getter list_of_children = [[] of {Int32, Int32, Int32}]
      # The child of a node on an exact range (a terminal edge is not
      # indexed): {node, low, high} => child.
      @children_by_range = {} of {Int32, Int32, Int32} => Int32

      def size : Int32
        @list_of_children.size
      end

      # Adds the sequence of *length* ranges in *ranges* (low, high
      # pairs), last range first.
      def add_reversed(ranges : StaticArray(Int32, 8), length : Int32) : Nil
        node = 0
        (length - 1).downto(0) do |position|
          low = ranges[2 * position]
          high = ranges[2 * position + 1]
          if position == 0
            children = @list_of_children[node]
            children << {low, high, ENTRY} unless children.includes?({low, high, ENTRY})
          elsif child = @children_by_range[{node, low, high}]?
            node = child
          else
            child = @list_of_children.size
            @list_of_children << [] of {Int32, Int32, Int32}
            @list_of_children[node] << {low, high, child}
            @children_by_range[{node, low, high}] = child
            node = child
          end
        end
      end
    end

    # The subset construction over *trie*: each subset of trie nodes
    # becomes one node whose edges split the bytes into disjoint ranges.
    private def self.determinize(trie : Trie, budget : Int32) : ReversedClass?
      list_of_children = trie.list_of_children
      list_of_edges = [] of {Int32, UInt8, UInt8, Int32}
      node_ids = {[0] => 0}
      list_of_pending = [[0]]
      scratch = [] of Int32
      while subset = list_of_pending.pop?
        node = node_ids[subset]
        each_interval(subset, list_of_children, scratch) do |low, high, list_of_targets|
          if list_of_targets.first == ENTRY
            list_of_edges << {node, low.to_u8, high.to_u8, ENTRY}
            list_of_targets = list_of_targets[1..]
          end
          next if list_of_targets.empty?
          target = node_ids[list_of_targets]?
          unless target
            return nil if node_ids.size >= budget
            target = node_ids.size
            node_ids[list_of_targets] = target
            list_of_pending << list_of_targets
          end
          list_of_edges << {node, low.to_u8, high.to_u8, target}
        end
      end
      minimize(list_of_edges, node_ids.size)
    end

    # Merges the nodes of the (acyclic) reversed class that have the same
    # edges to the same nodes, children before parents, as a minimal
    # acyclic automaton does: the subset construction leaves many nodes
    # that differ only in how they were reached.
    private def self.minimize(list_of_edges : Array({Int32, UInt8, UInt8, Int32}), node_count : Int32) : ReversedClass
      list_of_out = Array(Array({UInt8, UInt8, Int32})).new(node_count) { [] of {UInt8, UInt8, Int32} }
      list_of_edges.each { |node, low, high, target| list_of_out[node] << {low, high, target} }
      canonical = Array(Int32).new(node_count, -1)
      signatures = {} of Array({UInt8, UInt8, Int32}) => Int32
      list_of_merged = [] of Array({UInt8, UInt8, Int32})
      # Depth first from the root; a node is placed once its children are.
      list_of_pending = [{0, false}]
      while pending = list_of_pending.pop?
        node, children_done = pending
        next if canonical[node] >= 0
        unless children_done
          list_of_pending << {node, true}
          list_of_out[node].each do |_, _, target|
            list_of_pending << {target, false} if target != ENTRY && canonical[target] < 0
          end
          next
        end
        signature = list_of_out[node].map do |low, high, target|
          {low, high, target == ENTRY ? ENTRY : canonical[target]}
        end.sort!
        # The root keeps its own node (0), as the class's exit.
        if node != 0 && (existing = signatures[signature]?)
          canonical[node] = existing
          next
        end
        canonical[node] = list_of_merged.size
        list_of_merged << signature
        signatures[signature] = canonical[node] if node != 0
      end
      # Number the root 0 and the other merged nodes from 1.
      root = canonical[0]
      renumber = ->(merged : Int32) { merged == root ? 0 : (merged < root ? merged + 1 : merged) }
      list_of_minimal = [] of {Int32, UInt8, UInt8, Int32}
      list_of_merged.each_with_index do |signature, merged|
        signature.each do |low, high, target|
          list_of_minimal << {renumber.call(merged), low, high, target == ENTRY ? ENTRY : renumber.call(target)}
        end
      end
      new(list_of_minimal, list_of_merged.size)
    end

    # Yields each maximal byte interval over which the edges out of
    # *subset* reach the same targets, with the targets sorted (`ENTRY`
    # first when present): the edges' start and end points, sorted, cut
    # the bytes into intervals, and each interval's targets are the edges
    # that cover it. *scratch* holds the points between calls.
    private def self.each_interval(subset : Array(Int32), list_of_children : Array(Array({Int32, Int32, Int32})),
                                   scratch : Array(Int32), & : Int32, Int32, Array(Int32) ->) : Nil
      scratch.clear
      subset.each do |node|
        list_of_children[node].each do |low, high, _|
          scratch << low << high + 1
        end
      end
      scratch.sort!.uniq!
      current = [] of Int32
      run_low = 0
      run_high = -1
      (0...scratch.size - 1).each do |index|
        low = scratch[index]
        list_of_targets = [] of Int32
        subset.each do |node|
          list_of_children[node].each do |edge_low, edge_high, child|
            list_of_targets << child if edge_low <= low <= edge_high
          end
        end
        list_of_targets.sort!.uniq!
        if list_of_targets == current && run_high + 1 == low
          run_high = scratch[index + 1] - 1
          next
        end
        yield run_low, run_high, current unless current.empty?
        current = list_of_targets
        run_low = low
        run_high = scratch[index + 1] - 1
      end
      yield run_low, run_high, current unless current.empty?
    end
  end
end
