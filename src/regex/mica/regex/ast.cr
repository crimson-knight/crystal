module Regex::Mica::Regex
  # The syntax tree a dialect parser produces. Inline options are resolved
  # while parsing: every node that depends on them (literals, classes, `.`,
  # `^`, `$`, `\b`, quantifier greediness) records the options in force at
  # its position, so the tree has no option-setting nodes.
  #
  # Each node knows the byte offset where it starts in the pattern, for
  # errors raised after parsing (limits, class lowering).
  module Ast
    # The base of every node.
    abstract class Node
      # The 0-based byte offset of the node in the pattern.
      getter offset : Int32

      def initialize(@offset : Int32)
      end
    end

    # Matches the empty string (an empty branch or group).
    class Empty < Node
    end

    # One code point. *options* carries `IgnoreCase` and `CaselessRestrict`.
    class Literal < Node
      getter code_point : Int32
      getter options : CompileOptions
      # The set a case-folded literal stands for (its code point and its
      # fold partners), filled in by `Syntax` before the size preflight so
      # the preflight and the translator share one lowering; nil while
      # unlowered and for a literal that matches only itself.
      property folded_set : CodePointSet? = nil

      def initialize(offset : Int32, @code_point : Int32, @options : CompileOptions)
        super(offset)
      end
    end

    # What a class item contributes, before case folding and negation.
    enum ClassItemKind
      # The code points *first* to *last*; the only kind case folding
      # extends.
      Range
      # The Unicode table set *first* (an index into
      # `Unicode::Tables::SETS`).
      UnicodeSet
      # The ASCII set *first* (a value of `AsciiSet`).
      Ascii
    end

    # The fixed ASCII sets of `\d \s \w` and the POSIX classes when their
    # ASCII options are on (PCRE2's default C-locale tables).
    enum AsciiSet
      Alpha
      Lower
      Upper
      Alnum
      Ascii
      Blank
      Cntrl
      Digit
      Graph
      Print
      Punct
      Space
      Word
      Xdigit

      # Returns the set's range bounds, two entries per range (first,
      # last), as static data: reading them allocates nothing.
      def bounds : Slice(Int32)
        case self
        in .alpha?  then Slice(Int32).literal(0x41, 0x5A, 0x61, 0x7A)
        in .lower?  then Slice(Int32).literal(0x61, 0x7A)
        in .upper?  then Slice(Int32).literal(0x41, 0x5A)
        in .alnum?  then Slice(Int32).literal(0x30, 0x39, 0x41, 0x5A, 0x61, 0x7A)
        in .ascii?  then Slice(Int32).literal(0x00, 0x7F)
        in .blank?  then Slice(Int32).literal(0x09, 0x09, 0x20, 0x20)
        in .cntrl?  then Slice(Int32).literal(0x00, 0x1F, 0x7F, 0x7F)
        in .digit?  then Slice(Int32).literal(0x30, 0x39)
        in .graph?  then Slice(Int32).literal(0x21, 0x7E)
        in .print?  then Slice(Int32).literal(0x20, 0x7E)
        in .punct?  then Slice(Int32).literal(0x21, 0x2F, 0x3A, 0x40, 0x5B, 0x60, 0x7B, 0x7E)
        in .space?  then Slice(Int32).literal(0x09, 0x0D, 0x20, 0x20)
        in .word?   then Slice(Int32).literal(0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A)
        in .xdigit? then Slice(Int32).literal(0x30, 0x39, 0x41, 0x46, 0x61, 0x66)
        end
      end
    end

    # One member of a class: a range, a Unicode set or an ASCII set,
    # possibly negated (`\D`, `\P{L}`, `[:^alpha:]`).
    record ClassItem, item_kind : ClassItemKind, first : Int32, last : Int32, negated : Bool do
      def self.range(first : Int32, last : Int32) : self
        new(ClassItemKind::Range, first, last, false)
      end

      def self.unicode_set(set_id : Int32, negated : Bool) : self
        new(ClassItemKind::UnicodeSet, set_id, set_id, negated)
      end

      def self.ascii(set : AsciiSet, negated : Bool) : self
        new(ClassItemKind::Ascii, set.value, set.value, negated)
      end
    end

    # A bracketed class, or a single class escape (`\d`, `\p{L}`, `\h`)
    # outside brackets. Case folding (from *options*) extends only
    # `ClassItemKind::Range` items, as in PCRE2; *negated* applies after
    # folding.
    class CharClass < Node
      getter list_of_items : Array(ClassItem)
      getter? negated : Bool
      getter options : CompileOptions
      # The set this class lowers to, filled in by `Syntax` before the size
      # preflight so the preflight and the translator share one lowering.
      property lowered_set : CodePointSet? = nil

      def initialize(offset : Int32, @list_of_items : Array(ClassItem), @negated : Bool, @options : CompileOptions)
        super(offset)
      end
    end

    # `.` and `\N`: any character, or any character but a newline.
    class AnyCharacter < Node
      getter? matches_newline : Bool

      def initialize(offset : Int32, @matches_newline : Bool)
        super(offset)
      end
    end

    # `\R`: a line break, `\r\n` taken whole. *any_crlf* restricts it to
    # CR, LF and CRLF (`(*BSR_ANYCRLF)`).
    class LineBreak < Node
      getter? any_crlf : Bool

      def initialize(offset : Int32, @any_crlf : Bool)
        super(offset)
      end
    end

    # Zero-width assertions.
    enum AssertionKind
      # `\A`, and `^` without `Multiline`.
      StartOfText
      # `^` with `Multiline`.
      StartOfLine
      # `\z`, and `$` with `DollarEndOnly` (and without `Multiline`).
      EndOfText
      # `\Z`, and `$` without `Multiline`: the end, or before a final
      # newline.
      EndOfTextOrFinalNewline
      # `$` with `Multiline`.
      EndOfLine
      # `\b`.
      WordBoundary
      # `\B`.
      NotWordBoundary
      # `[[:<:]]`: a word boundary followed by a word character.
      WordStart
      # `[[:>:]]`: a word boundary preceded by a word character.
      WordEnd
      # `\G`: the search's start offset.
      SearchStart
    end

    # A zero-width assertion. *ascii_word* is set when `\w` is ASCII-only
    # for the word assertions (`(?aW)`).
    class Assertion < Node
      getter assertion_kind : AssertionKind
      getter? ascii_word : Bool

      def initialize(offset : Int32, @assertion_kind : AssertionKind, @ascii_word : Bool = false)
        super(offset)
      end
    end

    # Nodes in sequence.
    class Concatenation < Node
      getter list_of_children : Array(Node)

      def initialize(offset : Int32, @list_of_children : Array(Node))
        super(offset)
      end
    end

    # Branches tried in order (leftmost-first priority).
    class Alternation < Node
      getter list_of_branches : Array(Node)

      def initialize(offset : Int32, @list_of_branches : Array(Node))
        super(offset)
      end
    end

    # A parenthesized group. *capture_index* is 0 for a group that does not
    # capture; *group_name* is set for a named capture.
    class Group < Node
      getter capture_index : Int32
      getter group_name : String?
      getter child : Node

      def initialize(offset : Int32, @capture_index : Int32, @group_name : String?, @child : Node)
        super(offset)
      end

      def capturing? : Bool
        @capture_index > 0
      end
    end

    # A quantified node. *maximum* is nil when unbounded.
    class Repetition < Node
      getter minimum : Int32
      getter maximum : Int32?
      property? greedy : Bool
      getter child : Node

      def initialize(offset : Int32, @minimum : Int32, @maximum : Int32?, @greedy : Bool, @child : Node)
        super(offset)
      end
    end

    # Returns the number of direct children of *node* (0 for a leaf).
    def self.child_count(node : Node) : Int32
      case node
      when Concatenation then node.list_of_children.size
      when Alternation   then node.list_of_branches.size
      when Group         then 1
      when Repetition    then 1
      else                    0
      end
    end

    # Returns the direct child of *node* at *index*.
    def self.child_at(node : Node, index : Int32) : Node
      case node
      when Concatenation then node.list_of_children[index]
      when Alternation   then node.list_of_branches[index]
      when Group         then node.child
      when Repetition    then node.child
      else                    raise IndexError.new("A #{node.class} has no children")
      end
    end

    # Visits the tree under *root* in post-order without recursion, yielding
    # each node with its number of children; callers keep their own value
    # stack and pop that many results. The work stack has room for
    # *node_count* entries (every node is on it at most once), is charged
    # to *ledger* first, and sits in the caller's stack frame when the tree
    # is small (see `ScratchStack`).
    def self.each_post_order(root : Node, node_count : Int32, ledger : AllocationLedger, & : Node, Int32 ->) : Nil
      capacity = Math.max(node_count, 1)
      ledger.charge_array(capacity, sizeof({Node, Bool}), "a traversal stack", root.offset)
      stack = Mica::Regex.scratch_stack({Node, Bool}, capacity)
      stack << {root, false}
      until stack.empty?
        node, expanded = stack.pop
        count = child_count(node)
        if expanded
          yield node, count
        else
          stack << {node, true}
          (count - 1).downto(0) { |index| stack << {child_at(node, index), false} }
        end
      end
    end

    # A named group and its number, in pattern order (the name table).
    record GroupName, group_name : String, capture_index : Int32

    # How the source text ends: closed, or inside an extended-mode `#`
    # comment or a `\Q` quote that runs to the end. Text appended after
    # the source (as `Expression#to_s` appends a closing parenthesis)
    # needs a line feed or a `\E` first to be read as pattern again.
    enum SourceEnd
      Closed
      InComment
      InQuote
    end

    # The parse of a whole pattern.
    class Pattern
      # The root node.
      getter root : Node
      # The number of capturing groups (the highest group number).
      getter capture_count : Int32
      # Named groups in definition order; a name may appear more than once
      # (duplicate names are always allowed in the Crystal dialect).
      getter list_of_group_names : Array(GroupName)
      # The options in force at the start of the pattern, after any
      # start-of-pattern settings such as `(*CASELESS_RESTRICT)`.
      getter options : CompileOptions
      # Syntax nodes created (the parse's share of the compile work).
      getter node_count : Int32
      # How the source text ends.
      getter source_end : SourceEnd

      def initialize(@root : Node, @capture_count : Int32, @list_of_group_names : Array(GroupName),
                     @options : CompileOptions, @node_count : Int32, @source_end : SourceEnd = SourceEnd::Closed)
      end
    end
  end
end
