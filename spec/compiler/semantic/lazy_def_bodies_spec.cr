require "../../spec_helper"

private def semantic_with_lazy_bodies(code : String, enabled : Bool = true) : SemanticResult
  program = Program.new
  program.color = false
  program.lazy_def_bodies_enabled = enabled
  node = parse(code).as(Expressions)
  node.expressions.unshift(Crystal::Require.new("primitives"))
  node = program.semantic(program.normalize(node))
  SemanticResult.new(program, node)
end

private def untyped_def(result : SemanticResult, type_name : String, name : String) : Def
  type = result.program.types[type_name].as(ModuleType)
  type.lookup_defs(name).first
end

private MACRO_WRITTEN_METHODS = %(
  macro readers(*names)
    {% for name in names %}
      def {{name.id}}(value : Int32) : Int32
        doubled = value &+ value
        if doubled > 10
          doubled &- 1
        else
          doubled
        end
      end
    {% end %}

    def both(a : Int32, b : Int32) : Int32
      first(a) &+ second(b)
    end
  end

  class Holder
    readers first, second, third
  end
  )

describe "LazyDefBodies" do
  it "sets aside the bodies of methods a macro wrote and makes the called ones again" do
    result = semantic_with_lazy_bodies(MACRO_WRITTEN_METHODS + %(Holder.new.both(1, 2)))
    result.program.lazy_def_bodies.deferred.should eq(4)
    untyped_def(result, "Holder", "third").body_as_held.should be_a(LazyMacroDefBody)
    untyped_def(result, "Holder", "first").body_as_held.should_not be_a(LazyMacroDefBody)
    untyped_def(result, "Holder", "both").body_as_held.should_not be_a(LazyMacroDefBody)
    result.node.as(Expressions).last.type.to_s.should eq("Int32")
  end

  it "makes the body the parser and normalizer gave it, at the same locations" do
    kept = semantic_with_lazy_bodies(MACRO_WRITTEN_METHODS, enabled: false)
    lazy = semantic_with_lazy_bodies(MACRO_WRITTEN_METHODS)
    original = untyped_def(kept, "Holder", "third").body
    deferred = untyped_def(lazy, "Holder", "third")
    deferred.body_as_held.should be_a(LazyMacroDefBody)
    made = deferred.body
    made.to_s.should eq(original.to_s)
    made.location.should eq(original.location)
    made.end_location.should eq(original.end_location)
    lazy.program.lazy_def_bodies.materialized.should eq(1)
  end

  it "keeps methods written in a file and methods whose body macro code writes" do
    result = semantic_with_lazy_bodies(%(
      macro typed_reader
        def name_of_type : String
          {{ @type.name.stringify }}
        end
      end

      class Holder
        typed_reader

        def written(value : Int32) : Int32
          value
        end
      end

      Holder.new.written(1)
      ))
    result.program.lazy_def_bodies.deferred.should eq(0)
  end

  it "keeps a method whose text holds a location pragma" do
    result = semantic_with_lazy_bodies(%(
      macro wrap(&block)
        def wrapped : Int32
          {{ block.body }}
        end
      end

      class Holder
        wrap { 1 }
      end

      Holder.new.wrapped
      ))
    result.program.lazy_def_bodies.deferred.should eq(0)
    result.node.as(Expressions).last.type.to_s.should eq("Int32")
  end
end
