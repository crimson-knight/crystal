require "../../spec_helper"

private def var(name : String) : ASTNode
  Var.new(name)
end

private def names(nodes : Enumerable(ASTNode)) : Array(String)
  nodes.map(&.as(Var).name)
end

# Every `MetaVar` type inference still reaches from the typed def *typed_def*:
# the ones the def and its blocks own, and the ones the nodes of its body
# depend on.
private class MetaVarCollector < Visitor
  getter meta_vars = Set(MetaVar).new.compare_by_identity
  getter blocks = [] of Block

  def visit(node : ASTNode) : Bool
    collect(node)
    true
  end

  def visit(node : Call) : Bool
    collect(node)
    node.block.try { |block| blocks << block }
    true
  end

  def visit(node : Block) : Bool
    collect(node)
    node.vars.try &.each_value { |meta_var| collect(meta_var) }
    node.after_vars.try &.each_value { |meta_var| collect(meta_var) }
    true
  end

  private def collect(node : ASTNode) : Nil
    if node.is_a?(MetaVar)
      return unless meta_vars.add?(node)
    end
    node.dependencies.each { |dependency| collect(dependency) if dependency.is_a?(MetaVar) }
  end
end

private def semantic_without_release(code : String) : SemanticResult
  program = Program.new
  program.color = false
  program.release_inference_state = false
  program.define_crystal_constants
  node = parse(code).as(Expressions)
  node.expressions.unshift(Crystal::Require.new("primitives"))
  node = program.semantic(program.normalize(node))
  SemanticResult.new(program, node)
end

private def last_type(result : SemanticResult) : String
  result.node.as(Expressions).last.type.to_s
end

private def typed_def(result : SemanticResult, name : String) : Def
  result.program.def_instances.each_value do |typed_def|
    return typed_def if typed_def.name == name
  end
  fail "no typed def named #{name}"
end

private def collect_meta_vars(typed_def : Def) : MetaVarCollector
  collector = MetaVarCollector.new
  typed_def.body.accept(collector)
  typed_def.vars.try &.each_value { |meta_var| collector.visit(meta_var) }
  collector
end

describe "SmallNodeList#replace_first" do
  it "replaces an element in every position and keeps the others in place" do
    {1, 2, 4}.each do |size|
      size.times do |replaced|
        nodes = Array.new(size) { |index| var("n#{index}") }
        list = SmallNodeList.new.concat(nodes)
        list.replace_first(nodes[replaced], var("new")).should be_true
        expected = Array.new(size) { |index| index == replaced ? "new" : "n#{index}" }
        names(list).should eq(expected)
      end
    end
  end

  it "says so when the element is not there" do
    list = SmallNodeList.new.push(var("a")).push(var("b")).push(var("c"))
    list.replace_first(var("a"), var("new")).should be_false
    names(list).should eq(%w(a b c))
    SmallNodeList.new.replace_first(var("a"), var("new")).should be_false
  end
end

describe "ASTNode#splice_out_of_bindings" do
  it "makes the observers depend on the dependency, with the same types" do
    program = Program.new
    first_value = var("first_value")
    first_value.type = program.int32
    source = var("source")
    source.bind_to(first_value)
    middle = MetaVar.new("middle")
    middle.bind_to(source)
    first_reader = var("first")
    first_reader.bind_to(middle)
    second_reader = var("second")
    second_reader.bind_to(middle)

    middle.repeats_one_dependency?.should be_true
    middle.splice_out_of_bindings.should be_true

    middle.dependencies.empty?.should be_true
    first_reader.dependencies.first.should be(source)
    second_reader.dependencies.first.should be(source)

    # A later change of the source reaches both readers.
    wider = var("wider")
    wider.type = program.string
    source.bind_to(wider)
    first_reader.type.should eq(program.union_of(program.int32, program.string))
    second_reader.type.should eq(program.union_of(program.int32, program.string))
    middle.type.should eq(program.int32)
  end

  it "re-targets a type filter that read the spliced var" do
    program = Program.new
    first_value = var("first_value")
    first_value.type = program.union_of(program.int32, program.nil)
    source = var("source")
    source.bind_to(first_value)
    middle = MetaVar.new("middle")
    middle.bind_to(source)
    filtered = middle.filtered_by(TruthyFilter.instance)
    filtered.type.should eq(program.int32)

    middle.splice_out_of_bindings.should be_true
    filtered.dependencies.first.should be(source)

    wider = var("wider")
    wider.type = program.string
    source.bind_to(wider)
    filtered.type.should eq(program.union_of(program.int32, program.string))
  end

  it "leaves a var alone that does more than repeat one node" do
    program = Program.new
    source = var("source")
    source.type = program.int32
    other = var("other")
    other.type = program.string

    two_dependencies = MetaVar.new("two")
    two_dependencies.bind_to(source)
    two_dependencies.bind_to(other)
    two_dependencies.repeats_one_dependency?.should be_false

    frozen = MetaVar.new("frozen")
    frozen.freeze_type = program.int32
    frozen.bind_to(source)
    frozen.repeats_one_dependency?.should be_false

    kept = MetaVar.new("kept")
    kept.bind_to(source)
    kept.kept_by_visitor = true
    kept.repeats_one_dependency?.should be_false

    MetaVar.new("unbound").repeats_one_dependency?.should be_false
  end

  it "hands its place in a meta var's local vars to its observers" do
    program = Program.new
    source = var("source")
    source.type = program.int32
    meta_var = MetaVar.new("x")
    point_var = MetaVar.new("x")
    point_var.bind_to(source)
    reader = var("x")
    reader.bind_to(point_var)
    meta_var.add_local_var(point_var)
    meta_var.add_local_var(point_var)

    point_var.splice_out_of_bindings_leaving_observers_to(meta_var).should be_true

    # A closure captures the variable and assigns it: the reader gets the
    # cumulative type, as the point var would have.
    assigned_in_closure = var("assigned")
    assigned_in_closure.type = program.string
    meta_var.bind_to(source)
    meta_var.bind_to(assigned_in_closure)
    meta_var.mutably_closured = true
    meta_var.mark_as_closured
    reader.type.should eq(program.union_of(program.int32, program.string))
  end
end

describe "MainVisitor#release_inference_state" do
  it "drops the vars a call with a block wraps around untouched variables" do
    result = semantic(%(
      def each_one
        yield 1
      end

      def foo(a, b)
        c = a
        each_one { |x| x }
        each_one { |y| b }
        {a, b, c}
      end

      foo(1, "a")
      ), inject_primitives: true)

    foo = typed_def(result, "foo")
    collector = collect_meta_vars(foo)
    collector.blocks.size.should eq(2)
    collector.blocks.each(&.after_vars.should(be_nil))
    # What is left: the cumulative vars of the def and of its blocks, and
    # the argument vars. No var per variable per block call.
    collector.meta_vars.size.should be <= 10
  end

  it "keeps the var a block assigns, and types the code after the block with it" do
    assert_type(%(
      def each_one
        yield 1
      end

      def foo(a)
        b = a
        each_one { |x| b = "text" }
        b
      end

      foo(1)
      ), inject_primitives: true) { union_of(int32, string) }
  end

  # In these, `second` is typed while `first` has no type yet. `first` gets
  # `Int32 | Char` only after the visitor of `second` finished, so the body
  # of `second` is typed again through its edges and its calls.
  it "types a def again when a call in it gets a wider type later" do
    assert_type(%(
      def first(n)
        if n == 0
          1
        elsif n == 1
          'a'
        else
          second(n - 1)
        end
      end

      def second(n)
        value = first(n)
        copy = value
        if n == 5
          other = copy
        else
          other = copy
        end
        other
      end

      second(3)
      ), inject_primitives: true) { union_of(int32, char) }
  end

  it "types a call with a block again when its argument gets a wider type later" do
    assert_type(%(
      def pass(value)
        copy = value
        yield copy
      end

      def identity(value)
        value
      end

      def first(n)
        if n == 0
          1
        elsif n == 1
          'a'
        else
          second(n - 1)[0]
        end
      end

      def second(n)
        outer = first(n)
        pass(outer) do |element|
          inner = identity(element)
          {inner, outer}
        end
      end

      second(3)
      ), inject_primitives: true) { tuple_of([union_of(int32, char), union_of(int32, char)]) }
  end

  it "types a filtered variable, a loop and a block again when the variable gets a wider type later" do
    assert_type(%(
      def each_one
        yield 1
      end

      def first(n)
        if n == 0
          1
        elsif n == 1
          nil
        else
          second(n - 1)
        end
      end

      def second(n)
        current = first(n)
        count = 0
        while count < 2
          each_one { |x| count += x }
          if current
            current = current + 1
          end
        end
        current
      end

      second(3)
      ), inject_primitives: true) { nilable int32 }
  end

  it "types a captured block whose call is typed after its def's visitor finished" do
    assert_type(%(
      def capture(value, &block : -> Int32)
        block
      end

      def first(n)
        if n == 0
          1
        else
          second(n - 1)
        end
      end

      def second(n)
        local = 2
        capture(first(n)) { local }.call
      end

      first(3)
      ), inject_primitives: true) { int32 }
  end

  it "binds the reads in a typed block to a variable a later closure assigns" do
    assert_type(%(
      def each_one
        yield 1
      end

      def foo
        x = 1
        seen = each_one { |y| x }
        change = -> { x = "text" }
        change.call
        {seen, x}
      end

      foo
      ), inject_primitives: true) { tuple_of([union_of(int32, string), union_of(int32, string)]) }
  end

  it "keeps the variables of a visitor that types a lib call" do
    assert_type(%(
      lib LibFoo
        fun foo(x : Int32*) : Int32
      end

      def each_one
        yield 1
      end

      def foo
        each_one do |x|
          LibFoo.foo(out value)
          value
        end
      end

      foo
      ), inject_primitives: true) { int32 }
  end

  it "types the same with the release turned off" do
    code = %(
      def each_one
        yield 1
      end

      def foo(a)
        b = a
        each_one { |x| b = x if b.is_a?(String) }
        while b.is_a?(Int32)
          b = nil
        end
        b
      end

      foo("text")
      )
    released = semantic(code, inject_primitives: true)
    kept = semantic_without_release(code)

    last_type(kept).should eq(last_type(released))
    kept_count = collect_meta_vars(typed_def(kept, "foo")).meta_vars.size
    left_count = collect_meta_vars(typed_def(released, "foo")).meta_vars.size
    left_count.should be < kept_count
  end

  # `second` is typed, and its visitor finished, before `first` has a type.
  # The block of `capture` becomes a proc literal only then, and assigns `x`:
  # every read of `x` in `second`, also the ones that went through vars that
  # were spliced out in the meantime, must get the type the closure assigns.
  it "binds reads that went through spliced vars when a closure typed late assigns the variable" do
    code = %(
      def capture(value, &block : -> Int32)
        block
      end

      def each_one
        yield 1
      end

      def first(n)
        if n == 0
          1
        else
          second(n - 1)[0]
        end
      end

      def second(n)
        x = 2
        count = 0
        in_loop = 0
        while count < 1
          in_loop = x
          count += 1
        end
        in_block = each_one { |y| x }
        after = x
        capture(first(n)) do
          x = "text"
          4
        end.call
        {in_loop, in_block, after}
      end

      second(3)
      )
    released = semantic(code, inject_primitives: true)
    kept = semantic_without_release(code)

    last_type(released).should eq(last_type(kept))
    last_type(released).should eq("Tuple(Int32 | String, Int32 | String, Int32 | String)")
  end
end

describe "MainVisitor#release_local_var_lists" do
  it "drops the local var lists of a def that has no block or proc" do
    result = semantic(%(
      def plain(a)
        b = a
        c = b
        b = c
        b
      end

      plain(1)
      ), inject_primitives: true)
    typed_def(result, "plain").vars.not_nil!.each_value(&.local_vars?.should(be_false))
    result.program.inference_release_stats.dropped_local_var_lists.should be > 0
  end

  it "keeps the local var lists of a def with a proc literal" do
    result = semantic(%(
      def with_proc(a)
        b = a
        f = -> { 1 }
        f.call
        b
      end

      with_proc(1)
      ), inject_primitives: true)
    typed_def(result, "with_proc").vars.not_nil!["b"].local_vars?.should be_true
  end

  # The first proc literal is typed (and its visitor finishes) before the
  # second one closures `x`: the earlier reads of `x` must still get the
  # type the closure assigns.
  it "binds earlier reads when a later proc literal of the same def closures the variable" do
    code = %(
      def foo
        x = 1
        y = x
        first = -> { 2 }
        first.call
        change = -> { x = "text" }
        change.call
        {y, x}
      end

      foo
      )
    released = semantic(code, inject_primitives: true)
    kept = semantic_without_release(code)

    last_type(released).should eq(last_type(kept))
    last_type(released).should eq("Tuple(Int32 | String, Int32 | String)")
  end

  it "types the same with the lists kept" do
    code = %(
      def callee(n)
        n > 0 ? 1 : "one"
      end

      def plain(n)
        value = callee(n)
        other = value
        while other.is_a?(Int32)
          other = nil
        end
        {value, other}
      end

      plain(1)
      )
    program = Program.new
    program.release_local_var_lists = false
    program.color = false
    node = parse(code).as(Expressions)
    node.expressions.unshift(Crystal::Require.new("primitives"))
    node = program.semantic(program.normalize(node))
    kept = SemanticResult.new(program, node)
    released = semantic(code, inject_primitives: true)

    last_type(released).should eq(last_type(kept))
  end
end

describe "Call#recalculate" do
  # Every new instance of `Gen` makes the call on `Base+` look its matches up
  # again: first with the same result, then with one more target def.
  it "depends on exactly its target defs after recalculations that find the same and then more defs" do
    result = semantic(%(
      class Base
        def foo
          1
        end
      end

      class Gen(T) < Base
        def foo
          'a'
        end
      end

      class Other(T) < Base
      end

      x = Gen(Int32).new || Base.new
      r = x.foo
      Other(Int32).new
      Gen(String).new
      Other(String).new
      r
      ), inject_primitives: true)

    result.node.as(Expressions).last.type.to_s.should eq("(Char | Int32)")

    assign = result.node.as(Expressions).expressions.find! { |node| node.is_a?(Assign) && node.target.as?(Var).try(&.name) == "r" }
    call = assign.as(Assign).value.as(Call)
    target_defs = call.target_defs.not_nil!
    target_defs.map(&.owner.to_s).sort!.should eq(["Base+", "Gen(Int32)", "Gen(String)"])
    call.dependencies.to_a.should eq(target_defs.map(&.as(ASTNode)))
    call.keeps_target_defs_bound?.should be_false
  end
end
