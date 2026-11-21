module Regex::Mica::Regex
  # The literals every match of a pattern starts with, extracted from its
  # `Hir` when the pattern is compiled (roadmap 6.2, pipeline step 4). The
  # accelerators in `Prefilter` use them to skip ahead to the next position
  # where a match could start.
  #
  # Each literal is a byte string. Every match of the pattern starts with
  # one of them. When `exact?`, the set is more than that: the pattern
  # matches exactly these strings, in this priority order (leftmost-first,
  # earlier entries first), and contains no assertion, so a literal search
  # alone finds the match.
  #
  # A pattern that can match the empty string, or whose start is too varied
  # (a large class, more than `MAX_LITERALS` alternatives), has no set.
  class LiteralSet
    # The most literals a set holds.
    MAX_LITERALS = 64
    # The longest literal kept; longer ones are cut to a prefix.
    MAX_LITERAL_BYTES = 32
    # A class with more code points than this ends the literal.
    MAX_CLASS_CODE_POINTS = 8
    # How deep extraction descends into the tree before it stops.
    MAX_DEPTH = 512

    # The literals in priority order.
    getter list_of_literals : Array(Bytes)
    # True when the pattern matches exactly these literals (see the class
    # description).
    getter? exact : Bool

    def initialize(@list_of_literals : Array(Bytes), @exact : Bool)
    end

    # Returns the set for *pattern*, or nil when it has none. Charges one
    # operation per node visited to *meter*.
    def self.extract(pattern : Hir::Pattern, meter : Core::WorkMeter) : LiteralSet?
      extractor = LiteralExtractor.new(meter)
      sequence = extractor.sequence(pattern.root, 0)
      return nil unless sequence
      return nil if sequence.empty? || sequence.any?(&.bytes.empty?)
      exact = sequence.all?(&.exact?) && !extractor.saw_look? && unrestricted?(pattern.options)
      new(distinct_literals(sequence), exact)
    end

    # The distinct byte strings of *sequence*, first occurrence first. A
    # long sequence (up to `MAX_LITERALS` entries, often equal after being
    # cut to `MAX_LITERAL_BYTES`) is checked through a set rather than by
    # comparing each entry with every kept one.
    private def self.distinct_literals(sequence : Array(LiteralEntry)) : Array(Bytes)
      list_of_literals = Array(Bytes).new(sequence.size)
      if sequence.size <= 8
        sequence.each do |entry|
          list_of_literals << entry.bytes unless list_of_literals.includes?(entry.bytes)
        end
      else
        seen = Set(Bytes).new(sequence.size)
        sequence.each { |entry| list_of_literals << entry.bytes if seen.add?(entry.bytes) }
      end
      list_of_literals
    end

    # True when no option changes where a literal match may start or end.
    private def self.unrestricted?(options : CompileOptions) : Bool
      !options.anchored? && !options.end_anchored? && !options.first_line?
    end

    # The shortest literal's length.
    def minimum_length : Int32
      @list_of_literals.min_of(&.size)
    end
  end

  # :nodoc:
  # One literal of a sequence: its bytes, and whether it is the whole match
  # of its branch (exact) or only a prefix of it.
  record LiteralEntry, bytes : Bytes, exact : Bool do
    def exact? : Bool
      exact
    end
  end

  # :nodoc:
  # Computes the prefix literal sequence of a `Hir` node, following the
  # rules of Rust regex's literal extractor in a simpler form. A sequence of
  # nil means "anything can follow" (no finite set of prefixes).
  class LiteralExtractor
    getter? saw_look : Bool = false
    # True while an alternation gathers its branches cut to shares (see
    # `gather_branches`).
    @cutting = false

    def initialize(@meter : Core::WorkMeter)
    end

    # *limit* is the most entries the caller can use: an alternation gives
    # each branch what is left of `LiteralSet::MAX_LITERALS`, and a branch
    # whose entries already pass it returns nil early, as the alternation
    # would after building them all (a concatenation's entries only grow).
    def sequence(node : Hir::Node, depth : Int32, limit : Int32 = Int32::MAX) : Array(LiteralEntry)?
      @meter.charge(1)
      return nil if depth > LiteralSet::MAX_DEPTH
      if node.is_a?(Hir::Empty)
        [LiteralEntry.new(Bytes.empty, true)]
      elsif node.is_a?(Hir::Look)
        @saw_look = true
        [LiteralEntry.new(Bytes.empty, true)]
      elsif node.is_a?(Hir::Literal)
        [LiteralEntry.new(node.code_point.chr.to_s.to_slice, true)]
      elsif node.is_a?(Hir::Class)
        class_sequence(node.code_point_set)
      elsif node.is_a?(Hir::Capture)
        sequence(node.child, depth + 1, limit)
      elsif node.is_a?(Hir::Repetition)
        repetition_sequence(node, depth)
      elsif node.is_a?(Hir::Concatenation)
        concatenation_sequence(node.list_of_children, depth, limit)
      elsif node.is_a?(Hir::Alternation)
        alternation_sequence(node.list_of_branches, depth)
      else
        nil
      end
    end

    private def class_sequence(set : CodePointSet) : Array(LiteralEntry)?
      return nil if set.empty? || set.size > LiteralSet::MAX_CLASS_CODE_POINTS
      list_of_entries = [] of LiteralEntry
      set.each_range do |low, high|
        (low..high).each { |code_point| list_of_entries << LiteralEntry.new(code_point.chr.to_s.to_slice, true) }
      end
      list_of_entries
    end

    private def repetition_sequence(node : Hir::Repetition, depth : Int32) : Array(LiteralEntry)?
      return [LiteralEntry.new(Bytes.empty, false)] if node.minimum == 0
      child = sequence(node.child, depth + 1)
      return nil unless child
      if node.maximum == node.minimum
        result = [LiteralEntry.new(Bytes.empty, true)]
        node.minimum.times do
          break unless result.any?(&.exact?)
          crossed = cross(result, child)
          return inexact(result) unless crossed
          result = crossed
        end
        result
      else
        inexact(child)
      end
    end

    private def concatenation_sequence(list_of_children : Array(Hir::Node), depth : Int32,
                                       limit : Int32) : Array(LiteralEntry)?
      result = [LiteralEntry.new(Bytes.empty, true)]
      index = 0
      while index < list_of_children.size
        break unless result.any?(&.exact?)
        child = list_of_children[index]
        if child.is_a?(Hir::Literal)
          # A run of literal characters is one entry, crossed once:
          # appending them one at a time copied every prefix again.
          child_sequence, index = literal_run(list_of_children, index)
        else
          child_sequence = sequence(child, depth + 1)
          index += 1
        end
        return inexact(result) unless child_sequence
        crossed = cross(result, child_sequence)
        return inexact(result) unless crossed
        if crossed.size > limit
          return nil unless @cutting
          # Cut to its share (see `gather_branches`), the branch keeps the
          # prefixes so far, once they are `MIN_CUT_BYTES` long; shorter
          # ones grow past the share.
          return inexact(result) if result.all? { |entry| entry.bytes.size >= MIN_CUT_BYTES }
        end
        result = crossed
      end
      result
    end

    # The literal characters of *list_of_children* from *first* on, as one
    # exact entry, and the index after them. Charges one operation per
    # character, as `sequence` does per node.
    private def literal_run(list_of_children : Array(Hir::Node), first : Int32) : {Array(LiteralEntry), Int32}
      last = first
      byte_count = 0
      while last < list_of_children.size
        child = list_of_children[last]
        break unless child.is_a?(Hir::Literal)
        @meter.charge(1)
        byte_count += Core::UTF8.encoded_size(child.code_point)
        last += 1
      end
      # One ASCII character is a byte of static data.
      if byte_count == 1 && last == first + 1
        child = list_of_children[first]
        return {[LiteralEntry.new(ASCII_BYTES[child.code_point, 1], true)], last} if child.is_a?(Hir::Literal)
      end
      bytes = Bytes.new(byte_count)
      offset = 0
      (first...last).each do |child_index|
        child = list_of_children[child_index]
        next unless child.is_a?(Hir::Literal)
        offset += Core::UTF8.encode(child.code_point, bytes + offset)
      end
      {[LiteralEntry.new(bytes, true)], last}
    end

    # The 128 ASCII bytes in order: a one-character ASCII literal is a
    # slice of them.
    {% begin %}
      private ASCII_BYTES = Slice(UInt8).literal({% for byte in 0..127 %}{{ byte }}_u8, {% end %})
    {% end %}

    # The branches' entries in order. When they come to more than
    # `LiteralSet::MAX_LITERALS` (a few case-insensitive words, each of
    # which expands to dozens), they are gathered again with each branch
    # cut to an even share of what the earlier ones left (see
    # `gather_branches`).
    private def alternation_sequence(list_of_branches : Array(Hir::Node), depth : Int32) : Array(LiteralEntry)?
      gather_branches(list_of_branches, depth, false) || gather_branches(list_of_branches, depth, true)
    end

    # The fewest bytes a literal cut to its branch's share keeps: a shorter
    # prefix starts too many positions to skip anything.
    MIN_CUT_BYTES = 3

    # Gathers the entries of *list_of_branches*. Each branch may take what
    # the earlier ones left, less one entry for each later branch; with
    # *shared*, it takes an even share of that instead, and a concatenation
    # past its share ends there (its entries become prefixes, see
    # `concatenation_sequence`). A shared gathering whose prefixes come out
    # shorter than `MIN_CUT_BYTES` has no set.
    private def gather_branches(list_of_branches : Array(Hir::Node), depth : Int32, shared : Bool) : Array(LiteralEntry)?
      return nil if shared && list_of_branches.size > LiteralSet::MAX_LITERALS
      cutting = @cutting
      @cutting = shared
      begin
        result = [] of LiteralEntry
        list_of_branches.each_with_index do |branch, index|
          later = list_of_branches.size - 1 - index
          limit = shared ? (LiteralSet::MAX_LITERALS - result.size) // (later + 1) : LiteralSet::MAX_LITERALS - result.size - later
          return nil if shared && limit < 1
          branch_sequence = sequence(branch, depth + 1, limit)
          return nil unless branch_sequence
          return nil if shared && branch_sequence.any? { |entry| !entry.exact? && entry.bytes.size < MIN_CUT_BYTES }
          result.concat(branch_sequence)
          return nil if result.size > LiteralSet::MAX_LITERALS
        end
        result
      ensure
        @cutting = cutting
      end
    end

    # Appends each entry of *right* to each exact entry of *left*, in
    # priority order; inexact entries of *left* stay as they are. Returns nil
    # when the product would hold more than `MAX_LITERALS` entries.
    private def cross(left : Array(LiteralEntry), right : Array(LiteralEntry)) : Array(LiteralEntry)?
      size = left.sum { |entry| entry.exact? ? right.size : 1 }
      return nil if size > LiteralSet::MAX_LITERALS
      result = Array(LiteralEntry).new(size)
      # Every new literal is a slice of one buffer, so a product of up to
      # `MAX_LITERALS` entries allocates once rather than once per entry.
      # A literal with an empty side is the other side's bytes as they are
      # (`<` before a class, the first literal of a concatenation), so a
      # product of such pairs alone allocates no buffer.
      buffer_size = 0
      left.each do |entry|
        next unless entry.exact? && !entry.bytes.empty?
        right.each { |suffix| buffer_size += entry.bytes.size + suffix.bytes.size unless suffix.bytes.empty? }
      end
      buffer = buffer_size == 0 ? Bytes.empty : Bytes.new(buffer_size)
      buffer_offset = 0
      left.each do |entry|
        unless entry.exact?
          result << entry
          next
        end
        right.each do |suffix|
          if entry.bytes.empty?
            bytes = suffix.bytes
          elsif suffix.bytes.empty?
            bytes = entry.bytes
          else
            bytes = buffer[buffer_offset, entry.bytes.size + suffix.bytes.size]
            buffer_offset += bytes.size
            entry.bytes.copy_to(bytes)
            suffix.bytes.copy_to(bytes + entry.bytes.size)
          end
          if bytes.size > LiteralSet::MAX_LITERAL_BYTES
            result << LiteralEntry.new(bytes[0, LiteralSet::MAX_LITERAL_BYTES], false)
          else
            result << LiteralEntry.new(bytes, suffix.exact?)
          end
        end
      end
      result
    end

    private def inexact(list_of_entries : Array(LiteralEntry)) : Array(LiteralEntry)
      list_of_entries.map { |entry| LiteralEntry.new(entry.bytes, false) }
    end
  end
end
