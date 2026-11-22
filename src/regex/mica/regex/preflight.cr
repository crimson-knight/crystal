module Regex::Mica::Regex
  # The size preflight: an upper bound on the program states the NFA
  # compiler (R2) will emit, computed from the syntax tree with saturating
  # arithmetic before any `Hir` exists, so `((a{1000}){1000}){1000}` is
  # refused without being expanded.
  #
  # The state model, which the compiler's emission must stay within:
  #
  # | Node | States |
  # |---|---|
  # | literal (exact) | its UTF-8 length |
  # | class, `.`, `\N`, case-folded literal | byte ranges of its UTF-8 sequences + (sequences − 1) splits; 1 for an empty class |
  # | `\R` | `\r\n` (2) + the other line breaks as a class + 1 split |
  # | assertion | 1 |
  # | empty | 0 |
  # | concatenation | the sum |
  # | alternation of k branches | the sum + (k − 1) splits |
  # | capturing group | child + 2 (two slot saves) |
  # | `{n,m}` | child × m + (m − n) splits |
  # | `{n,}` | child × max(n, 1) + 1 loop split, plus one more child when the child can match the empty string (the compiler's fresh-iteration copy) |
  # | whole pattern | root + group 0 (2) + match (1) + the unanchored `(?s:.)*?` prefix |
  #
  # Class counts come from `Utf8Sequences`, the routine the compiler uses,
  # over the class's lowered set. A pattern whose bound passes
  # `CompileLimits#max_program_states` is refused at the first subtree that
  # passes it (the decision waits for the root, since `{0}` cancels its
  # child).
  module Preflight
    # Returns the bound for *pattern*. Raises `CompileLimitError` naming
    # `max_program_states`.
    #
    # With *lower_sets*, each class and case-folded literal is lowered
    # (`ClassLowering`) as the walk reaches it, so the front half walks the
    # tree once for both; otherwise they must already be lowered.
    def self.estimate(pattern : Ast::Pattern, dialect : Dialect, limits : CompileLimits, ledger : AllocationLedger,
                      meter : Core::WorkMeter, *, lower_sets : Bool = false) : Int64
      # Every node pushes one value after popping its children's, so the
      # stack never holds more values than there are nodes.
      capacity = Math.max(pattern.node_count, 1)
      ledger.charge_array(capacity, sizeof(Int64), "the preflight value stack", pattern.root.offset)
      list_of_values = OffHeapList(Int64).new(capacity)
      ledger.charge_array(capacity, sizeof(Bool), "the preflight nullability stack", pattern.root.offset)
      list_of_nullable = OffHeapList(Bool).new(capacity)
      limit = limits.max_program_states
      # The first subtree over the limit locates the error; the decision
      # waits for the root, because a {0} repetition can cancel a subtree.
      first_offender = nil
      Ast.each_post_order(pattern.root, pattern.node_count, ledger) do |node, child_count|
        offset = node.offset
        meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(1)
        if lower_sets
          if node.is_a?(Ast::CharClass)
            node.lowered_set = ClassLowering.lower(node, dialect, limits, ledger, meter)
          elsif node.is_a?(Ast::Literal)
            node.folded_set = ClassLowering.fold_literal(node, dialect, limits, ledger, meter)
          end
        end
        nullable = node_nullable?(node, list_of_nullable, child_count)
        value = node_states(node, list_of_values, list_of_nullable, child_count, ledger, meter)
        child_count.times do
          list_of_values.pop
          list_of_nullable.pop
        end
        list_of_nullable << nullable
        first_offender ||= offset if value > limit
        list_of_values << value
      end
      root_states = list_of_values.pop? || 0_i64
      total = add(root_states, overhead_states)
      if total > limit
        raise CompileLimitError.new("max_program_states", limit, "A program of at least #{total} states",
          Core::Position.new((first_offender || 0).to_i64))
      end
      total
    ensure
      # Scratch outside the collector's heap, for this call alone.
      list_of_values.try(&.free)
      list_of_nullable.try(&.free)
    end

    # States of the fixed parts every program has: group 0's two slot
    # saves, the match state, and the unanchored prefix `(?s:.)*?` (a
    # class of every code point plus its loop split).
    def self.overhead_states : Int64
      add(add(3_i64, ANY_CHARACTER_STATES[1]), 1_i64)
    end

    # Returns the class bound for *set*: byte ranges plus splits between
    # sequences, or 1 for an empty set.
    #
    # A large set's bound is its memoized automaton's exact state count
    # (`ClassMemo`), which the compiler emits; *ledger* and *meter* are
    # charged when that automaton is built.
    def self.set_states(set : CodePointSet, ledger : AllocationLedger, meter : Core::WorkMeter) : Int64
      return ClassMemo.block_for(set, ledger, meter).list_of_states.size.to_i64 if ClassMemo.memoized?(set)
      small_set_states(set)
    end

    # The bound for a set counted from its UTF-8 sequences. The trie the
    # compiler builds has no more states, and a memoized set's automaton
    # (the trie with equal suffixes merged) has no more than the trie, so
    # this bounds every set; `set_states` is exact for memoized ones.
    private def self.small_set_states(set : CodePointSet) : Int64
      return 1_i64 if set.empty?
      count_set_states(set)
    end

    private def self.count_set_states(set : CodePointSet) : Int64
      bounds_states(set.list_of_bounds)
    end

    # The class bound for the ranges in *list_of_bounds* (two entries per
    # range: first, last), which has at least one range.
    private def self.bounds_states(list_of_bounds : Slice(Int32)) : Int64
      range_count = list_of_bounds.size // 2
      # An ASCII set is one one-byte sequence per range.
      return add(range_count.to_i64, range_count.to_i64 - 1) if list_of_bounds[-1] < 0x80
      sequences = 0_i64
      byte_ranges = 0_i64
      range_count.times do |index|
        count, bytes = Utf8Sequences.count(list_of_bounds[index * 2], list_of_bounds[index * 2 + 1])
        sequences += count
        byte_ranges += bytes
      end
      return 1_i64 if sequences == 0
      add(byte_ranges, sequences - 1)
    end

    # The class bounds of `\N` (index 0) and of `.` matching newlines
    # (index 1), computed once per process.
    private ANY_CHARACTER_STATES = {
      small_set_states(ClassLowering.any_character(false)),
      small_set_states(ClassLowering.any_character(true)),
    }

    # The bounds of `\R` (index 0) and of `\R` under `(*BSR_ANYCRLF)`
    # (index 1), computed once per process.
    private LINE_BREAK_STATES = {
      add(add(2_i64, bounds_states(Slice(Int32).literal(0x0A, 0x0D, 0x85, 0x85, 0x2028, 0x2029))), 1_i64),
      add(add(2_i64, bounds_states(Slice(Int32).literal(0x0A, 0x0A, 0x0D, 0x0D))), 1_i64),
    }

    # The bound for *node*, whose *child_count* children's bounds are on
    # top of *list_of_values*.
    private def self.node_states(node : Ast::Node, list_of_values : OffHeapList(Int64), list_of_nullable : OffHeapList(Bool),
                                 child_count : Int32, ledger : AllocationLedger, meter : Core::WorkMeter) : Int64
      first_child = list_of_values.size - child_count
      case node
      when Ast::Literal
        if set = node.folded_set
          set_states(set, ledger, meter)
        else
          Utf8Sequences.encoded_length(node.code_point).to_i64
        end
      when Ast::CharClass
        set = node.lowered_set || raise SyntaxError.new("internal error: class not lowered before the preflight",
          Core::Position.new(node.offset.to_i64))
        offset = node.offset
        meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(set.range_count)
        set_states(set, ledger, meter)
      when Ast::AnyCharacter
        ANY_CHARACTER_STATES[node.matches_newline? ? 1 : 0]
      when Ast::LineBreak
        LINE_BREAK_STATES[node.any_crlf? ? 1 : 0]
      when Ast::Assertion
        1_i64
      when Ast::Empty
        0_i64
      when Ast::Concatenation
        sum_from(list_of_values, first_child)
      when Ast::Alternation
        add(sum_from(list_of_values, first_child), (child_count - 1).to_i64)
      when Ast::Group
        child = child_count > 0 ? list_of_values[first_child] : 0_i64
        node.capturing? ? add(child, 2_i64) : child
      when Ast::Repetition
        child = child_count > 0 ? list_of_values[first_child] : 0_i64
        child_nullable = child_count == 0 || list_of_nullable[first_child]
        repetition_states(child, node.minimum, node.maximum, child_nullable)
      else
        raise SyntaxError.new("internal error: unknown syntax node #{node.class}", Core::Position.new(node.offset.to_i64))
      end
    end

    # The saturating sum of the values from index *first* to the top.
    private def self.sum_from(list_of_values : OffHeapList(Int64), first : Int32) : Int64
      total = 0_i64
      (first...list_of_values.size).each { |index| total = add(total, list_of_values[index]) }
      total
    end

    # `{n,m}`: m copies, the last m − n optional (one split each); `{n,}`:
    # max(n, 1) copies and a loop split, plus a second copy of the looping
    # body when it can match the empty string (*child_nullable*): the
    # compiler runs each iteration in a fresh copy until it consumes a byte,
    # so an empty iteration leaves the loop as PCRE2 leaves it.
    def self.repetition_states(child : Int64, minimum : Int32, maximum : Int32?, child_nullable : Bool = false) : Int64
      if maximum
        add(multiply(child, maximum.to_i64), (maximum - minimum).to_i64)
      else
        copies = Math.max(minimum, 1).to_i64 + (child_nullable ? 1 : 0)
        add(multiply(child, copies), 1_i64)
      end
    end

    # Returns true when *node* can match the empty string, from its
    # children's answers on top of *list_of_nullable*. Assertions count as
    # nullable (they consume nothing).
    private def self.node_nullable?(node : Ast::Node, list_of_nullable : OffHeapList(Bool), child_count : Int32) : Bool
      first_child = list_of_nullable.size - child_count
      case node
      when Ast::Literal, Ast::CharClass, Ast::AnyCharacter, Ast::LineBreak
        false
      when Ast::Concatenation
        (first_child...list_of_nullable.size).all? { |index| list_of_nullable[index] }
      when Ast::Alternation
        (first_child...list_of_nullable.size).any? { |index| list_of_nullable[index] }
      when Ast::Repetition
        node.minimum == 0 || child_count == 0 || list_of_nullable[first_child]
      when Ast::Group
        child_count == 0 || list_of_nullable[first_child]
      else
        true
      end
    end

    # Saturating addition of non-negative counts.
    def self.add(left : Int64, right : Int64) : Int64
      left > Int64::MAX - right ? Int64::MAX : left + right
    end

    # Saturating multiplication of non-negative counts.
    def self.multiply(left : Int64, right : Int64) : Int64
      return 0_i64 if left == 0 || right == 0
      left > Int64::MAX // right ? Int64::MAX : left * right
    end
  end
end
