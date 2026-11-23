require "../../spec_helper"

private def compare(before : String, after : String) : Crystal::Location::LineShift?
  Crystal::InferReuse::MethodListExpansion.compare(Crystal::Program.new, before, after)
end

describe Crystal::InferReuse::MethodListExpansion do
  describe ".compare" do
    it "accepts the same text, with no line moved" do
      compare("a = 1\nb = a\n", "a = 1\nb = a\n").try(&.identity?).should be_true
    end

    it "numbers fresh variable names in the order they appear" do
      compare("__temp_12 = 1\nputs __temp_12\n", "__temp_98 = 1\nputs __temp_98\n").try(&.identity?).should be_true
      compare("__temp_1 = 1\n__temp_2 = 2\nputs __temp_1\n", "__temp_1 = 1\n__temp_2 = 2\nputs __temp_2\n").should be_nil
    end

    it "moves the lines after blank lines a macro loop added" do
      shift = compare("a = 1\nb = 2\n", "a = 1\n   \n\nb = 2\n")
      shift.try(&.apply(1)).should eq(1)
      shift.try(&.apply(2)).should eq(4)
    end

    it "treats a blank line added inside a string as a change" do
      compare("a = \"x\ny\"\n", "a = \"x\n\ny\"\n").should be_nil
    end

    it "treats any other difference as a change" do
      compare("a = 1\n", "a = 2\n").should be_nil
    end
  end
end

describe Crystal::InferReuse::MethodListReplay do
  it "answers each read from the record, with the added and removed methods" do
    program = semantic(<<-CRYSTAL).program
      class Foo
        def a; end
        def b; end
      end
      CRYSTAL
    foo_type = program.types["Foo"]
    list_of_defs = foo_type.lookup_defs("a") + foo_type.lookup_defs("b")
    added = Crystal::Def.new("c")
    added.owner = foo_type
    read = Crystal::InferReuse::MethodListRead.new(foo_type, "methods", list_of_defs, nil, false)
    replay = Crystal::InferReuse::MethodListReplay.new([read], [added], [list_of_defs.first])
    replay.methods(foo_type, "methods").map(&.name).should eq(["b", "c"])
    expect_raises(Crystal::InferReuse::Refusal, "read more lists of methods") { replay.methods(foo_type, "methods") }
  end
end
