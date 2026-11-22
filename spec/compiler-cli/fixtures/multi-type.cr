# Several types, so a multi-module build emits several object files.
abstract class Shape
  abstract def area : Float64

  def describe : String
    "#{self.class.name.downcase} #{area.round(2)}"
  end
end

class Circle < Shape
  def initialize(@radius : Float64)
  end

  def area : Float64
    Math::PI * @radius * @radius
  end
end

class Rectangle < Shape
  def initialize(@width : Float64, @height : Float64)
  end

  def area : Float64
    @width * @height
  end
end

struct Tally
  getter total : Float64 = 0.0

  def add(shape : Shape) : Nil
    @total += shape.area
  end
end

list_of_shapes = [Circle.new(1.0), Rectangle.new(2.0, 3.5), Circle.new(0.5)] of Shape
tally = Tally.new
list_of_shapes.each do |shape|
  puts shape.describe
  tally.add(shape)
end
puts "total #{tally.total.round(2)}"
puts({"shapes" => list_of_shapes.size}.to_s)
