require "../../spec_helper"

# A typed copy with the shape of an earlier one lets its body go during type
# inference and uses the earlier copy's function (see `Crystal::ShapeBodies`).

private def with_shape_bodies(setting : String, &)
  old_setting = ENV["CRYSTAL_SHAPE_BODIES"]?
  ENV["CRYSTAL_SHAPE_BODIES"] = setting
  begin
    yield
  ensure
    if old_setting
      ENV["CRYSTAL_SHAPE_BODIES"] = old_setting
    else
      ENV.delete("CRYSTAL_SHAPE_BODIES")
    end
  end
end

private def shape_bodies_of(code : String, setting = "1") : Crystal::ShapeBodies
  with_shape_bodies(setting) do
    semantic(code, inject_primitives: true).program.shape_bodies.should_not be_nil
  end
end

private def typed_copy(program : Crystal::Program, owner_name : String, name : String) : Crystal::Def
  owner = program.types[owner_name].as(Crystal::DefInstanceContainer)
  typed_def = owner.@def_instances.try &.each_value.find(&.name.==(name))
  typed_def.should_not be_nil
end

private def run_with_shape_bodies(code : String)
  with_shape_bodies("1") { run(code) }
end

private SHARED_ADVANCE = %(
  class Base
    def initialize(@count : Int32, @step : Int32)
    end

    def advance
      @count = @count &+ @step
      @count &* 2
    end
  end

  class First < Base
  end

  class Second < Base
  end

  class Third < Base
  end

  first = First.new(1, 10)
  second = Second.new(2, 100)
  third = Third.new(3, 1000)
  first.advance &+ second.advance &+ third.advance &+ first.advance
  )

describe "Semantic: shape bodies" do
  it "lets the bodies of copies with the shape of an earlier copy go" do
    with_shape_bodies("1") do
      result = semantic(SHARED_ADVANCE, inject_primitives: true)
      shape_bodies = result.program.shape_bodies.should_not be_nil
      shape_bodies.stats.shared.should eq(2)
      typed_copy(result.program, "First", "advance").body.should_not be_a(Crystal::SharedShapeBody)
      second = typed_copy(result.program, "Second", "advance")
      second.body.should be_a(Crystal::SharedShapeBody)
      second.type.to_s.should eq("Int32")
      shape_bodies.shared_copy?(second).should_not be_nil
      shape_bodies.function_def(second).owner.to_s.should eq("First")
    end
  end

  it "runs the shared function with each copy's own instance" do
    run_with_shape_bodies(SHARED_ADVANCE).to_i.should eq(22 + 204 + 2006 + 42)
  end

  it "keeps a body whose class has another layout" do
    shape_bodies = shape_bodies_of(%(
      class First
        def initialize(@count : Int32)
        end

        def double
          @count &* 2
        end
      end

      class Second
        def initialize(@flag : Bool, @count : Int32)
        end

        def double
          @count &* 2
        end
      end

      First.new(1).double &+ Second.new(true, 2).double
      ))
    shape_bodies.stats.shared.should eq(0)
  end

  it "keeps a body that reads the identity of its class" do
    shape_bodies = shape_bodies_of(%(
      class First
        @@count = 1

        def initialize(@value : Int32)
        end

        def read
          @value &+ @@count
        end
      end

      class Second
        @@count = 2

        def initialize(@value : Int32)
        end

        def read
          @value &+ @@count
        end
      end

      First.new(1).read &+ Second.new(2).read
      ))
    shape_bodies.stats.shared.should eq(0)
  end

  it "types a shared copy again into the same def" do
    with_shape_bodies("1") do
      result = semantic(SHARED_ADVANCE, inject_primitives: true)
      shape_bodies = result.program.shape_bodies.should_not be_nil
      second = typed_copy(result.program, "Second", "advance")
      shared_copy = shape_bodies.shared_copy?(second).should_not be_nil
      shape_bodies.type_again(shared_copy)
      second.body.should_not be_a(Crystal::SharedShapeBody)
      second.type.to_s.should eq("Int32")
      shape_bodies.shared_copy?(second).should be_nil
      shape_bodies.function_def(second).should be(second)
    end
  end

  it "keeps every body in verify mode and finds no difference" do
    with_shape_bodies("verify") do
      result = semantic(SHARED_ADVANCE, inject_primitives: true)
      shape_bodies = result.program.shape_bodies.should_not be_nil
      shape_bodies.stats.shared.should eq(2)
      shape_bodies.stats.compared.should eq(2)
      shape_bodies.stats.differ_unflagged.should eq(0)
      typed_copy(result.program, "Second", "advance").body.should_not be_a(Crystal::SharedShapeBody)
      shape_bodies.shared_copy?(typed_copy(result.program, "Second", "advance")).should be_nil
    end
  end

  it "is off when CRYSTAL_SHAPE_BODIES=0" do
    with_shape_bodies("0") do
      semantic(SHARED_ADVANCE, inject_primitives: true).program.shape_bodies.should be_nil
    end
  end
end
