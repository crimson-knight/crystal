# crystal: strict
require "strict"

alias Transform = String -> String

abstract class Shape
  abstract def area : Int32

  def describe(label : String) : String
    "#{label} with area #{area}"
  end

  def describe(times : Int32) : String
    describe("shape") * times
  end

  def rename(name : String, &block : Transform) : String
    block.call(name)
  end

  @[Override]
  def to_s(io : IO) : Nil
    io << describe("shape")
  end
end

class Square < Shape
  def initialize(@side : Int32)
  end

  @[Override]
  def area : Int32
    @side * @side
  end

  @[Override]
  def describe(label : String) : String
    "square " + super
  end
end

class Circle < Shape
  def initialize(@radius : Int32)
  end

  @[Override]
  def area : Int32
    3 * @radius * @radius
  end
end

list_of_shapes = [Square.new(3), Circle.new(2)] of Shape
list_of_shapes.each do |shape|
  puts shape.describe("shape")
  puts shape.describe(2)
  puts shape.rename("a") { |name| name.upcase }
  puts shape
end
