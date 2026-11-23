module Crystal::StrictTool
  # Finds where the types and the `@[Override]` of one method plan go in the
  # source of its file. *ast_def* is the def as parsed from that source.
  class Editor
    # Words that may stand before `def` on its line.
    DEF_PREFIXES = {"private", "protected", "abstract"}

    def initialize(@source : SourceText, @ast_def : Def, @plan : MethodPlan)
    end

    # The insertions for the plan, or `nil` when a place to write one of its
    # types can't be found in the source.
    def insertions : Array(Insertion)?
      list = [] of Insertion
      @plan.arg_texts.each do |index, text|
        arg = @ast_def.args[index]? || return nil
        line, column = arg_name_end(arg) || return nil
        list << Insertion.new(line, column, " : #{text}")
      end
      if text = @plan.block_text
        block_arg = @ast_def.block_arg || return nil
        line, column = block_name_end(block_arg) || return nil
        list << Insertion.new(line, column, " : #{text}")
      end
      if text = @plan.return_text
        line, column = signature_end || return nil
        list << Insertion.new(line, column, " : #{text}")
      end
      if @plan.needs_override?
        list << (override_insertion || return nil)
      end
      list
    end

    # The position after the parameter's own name (`name`, `@name`, or the
    # internal name after an external one).
    private def arg_name_end(arg : Arg) : {Int32, Int32}?
      location = arg.location || return nil
      line, column = location.line_number, location.column_number
      return nil unless (char = @source.char_at(line, column)) && (char == '@' || char == '_' || char.letter?)
      end_line, end_column = @source.word_end(line, column)
      word = text_between(line, column, end_column)
      if word.starts_with?('@')
        return word.lstrip('@') == arg.name ? {end_line, end_column} : nil
      end
      if arg.external_name != arg.name
        return nil unless word == arg.external_name
        line, column = @source.skip_space(end_line, end_column, newlines: true)
        end_line, end_column = @source.word_end(line, column)
        word = text_between(line, column, end_column)
      end
      word == arg.name ? {end_line, end_column} : nil
    end

    private def block_name_end(block_arg : Arg) : {Int32, Int32}?
      location = block_arg.location || return nil
      line, column = location.line_number, location.column_number
      if @source.char_at(line, column) == '&'
        column += 1
        return {line, column} if block_arg.name.empty?
        line, column = @source.skip_space(line, column)
      end
      end_line, end_column = @source.word_end(line, column)
      text_between(line, column, end_column) == block_arg.name ? {end_line, end_column} : nil
    end

    # The position after the parameter list, or after the name when the
    # method has no parentheses.
    private def signature_end : {Int32, Int32}?
      location = @ast_def.name_location || return nil
      line, column = location.line_number, location.column_number
      name_end = column + @ast_def.name.size
      return nil unless text_between(line, column, name_end) == @ast_def.name
      after_name_line, after_name_column = @source.skip_space(line, name_end)
      if @source.char_at(after_name_line, after_name_column) == '('
        @source.after_closing_paren(after_name_line, after_name_column)
      else
        {line, name_end}
      end
    end

    private def override_insertion : Insertion?
      location = @ast_def.location || return nil
      line, column = location.line_number, location.column_number
      line_text = @source.lines[line - 1]? || return nil
      prefix = line_text[0, column - 1]
      words = prefix.split
      if words.all? { |word| DEF_PREFIXES.includes?(word) }
        indent = line_text[0, line_text.size - line_text.lstrip.size]
        Insertion.new(line, 1, "#{indent}@[Override]\n")
      else
        Insertion.new(line, column, "@[Override] ")
      end
    end

    private def text_between(line : Int32, from_column : Int32, to_column : Int32) : String
      line_text = @source.lines[line - 1]? || return ""
      line_text[from_column - 1, Math.max(0, to_column - from_column)]? || ""
    end
  end

  # A unified diff of two lists of lines.
  class LineDiff
    CONTEXT = 3

    # Above this many cells the diff shows the changed middle as one block.
    MAX_TABLE_CELLS = 25_000_000

    enum Kind
      Same
      Removed
      Added
    end

    record Change, kind : Kind, text : String, old_line : Int32, new_line : Int32

    def initialize(@old_lines : Array(String), @new_lines : Array(String))
    end

    def changes : Array(Change)
      prefix = 0
      while prefix < @old_lines.size && prefix < @new_lines.size && @old_lines[prefix] == @new_lines[prefix]
        prefix += 1
      end
      suffix = 0
      while suffix < @old_lines.size - prefix && suffix < @new_lines.size - prefix &&
            @old_lines[-1 - suffix] == @new_lines[-1 - suffix]
        suffix += 1
      end
      old_middle = @old_lines[prefix, @old_lines.size - prefix - suffix]
      new_middle = @new_lines[prefix, @new_lines.size - prefix - suffix]

      result = [] of Change
      prefix.times { |index| result << Change.new(Kind::Same, @old_lines[index], index, index) }
      middle_changes(old_middle, new_middle, prefix).each { |change| result << change }
      suffix.times do |offset|
        old_index = @old_lines.size - suffix + offset
        new_index = @new_lines.size - suffix + offset
        result << Change.new(Kind::Same, @old_lines[old_index], old_index, new_index)
      end
      result
    end

    private def middle_changes(old_middle : Array(String), new_middle : Array(String), start : Int32) : Array(Change)
      result = [] of Change
      if old_middle.size.to_i64 * new_middle.size > MAX_TABLE_CELLS
        old_middle.each_with_index { |text, index| result << Change.new(Kind::Removed, text, start + index, start) }
        new_middle.each_with_index { |text, index| result << Change.new(Kind::Added, text, start + old_middle.size, start + index) }
        return result
      end
      rows = old_middle.size + 1
      columns = new_middle.size + 1
      # lengths[i * columns + j]: longest common subsequence of old_middle[i..] and new_middle[j..].
      lengths = Array(Int32).new(rows * columns, 0)
      (old_middle.size - 1).downto(0) do |i|
        (new_middle.size - 1).downto(0) do |j|
          lengths[i * columns + j] = if old_middle[i] == new_middle[j]
                                       lengths[(i + 1) * columns + j + 1] + 1
                                     else
                                       Math.max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
                                     end
        end
      end
      i = 0
      j = 0
      while i < old_middle.size || j < new_middle.size
        if i < old_middle.size && j < new_middle.size && old_middle[i] == new_middle[j]
          result << Change.new(Kind::Same, old_middle[i], start + i, start + j)
          i += 1
          j += 1
        elsif i < old_middle.size && (j == new_middle.size || lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1])
          result << Change.new(Kind::Removed, old_middle[i], start + i, start + j)
          i += 1
        else
          result << Change.new(Kind::Added, new_middle[j], start + i, start + j)
          j += 1
        end
      end
      result
    end

    # Writes the hunks of the diff to *io*.
    def hunks(io : IO) : Nil
      list = changes
      changed = list.each_index.select { |position| !list[position].kind.same? }.to_a
      return if changed.empty?
      groups = [] of {Int32, Int32}
      changed.each do |position|
        from = Math.max(0, position - CONTEXT)
        to = Math.min(list.size - 1, position + CONTEXT)
        if (last = groups.last?) && from <= last[1] + 1
          groups[-1] = {last[0], to}
        else
          groups << {from, to}
        end
      end
      groups.each do |from, to|
        hunk = list[from..to]
        old_count = hunk.count { |change| !change.kind.added? }
        new_count = hunk.count { |change| !change.kind.removed? }
        old_start = hunk.first.old_line + (old_count > 0 ? 1 : 0)
        new_start = hunk.first.new_line + (new_count > 0 ? 1 : 0)
        io << "@@ -" << old_start << ',' << old_count << " +" << new_start << ',' << new_count << " @@\n"
        hunk.each do |change|
          marker = case change.kind
                   in .same?    then ' '
                   in .removed? then '-'
                   in .added?   then '+'
                   end
          io << marker << change.text << '\n'
        end
      end
    end
  end
end
