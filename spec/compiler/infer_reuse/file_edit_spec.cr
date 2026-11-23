require "../../spec_helper"

private OLD_TEXT = <<-CRYSTAL
  # A comment
  class Greeter
    def greet(name : String) : String
      "Hello \#{name}"
    end

    private def shout(name : String) : String
      greet(name).upcase
    end
  end

  def top_level : Int32
    1
  end

  macro made
    def made_value : Int32
      1
    end
  end

  puts Greeter.new.greet("x")

  CRYSTAL

private def compare(new_text : String, old_text = OLD_TEXT) : Crystal::InferReuse::FileEdit
  Crystal::InferReuse::FileEdit.compare(Crystal::Program.new, "greeter.cr", old_text, new_text)
end

private def refusal_of(new_text : String, old_text = OLD_TEXT) : String
  compare(new_text, old_text)
  fail "expected a refusal"
rescue ex : Crystal::InferReuse::Refusal
  ex.message.not_nil!
end

describe Crystal::InferReuse::FileEdit do
  it "finds the method whose body changed" do
    edit = compare(OLD_TEXT.sub("Hello", "Hi"))
    edit.list_of_changed_defs.map(&.new_def.name).should eq(["greet"])
    edit.list_of_changed_defs.first.old_line.should eq(3)
    edit.line_shift.identity?.should be_true
    edit.bodies_only?.should be_true
  end

  it "finds private and top-level methods" do
    edit = compare(OLD_TEXT.sub(".upcase", ".downcase").sub("  1\nend", "  2\nend"))
    edit.list_of_changed_defs.map(&.new_def.name).sort.should eq(["shout", "top_level"])
  end

  it "finds nothing in an unchanged text" do
    edit = compare(OLD_TEXT)
    edit.list_of_changed_defs.should be_empty
    edit.bodies_only?.should be_true
  end

  it "moves the lines after a body that grew" do
    edit = compare(OLD_TEXT.sub("    \"Hello", "    1\n    2\n    3\n    \"Hello"))
    edit.list_of_changed_defs.map(&.new_def.name).should eq(["greet"])
    shift = edit.line_shift
    shift.apply(2).should eq(2)   # class Greeter
    shift.apply(5).should eq(8)   # the `end` of greet
    shift.apply(7).should eq(10)  # private def shout
    shift.apply(8).should eq(11)  # its unchanged body
    shift.apply(22).should eq(25) # puts ...
    edit.replaced_line?(4).should be_true
    edit.replaced_line?(8).should be_false
  end

  it "moves the lines after a body that shrank" do
    grown = OLD_TEXT.sub("    \"Hello", "    1\n    2\n    \"Hello")
    edit = compare(OLD_TEXT, grown)
    edit.line_shift.apply(10).should eq(8)
  end

  it "finds an added method and moves the lines after it" do
    edit = compare(OLD_TEXT.sub("  end\n\n  private def shout", "  end\n\n  # Says it twice.\n  def twice(name : String) : String\n    greet(name) * 2\n  end\n\n  private def shout"))
    edit.list_of_added_defs.map(&.new_def.name).should eq(["twice"])
    edit.list_of_added_defs.first.list_of_scopes.size.should eq(1)
    edit.list_of_changed_defs.should be_empty
    edit.line_shift.apply(7).should eq(12)
    edit.line_shift.apply(3).should eq(3)
  end

  it "finds a removed method" do
    edit = compare(OLD_TEXT.sub("\n  private def shout(name : String) : String\n    greet(name).upcase\n  end\n", ""))
    edit.list_of_removed_defs.map(&.old_def.name).should eq(["shout"])
    edit.list_of_removed_defs.first.old_first_line.should eq(7)
    edit.replaced_line?(8).should be_true
    edit.line_shift.apply(12).should eq(8)
  end

  it "reads a changed method header as a method removed and one added" do
    edit = compare(OLD_TEXT.sub("def greet(name : String) : String", "def greet(name : String) : String?"))
    edit.list_of_removed_defs.map(&.old_def.name).should eq(["greet"])
    edit.list_of_added_defs.map(&.new_def.name).should eq(["greet"])
    edit.list_of_changed_defs.should be_empty
  end

  it "refuses a change outside every method" do
    refusal_of(OLD_TEXT.sub("# A comment", "# Another comment")).should contain("greeter.cr:1 changed outside a method body")
    refusal_of(OLD_TEXT.sub(%(greet("x")), %(greet("y")))).should contain("outside a method body")
    refusal_of(OLD_TEXT.sub("class Greeter\n", "class Greeter\n  @x = 1\n")).should contain("outside a method body")
  end

  it "refuses a change inside a macro" do
    refusal_of(OLD_TEXT.sub("    1\n  end\nend", "    2\n  end\nend")).should contain("outside a method body")
  end

  it "refuses an annotation added with a method" do
    refusal_of(OLD_TEXT.sub("class Greeter\n", "class Greeter\n  @[AlwaysInline]\n  def other\n  end\n")).should contain("outside a method body")
  end

  it "refuses moving a line that uses __LINE__" do
    with_line = OLD_TEXT.sub(%(puts Greeter.new.greet("x")), %(puts __LINE__))
    refusal_of(with_line.sub("    \"Hello", "    1\n    \"Hello"), with_line).should contain("uses __LINE__")
  end
end

describe Crystal::Location::LineShift do
  it "applies steps and composes" do
    first = Crystal::Location::LineShift.new([{1, 0}, {10, 3}])
    second = Crystal::Location::LineShift.new([{1, 0}, {5, -1}, {20, 2}])
    first.apply(9).should eq(9)
    first.apply(10).should eq(13)
    both = first.then(second)
    (1..40).each do |line|
      both.apply(line).should eq(second.apply(first.apply(line)))
    end
  end
end
