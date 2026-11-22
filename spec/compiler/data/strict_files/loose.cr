# crystal: strict
require "strict"

class Greeter
  def greet(name)
    "hello #{name}"
  end

  def with_block(&block)
    block.call
    "called"
  end
end

puts Greeter.new.greet("Ada")
puts Greeter.new.with_block { }
