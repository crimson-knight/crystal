require "../../spec_helper"

# The proc literals of a typed program, in source order.
private class ProcLiteralCollector < Visitor
  getter list_of_proc_literals = [] of ProcLiteral

  def visit(node : ProcLiteral) : Bool
    @list_of_proc_literals << node
    true
  end

  def visit(node : ASTNode) : Bool
    true
  end
end

private def proc_literals(result : SemanticResult) : Array(ProcLiteral)
  collector = ProcLiteralCollector.new
  result.node.accept collector
  collector.list_of_proc_literals
end

private def var_names(proc_literal : ProcLiteral) : Array(String)
  proc_literal.def.vars.not_nil!.keys.sort
end

describe "MainVisitor#trim_proc_literal_vars" do
  it "keeps a typed proc literal's own, closured and named variables, and drops the rest" do
    result = semantic(%(
      unrelated = 1
      captured = 2
      other = 3
      handler = ->(x : Int32) { y = x + captured; y }
      handler.call(1)
      ), inject_primitives: true)
    proc_literal = proc_literals(result).first
    names = var_names(proc_literal)
    names.should contain("x")
    names.should contain("y")
    names.should contain("captured")
    names.should_not contain("unrelated")
    names.should_not contain("other")
    names.should_not contain("handler")
  end

  it "keeps the whole copy with CRYSTAL_TRIM_PROC_LITERAL_VARS=0" do
    program = Program.new
    program.color = false
    program.trims_proc_literal_vars = false
    program.define_crystal_constants
    node = parse(%(
      unrelated = 1
      handler = ->(x : Int32) { x }
      handler.call(1)
      )).as(Expressions)
    node.expressions.unshift(Crystal::Require.new("primitives"))
    node = program.semantic(program.normalize(node))
    var_names(proc_literals(SemanticResult.new(program, node)).first).should contain("unrelated")
  end

  it "keeps every variable when the body holds macro code" do
    result = semantic(%(
      unrelated = 1
      handler = ->(x : Int32) { {% if true %} x {% end %} }
      handler.call(1)
      ), inject_primitives: true)
    var_names(proc_literals(result).first).should contain("unrelated")
  end

  it "gives each proc literal in a long scope only what it uses" do
    code = String.build do |io|
      # Like Amber's routes: each entry assigns fresh variables and makes a
      # proc literal that reads none of them.
      40.times { |index| io << "value_#{index} = #{index}\nhandler_#{index} = ->(x : Int32) { x + 1 }\n" }
      io << "handler_39.call(1)\n"
    end
    result = semantic(code, inject_primitives: true)
    list_of_proc_literals = proc_literals(result)
    list_of_proc_literals.size.should eq(40)
    list_of_proc_literals.each do |proc_literal|
      var_names(proc_literal).should eq(["x"])
    end
  end
end
