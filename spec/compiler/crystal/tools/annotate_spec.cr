require "../../../spec_helper"
include Crystal

private def annotate(code, &)
  with_tempfile("annotate") do |dir|
    Dir.mkdir_p(dir)
    filename = File.join(dir, "main.cr")
    File.write(filename, code)

    compiler = Compiler.new
    compiler.prelude = "empty"
    compiler.no_codegen = true
    instances = [] of Def
    result = compiler.compile_configure_program(Compiler::Source.new(filename, code), "fake-no-build") do |program|
      program.collected_def_instances = instances
    end

    annotator = ReturnTypeAnnotator.new(result.program, dir, instances)
    annotator.process
    annotator.apply
    yield File.read(filename), annotator
  end
end

describe ReturnTypeAnnotator do
  it "adds the inferred return types" do
    annotate(<<-CRYSTAL) do |source, annotator|
      require "primitives"

      class Point
        def initialize(@x : Int32)
        end

        def x
          @x
        end

        def +(other : Point)
          Point.new(@x + other.x)
        end

        def double(factor = (1 + 1)) # (comment
          @x * factor
        end
      end

      def nothing; end

      p = Point.new(1) + Point.new(2)
      p.x
      p.double
      nothing
      CRYSTAL
      source.should contain("def initialize(@x : Int32)\n")
      source.should contain("def x : Int32\n")
      source.should contain("def +(other : Point) : Point\n")
      source.should contain("def double(factor = (1 + 1)) : Int32 # (comment\n")
      source.should contain("def nothing : Nil; end")
      annotator.unresolved.should be_empty
    end
  end

  it "uses type parameters in generic types" do
    annotate(<<-CRYSTAL) do |source, annotator|
      class Box(T)
        def initialize(@value : T)
        end

        def value
          @value
        end

        def me
          self
        end
      end

      Box.new(1).value
      Box.new('a').value
      Box.new(1).me
      Box.new('a').me
      CRYSTAL
      source.should contain("def value : T\n")
      source.should contain("def me : self\n")
      annotator.unresolved.should be_empty
    end
  end

  it "leaves methods without a single type to a human" do
    annotate(<<-CRYSTAL) do |source, annotator|
      def ident(x)
        x
      end

      def unused
        1
      end

      ident(1)
      ident('a')
      CRYSTAL
      source.should contain("def ident(x)\n")
      source.should contain("def unused\n")
      annotator.unresolved.map(&.def_node.name).sort.should eq(%w[ident unused])
    end
  end

  it "annotates methods that take a block" do
    annotate(<<-CRYSTAL) do |source, annotator|
      def twice
        yield
        yield
      end

      twice { 1 }
      CRYSTAL
      source.should contain("def twice : Int32\n")
      annotator.unresolved.should be_empty
    end
  end
end
