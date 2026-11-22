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

private def compare(new_text : String) : Array(Crystal::InferReuse::BodyEdit::ChangedDef)
  Crystal::InferReuse::BodyEdit.compare(Crystal::Program.new, "greeter.cr", OLD_TEXT, new_text)
end

private def refusal_of(new_text : String) : String
  compare(new_text)
  fail "expected a refusal"
rescue ex : Crystal::InferReuse::Refusal
  ex.message.not_nil!
end

describe Crystal::InferReuse::BodyEdit do
  it "finds the method whose body changed" do
    list_of_changed = compare(OLD_TEXT.sub("Hello", "Hi"))
    list_of_changed.map(&.new_def.name).should eq(["greet"])
    list_of_changed.first.old_def.location.not_nil!.line_number.should eq(3)
  end

  it "finds private and top-level methods" do
    list_of_changed = compare(OLD_TEXT.sub(".upcase", ".downcase").sub("  1\nend", "  2\nend"))
    list_of_changed.map(&.new_def.name).sort.should eq(["shout", "top_level"])
  end

  it "finds nothing in an unchanged text" do
    compare(OLD_TEXT).should be_empty
  end

  it "refuses a change to a method header" do
    refusal_of(OLD_TEXT.sub("def greet(name : String) : String", "def greet(name : String) : String?")).should contain("outside a method body")
  end

  it "refuses a change outside every method" do
    refusal_of(OLD_TEXT.sub("# A comment", "# Another comment")).should contain("greeter.cr:1 changed outside a method body")
    refusal_of(OLD_TEXT.sub(%(greet("x")), %(greet("y")))).should contain("outside a method body")
  end

  it "refuses a change inside a macro" do
    refusal_of(OLD_TEXT.sub("    1\n  end\nend", "    2\n  end\nend")).should contain("outside a method body")
  end

  it "refuses a new method or a different line count" do
    refusal_of(OLD_TEXT.sub("  # A comment\n", "").sub("class Greeter\n", "class Greeter\n  def other; end\n")).should contain("added, removed or moved")
    refusal_of(OLD_TEXT.sub("    \"Hello", "    1\n    \"Hello")).should contain("lines")
  end
end
