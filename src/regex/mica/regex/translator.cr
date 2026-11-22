module Regex::Mica::Regex
  # Translates a syntax tree (with its classes and case-folded literals
  # lowered) into `Hir`. Runs after the size preflight, so every repetition
  # it records has already been bounded; it does not expand repetitions
  # (the compiler does, in R2).
  module Translator
    # Returns the `Hir::Pattern` for *pattern* in *dialect*.
    def self.translate(pattern : Ast::Pattern, dialect : Dialect, ledger : AllocationLedger,
                       meter : Core::WorkMeter) : Hir::Pattern
      # Every node pushes one result after popping its children's, so the
      # stack never holds more results than there are nodes.
      capacity = Math.max(pattern.node_count, 1)
      ledger.charge_array(capacity, sizeof(Hir::Node), "the translation stack", pattern.root.offset)
      list_of_results = Mica::Regex.scratch_stack(Hir::Node, capacity)
      Ast.each_post_order(pattern.root, pattern.node_count, ledger) do |node, child_count|
        offset = node.offset
        meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(1)
        hir = translate_node(node, list_of_results, child_count, ledger)
        child_count.times { list_of_results.pop }
        list_of_results << hir
      end
      ledger.charge_object(instance_sizeof(Hir::Pattern), "a Hir pattern", pattern.root.offset)
      root = list_of_results.pop? || empty_node(ledger, pattern.root.offset)
      root = factor_root(root, ledger, pattern.root.offset) if root.is_a?(Hir::Alternation)
      Hir::Pattern.new(root, pattern.capture_count, pattern.list_of_group_names, pattern.options, dialect,
        pattern.source_end)
    end

    # The `Hir` for *node*, whose *child_count* children's results are on
    # top of *list_of_results*.
    private def self.translate_node(node : Ast::Node, list_of_results : ScratchStack(Hir::Node), child_count : Int32,
                                    ledger : AllocationLedger) : Hir::Node
      offset = node.offset
      first_child = list_of_results.size - child_count
      case node
      when Ast::Literal
        if set = node.folded_set
          ledger.charge_object(instance_sizeof(Hir::Class), "a Hir class", offset)
          return Hir::Class.new(set)
        end
        code_point = node.code_point
        return ascii_literal(code_point) if code_point < ASCII_LITERAL_COUNT
        ledger.charge_object(instance_sizeof(Hir::Literal), "a Hir literal", offset)
        Hir::Literal.new(code_point)
      when Ast::CharClass
        set = node.lowered_set || raise SyntaxError.new("internal error: class not lowered before translation",
          Core::Position.new(offset.to_i64))
        ledger.charge_object(instance_sizeof(Hir::Class), "a Hir class", offset)
        Hir::Class.new(set)
      when Ast::AnyCharacter
        ledger.charge_object(instance_sizeof(Hir::Class), "a Hir class", offset)
        Hir::Class.new(ClassLowering.any_character(node.matches_newline?))
      when Ast::LineBreak
        ledger.charge_object(instance_sizeof(Hir::LineBreak), "a Hir line break", offset)
        Hir::LineBreak.new(node.any_crlf?)
      when Ast::Assertion
        ledger.charge_object(instance_sizeof(Hir::Look), "a Hir assertion", offset)
        Hir::Look.new(node.assertion_kind, node.ascii_word?)
      when Ast::Empty
        empty_node(ledger, offset)
      when Ast::Concatenation
        ledger.charge_object(instance_sizeof(Hir::Concatenation), "a Hir concatenation", offset)
        Hir::Concatenation.new(children_from(list_of_results, first_child, ledger, offset))
      when Ast::Alternation
        ledger.charge_object(instance_sizeof(Hir::Alternation), "a Hir alternation", offset)
        Hir::Alternation.new(children_from(list_of_results, first_child, ledger, offset))
      when Ast::Group
        child = child_count > 0 ? list_of_results[first_child] : empty_node(ledger, offset)
        return child unless node.capturing?
        ledger.charge_object(instance_sizeof(Hir::Capture), "a Hir capture", offset)
        Hir::Capture.new(node.capture_index, node.group_name, child)
      when Ast::Repetition
        child = child_count > 0 ? list_of_results[first_child] : empty_node(ledger, offset)
        ledger.charge_object(instance_sizeof(Hir::Repetition), "a Hir repetition", offset)
        Hir::Repetition.new(node.minimum, node.maximum, node.greedy?, child)
      else
        raise SyntaxError.new("internal error: unknown syntax node #{node.class}", Core::Position.new(offset.to_i64))
      end
    end

    private ASCII_LITERAL_COUNT = 0x80

    # The `Hir` node of each ASCII literal, shared by every translation:
    # nodes are never changed after they are made, and most patterns are
    # mostly ASCII literals, so these are made once rather than once per
    # character. They are static objects (see `Mica::Regex.static_object`): a
    # node holds one number, so the table costs the collector's heap
    # nothing, at program start or in a translation.
    @@ascii_literal_storage = uninitialized StaticArray(ReferenceStorage(Hir::Literal), ASCII_LITERAL_COUNT)
    @@ascii_literals : Pointer(ReferenceStorage(Hir::Literal)) = begin
      storage = @@ascii_literal_storage.to_unsafe
      ASCII_LITERAL_COUNT.times { |code_point| Hir::Literal.unsafe_construct(storage + code_point, code_point) }
      storage
    end

    private def self.ascii_literal(code_point : Int32) : Hir::Literal
      (@@ascii_literals + code_point).as(Hir::Literal)
    end

    # Copies the results from index *first* to the top into an array of
    # exactly that size, charged first.
    private def self.children_from(list_of_results : ScratchStack(Hir::Node), first : Int32, ledger : AllocationLedger,
                                   offset : Int32) : Array(Hir::Node)
      count = list_of_results.size - first
      ledger.charge_array(count, sizeof(Hir::Node), "a Hir child list", offset)
      list_of_children = Array(Hir::Node).new(count)
      (first...list_of_results.size).each { |index| list_of_children << list_of_results[index] }
      list_of_children
    end

    # The pattern's top-level alternation with its shared first literals
    # factored (see `factor_first_literals`). Only the top level: a
    # factored alternation inside a larger pattern can make it one-pass
    # where building the one-pass DFA costs more than its first searches
    # save.
    private def self.factor_root(root : Hir::Alternation, ledger : AllocationLedger, offset : Int32) : Hir::Node
      list_of_branches = factor_first_literals(root.list_of_branches, ledger, offset)
      return root if list_of_branches.same?(root.list_of_branches)
      return list_of_branches[0] if list_of_branches.size == 1
      ledger.charge_object(instance_sizeof(Hir::Alternation), "a Hir alternation", offset)
      Hir::Alternation.new(list_of_branches)
    end

    # Factors the first literal out of each run of adjacent branches that
    # start with the same one: `,|,\s` becomes `,(?:|\s)`, which the
    # one-pass DFA can read (after the comma the empty branch ranks first)
    # where the two branches made it ambiguous. Leftmost-first matching
    # tries the same paths in the same order either way (`L·X|L·Y` reads
    # `L`, then tries `X`, then `Y`), so every match and group is the same.
    # Only adjacent branches are joined, so priority between branches is
    # kept.
    private def self.factor_first_literals(list_of_branches : Array(Hir::Node), ledger : AllocationLedger,
                                           offset : Int32) : Array(Hir::Node)
      return list_of_branches if list_of_branches.size < 2
      factored = nil
      index = 0
      while index < list_of_branches.size
        literal = first_literal(list_of_branches[index])
        run_end = index + 1
        if literal
          while run_end < list_of_branches.size && first_literal(list_of_branches[run_end]).try(&.code_point) == literal.code_point
            run_end += 1
          end
        end
        if run_end - index >= 2 && literal
          factored ||= list_of_branches[0, index]
          ledger.charge_array(run_end - index, sizeof(Hir::Node), "a Hir child list", offset)
          list_of_rests = Array(Hir::Node).new(run_end - index)
          (index...run_end).each { |branch| list_of_rests << rest_after_first(list_of_branches[branch], ledger, offset) }
          ledger.charge_object(instance_sizeof(Hir::Alternation), "a Hir alternation", offset)
          ledger.charge_object(instance_sizeof(Hir::Concatenation), "a Hir concatenation", offset)
          ledger.charge_array(2, sizeof(Hir::Node), "a Hir child list", offset)
          factored << Hir::Concatenation.new([literal, Hir::Alternation.new(list_of_rests)] of Hir::Node)
        elsif factored
          (index...run_end).each { |branch| factored << list_of_branches[branch] }
        end
        index = run_end
      end
      factored || list_of_branches
    end

    # The literal *branch* starts with, or nil.
    private def self.first_literal(branch : Hir::Node) : Hir::Literal?
      return branch if branch.is_a?(Hir::Literal)
      return nil unless branch.is_a?(Hir::Concatenation)
      first = branch.list_of_children.first?
      first.is_a?(Hir::Literal) ? first : nil
    end

    # *branch* without its first literal (see `first_literal`).
    private def self.rest_after_first(branch : Hir::Node, ledger : AllocationLedger, offset : Int32) : Hir::Node
      return empty_node(ledger, offset) unless branch.is_a?(Hir::Concatenation)
      children = branch.list_of_children
      return empty_node(ledger, offset) if children.size == 1
      return children[1] if children.size == 2
      ledger.charge_object(instance_sizeof(Hir::Concatenation), "a Hir concatenation", offset)
      ledger.charge_array(children.size - 1, sizeof(Hir::Node), "a Hir child list", offset)
      Hir::Concatenation.new(children[1..])
    end

    private def self.empty_node(ledger : AllocationLedger, offset : Int32) : Hir::Node
      ledger.charge_object(instance_sizeof(Hir::Empty), "a Hir empty node", offset)
      Hir::Empty.new
    end
  end
end
