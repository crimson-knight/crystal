require "../../spec_helper"

private def new_node(name : String) : ASTNode
  Var.new(name)
end

private def names(list : SmallNodeList) : Array(String)
  list.map(&.as(Var).name)
end

describe "SmallNodeList" do
  it "takes one pointer" do
    sizeof(SmallNodeList).should eq(8)
  end

  it "holds one element inline, two in a pair, and three or more in an array" do
    list = SmallNodeList.new.push(new_node("a"))
    list.census_allocation.should be_nil
    list = list.push(new_node("b"))
    list.census_allocation.should be_a(SmallNodeList::NodePair)
    list = list.push(new_node("c"))
    list.census_allocation.should be_a(Array(ASTNode))
    list = list.reject!(&.as(Var).name.==("b"))
    list.census_allocation.should be_a(SmallNodeList::NodePair)
    names(list).should eq(%w(a c))
  end

  it "yields elements pushed while iterating a list of one" do
    list = SmallNodeList.new.push(new_node("a"))
    pointer = pointerof(list)
    seen = [] of String
    pointer.value.each do |node|
      seen << node.as(Var).name
      pointer.value.push(new_node("b")) if seen.size == 1
      pointer.value.push(new_node("c")) if seen.size == 2
    end
    seen.should eq(%w(a b c))
  end

  it "keeps insertion order across the inline slots and the array" do
    list = SmallNodeList.new
    list.empty?.should be_true
    list.size.should eq(0)

    %w(a b c d).each_with_index do |name, index|
      list = list.push(new_node(name))
      list.size.should eq(index + 1)
    end

    names(list).should eq(%w(a b c d))
    list.first.as(Var).name.should eq("a")
    list.empty?.should be_false
  end

  it "rejects elements from every position" do
    nodes = %w(a b c d).map { |name| new_node(name) }

    {0, 1, 2, 3}.each do |removed|
      list = SmallNodeList.new.concat(nodes)
      list = list.reject!(&.same?(nodes[removed]))
      names(list).should eq(%w(a b c d).reject { |name| name == nodes[removed].as(Var).name })
    end

    list = SmallNodeList.new.concat(nodes)
    list = list.reject! { true }
    list.size.should eq(0)

    list = SmallNodeList.new.push(nodes[0]).push(nodes[1])
    list = list.reject!(&.same?(nodes[0]))
    names(list).should eq(%w(b))
  end

  it "yields elements pushed while iterating" do
    list = SmallNodeList.new.push(new_node("a")).push(new_node("b"))
    pointer = pointerof(list)
    seen = [] of String
    pointer.value.each do |node|
      seen << node.as(Var).name
      pointer.value.push(new_node("c")) if seen.size == 2
    end
    seen.should eq(%w(a b c))
  end
end

describe "MetaVars" do
  it "is a 24-byte object" do
    instance_sizeof(MetaVars).should eq(24)
  end

  it "keeps insertion order and finds names by content" do
    vars = MetaVars.new
    vars.empty?.should be_true
    vars["a"]?.should be_nil

    a = MetaVar.new("a")
    b = MetaVar.new("b")
    vars["a"] = a
    vars["b"] = b
    replacement = MetaVar.new("a")
    vars[String.build { |io| io << 'a' }] = replacement

    vars.size.should eq(2)
    vars.keys.should eq(%w(a b))
    vars["a"].should be(replacement)
    vars.has_key?("b").should be_true
    vars.has_key?("c").should be_false
    vars.last_key.should eq("b")
    expect_raises(KeyError) { vars["c"] }
  end

  it "behaves the same below and above the flat buffer's limit" do
    {3, 15, 16, 40}.each do |count|
      vars = MetaVars.new
      metas = Array.new(count) { |index| MetaVar.new("v#{index}") }
      metas.each { |meta| vars[meta.name] = meta }

      vars.size.should eq(count)
      vars.keys.should eq(metas.map(&.name))
      vars.values.should eq(metas)
      vars.to_a.should eq(metas.map { |meta| {meta.name, meta} })

      copy = vars.dup
      copy.delete("v1").should be(metas[1])
      copy.delete("missing").should be_nil
      copy.size.should eq(count - 1)
      copy.keys.should eq(metas.map(&.name).reject("v1"))
      vars.size.should eq(count)
      vars["v1"].should be(metas[1])
    end
  end

  it "yields variables added while iterating" do
    vars = MetaVars{"a" => MetaVar.new("a")}
    seen = [] of String
    vars.each do |name, _|
      seen << name
      vars["b"] = MetaVar.new("b") if seen.size == 1
    end
    seen.should eq(%w(a b))
  end
end

describe "ASTNode memory layout" do
  it "keeps the most common nodes inside their collector cells" do
    # The collector adds one byte to every allocation, so a node stays in a
    # cell of 16 * n bytes while its instance size is at most 16 * n - 8.
    instance_sizeof(Var).should be <= 72
    instance_sizeof(MetaVar).should be <= 88
    instance_sizeof(Crystal::Path).should be <= 88
    instance_sizeof(Call).should be <= 136
    instance_sizeof(Def).should be <= 200
  end

  it "stores flags without disturbing each other" do
    path = Crystal::Path.new(["Foo"], true)
    path.global?.should be_true
    path.visibility.should eq(Visibility::Public)
    path.visibility = Visibility::Private
    path.global?.should be_true
    path.visibility.should eq(Visibility::Private)
    path.global = false
    path.visibility.should eq(Visibility::Private)
    path.clone.global?.should be_false

    meta_var = MetaVar.new("a")
    meta_var.assigned_to = true
    meta_var.mutably_closured = true
    meta_var.nil_if_read?.should be_false
    meta_var.closured?.should be_false
    meta_var.assigned_to?.should be_true
    meta_var.assigned_to = false
    meta_var.mutably_closured?.should be_true
  end

  it "allocates a call's rare fields only when one is set" do
    call = Call.new(nil, "foo")
    call.named_args.should be_nil
    call.block_arg.should be_nil
    call.expanded.should be_nil
    call.uses_with_scope?.should be_false
    call.named_args = nil
    call.uses_with_scope = false
    call.@rare_fields.should be_nil

    call.named_args = [NamedArgument.new("x", NilLiteral.new)]
    call.@rare_fields.should_not be_nil
    call.clone.named_args.not_nil!.size.should eq(1)
    call.should eq(call.clone)
  end

  it "keeps a def's rarely set fields through a clone" do
    a_def = Def.new("foo", [Arg.new("x")], receiver: Var.new("self"), splat_index: 0, free_vars: ["T"])
    a_def.original_name = "bar"
    copy = a_def.clone
    copy.receiver.should eq(Var.new("self"))
    copy.splat_index.should eq(0)
    copy.free_vars.should eq(["T"])
    copy.original_name.should eq("bar")
    Def.new("foo").@rare_fields.should be_nil
    Def.new("foo").original_name.should eq("foo")
  end

  it "stores one target def without an array and several in one" do
    call = Call.new(nil, "foo")
    call.target_defs.should be_nil

    first = Def.new("foo")
    second = Def.new("foo")
    call.target_defs = [first]
    call.@target_defs.should be(first)
    call.target_def.should be(first)
    call.target_defs.should eq([first])

    call.target_defs = [first, second]
    seen = [] of Def
    call.each_target_def { |target_def| seen << target_def }
    seen.should eq([first, second])
    expect_raises(Exception, "2 target defs") { call.target_def }
  end

  it "shares a def's signature nodes with its typed copy" do
    result = semantic(%(
      def foo(x : Int32, y = 2) : Int32
        x + y
      end

      foo(1)
      foo(1, 3)
      ), inject_primitives: true)
    untyped_def = result.program.lookup_first_def("foo", false).not_nil!
    typed_def = result.program.def_instances.values.find! { |a_def| a_def.name == "foo" && a_def.args.size == 2 }
    typed_def.should_not be(untyped_def)
    typed_def.body.should_not be(untyped_def.body)
    typed_def.return_type.should be(untyped_def.return_type)
    typed_def.args[0].restriction.should be(untyped_def.args[0].restriction)
    typed_def.args[1].default_value.should be(untyped_def.args[1].default_value)
    typed_def.args.each(&.type.should(eq(result.program.int32)))
    untyped_def.args.each(&.type?.should(be_nil))
  end

  it "keeps doc comments on variables when docs are enabled" do
    node = parse("lib LibFoo\n  struct Bar\n    # The x.\n    x : Int32\n  end\nend", wants_doc: true)
    declaration = node.as(LibDef).body.as(CStructOrUnionDef).body.as(TypeDeclaration)
    var = declaration.var.as(Var)
    var.doc.should eq("The x.")
    var.clone.doc.should eq("The x.")
    var.should eq(Var.new("x"))
    Var.new("x").doc.should be_nil
  end
end

describe "Location" do
  it "is one word that keeps the filename, the line and the column" do
    sizeof(Location).should eq(8)

    location = Location.new("foo.cr", 12, 34)
    location.filename.should eq("foo.cr")
    location.line_number.should eq(12)
    location.column_number.should eq(34)
    location.to_s.should eq("foo.cr:12:34")

    without_filename = Location.new(nil, 0, 0)
    without_filename.filename.should be_nil
    without_filename.bits.should_not eq(0)
  end

  it "round-trips through a node, with zero standing for no location" do
    node = Var.new("a")
    node.location.should be_nil
    node.end_location.should be_nil

    location = Location.new("foo.cr", 1, 2)
    node.location = location
    node.end_location = Location.new("foo.cr", 1, 3)
    node.location.should eq(location)
    node.end_location.not_nil!.column_number.should eq(3)

    copy = Var.new("b").at(node)
    copy.location.should eq(location)
    copy.end_location.should eq(node.end_location)

    node.location = nil
    node.location.should be_nil
    Location.from_bits?(0_u64).should be_nil
  end

  it "compares and hashes by position" do
    first = Location.new(String.build { |io| io << "foo.cr" }, 3, 4)
    second = Location.new("foo.cr", 3, 4)
    first.should eq(second)
    first.hash.should eq(second.hash)
    first.should_not eq(Location.new("bar.cr", 3, 4))
    (first < Location.new("foo.cr", 3, 5)).should be_true
    (Location.new("foo.cr", 3, 4) <=> Location.new("bar.cr", 3, 4)).should be_nil
  end

  it "keeps lines and columns that do not fit the word" do
    {Location.new("foo.cr", 5_000_000, 7), Location.new("foo.cr", 7, 70_000), Location.new("foo.cr", -1, -1)}.each do |location|
      location.filename.should eq("foo.cr")
      Location.from_bits?(location.bits).should eq(location)
    end

    wide = Location.new("foo.cr", 7, 70_000)
    wide.line_number.should eq(7)
    wide.column_number.should eq(70_000)
    wide.should eq(Location.new("foo.cr", 7, 70_000))
    wide.hash.should eq(Location.new("foo.cr", 7, 70_000).hash)
    wide.should_not eq(Location.new("foo.cr", 7, 70_001))
  end

  it "points at the virtual file of a macro expansion while the program lives" do
    result = semantic(%(
      macro define_foo
        def foo
          1
        end
      end

      define_foo
      foo
      ))
    program = result.program
    program.virtual_files.size.should be > 0

    filename = program.lookup_first_def("foo", false).not_nil!.location.not_nil!.filename
    filename.should be_a(VirtualFile)
    program.virtual_files.should contain(filename.as(VirtualFile))
    filename.as(VirtualFile).source.should contain("def foo")
  end
end

describe "CodeError" do
  it "still prints the macro expansion it points at after its program is gone" do
    error = expect_raises(Crystal::TypeException) do
      semantic(%(
        macro define_bad
          def bad
            nope
          end
        end

        define_bad
        bad
        ))
    end
    5.times { GC.collect }

    message = error.to_s
    message.should contain("undefined local variable or method 'nope'")
    message.should contain("define_bad")
    message.should contain("def bad")
  end
end

describe "MetaVars in type inference" do
  it "finds the variables of the first break of an endless while" do
    assert_type(<<-CRYSTAL, inject_primitives: true) { int32 }
      while true
        a = 1
        if 1 == 1
          break
        end
        a = 'x'
      end
      a
      CRYSTAL
  end
end
