module Crystal::InferReuse
  # An edit of a file that holds only top-level code, such as the routes of
  # an Amber app (`config/routes.cr`): calls, blocks and local variables of
  # blocks, and no definitions.
  #
  # `FileEdit` accepts only edits inside method bodies; an edit anywhere in
  # such a file typed the whole program again (about 160 s in an Amber app
  # of 300 resources, for one new route). Instead, the kept program types
  # the new text of the file alone, as type inference types any top-level
  # code, and the typed file takes the place of the old one in the program.
  #
  # Both texts must define nothing (no type, method, macro, constant, class
  # or global variable, `require` or `include`), the file may have no
  # variables at its top level (their types would mix with the old ones),
  # and no macro of the kept build may have read the file's lines or listed
  # methods from inside it. Everything else the retyper checks for an edit
  # (the type of every re-typed method, no new class variable initializers)
  # holds as well.
  class TopLevelEdit
    getter filename : String
    getter text : String

    def initialize(@filename : String, @text : String)
    end

    # Why the file named *filename* cannot be typed again on its own in the
    # kept program, or `nil` when it can.
    def self.refusal_reason(program : Program, main_node : ASTNode, record : SourceRecord, filename : String) : String?
      place = NewFile.file_node_place(main_node, filename) || return "its typed code is not in the program"
      expressions, index = place
      old_file_node = expressions.expressions[index].as(FileNode)
      if reason = DeclarationFinder.reason(old_file_node.node)
        return reason
      end
      if (file_module = program.file_modules[filename]?) && (vars = file_module.vars?) && !vars.empty?
        return "it has variables at its top level"
      end
      return "a macro read the line number of one of its lines" if record.line_reads_by_filename.has_key?(filename)
      if record.list_of_method_list_expansions.any? { |expansion| expansion.site.try(&.expanded_location).try(&.filename) == filename }
        return "a macro in it listed methods"
      end
      nil
    end

    # Types the new text and puts it in the place of the old file in
    # *main_node*.
    def retype(program : Program, main_node : ASTNode) : Nil
      parser = program.new_parser(@text)
      parser.filename = @filename
      parser.wants_doc = program.wants_doc?
      parsed = begin
        parser.parse
      rescue ex : CodeError
        refuse("does not parse: #{ex.message}")
      end
      node = program.normalize(parsed)
      if reason = DeclarationFinder.reason(node)
        refuse(reason)
      end
      node.accept TopLevelVisitor.new(program)
      # Macros at the top level expanded now; their code may define things.
      if reason = DeclarationFinder.reason(node)
        refuse(reason)
      end

      typed_file_node = program.visit_main(FileNode.new(node, @filename), cleanup: true)
      place = NewFile.file_node_place(main_node, @filename) || refuse("has no typed code in the program")
      expressions, index = place
      expressions.expressions[index] = typed_file_node
    end

    private def refuse(why : String) : NoReturn
      raise Refusal.new("top-level code of #{@filename} #{why}")
    end

    # Finds what top-level code must not hold to be typed again alone.
    class DeclarationFinder < Visitor
      getter reason : String?

      def self.reason(node : ASTNode) : String?
        finder = new
        node.accept finder
        finder.reason
      end

      def visit(node : ASTNode) : Bool
        @reason.nil?
      end

      def visit(node : ClassDef | ModuleDef | EnumDef | LibDef | FunDef | Def | Macro | Alias | AnnotationDef |
                       Require | FileNode | Include | Extend | VisibilityModifier | TypeDef | CStructOrUnionDef) : Bool
        @reason ||= "holds a #{node.class_desc}"
        false
      end

      def visit(node : Assign | OpAssign) : Bool
        target = node.target
        @reason ||= "assigns #{target}" if target.is_a?(Path | ClassVar | Global)
        @reason.nil?
      end

      def visit(node : TypeDeclaration) : Bool
        var = node.var
        @reason ||= "declares #{var}" if var.is_a?(ClassVar | Global)
        @reason.nil?
      end

      # A proc's body is code like any other; its def is no definition.
      def visit(node : ProcLiteral) : Bool
        node.def.body.accept self
        false
      end

      def visit(node : Call) : Bool
        if expanded = node.expanded
          expanded.accept self
        end
        @reason.nil?
      end

      def visit(node : MacroExpression | MacroIf | MacroFor | MacroLiteral | MacroVerbatim) : Bool
        @reason ||= "holds macro code"
        false
      end
    end
  end
end
