module Crystal::InferReuse
  # Raised when a build cannot reuse the kept program; the message says why
  # and the build types the whole program instead.
  class Refusal < Exception
  end

  # What changed between the old and new text of one source file, when
  # every change is one of:
  #
  # * the body of a method that sits directly in the file, a class or a
  #   module (not in a macro, a macro call or a method), keeping its header;
  # * a whole such method added (with the comment lines right above it and
  #   the blank lines around it);
  # * a whole such method removed, the same way.
  #
  # Every other line must read the same, in the same order, so that each node
  # outside those methods keeps its place up to a whole-line move, which
  # `#line_shift` gives. Anything else raises `Refusal`.
  class FileEdit
    # A method whose body changed: its definition as parsed from the old and
    # from the new text, and where it was in the old text (the old
    # definition's locations move with the file once the edit is applied).
    record ChangedDef, filename : String, old_def : Def, new_def : Def,
      old_line : Int32, old_column : Int32, old_first_line : Int32, old_last_line : Int32

    # A method the new text adds, with the classes and modules around it
    # (outermost first).
    record AddedDef, filename : String, new_def : Def, list_of_scopes : Array(ASTNode)

    # A method the new text no longer has, as parsed from the old text, with
    # where it was.
    record RemovedDef, filename : String, old_def : Def, list_of_scopes : Array(ASTNode),
      old_line : Int32, old_column : Int32, old_first_line : Int32, old_last_line : Int32

    getter filename : String
    getter list_of_changed_defs = [] of ChangedDef
    getter list_of_added_defs = [] of AddedDef
    getter list_of_removed_defs = [] of RemovedDef
    # Old line numbers to new ones, for the nodes the program keeps.
    getter line_shift : Location::LineShift
    # The file indexes of the locations parsed from earlier texts of the
    # file, which `#line_shift` moves (`Location.start_new_version`).
    getter list_of_earlier_indexes : Array(UInt32)

    def initialize(@filename, @line_shift, @list_of_earlier_indexes)
    end

    # Whether the edit changes only method bodies, and no line moves.
    def bodies_only? : Bool
      @list_of_added_defs.empty? && @list_of_removed_defs.empty?
    end

    # Whether old line *line_number* held code of a method whose body changed
    # or that was removed: nodes there are not kept.
    def replaced_line?(line_number : Int32) : Bool
      @list_of_changed_defs.any? { |changed| changed.old_first_line <= line_number <= changed.old_last_line } ||
        @list_of_removed_defs.any? { |removed| removed.old_first_line <= line_number <= removed.old_last_line }
    end

    # Applies `#line_shift` to every location parsed from the old text.
    def shift_program_lines : Nil
      return if @line_shift.identity?
      Location.shift_lines(@list_of_earlier_indexes, @line_shift)
    end

    def self.compare(program : Program, filename : String, old_text : String, new_text : String) : FileEdit
      FileEditComparison.new(program, filename, old_text, new_text).run
    end
  end

  # A method as `FileEditComparison` sees it: where its header and body are,
  # and the classes and modules around it.
  record DefSpan, a_def : Def, list_of_scopes : Array(ASTNode), key : String,
    first_line : Int32, column : Int32, header_last_line : Int32, end_line : Int32 do
    # The lines strictly inside the body (possibly none).
    def body_range : Range(Int32, Int32)
      (header_last_line + 1)..(end_line - 1)
    end
  end

  # Compares the old and new text of one file (see `FileEdit`).
  class FileEditComparison
    @list_of_old_lines : Array(String)
    @list_of_new_lines : Array(String)

    def initialize(@program : Program, @filename : String, @old_text : String, @new_text : String)
      @list_of_old_lines = old_text.split('\n')
      @list_of_new_lines = new_text.split('\n')
    end

    def run : FileEdit
      # The old text's locations get the file's current index; locations of
      # the new text a new one, so that shifting the old ones leaves the new
      # ones alone.
      list_of_old_spans = spans_of(@old_text)
      list_of_earlier_indexes = Location.start_new_version(@filename)
      list_of_new_spans = spans_of(@new_text)

      list_of_pairs = aligned(list_of_old_spans, list_of_new_spans)
      old_matched = Set(Int32).new
      new_matched = Set(Int32).new
      list_of_pairs.each do |(old_index, new_index)|
        old_matched << old_index
        new_matched << new_index
      end

      # Lines that are not compared one to one: bodies of matched methods,
      # and whole added or removed methods with what goes with them.
      old_skipped = Array(Bool).new(@list_of_old_lines.size + 2, false)
      new_skipped = Array(Bool).new(@list_of_new_lines.size + 2, false)
      old_absorbable = Array(Bool).new(@list_of_old_lines.size + 2, false)
      new_absorbable = Array(Bool).new(@list_of_new_lines.size + 2, false)
      list_of_pairs.each do |(old_index, new_index)|
        list_of_old_spans[old_index].body_range.each { |line| old_skipped[line] = true }
        list_of_new_spans[new_index].body_range.each { |line| new_skipped[line] = true }
      end
      list_of_removed_ranges = [] of Range(Int32, Int32)
      list_of_old_spans.each_with_index do |span, index|
        next if old_matched.includes?(index)
        list_of_removed_ranges << mark_whole_def(span, @list_of_old_lines, old_skipped, old_absorbable)
      end
      list_of_new_spans.each_with_index do |span, index|
        next if new_matched.includes?(index)
        mark_whole_def(span, @list_of_new_lines, new_skipped, new_absorbable)
      end

      list_of_line_pairs = paired_outside_lines(old_skipped, new_skipped, old_absorbable, new_absorbable)

      edit_changes = [] of FileEdit::ChangedDef
      list_of_pairs.each do |(old_index, new_index)|
        old_span = list_of_old_spans[old_index]
        new_span = list_of_new_spans[new_index]
        old_body = old_span.body_range.map { |line| @list_of_old_lines[line - 1] }
        new_body = new_span.body_range.map { |line| @list_of_new_lines[line - 1] }
        if old_body == new_body
          offset = new_span.header_last_line - old_span.header_last_line
          old_span.body_range.each { |line| list_of_line_pairs << {line, line + offset} }
        else
          check_same_header(old_span, new_span)
          edit_changes << FileEdit::ChangedDef.new(@filename, old_span.a_def, new_span.a_def,
            old_span.first_line, old_span.column, old_span.body_range.begin, old_span.body_range.end)
        end
      end

      line_shift = line_shift_of(list_of_line_pairs)
      edit = FileEdit.new(@filename, line_shift, list_of_earlier_indexes)
      edit.list_of_changed_defs.concat(edit_changes)
      list_of_old_spans.each_with_index do |span, index|
        next if old_matched.includes?(index)
        edit.list_of_removed_defs << FileEdit::RemovedDef.new(@filename, span.a_def, span.list_of_scopes,
          span.first_line, span.column, span.first_line, span.end_line)
      end
      list_of_new_spans.each_with_index do |span, index|
        next if new_matched.includes?(index)
        edit.list_of_added_defs << FileEdit::AddedDef.new(@filename, span.a_def, span.list_of_scopes)
      end
      edit
    end

    # The methods of *text* that sit directly in the file, a class or a
    # module, in source order.
    private def spans_of(text : String) : Array(DefSpan)
      parser = @program.new_parser(text)
      parser.filename = @filename
      parser.wants_doc = @program.wants_doc?
      node = begin
        parser.parse
      rescue ex : CodeError
        raise Refusal.new("#{@filename} does not parse: #{ex.message}")
      end

      list_of_lines = text.split('\n')
      result = [] of DefSpan
      collect_defs(node, [] of ASTNode) do |a_def, list_of_scopes|
        result << span_of(a_def, list_of_scopes, list_of_lines)
      end
      result
    end

    private def collect_defs(node : ASTNode, list_of_scopes : Array(ASTNode), &block : Def, Array(ASTNode) ->) : Nil
      case node
      when Expressions
        node.expressions.each { |expression| collect_defs(expression, list_of_scopes, &block) }
      when ClassDef, ModuleDef
        collect_defs(node.body, list_of_scopes + [node.as(ASTNode)], &block)
      when VisibilityModifier
        collect_defs(node.exp, list_of_scopes, &block)
      when Def
        block.call(node, list_of_scopes)
      end
    end

    private def span_of(a_def : Def, list_of_scopes : Array(ASTNode), list_of_lines : Array(String)) : DefSpan
      location = a_def.location || raise Refusal.new("#{@filename}: method '#{a_def.name}' has no location")
      end_location = a_def.end_location || raise Refusal.new("#{@filename}: method '#{a_def.name}' has no end location")
      first_line = location.line_number
      header_last_line = first_line
      {a_def.name_location, a_def.return_type.try(&.end_location), a_def.block_arg.try(&.end_location)}.each do |header_location|
        header_last_line = {header_last_line, header_location.line_number}.max if header_location
      end
      a_def.args.each do |arg|
        arg.end_location.try { |arg_end| header_last_line = {header_last_line, arg_end.line_number}.max }
      end
      end_line = end_location.line_number
      # A method written on one line, or whose header reaches its `end`, has
      # no body lines; its whole text is compared as it stands.
      header_last_line = {header_last_line, end_line - 1}.min if end_line > first_line
      header_last_line = end_line if end_line == first_line

      key = String.build do |io|
        list_of_scopes.each do |scope|
          case scope
          when ClassDef  then io << scope.name
          when ModuleDef then io << scope.name
          end
          io << "::"
        end
        (first_line..header_last_line).each { |line| io << list_of_lines[line - 1]?.try(&.strip) << '\n' }
      end
      DefSpan.new(a_def, list_of_scopes, key, first_line, location.column_number, header_last_line, end_line)
    end

    # Pairs old and new methods with the same scopes and header text, in
    # order: the longest common subsequence after the common start and end.
    private def aligned(list_of_old : Array(DefSpan), list_of_new : Array(DefSpan)) : Array({Int32, Int32})
      result = [] of {Int32, Int32}
      start = 0
      while start < list_of_old.size && start < list_of_new.size && list_of_old[start].key == list_of_new[start].key
        result << {start, start}
        start += 1
      end
      old_end = list_of_old.size
      new_end = list_of_new.size
      list_of_tail = [] of {Int32, Int32}
      while old_end > start && new_end > start && list_of_old[old_end - 1].key == list_of_new[new_end - 1].key
        old_end -= 1
        new_end -= 1
        list_of_tail << {old_end, new_end}
      end

      old_count = old_end - start
      new_count = new_end - start
      if old_count > 0 && new_count > 0
        if old_count.to_i64 * new_count > 1_000_000
          raise Refusal.new("#{@filename}: too many methods changed places to compare")
        end
        lengths = Array.new(old_count + 1) { Array(Int32).new(new_count + 1, 0) }
        (old_count - 1).downto(0) do |old_position|
          (new_count - 1).downto(0) do |new_position|
            lengths[old_position][new_position] =
              if list_of_old[start + old_position].key == list_of_new[start + new_position].key
                lengths[old_position + 1][new_position + 1] + 1
              else
                {lengths[old_position + 1][new_position], lengths[old_position][new_position + 1]}.max
              end
          end
        end
        old_position = 0
        new_position = 0
        while old_position < old_count && new_position < new_count
          if list_of_old[start + old_position].key == list_of_new[start + new_position].key
            result << {start + old_position, start + new_position}
            old_position += 1
            new_position += 1
          elsif lengths[old_position + 1][new_position] >= lengths[old_position][new_position + 1]
            old_position += 1
          else
            new_position += 1
          end
        end
      end
      result.concat(list_of_tail.reverse!)
      result
    end

    # Marks the lines of a whole added or removed method as skipped: from
    # its first line, or the comment lines right above it, to its `end`; and
    # the blank lines right around that as absorbable. Returns the method's
    # own lines.
    private def mark_whole_def(span : DefSpan, list_of_lines : Array(String), skipped : Array(Bool), absorbable : Array(Bool)) : Range(Int32, Int32)
      first_line = span.first_line
      while first_line > 1 && list_of_lines[first_line - 2].lstrip.starts_with?('#') && !list_of_lines[first_line - 2].lstrip.starts_with?("#<")
        first_line -= 1
      end
      (first_line..span.end_line).each { |line| skipped[line] = true }
      line = first_line - 1
      while line >= 1 && list_of_lines[line - 1].blank?
        absorbable[line] = true
        line -= 1
      end
      line = span.end_line + 1
      while line <= list_of_lines.size && list_of_lines[line - 1].blank?
        absorbable[line] = true
        line += 1
      end
      first_line..span.end_line
    end

    # Pairs every line outside the skipped ones, old with new, requiring the
    # same text; blank lines next to an added or removed method may go
    # unpaired. Raises `Refusal` at the first line that differs.
    private def paired_outside_lines(old_skipped : Array(Bool), new_skipped : Array(Bool),
                                     old_absorbable : Array(Bool), new_absorbable : Array(Bool)) : Array({Int32, Int32})
      result = [] of {Int32, Int32}
      old_line = 1
      new_line = 1
      old_size = @list_of_old_lines.size
      new_size = @list_of_new_lines.size
      loop do
        while old_line <= old_size && old_skipped[old_line]
          old_line += 1
        end
        while new_line <= new_size && new_skipped[new_line]
          new_line += 1
        end
        old_done = old_line > old_size
        new_done = new_line > new_size
        break if old_done && new_done

        if !old_done && !new_done && @list_of_old_lines[old_line - 1] == @list_of_new_lines[new_line - 1]
          result << {old_line, new_line}
          old_line += 1
          new_line += 1
        elsif !new_done && new_absorbable[new_line]
          new_line += 1
        elsif !old_done && old_absorbable[old_line]
          old_line += 1
        else
          line = old_done ? old_size : old_line
          raise Refusal.new("#{@filename}:#{line} changed outside a method body")
        end
      end
      result
    end

    # The line shift that takes each paired old line to its new line. A
    # paired line that moves may not hold `__LINE__`: its value was fixed
    # when the old text was parsed.
    private def line_shift_of(list_of_line_pairs : Array({Int32, Int32})) : Location::LineShift
      list_of_line_pairs.sort_by!(&.[0])
      list_of_steps = [{1, 0}]
      list_of_line_pairs.each do |(old_line, new_line)|
        offset = new_line - old_line
        if offset != 0
          text = @list_of_old_lines[old_line - 1]
          if text.includes?("__LINE__") || text.includes?("__END_LINE__")
            raise Refusal.new("#{@filename}:#{old_line} uses __LINE__ and moves to line #{new_line}")
          end
        end
        list_of_steps << {old_line, offset} unless list_of_steps.last[1] == offset
      end
      Location::LineShift.new(list_of_steps)
    end

    # Whether the two definitions agree on everything but their bodies.
    private def check_same_header(old_span : DefSpan, new_span : DefSpan) : Nil
      old_def = old_span.a_def
      new_def = new_span.a_def
      same = old_def.name == new_def.name &&
             old_def.args == new_def.args &&
             old_def.receiver == new_def.receiver &&
             old_def.block_arg == new_def.block_arg &&
             old_def.return_type == new_def.return_type &&
             old_def.block_arity == new_def.block_arity &&
             old_def.macro_def? == new_def.macro_def? &&
             old_def.abstract? == new_def.abstract? &&
             old_def.splat_index == new_def.splat_index &&
             old_def.double_splat == new_def.double_splat &&
             old_def.free_vars == new_def.free_vars &&
             old_def.visibility == new_def.visibility &&
             old_def.uses_block_arg? == new_def.uses_block_arg? &&
             old_def.assigns_special_var? == new_def.assigns_special_var? &&
             old_def.calls_super? == new_def.calls_super? &&
             old_def.calls_initialize? == new_def.calls_initialize? &&
             old_def.calls_previous_def? == new_def.calls_previous_def? &&
             old_def.doc == new_def.doc &&
             old_span.column == new_span.column &&
             old_def.name_location.try(&.column_number) == new_def.name_location.try(&.column_number) &&
             old_def.end_location.try(&.column_number) == new_def.end_location.try(&.column_number)
      return if same
      raise Refusal.new("#{@filename}:#{old_span.first_line}: the header of method '#{old_def.name}' changed")
    end
  end
end
