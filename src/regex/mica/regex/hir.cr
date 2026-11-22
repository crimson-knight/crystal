module Regex::Mica::Regex
  # The high-level intermediate representation every dialect lowers to,
  # and the input of the NFA compiler (R2). Compared with the syntax tree:
  #
  # - classes, `.`, `\N` and case-insensitive literals are `Class` nodes
  #   holding a sorted `CodePointSet` (case folding already applied, per
  #   dialect);
  # - repetitions are explicit `{minimum, maximum}` counts;
  # - non-capturing groups are gone, and options are resolved.
  #
  # ```
  # hir = Mica::Regex::Syntax.translate("a+(?i:k)", dialect: :crystal,
  #   compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  # hir.root.to_s # => "(cat a{1,} [Kk\\x{212A}])"
  # ```
  module Hir
    # The base of every node.
    abstract class Node
      # Writes the node in a compact s-expression form (for specs and
      # diagnostics).
      abstract def to_s(io : IO) : Nil
    end

    # Matches the empty string.
    class Empty < Node
      def to_s(io : IO) : Nil
        io << "(empty)"
      end
    end

    # One code point, matched exactly.
    class Literal < Node
      getter code_point : Int32

      def initialize(@code_point : Int32)
      end

      def to_s(io : IO) : Nil
        if 0x21 <= @code_point <= 0x7E && !"()[]{}\\".includes?(@code_point.chr)
          io << @code_point.chr
        else
          io << "\\x{" << @code_point.to_s(16).upcase << '}'
        end
      end
    end

    # Any one code point in a set.
    class Class < Node
      getter code_point_set : CodePointSet

      def initialize(@code_point_set : CodePointSet)
      end

      def to_s(io : IO) : Nil
        @code_point_set.to_s(io)
      end
    end

    # A zero-width assertion (see `Ast::AssertionKind`).
    class Look < Node
      getter assertion_kind : Ast::AssertionKind
      getter? ascii_word : Bool

      def initialize(@assertion_kind : Ast::AssertionKind, @ascii_word : Bool)
      end

      def to_s(io : IO) : Nil
        io << "(look " << @assertion_kind.to_s.underscore << (@ascii_word ? " ascii" : "") << ')'
      end
    end

    # `\R`. PCRE2 matches it atomically (`\r\n` is never split by
    # backtracking), so it stays a node of its own until the compiler
    # (R2) gives it that meaning.
    class LineBreak < Node
      getter? any_crlf : Bool

      def initialize(@any_crlf : Bool)
      end

      def to_s(io : IO) : Nil
        io << (@any_crlf ? "(linebreak anycrlf)" : "(linebreak)")
      end
    end

    # A repetition of *child*; *maximum* is nil when unbounded.
    class Repetition < Node
      getter minimum : Int32
      getter maximum : Int32?
      getter? greedy : Bool
      getter child : Node

      def initialize(@minimum : Int32, @maximum : Int32?, @greedy : Bool, @child : Node)
      end

      def to_s(io : IO) : Nil
        io << @child << '{' << @minimum << ','
        if maximum = @maximum
          io << maximum
        end
        io << '}'
        io << '?' unless @greedy
      end
    end

    # A capturing group.
    class Capture < Node
      getter capture_index : Int32
      getter group_name : String?
      getter child : Node

      def initialize(@capture_index : Int32, @group_name : String?, @child : Node)
      end

      def to_s(io : IO) : Nil
        io << "(cap " << @capture_index
        if group_name = @group_name
          io << ' ' << group_name
        end
        io << ' ' << @child << ')'
      end
    end

    # Nodes in sequence.
    class Concatenation < Node
      getter list_of_children : Array(Node)

      def initialize(@list_of_children : Array(Node))
      end

      def to_s(io : IO) : Nil
        io << "(cat"
        @list_of_children.each { |child| io << ' ' << child }
        io << ')'
      end
    end

    # Branches in priority order.
    class Alternation < Node
      getter list_of_branches : Array(Node)

      def initialize(@list_of_branches : Array(Node))
      end

      def to_s(io : IO) : Nil
        io << "(alt"
        @list_of_branches.each { |branch| io << ' ' << branch }
        io << ')'
      end
    end

    # A translated pattern.
    class Pattern
      getter root : Node
      getter capture_count : Int32
      getter list_of_group_names : Array(Ast::GroupName)
      getter options : CompileOptions
      getter dialect : Dialect
      getter source_end : Ast::SourceEnd

      def initialize(@root : Node, @capture_count : Int32, @list_of_group_names : Array(Ast::GroupName),
                     @options : CompileOptions, @dialect : Dialect, @source_end : Ast::SourceEnd = Ast::SourceEnd::Closed)
      end
    end
  end
end
