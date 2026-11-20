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
