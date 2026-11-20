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
