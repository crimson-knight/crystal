require "../../spec_helper"

# Calls that pass a block to a yielding def share one typed def when their
# argument and block types are equal (see `Crystal::BlockInstance`). Codegen
# inlines that typed def at each call with the call's own block, so each
# program here checks that every call still runs its own block.
describe "Code gen: shared block instances" do
  it "runs each call's own block" do
    run(%(
      def twice(value, &)
        yield value
        yield value
      end

      a = 0
      b = 0
      twice(1) { |x| a = a &+ x }
      twice(10) { |x| b = b &+ x }
      twice(100) { |x| a = a &+ (x &+ b) }
      a &* 1000 &+ b
      )).to_i.should eq(242_020)
  end

  it "runs blocks that capture different variables" do
    run(%(
      def pass(value, &)
        yield value
      end

      a = 1
      b = 20
      c = 300
      x = pass(1) { |v| v &+ a }
      y = pass(1) { |v| v &+ b }
      z = pass(1) { |v| v &+ c &+ a }
      x &+ y &+ z
      )).to_i.should eq(2 + 21 + 302)
  end

  it "runs blocks with different return types" do
    run(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |v| v &+ 1 }
      b = pass(1) { |v| v == 1 }
      c = pass(1) { |v| v &+ 2 }
      d = pass(1) { |v| nil }
      e = pass(1) { |v| v == 2 }
      total = a &+ c
      total = total &+ 10 if b
      total = total &+ 100 if e
      total = total &+ 1000 if d.nil?
      total
      )).to_i.should eq(2 + 3 + 10 + 1000)
  end

  it "runs next and break with values" do
    run(%(
      def each_number(&)
        i = 0
        while i < 5
          yield i
          i = i &+ 1
        end
        -1
      end

      def pass(value, &)
        yield value
      end

      a = each_number { |i| break i &* 10 if i == 3 }
      b = each_number { |i| break i &* 100 if i == 2 }
      c = each_number { |i| next if i == 1 }
      d = pass(5) { |v| next 7 if v == 5; 9 }
      e = pass(5) { |v| next 7 if v == 6; 9 }
      a &+ b &+ c &+ d &+ e
      )).to_i.should eq(30 + 200 - 1 + 7 + 9)
  end

  it "runs nested yields" do
    run(%(
      def each_number(&)
        i = 1
        while i <= 3
          yield i
          i = i &+ 1
        end
      end

      def each_double(&)
        each_number { |i| yield i &* 2 }
      end

      def each_pair(&)
        each_double do |i|
          each_double do |j|
            yield i, j
          end
        end
      end

      a = 0
      b = 0
      c = 0
      each_double { |x| a = a &+ x }
      each_double { |x| b = b &+ (x &* 10) }
      each_pair { |x, y| c = c &+ (x &* y) }
      each_pair { |x, y| a = a &+ (x &- y) }
      a &+ b &+ c
      )).to_i.should eq(12 + 120 + 144)
  end

  it "runs blocks that are closures" do
    run(%(
      def pass(value, &)
        yield value
      end

      def call_twice(&block : Int32 -> Int32)
        block.call(1) &+ block.call(2)
      end

      a = 10
      b = 200
      x = pass(1) { |v| call_twice { |w| w &+ a &+ v } }
      y = pass(1) { |v| call_twice { |w| w &+ b &+ v } }
      first = ->{ pass(1) { |v| v &+ a } }
      second = ->{ pass(1) { |v| v &+ b } }
      a = 20
      x &+ y &+ first.call &+ second.call
      )).to_i.should eq(25 + 405 + 21 + 201)
  end

  it "runs a def that keeps its own closure" do
    run(%(
      def counted(start, &)
        count = start
        increment = ->{ count = count &+ 1 }
        yield increment
        yield increment
        count
      end

      a = counted(1) { |increment| increment.call }
      b = counted(1) { |increment| increment.call; increment.call }
      a &+ b &* 10
      )).to_i.should eq(3 + 50)
  end

  it "runs a call whose block type changed after it shared a def" do
    run(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| x }
      y = 1
      b = 0
      i = 0
      while i < 2
        b = pass(1) { |x| y } if i == 0
        y = 'a'
        i = i &+ 1
      end
      c = pass(1) { |x| x &+ 5 }
      a &+ c &+ (b.is_a?(Int32) ? b : 100)
      )).to_i.should eq(1 + 6 + 1)
  end

  it "runs block parameters that unpack and splat" do
    run(%(
      def pass_pair(&)
        yield({1, 2})
      end

      def pass_two(&)
        yield 3, 4
      end

      a = pass_pair { |x, y| x &+ y }
      b = pass_pair { |pair| pair[0] &* 10 &+ pair[1] }
      c = pass_two { |x| x }
      d = pass_two { |x, y| x &* y }
      e = pass_two { |*all| all[0] &+ all[1] }
      a &+ b &+ c &+ d &+ e
      )).to_i.should eq(3 + 12 + 3 + 12 + 7)
  end

  it "runs one block dispatched over two receiver types" do
    run(%(
      require "prelude"

      first = {1 => {"x" => 1}}
      second = {2 => {"y" => 'c'}}
      list_of_lines = [] of String
      first.each do |owner, vars|
        vars.each { |name, info| list_of_lines << "\#{owner} \#{name} \#{info}" }
      end
      second.each do |owner, vars|
        vars.each { |name, info| list_of_lines << "\#{owner} \#{name} \#{info}" }
      end
      {first, second}.each do |all_vars|
        all_vars.each do |owner, vars|
          vars.each do |name, info|
            list_of_lines << "\#{owner} \#{name} \#{info}"
          end
        end
      end
      list_of_lines.join(",")
      )).to_string.should eq("1 x 1,2 y c,1 x 1,2 y c")
  end

  it "runs yields under an ensure" do
    run(%(
      require "prelude"

      class Tracker
        class_property log = [] of String
      end

      def tracked(name, &)
        Tracker.log << "open \#{name}"
        yield name
      ensure
        Tracker.log << "close \#{name}"
      end

      first = tracked("a") { |name| name + "1" }
      second = tracked("b") { |name| name + "2" }
      third = begin
        tracked("c") { |name| raise "stop"; name }
      rescue error
        error.message.to_s
      end
      list_of_sizes = [[1, 2], [3]].map { |list| list.map { |number| number * 2 }.sum }
      list_of_names = ["x", "y"].map { |text| text.upcase }
      "\#{first} \#{second} \#{third} \#{list_of_sizes} \#{list_of_names} \#{Tracker.log.join(",")}"
      )).to_string.should eq(%(a1 b2 stop [6, 6] ["X", "Y"] open a,close a,open b,close b,open c,close c))
  end
end
