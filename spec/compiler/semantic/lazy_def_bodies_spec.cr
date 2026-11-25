require "../../spec_helper"

# Bodies of methods that macros write are let go when type inference starts
# and parsed again when something reads them
# (see `src/compiler/crystal/semantic/lazy_def_bodies.cr`).

private MACRO_METHODS = %(
  macro make_methods(*names)
    {% for name in names %}
      def {{name.id}}(value : Int32)
        total = value + {{name.id.size}}
        first, second = total, value
        first + second
      end
    {% end %}

    def never_called
      1 + "a"
    end

    def store(@select : Int32)
    end
  end

  class Holder
    make_methods alpha, beta
  end
  )

private def lazy_semantic(code : String, lazy : Bool = true) : {Program, ASTNode}
  Program.lazy_def_bodies_default_setting = lazy
  result = semantic(code, inject_primitives: true)
  {result.program, result.node}
ensure
  Program.lazy_def_bodies_default_setting = nil
end

private def holder_def(program : Program, name : String) : Def
  program.types["Holder"].lookup_defs(name).first
end

describe "Semantic: lazy def bodies" do
  it "lets the bodies of macro-written methods go, parses a called one again and lets it go once typed" do
    program, node = lazy_semantic(MACRO_METHODS + %(
      Holder.new.alpha(1)
      ))
    node.type.should eq(program.int32)
    program.lazy_def_bodies_dropped.should be > 0
    program.lazy_def_bodies_parsed_again.should be > 0
    program.lazy_def_bodies_dropped_again.should be > 0
    holder_def(program, "alpha").lazy_body?.should be_true
    holder_def(program, "beta").lazy_body?.should be_true
    holder_def(program, "never_called").lazy_body?.should be_true
  end

  it "keeps the body of a method whose parameters the normalizer renamed" do
    program, _ = lazy_semantic(MACRO_METHODS + %(
      Holder.new.alpha(1)
      ))
    holder_def(program, "store").lazy_body?.should be_false
  end

  it "parses a body again with the same nodes and locations" do
    lazy_program, _ = lazy_semantic(MACRO_METHODS + %(1))
    kept_program, _ = lazy_semantic(MACRO_METHODS + %(1), lazy: false)

    lazy_def = holder_def(lazy_program, "beta")
    lazy_def.lazy_body?.should be_true
    parsed_again = lazy_def.body
    kept = holder_def(kept_program, "beta").body

    LazyMacroDefBodies.first_difference(kept, parsed_again).should be_nil
    parsed_again.location.to_s.should eq(kept.location.to_s)
    parsed_again.end_location.to_s.should eq(kept.end_location.to_s)
  end

  it "gives the same error from a body parsed again" do
    code = MACRO_METHODS + %(
      Holder.new.never_called
      )
    lazy_error = expect_raises(TypeException, "instantiating 'Holder#never_called()'") { lazy_semantic(code) }
    kept_error = expect_raises(TypeException) { lazy_semantic(code, lazy: false) }
    lazy_error.to_s.should eq(kept_error.to_s)
  end

  it "parses a body again for a macro that reads it" do
    _, node = lazy_semantic(MACRO_METHODS + %(
      class Holder
        def alpha_body_text
          {{ @type.methods.find(&.name.== "alpha").body.stringify }}
        end
      end

      Holder.new.alpha_body_text
      ))
    node.type.to_s.should eq("String")
  end
end
