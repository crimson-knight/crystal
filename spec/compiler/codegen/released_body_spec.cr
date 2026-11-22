require "../../spec_helper"

# A full compile (`Compiler#compile`) releases untyped bodies after semantic
# analysis and each typed def body once its function is generated. These
# programs exercise the paths that reach a def more than once: blocks inlined
# at several `yield`s, procs, closures, `previous_def`, virtual dispatch and
# a method called from many sites.
describe "Code gen: released def bodies" do
  it "runs a program with blocks, procs and closures" do
    run(%(
      require "prelude"

      def twice(&)
        yield 1
        yield 2
      end

      def make_adder(amount)
        ->(value : Int32) { value + amount }
      end

      total = 0
      twice { |number| total += number }
      twice { |number| total += number * 10 }
      adder = make_adder(100)
      total = adder.call(total)
      list_of_squares = [1, 2, 3].map { |number| number * number }
      "\#{total} \#{list_of_squares.sum}"
      )).to_string.should eq("133 14")
  end

  it "runs a program with previous_def and virtual dispatch" do
    run(%(
      require "prelude"

      abstract class Shape
        abstract def area : Int32

        def describe
          "area=\#{area}"
        end
      end

      class Square < Shape
        def initialize(@side : Int32)
        end

        def area : Int32
          @side * @side
        end
      end

      class Rectangle < Shape
        def initialize(@width : Int32, @height : Int32)
        end

        def area : Int32
          @width * @height
        end

        def area : Int32
          previous_def + 1
        end
      end

      list_of_shapes = [Square.new(3), Rectangle.new(2, 4)] of Shape
      list_of_shapes.map(&.describe).join(",")
      )).to_string.should eq("area=9,area=9")
  end

  it "calls a method whose function was already generated from many sites" do
    run(%(
      require "prelude"

      class Counter
        getter count = 0

        def bump
          @count += 1
          self
        end
      end

      counter = Counter.new
      counter.bump
      counter.bump.bump
      3.times { counter.bump }
      counter.count
      )).to_string.should eq("6")
  end
end
