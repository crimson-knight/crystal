require "../../spec_helper"

describe "Program#release_semantic_only_data" do
  it "replaces the bodies of untyped defs and macros" do
    result = semantic(%(
      class Foo
        def bar
          1 + 2
        end

        macro baz
          1
        end
      end

      Foo.new.bar
      ), inject_primitives: true)
    program = result.program
    foo = program.types["Foo"].as(ModuleType)

    program.release_semantic_only_data.should be > 0

    foo.lookup_first_def("bar", false).not_nil!.body.should be_a(Nop)
    # Macros defined in a class body live on its metaclass.
    foo.metaclass.as(ModuleType).macros.not_nil!["baz"].first.body.should be_a(Nop)
  end

  it "keeps the typed def instances that codegen reads" do
    result = semantic(%(
      class Foo
        def bar
          1 + 2
        end
      end

      Foo.new.bar
      ), inject_primitives: true)
    program = result.program
    foo = program.types["Foo"].as(DefInstanceContainer)

    program.release_semantic_only_data

    typed_defs = foo.def_instances.values
    typed_defs.should_not be_empty
    typed_defs.each { |typed_def| typed_def.body.should_not be_a(Nop) }
  end

  it "keeps the bodies of funs, which are code-generated in place" do
    result = semantic(%(
      fun forty_two : Int32
        42
      end

      forty_two
      ))
    program = result.program

    program.release_semantic_only_data

    fun_def = program.lookup_first_def("forty_two", false).not_nil!
    fun_def.should be_a(External)
    fun_def.body.should be_a(NumberLiteral)
  end

  it "drops the type-inference edges of instance vars and keeps their types" do
    result = semantic(%(
      class Foo
        def initialize
          @value = 1
        end

        def value
          @value
        end
      end

      Foo.new.value
      ), inject_primitives: true)
    program = result.program
    instance_var = program.types["Foo"].as(InstanceVarContainer).instance_vars["@value"]
    instance_var.dependencies.should_not be_empty

    program.release_semantic_only_data

    instance_var.dependencies.should be_empty
    instance_var.type.should eq(program.int32)
  end

  it "keeps a local var's nil marker when releasing its bindings" do
    program = Program.new
    var = MetaVar.new("x")
    var.bind_to(program.nil_var)
    var.bind_to(Var.new("y", program.int32))

    var.release_bindings(program.nil_var)

    var.dependencies.size.should eq(1)
    var.dependencies.first.should be(program.nil_var)
  end

  it "drops the type-inference edges of the nodes in typed defs and in the main program" do
    result = semantic(%(
      class Foo
        def initialize
          @value = 1
        end

        def value
          copy = @value
          copy + 2
        end
      end

      Foo.new.value
      ), inject_primitives: true)
    program = result.program
    main_call = result.node.as(Expressions).expressions.last.as(Call)
    typed_def = main_call.target_defs.not_nil!.first
    assign = typed_def.body.as(Expressions).expressions.first.as(Assign)
    main_call.dependencies.should_not be_empty
    main_call.parent_visitor?.should_not be_nil
    typed_def.@observers.to_a.should_not be_empty
    assign.target.dependencies.should_not be_empty

    program.release_semantic_only_data(result.node)

    main_call.dependencies.should be_empty
    main_call.parent_visitor?.should be_nil
    main_call.type.should eq(program.int32)
    typed_def.@observers.to_a.should be_empty
    typed_def.type.should eq(program.int32)
    assign.target.dependencies.should be_empty
    assign.target.type.should eq(program.int32)
    typed_def.vars.not_nil!["copy"].dependencies.should be_empty
    program.last_inference_edge_releaser.not_nil!.released_def_count.should be > 0
  end

  it "releases the typed defs that only a call with a block owns" do
    result = semantic(%(
      def twice(&)
        yield 1
        yield 2
      end

      total = 0
      twice { |number| total = number }
      ), inject_primitives: true)
    program = result.program
    block_call = result.node.as(Expressions).expressions.last.as(Call)
    typed_def = block_call.target_defs.not_nil!.first
    typed_def.@observers.to_a.should_not be_empty

    program.release_semantic_only_data(result.node)

    typed_def.@observers.to_a.should be_empty
    block_call.block.not_nil!.after_vars.should be_nil
  end

  it "keeps the nil marker of a local var of a typed def when releasing its edges" do
    result = semantic(%(
      def maybe
        if 1 == 2
          value = 1
        end
        value
      end

      maybe
      ), inject_primitives: true)
    program = result.program
    typed_def = result.node.as(Expressions).expressions.last.as(Call).target_defs.not_nil!.first

    program.release_semantic_only_data(result.node)

    list_of_dependencies = typed_def.vars.not_nil!["value"].dependencies.to_a
    list_of_dependencies.size.should eq(1)
    list_of_dependencies.first.should be(program.nil_var)
  end

  it "drops the text of macro expansions, which only error messages read" do
    result = semantic(%(
      macro forty_two
        42
      end

      forty_two
      ))
    program = result.program
    program.virtual_files.should_not be_empty
    program.virtual_files.first.source.should_not be_empty

    program.release_semantic_only_data(result.node)

    program.virtual_files.each { |virtual_file| virtual_file.source.should be_empty }
  end

  it "keeps the edges when no main node is given" do
    result = semantic(%(
      def bar
        1
      end

      bar
      ))
    program = result.program
    main_call = result.node.as(Expressions).expressions.last.as(Call)

    program.release_semantic_only_data

    main_call.dependencies.should_not be_empty
    program.last_inference_edge_releaser.should be_nil
  end

  it "returns zero when nothing is left to release" do
    result = semantic(%(
      def bar
        1
      end

      bar
      ))
    program = result.program
    program.release_semantic_only_data
    program.release_semantic_only_data.should eq(0)
  end
end
