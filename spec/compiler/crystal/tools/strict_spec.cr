require "../../../spec_helper"

# Runs `crystal tool strict` with *arguments* on *source*, written to a file
# of its own, and returns the exit status, the converted text and the report.
private def run_strict_tool(source : String, arguments : Array(String) = [] of String, *, prelude = "empty", file = __FILE__) : {Int32, String, String}
  with_tempfile("strict_tool_sample.cr", file: file) do |path|
    File.write(path, source)
    output = IO::Memory.new
    error_output = IO::Memory.new
    options = arguments + ["--prelude", prelude, path]
    status = Crystal::StrictTool::Command.new(options, output, error_output).run
    {status, File.read(path), output.to_s + error_output.to_s}
  end
end

describe "crystal tool strict" do
  it "adds the marker and writes the types every caller agrees on" do
    status, converted, report = run_strict_tool(<<-CRYSTAL)
      class Counter
        def initialize(@count : Int32)
        end

        def add(amount)
          amount
        end
      end

      def twice(value)
        value
      end

      Counter.new(1).add(2)
      twice("hello")
      CRYSTAL

    status.should eq(0)
    converted.should eq(<<-CRYSTAL)
      # crystal: strict
      class Counter
        def initialize(@count : Int32)
        end

        def add(amount : Int32) : Int32
          amount
        end
      end

      def twice(value : String) : String
        value
      end

      Counter.new(1).add(2)
      twice("hello")

      CRYSTAL
    report.should contain("typed     Counter#add")
    report.should contain("2 methods typed, 0 marked @[Override], 0 left as they are")
    report.should contain("strict-file warnings in the program: 0 before, 0 after")
  end

  it "types the parameters of initialize and leaves its return type out" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL)
      class Point
        @x : Int32

        def initialize(x)
          @x = x
        end
      end

      Point.new(1)
      CRYSTAL

    converted.should contain("def initialize(x : Int32)\n")
  end

  it "lists a method whose types differ by caller and leaves it as it is" do
    status, converted, report = run_strict_tool(<<-CRYSTAL)
      def echo(value)
        value
      end

      echo(1)
      echo("one")
      CRYSTAL

    status.should eq(0)
    converted.should contain("def echo(value)\n")
    report.should contain("left      echo: parameter 'value' differs by caller (Int32, String), so it stays typed per caller; --unions writes `Int32 | String`")
  end

  it "writes the union with --unions" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL, ["--unions"])
      def echo(value)
        value
      end

      echo(1)
      echo("one")
      CRYSTAL

    converted.should contain("def echo(value : Int32 | String) : Int32 | String\n")
  end

  it "writes `T?` for a type or nil" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL, ["--unions"])
      def maybe(value)
        value
      end

      maybe(1)
      maybe(nil)
      CRYSTAL

    converted.should contain("def maybe(value : Int32?) : Int32?\n")
  end

  it "marks an override with @[Override]" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      class Animal
        def sound(times)
          times
        end
      end

      class Dog < Animal
        def sound(times)
          times
        end
      end

      Animal.new.sound(1)
      Dog.new.sound(2)
      CRYSTAL

    converted.should contain(<<-CRYSTAL)
      class Dog < Animal
        @[Override]
        def sound(times : Int32) : Int32
      CRYSTAL
    report.should contain("typed     Dog#sound, marked @[Override]")
  end

  it "marks a redefinition with @[Override] and leaves its types" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      class Box
        def size
          1
        end

        def size
          2
        end
      end

      Box.new.size
      CRYSTAL

    converted.should contain(<<-CRYSTAL)
        @[Override]
        def size
          2
      CRYSTAL
    report.should contain("Box#size: it redefines the method at")
  end

  it "keeps the type an overridden method declares" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL, prelude: "prelude")
      class Tag
        def to_s(io)
          io << "tag"
        end
      end

      Tag.new.to_s(STDOUT)
      CRYSTAL

    converted.should contain("  @[Override]\n  def to_s(io : IO) : Nil\n")
  end

  it "writes the type of a captured block" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL)
      def later(&block)
        block
      end

      later { 1 }
      CRYSTAL

    converted.should contain("def later(&block : -> Nil) : Proc(Nil)\n")
  end

  it "lists a method that yields" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      def each_twice(&)
        yield 1
        yield 2
      end

      each_twice { |value| value }
      CRYSTAL

    converted.should contain("def each_twice(&)\n")
    report.should contain("each_twice: it yields")
  end

  it "lists a method no caller reaches" do
    _, _, report = run_strict_tool(<<-CRYSTAL)
      def unused(value)
        value
      end
      CRYSTAL

    report.should contain("unused: never called in this program")
  end

  it "includes the type of a default value" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL)
      def greet(name = nil)
        name
      end

      greet("Ada")
      CRYSTAL

    converted.should contain("def greet(name : String? = nil) : String?\n")
  end

  it "leaves a file that already has every type as it is, apart from the marker" do
    source = <<-CRYSTAL
      class Counter
        def add(amount : Int32) : Int32
          amount
        end
      end

      Counter.new.add(1)
      CRYSTAL
    _, converted, report = run_strict_tool(source)

    converted.should eq("# crystal: strict\n#{source}\n")
    report.should contain("0 methods typed, 0 marked @[Override], 0 left as they are")
  end

  it "puts back a method the build rejects once it is typed once" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      module Greets
        def greet(name)
          prefix
        end
      end

      class Speaker
        include Greets
      end

      class English < Speaker
        def prefix
          "Hello"
        end
      end

      English.new.greet("Ada")
      CRYSTAL

    converted.should contain("  def greet(name)\n")
    converted.should contain("  def prefix : String\n")
    report.should contain("Greets#greet: the build fails when it is typed once: method 'Greets#greet', typed once in a strict file, can't be typed once")
    report.should contain("undefined local variable or method 'prefix' for Speaker")
  end

  it "changes nothing when it runs twice" do
    source = <<-CRYSTAL
      class Animal
        def sound(times)
          times
        end
      end

      class Dog < Animal
        def sound(times)
          times
        end
      end

      def echo(value)
        value
      end

      Animal.new.sound(1)
      Dog.new.sound(2)
      echo(1)
      echo("one")
      CRYSTAL
    with_tempfile("strict_tool_twice.cr") do |path|
      File.write(path, source)
      Crystal::StrictTool::Command.new(["--prelude", "empty", path], IO::Memory.new, IO::Memory.new).run.should eq(0)
      first = File.read(path)
      first.should_not eq(source)

      output = IO::Memory.new
      Crystal::StrictTool::Command.new(["--prelude", "empty", "--check", path], output, IO::Memory.new).run.should eq(0)
      File.read(path).should eq(first)
      output.to_s.should contain("unchanged")
    end
  end

  it "reports with --check without writing, and exits 1" do
    source = <<-CRYSTAL
      def twice(value)
        value
      end

      twice(1)
      CRYSTAL
    status, converted, report = run_strict_tool(source, ["--check"])

    status.should eq(1)
    converted.should eq(source)
    report.should contain("would change")
  end

  it "prints a diff with --dry-run without writing" do
    source = <<-CRYSTAL
      def twice(value)
        value
      end

      twice(1)
      CRYSTAL
    status, converted, report = run_strict_tool(source, ["--dry-run"])

    status.should eq(0)
    converted.should eq(source)
    report.should contain(<<-DIFF)
      -def twice(value)
      +# crystal: strict
      +def twice(value : Int32) : Int32
         value
       end
      DIFF
  end

  it "formats the converted file" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL)
      def twice( value )
          value
      end
      twice(1)
      CRYSTAL

    converted.should eq("# crystal: strict\ndef twice(value : Int32) : Int32\n  value\nend\n\ntwice(1)\n")
  end
  it "adds the marker to a file without methods" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      class Empty
      end

      Empty
      CRYSTAL

    converted.should eq("# crystal: strict\nclass Empty\nend\n\nEmpty\n")
    report.should contain("0 methods typed")
  end
  it "leaves out a type only the program's entry defines" do
    with_tempfile("strict_tool_library") do |directory|
      library = File.join(directory, "library", "greeter.cr")
      entry = File.join(directory, "app", "main.cr")
      Dir.mkdir_p(File.dirname(library))
      Dir.mkdir_p(File.dirname(entry))
      File.write(library, "def greet(model)\n  model\nend\n")
      File.write(entry, "require \"../library/greeter\"\n\nclass Model\nend\n\ngreet(Model.new)\n")

      output = IO::Memory.new
      Crystal::StrictTool::Command.new(["--prelude", "empty", "--entry", entry, library], output, IO::Memory.new).run.should eq(0)
      File.read(library).should eq("# crystal: strict\ndef greet(model)\n  model\nend\n")
      output.to_s.should contain("greet: parameter 'model' is Model, a type defined outside these files and the libraries they use")
    end
  end
  it "writes nothing with --check, even while it verifies" do
    source = <<-SOURCE
      def twice(value)
        value
      end

      twice(1)
      SOURCE
    with_tempfile("strict_tool_read_only.cr") do |path|
      File.write(path, source)
      modified = File.info(path).modification_time
      # A file the tool can't write: a run that writes while it verifies fails.
      File.chmod(path, 0o444)
      output = IO::Memory.new
      status = Crystal::StrictTool::Command.new(["--prelude", "empty", "--check", path], output, IO::Memory.new).run
      File.chmod(path, 0o644)

      status.should eq(1)
      File.read(path).should eq(source)
      File.info(path).modification_time.should eq(modified)
      output.to_s.should contain("would change")
      output.to_s.should contain("typed     twice")
    end
  end

  it "writes the alias a union stands for, keeping what it holds in other programs" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL, ["--unions"])
      class Decimal
      end

      {% if flag?(:with_decimal) %}
        alias Value = Int32 | Char | Decimal
      {% else %}
        alias Value = Int32 | Char
      {% end %}

      def keep(value)
        value
      end

      keep(1.as(Value))
      CRYSTAL

    converted.should contain("def keep(value : Value) : Value\n")
  end

  it "types a parameter assigned to an instance variable with the variable's type" do
    _, converted, _ = run_strict_tool(<<-CRYSTAL, ["--unions"])
      class Wrapper(T)
        def initialize(@value : T)
        end
      end

      alias Value = Int32 | Char

      class Relation
        @wrapped : Wrapper(Value)
        @limit : Int32 | Char | Nil

        def initialize(@wrapped, @limit)
        end
      end

      Relation.new(Wrapper(Value).new(1), 1)
      Relation.new(Wrapper(Value).new('a'), 2)
      CRYSTAL

    converted.should contain("def initialize(@wrapped : Wrapper(Value), @limit : ")
    converted.should match(/@limit : [^)]*Char[^)]*\)\n/)
    converted.should match(/@limit : [^)]*Nil/)
  end

  it "leaves a method that calls a macro on its receiver typed per receiver, and says why" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      class Model
        macro kind_name
          1
        end

        def kind
          kind_name
        end
      end

      class Post < Model
      end

      Post.new.kind
      CRYSTAL

    converted.should contain("  def kind\n")
    report.should contain("left      Model#kind: it calls the macro 'kind_name' on its receiver")
    report.should contain("typed once, the macro would expand once, for Model, instead of for each receiver")
  end

  it "reports a typed method that can't be typed once and leaves its file ordinary" do
    _, converted, report = run_strict_tool(<<-CRYSTAL)
      abstract class Model
        macro inherited
          def save : Int32
            1
          end
        end

        def save : Int32
          {% raise "save needs a concrete model" if @type == Model %}
          0
        end
      end

      class Post < Model
      end

      def store(record : Model) : Int32
        record.save
      end

      store(Post.new)
      CRYSTAL

    converted.should_not contain("# crystal: strict")
    report.should contain("left an ordinary file")
    report.should contain("can't be typed once")
    report.should contain("save needs a concrete model")
  end
end
