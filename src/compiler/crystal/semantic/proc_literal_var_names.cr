module Crystal
  # The names of the local variables a proc literal's body mentions, for
  # `MainVisitor#trim_proc_literal_vars`. `nil` when the body holds macro
  # code, whose expansion may mention any name: then nothing is trimmed.
  class ProcLiteralVarNames < Visitor
    getter collection_of_names = Set(String).new
    getter? has_macro_code = false

    def self.collect(body : ASTNode) : Set(String)?
      visitor = new
      body.accept visitor
      visitor.has_macro_code? ? nil : visitor.collection_of_names
    end

    def visit(node : Var) : Bool
      @collection_of_names << node.name
      true
    end

    def visit(node : MacroExpression | MacroIf | MacroFor | MacroVerbatim | MacroLiteral) : Bool
      @has_macro_code = true
      false
    end

    def visit(node : ASTNode) : Bool
      !@has_macro_code
    end
  end
end
