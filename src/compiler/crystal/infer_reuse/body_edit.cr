module Crystal::InferReuse
  # Raised when a build cannot reuse the kept program; the message says why
  # and the build types the whole program instead.
  class Refusal < Exception
  end

  # Compares the old and new text of one source file and finds the methods
  # whose bodies changed. It accepts an edit only when every changed line is
  # strictly inside the body of a method that sits directly in the file, a
  # class or a module (not in a macro, a macro call or a method), the file
  # keeps its line count, and every method keeps its place and its header.
  # Every other part of the file, comments included, must read the same, so
  # every node outside those bodies keeps its location.
  module BodyEdit
    # A method whose body changed: its definition as parsed from the old and
    # from the new text.
    record ChangedDef, filename : String, old_def : Def, new_def : Def

    def self.compare(program : Program, filename : String, old_text : String, new_text : String) : Array(ChangedDef)
      list_of_old_lines = old_text.split('\n')
      list_of_new_lines = new_text.split('\n')
      unless list_of_old_lines.size == list_of_new_lines.size
        raise Refusal.new("#{filename} has #{list_of_new_lines.size} lines, it had #{list_of_old_lines.size}")
      end

      old_def_by_position = def_by_position(program, filename, old_text)
      new_def_by_position = def_by_position(program, filename, new_text)
      unless old_def_by_position.keys == new_def_by_position.keys
        raise Refusal.new("#{filename}: a method was added, removed or moved")
      end

      changed_positions = Set({Int32, Int32}).new
      list_of_old_lines.each_with_index do |old_line, index|
        next if old_line == list_of_new_lines[index]
        line_number = index + 1
        position = body_position_holding(old_def_by_position, line_number) ||
                   raise Refusal.new("#{filename}:#{line_number} changed outside a method body")
        changed_positions << position
      end

      changed_positions.map do |position|
        old_def = old_def_by_position[position]
        new_def = new_def_by_position[position]
        unless same_header?(old_def, new_def)
          raise Refusal.new("#{filename}:#{position[0]}: the header of method '#{old_def.name}' changed")
        end
        ChangedDef.new(filename, old_def, new_def)
      end
    end

    # The methods of *text* that sit directly in the file, a class or a
    # module, by line and column.
    private def self.def_by_position(program : Program, filename : String, text : String) : Hash({Int32, Int32}, Def)
      parser = program.new_parser(text)
      parser.filename = filename
      parser.wants_doc = program.wants_doc?
      node = begin
        parser.parse
      rescue ex : CodeError
        raise Refusal.new("#{filename} does not parse: #{ex.message}")
      end

      result = {} of {Int32, Int32} => Def
      collect_defs(node) do |a_def|
        location = a_def.location || raise Refusal.new("#{filename}: method '#{a_def.name}' has no location")
        result[{location.line_number, location.column_number}] = a_def
      end
      result
    end

    private def self.collect_defs(node : ASTNode, &block : Def ->) : Nil
      case node
      when Expressions
        node.expressions.each { |expression| collect_defs(expression, &block) }
      when ClassDef
        collect_defs(node.body, &block)
      when ModuleDef
        collect_defs(node.body, &block)
      when VisibilityModifier
        collect_defs(node.exp, &block)
      when Def
        block.call(node)
      end
    end

    # The method whose body (the lines after its header and before its
    # `end`) holds *line_number*.
    private def self.body_position_holding(def_by_position : Hash({Int32, Int32}, Def), line_number : Int32) : {Int32, Int32}?
      def_by_position.each do |position, a_def|
        first_line, last_line = body_lines(a_def) || next
        return position if first_line <= line_number <= last_line
      end
      nil
    end

    # The first and last line strictly inside *a_def*'s body, or `nil` for a
    # method without lines between its header and its `end`.
    def self.body_lines(a_def : Def) : {Int32, Int32}?
      location = a_def.location || return nil
      end_location = a_def.end_location || return nil
      header_last_line = location.line_number
      if body_location = a_def.body.location
        header_last_line = {header_last_line, body_location.line_number - 1}.max
      end
      first_line = header_last_line + 1
      last_line = end_location.line_number - 1
      first_line <= last_line ? {first_line, last_line} : nil
    end

    # Whether the two definitions agree on everything but their bodies.
    private def self.same_header?(old_def : Def, new_def : Def) : Bool
      old_def.name == new_def.name &&
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
        old_def.end_location == new_def.end_location &&
        old_def.name_location == new_def.name_location &&
        old_def.body.location.try(&.line_number) == new_def.body.location.try(&.line_number)
    end
  end
end
