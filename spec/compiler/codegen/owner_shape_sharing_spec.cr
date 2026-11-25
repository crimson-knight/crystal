require "../../spec_helper"

# Typed defs that differ only in interchangeable classes share one LLVM
# function (see `Crystal::OwnerShapeSharing`). Each example checks which defs
# share a function and that the program still computes the right value.

private def analyze_shapes(code : String) : Crystal::OwnerShapeSharing
  result = semantic(code, inject_primitives: true)
  sharing = Crystal::OwnerShapeSharing.new(result.program)
  sharing.analyze(result.node)
  sharing
end

# The owner of the def whose function is generated for `owner#name`.
private def function_owner(sharing : Crystal::OwnerShapeSharing, owner : String, name : String) : String
  shape = sharing.shapes.find { |candidate| candidate.typed_def.name == name && candidate.typed_def.owner.to_s == owner }
  shape = shape.should_not be_nil
  (sharing.representative?(shape.typed_def) || shape.typed_def).owner.to_s
end

private def generated_functions(code : String, share : Bool) : Int32
  result = semantic(code, inject_primitives: true)
  result.program.share_owner_shapes = share
  visitor = Crystal::CodeGenVisitor.new(result.program, result.node, single_module: true, debug: Crystal::Debug::None)
  visitor.accept result.node
  visitor.process_finished_hooks
  visitor.finish
  visitor.generated_fun_count
end

describe "Code gen: owner shape sharing" do
  it "shares a def that reads and writes instance variables at equal offsets" do
    code = %(
      class Base
        def initialize(@count : Int32, @step : Int32)
        end

        def advance
          @count = @count &+ @step
          @count &* 2
        end
      end

      class First < Base
      end

      class Second < Base
      end

      first = First.new(1, 10)
      second = Second.new(2, 100)
      first.advance &+ second.advance &+ first.advance
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "First", "advance").should eq("First")
    function_owner(sharing, "Second", "advance").should eq("First")
    run(code).to_i.should eq(22 + 204 + 42)
  end

  it "keeps apart defs whose instance variables sit at different offsets" do
    code = %(
      class First
        def initialize(@count : Int32, @wide : Int64)
        end

        def advance
          @count = @count &+ 1
          @count &* 2
        end
      end

      class Second
        def initialize(@wide : Int64, @count : Int32)
        end

        def advance
          @count = @count &+ 1
          @count &* 2
        end
      end

      First.new(1, 7_i64).advance &+ Second.new(9_i64, 20).advance
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "advance").should eq("Second")
    run(code).to_i.should eq(4 + 42)
  end

  it "shares a def that passes self along to shared defs" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def count_plus(amount : Int32)
          @count &+ amount
        end

        def doubled
          count_plus(1) &* 2
        end

        def total
          doubled &+ helper(self)
        end
      end

      def helper(value : Base)
        value.count_plus(1000)
      end

      class First < Base
      end

      class Second < Base
      end

      First.new(1).total &+ Second.new(20).total
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "count_plus").should eq("First")
    function_owner(sharing, "Second", "doubled").should eq("First")
    function_owner(sharing, "Second", "total").should eq("First")
    run(code).to_i.should eq(4 + 1001 + 42 + 1020)
  end

  it "keeps apart defs that call a method each class overrides, and dispatches on self" do
    code = %(
      abstract class Base
        def initialize(@count : Int32)
        end

        abstract def weight : Int32

        def weighted
          work = @count &* weight
          work &+ 1
        end

        def plain
          work = @count &+ 5
          work &* 3
        end
      end

      class First < Base
        def weight : Int32
          work = 10
          work &+ @count
        end
      end

      class Second < Base
        def weight : Int32
          work = 100
          work &+ @count
        end
      end

      def measure(value : Base)
        value.weighted &+ value.plain
      end

      measure(First.new(1)) &+ measure(Second.new(2))
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "weighted").should eq("Second")
    function_owner(sharing, "Second", "plain").should eq("First")
    run(code).to_i.should eq(11 + 1 + 18 + 204 + 1 + 21)
  end

  it "shares class methods that do not read the class, and keeps apart those that do" do
    code = %(
      class Base
        def self.scale(value : Int32)
          work = value &* 3
          work &+ 1
        end

        def self.tag_id
          work = crystal_instance_type_id
          work &+ 0
        end

        def initialize(@count : Int32)
        end

        def scaled
          self.class.scale(@count) &+ 7
        end

        def tagged
          self.class.tag_id &+ @count
        end
      end

      class First < Base
      end

      class Second < Base
      end

      first = First.new(1)
      second = Second.new(2)
      same = first.tagged &- 1 == First.crystal_instance_type_id && second.tagged &- 2 == Second.crystal_instance_type_id
      different = first.tagged &- 1 != second.tagged &- 2
      (same && different ? 1000 : 0) &+ first.scaled &+ second.scaled &+ First.scale(5) &+ Second.scale(6)
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second.class", "scale").should eq("First.class")
    function_owner(sharing, "Second", "scaled").should eq("First")
    function_owner(sharing, "Second.class", "tag_id").should eq("Second.class")
    function_owner(sharing, "Second", "tagged").should eq("Second")
    run(code).to_i.should eq(1000 + 11 + 14 + 16 + 19)
  end

  it "shares defs of generic classes instantiated with interchangeable classes" do
    code = %(
      class Item
        def initialize(@count : Int32)
        end

        def count
          @count
        end
      end

      class First < Item
      end

      class Second < Item
      end

      class Box(T)
        def initialize(@item : T, @extra : Int32)
        end

        def total
          work = @item.count &+ @extra
          work &* 2
        end

        def swap(other : T)
          previous = @item
          @item = other
          previous
        end
      end

      first_box = Box(First).new(First.new(1), 10)
      second_box = Box(Second).new(Second.new(2), 100)
      old = second_box.swap(Second.new(3))
      older = first_box.swap(First.new(4))
      first_box.total &+ second_box.total &+ old.count &+ older.count
      )
    sharing = analyze_shapes(code)
    # Either copy can stand for the pair: with `CRYSTAL_SHAPE_BODIES=1` the
    # one typed first does.
    function_owner(sharing, "Box(Second)", "total").should eq(function_owner(sharing, "Box(First)", "total"))
    function_owner(sharing, "Box(Second)", "swap").should eq(function_owner(sharing, "Box(First)", "swap"))
    run(code).to_i.should eq(28 + 206 + 2 + 1)
  end

  it "shares a def that passes a block to a yielding def" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def each_step(&)
          yield @count
          yield @count &+ 1
        end

        def sum(extra : Int32)
          total = extra
          each_step { |step| total = total &+ step }
          total
        end
      end

      class First < Base
      end

      class Second < Base
      end

      First.new(1).sum(100) &+ Second.new(10).sum(1000)
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "sum").should eq("First")
    run(code).to_i.should eq(103 + 1021)
  end

  it "keeps apart defs that store self in a mixed union" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def count
          @count
        end

        def self_or_number(number : Bool)
          number ? 5 : self
        end
      end

      class First < Base
      end

      class Second < Base
      end

      def weigh(value : First | Int32)
        value.is_a?(First) ? value.count : -1
      end

      def weigh(value : Second | Int32)
        value.is_a?(Second) ? value.count &* 10 : -2
      end

      weigh(First.new(3).self_or_number(false)) &+ weigh(Second.new(4).self_or_number(false)) &+ weigh(Second.new(4).self_or_number(true))
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "self_or_number").should eq("Second")
    run(code).to_i.should eq(3 + 40 - 1)
  end

  it "keeps apart defs that test or name the class of self" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def matches?(other : Base)
          found = other.is_a?(self)
          found ? @count : 0
        end

        def type_number
          work = self.class.crystal_instance_type_id
          work &+ 0
        end
      end

      class First < Base
      end

      class Second < Base
      end

      class Holder
        def initialize(@held : Base)
        end

        def held
          @held
        end
      end

      first = First.new(1)
      second = Second.new(20)
      ids = first.type_number != second.type_number ? 1000 : 0
      holds_first = Holder.new(first)
      holds_second = Holder.new(second)
      ids &+ first.matches?(holds_first.held) &+ first.matches?(holds_second.held) &+ second.matches?(holds_second.held) &+ second.matches?(holds_first.held)
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "matches?").should eq("Second")
    function_owner(sharing, "Second", "type_number").should eq("Second")
    run(code).to_i.should eq(1000 + 1 + 0 + 20 + 0)
  end

  it "keeps apart defs that allocate their class" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def count
          @count
        end

        def copy_plus(amount : Int32)
          self.class.new(@count &+ amount)
        end
      end

      class First < Base
        def count
          @count &* 2
        end
      end

      class Second < Base
        def count
          @count &* 3
        end
      end

      First.new(1).copy_plus(10).count &+ Second.new(2).copy_plus(20).count
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "Second", "copy_plus").should eq("Second")
    run(code).to_i.should eq(22 + 66)
  end

  it "shares defs that hold another interchangeable class in a nilable instance variable" do
    code = %(
      class Node
        def initialize(@count : Int32)
        end

        def count
          @count
        end
      end

      class FirstNode < Node
      end

      class SecondNode < Node
      end

      class FirstHolder
        @node : FirstNode?

        def node=(@node : FirstNode?)
        end

        def node_count
          node = @node
          node ? node.count &+ 1 : -1
        end
      end

      class SecondHolder
        @node : SecondNode?

        def node=(@node : SecondNode?)
        end

        def node_count
          node = @node
          node ? node.count &+ 1 : -1
        end
      end

      first = FirstHolder.new
      second = SecondHolder.new
      empty = second.node_count
      first.node = FirstNode.new(5)
      second.node = SecondNode.new(50)
      first.node_count &+ second.node_count &+ empty
      )
    sharing = analyze_shapes(code)
    function_owner(sharing, "SecondHolder", "node_count").should eq("FirstHolder")
    run(code).to_i.should eq(6 + 51 - 1)
  end

  it "generates fewer functions, and the same number with sharing off" do
    code = %(
      class Base
        def initialize(@count : Int32)
        end

        def advance(step : Int32)
          @count = @count &+ step
          @count &* 2
        end
      end

      class First < Base
      end

      class Second < Base
      end

      class Third < Base
      end

      First.new(1).advance(1) &+ Second.new(2).advance(2) &+ Third.new(3).advance(3)
      )
    shared = generated_functions(code, share: true)
    separate = generated_functions(code, share: false)
    # `initialize` and `advance` of the second and third class.
    (separate - shared).should eq(4)
  end

  it "runs a program with the prelude, strings and exceptions" do
    run(%(
      require "prelude"

      abstract class Record
        getter name : String
        getter errors = [] of String

        def initialize(@name : String, @age : Int32)
        end

        def describe : String
          "\#{@name} (\#{@age})"
        end

        def validate : Bool
          errors << "\#{self.class.name}: name is empty" if @name.empty?
          errors << "age" if @age < 0
          errors.empty?
        end

        def check!
          raise ArgumentError.new(errors.join(", ")) unless validate
          self
        end
      end

      class Person < Record
      end

      class Animal < Record
      end

      output = [] of String
      list = [Person.new("Ada", 36), Animal.new("Rex", 4), Person.new("", 1), Animal.new("", -1)] of Record
      list.each do |record|
        begin
          output << record.check!.describe
        rescue error : ArgumentError
          output << (error.message || "")
        end
      end
      output.join("; ")
      )).to_string.should eq("Ada (36); Rex (4); Person: name is empty; Animal: name is empty, age")
  end
end
