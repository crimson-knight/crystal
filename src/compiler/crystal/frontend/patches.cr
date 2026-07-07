# Workarounds needed only for the frontend-only (-Dwithout_llvm) build.
#
# ROOT CAUSE (BREAK A-1, classification: host-compiler overload-ordering):
# Crystal's overload registration order depends on which classes are defined
# at `def`-registration time. When the compiler sources are required in a
# different order than src/compiler/requires.cr (as a frontend-only subset
# necessarily does — it excludes command/codegen), some multi-dispatch sites
# on `ASTNode+` either fail to type-check ("expected argument #1 ... not
# Crystal::ASTNode" even when the expected list covers every concrete
# subclass) or, worse, silently dispatch to catch-alls at runtime.
#
# One instance was fixed properly: `require "./crystal/semantic"` must come
# BEFORE `require "./crystal/macros/*"` (see frontend_main.cr), otherwise the
# macro interpreter's union overload (macros/interpreter.cr:746) referencing
# semantic/ast.cr classes (TypeNode, MacroId) is mis-ordered and every macro
# `flag?(...)` evaluation dies with "can't execute SymbolLiteral in a macro".
#
# The remaining sites below could not be fixed by require reordering within
# the subset; they get explicit, runtime-unreachable fallback definitions so
# the type checker accepts the dispatch. Verified against the full compiler:
# every concrete ASTNode subclass in the subset has its own specific overload
# for each of these methods, so these fallbacks never fire for well-formed
# ASTs (spot-checked at runtime with sizeof/offsetof/macro-heavy programs).
{% raise "patches.cr is only for -Dwithout_llvm builds" unless flag?(:without_llvm) %}

module Crystal
  abstract class ASTNode
    # `Crystal::ASTNode+#clone` fails with "undefined local variable or
    # method 'clone_without_location' for Crystal::ASTNode" without this.
    def clone_without_location
      raise "BUG: clone_without_location called on abstract ASTNode (#{class_desc})"
    end
  end

  class Transformer
    # `Crystal::ASTNode+#transform(Crystal::Normalizer)` fails at
    # syntax/transformer.cr:7 without this. Identity fallback mirrors the
    # playground instrumentor's untyped catch-all.
    def transform(node : ASTNode)
      node
    end
  end

  class ToSVisitor
    # `visitor.visit self` at syntax/visitor.cr:27 fails for ToSVisitor
    # without this.
    def visit(node : ASTNode)
      @str << "#<"
      @str << node.class_desc
      @str << '>'
      false
    end
  end
end
