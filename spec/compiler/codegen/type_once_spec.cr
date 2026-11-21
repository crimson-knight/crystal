require "../../spec_helper"

# Programs that call `@[TypeOnce]` methods run the same as without the
# annotation: the one typed copy dispatches at run time.

private SHAPES = %(
  require "prelude"

  abstract class Shape
    def initialize(@side : Int32)
    end

    abstract def area : Int32

    def name : String
      "shape"
    end

    @[TypeOnce]
    def describe(times : Int32) : String
      "\#{name}:\#{area * times}"
    end
  end

  class Square < Shape
    def area : Int32
      @side * @side
    end

    def name : String
      "square"
    end
  end

  class Line < Shape
    def area : Int32
      @side
    end
  end

  class Cube < Square
    def area : Int32
      @side * @side * 6
    end
  end
  )

describe "Code gen: @[TypeOnce]" do
  it "dispatches on the run-time class of self" do
    run(SHAPES + %(
      Square.new(3).describe(2) + " " + Line.new(4).describe(1) + " " + Cube.new(1).describe(1)
      )).to_string.should eq("square:18 shape:4 square:6")
  end

  it "dispatches on the run-time class of a parameter" do
    run(SHAPES + %(
      @[TypeOnce]
      def total(first : Shape, second : Shape) : Int32
        first.area + second.area
      end

      total(Square.new(2), Line.new(5)) + total(Cube.new(1), Square.new(1)) + total(Line.new(1), Line.new(1))
      )).to_i.should eq(18)
  end

  it "dispatches on a class passed as a value" do
    run(SHAPES + %(
      class Shape
        def self.sides : Int32
          0
        end
      end

      class Square < Shape
        def self.sides : Int32
          4
        end
      end

      @[TypeOnce]
      def sides_of(kind : Shape.class) : Int32
        kind.sides
      end

      sides_of(Square) + sides_of(Line) + sides_of(Cube) * 10
      )).to_i.should eq(44)
  end

  it "passes members of a declared union" do
    run(%(
      require "prelude"

      @[TypeOnce]
      def show(value : Int32 | String | Nil, fallback : String?) : String
        case value
        when Int32  then (value + 1).to_s
        when String then value.upcase
        else             fallback || "none"
        end
      end

      maybe = 1 == 1 ? 41 : nil
      [show(1, nil), show("a", "x"), show(nil, "y"), show(nil, nil), show(maybe, "z")].join(",")
      )).to_string.should eq("2,A,y,none,42")
  end

  it "passes named arguments and default values" do
    run(SHAPES + %(
      class Shape
        @[TypeOnce]
        def scaled(by : Int32 = 2, *, plus : Int32 | Nil = nil, other : Shape? = nil) : Int32
          area * by + (plus || 0) + (other.try(&.area) || 0)
        end
      end

      Square.new(2).scaled + Line.new(3).scaled(3) + Cube.new(1).scaled(plus: 1) + Line.new(1).scaled(1, other: Square.new(3))
      )).to_i.should eq(8 + 9 + 13 + 10)
  end

  it "runs an overriding method and its super call" do
    run(SHAPES + %(
      class Loud < Square
        def describe(times : Int32) : String
          super(times).upcase
        end
      end

      Loud.new(2).describe(1) + " " + Square.new(2).describe(1)
      )).to_string.should eq("SQUARE:4 square:4")
  end

  it "runs a call that dispatches over a union receiver" do
    run(SHAPES + %(
      class Dot
        def describe(times : Int32) : String
          "dot"
        end
      end

      values = [Square.new(1), Dot.new, Line.new(7), Cube.new(1)] of Shape | Dot
      values.map(&.describe(1)).join(" ")
      )).to_string.should eq("square:1 dot shape:7 square:6")
  end

  it "runs a method called through the base class and through subclasses" do
    run(SHAPES + %(
      shapes = [Square.new(2), Line.new(2)] of Shape
      shapes.map(&.describe(1)).join(" ") + " " + Square.new(5).describe(1)
      )).to_string.should eq("square:4 shape:2 square:25")
  end

  it "calls a typed-once method from another typed-once method" do
    run(SHAPES + %(
      class Shape
        @[TypeOnce]
        def report(other : Shape) : String
          describe(1) + "+" + other.describe(2)
        end
      end

      Cube.new(1).report(Line.new(3))
      )).to_string.should eq("square:6+shape:6")
  end

  it "passes a captured block" do
    run(SHAPES + %(
      class Shape
        @[TypeOnce]
        def apply(&block : Int32 -> Int32) : Int32
          block.call(area)
        end
      end

      Square.new(3).apply { |value| value + 1 } + Line.new(3).apply { |value| value * 2 }
      )).to_i.should eq(16)
  end

  it "generates one function for all receivers" do
    with_once = SHAPES + %(
      Square.new(3).describe(2)
      Line.new(4).describe(1)
      Cube.new(1).describe(1)
      )
    count = ->(code : String) do
      result = semantic(code)
      result.program.share_owner_shapes = false
      visitor = Crystal::CodeGenVisitor.new(result.program, result.node, single_module: true, debug: Crystal::Debug::None)
      visitor.accept result.node
      visitor.process_finished_hooks
      visitor.finish
      visitor.generated_fun_count
    end
    (count.call(with_once.sub("@[TypeOnce]", "")) - count.call(with_once)).should eq(2)
  end
end
