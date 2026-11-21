module Regex::Mica::Regex
  # :nodoc:
  # The byte trie a class is compiled from: the class's UTF-8 sequences
  # (`Utf8Sequences`) share their leading byte ranges, one node per shared
  # prefix, and every sequence's last byte is an edge to `LEAF`.
  #
  # A trie is reused for many classes. Its lists are charged to the ledger
  # only when they pass their largest size so far, so rebuilding costs the
  # ledger nothing; every sequence is charged to the work meter.
  class ClassTrie
    # The child of an edge that ends a sequence.
    LEAF = -1
    # No edge.
    NONE = -1

    # One edge: a byte range and the node it leads to (`LEAF` for the end
    # of a sequence), with the next edge of the same node.
    record Edge, low : UInt8, high : UInt8, child : Int32, next_sibling : Int32

    # Each node's first and last edge (`NONE` for a node with no edges).
    # Children are created after their parents.
    # Both lists sit outside the collector's heap (`OffHeapList`); the
    # owner frees them with `release`.
    getter list_of_nodes = OffHeapList({Int32, Int32}).new
    # Every edge, linked per node through `next_sibling`.
    getter list_of_edges = OffHeapList(Edge).new
    @node_high_water = 0
    @edge_high_water = 0

    # Charges the trie object and its two empty lists to *ledger*.
    def self.charge_new(ledger : AllocationLedger) : Nil
      ledger.charge_object(instance_sizeof(ClassTrie), "the class trie", 0)
      ledger.charge_array(0, sizeof({Int32, Int32}), "the class trie", 0)
      ledger.charge_array(0, sizeof(Edge), "the class trie", 0)
    end

    # Rebuilds the trie for *set*.
    def build(set : CodePointSet, ledger : AllocationLedger, meter : Core::WorkMeter) : Nil
      @list_of_nodes.clear
      @list_of_edges.clear
      add_node(ledger)
      lows = StaticArray(UInt8, 4).new(0_u8)
      highs = StaticArray(UInt8, 4).new(0_u8)
      set.each_range do |first, last|
        Utf8Sequences.each(first, last) do |length, low, high|
          meter.enforce { Core::Position.new(0_i64) } if meter.charge(1)
          Core::UTF8.encode(low, lows.to_slice)
          Core::UTF8.encode(high, highs.to_slice)
          node = 0
          length.times do |depth|
            node = add_edge(node, lows[depth], highs[depth], depth == length - 1, ledger)
          end
        end
      end
    end

    # Frees the trie's lists. Its owner calls this once, when it is done
    # with the trie, which nothing else holds.
    def release : Nil
      @list_of_nodes.free
      @list_of_edges.free
    end

    # Returns true when the set had no UTF-8 sequences (surrogates only,
    # `\p{Cs}`): like an empty class, it never matches.
    def empty? : Bool
      @list_of_nodes[0][0] == NONE
    end

    def node_count : Int32
      @list_of_nodes.size
    end

    # Adds a node with no edges and returns its index.
    private def add_node(ledger : AllocationLedger) : Int32
      size = @list_of_nodes.size + 1
      if size > @node_high_water
        ledger.charge_append(sizeof({Int32, Int32}), "the class trie", 0)
        @node_high_water = size
      end
      @list_of_nodes << {NONE, NONE}
      @list_of_nodes.size - 1
    end

    # Follows (or adds) the edge *low*..*high* from *node* and returns the
    # node it leads to (`LEAF` for a sequence's last byte). Sequences
    # arrive in code point order, so an equal edge can only be the last one
    # added to *node*.
    private def add_edge(node : Int32, low : UInt8, high : UInt8, final : Bool, ledger : AllocationLedger) : Int32
      first_edge, last_edge = @list_of_nodes[node]
      if last_edge != NONE
        edge = @list_of_edges[last_edge]
        return edge.child if edge.low == low && edge.high == high && !final && edge.child != LEAF
      end
      child = final ? LEAF : add_node(ledger)
      size = @list_of_edges.size + 1
      if size > @edge_high_water
        ledger.charge_append(sizeof(Edge), "the class trie", 0)
        @edge_high_water = size
      end
      @list_of_edges << Edge.new(low, high, child, NONE)
      edge_index = @list_of_edges.size - 1
      if last_edge == NONE
        @list_of_nodes[node] = {edge_index, edge_index}
      else
        previous = @list_of_edges[last_edge]
        @list_of_edges[last_edge] = previous.copy_with(next_sibling: edge_index)
        @list_of_nodes[node] = {first_edge, edge_index}
      end
      child
    end
  end
end
