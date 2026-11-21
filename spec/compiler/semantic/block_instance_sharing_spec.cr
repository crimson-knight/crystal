require "../../spec_helper"

private def block_instance_stats(code : String) : Crystal::BlockInstanceStats
  semantic(code, inject_primitives: true).program.block_instance_stats
end

describe "Semantic: shared block instances" do
  it "shares one typed def between calls with equal argument and block types" do
    stats = block_instance_stats(%(
      def twice(value, &)
        yield value
        yield value
      end

      a = 0
      b = 0
      twice(1) { |x| a += x }
      twice(2) { |x| b += x }
      twice(3) { |x| a += x + b }
      ))
    stats.typed.should eq(1)
    stats.shared.should eq(2)
  end

  it "types the calls like private clones do" do
    assert_type(%(
      def twice(value, &)
        yield value
        yield value
      end

      a = twice(1) { |x| x + 1 }
      b = twice(2) { |x| x + 2 }
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, int32]) }
  end

  it "gives each block type its own typed def" do
    result = assert_type(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| x }
      b = pass(1) { |x| 'a' }
      c = pass(1) { |x| nil }
      d = pass(1) { |x| x + 1 }
      {a, b, c, d}
      ), inject_primitives: true) { tuple_of([int32, char, nil_type, int32]) }
    stats = result.program.block_instance_stats
    stats.typed.should eq(3)
    stats.shared.should eq(1)
  end

  it "gives each argument type its own typed def" do
    result = assert_type(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| x }
      b = pass('a') { |x| x }
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, char]) }
    result.program.block_instance_stats.shared.should eq(0)
  end

  it "keeps the value of next and break out of the shared def" do
    assert_type(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| next 2 if x == 1; 3 }
      b = pass(1) { |x| break 'a' if x == 1; 3 }
      c = pass(1) { |x| x }
      {a, b, c}
      ), inject_primitives: true) { tuple_of([int32, union_of(int32, char), int32]) }
  end

  it "does not share a def whose yield expressions depend on the block" do
    result = assert_type(%(
      def fold(value, &)
        memo = value
        memo = yield memo
        memo = yield memo
        memo
      end

      a = fold(1) { |x| x.is_a?(Int32) ? 'a' : 1.5 }
      b = fold(1) { |x| x.is_a?(Int32) ? 'b' : 2.5 }
      {a, b}
      ), inject_primitives: true) { tuple_of([union_of(char, float64), union_of(char, float64)]) }
    stats = result.program.block_instance_stats
    stats.typed.should eq(2)
    stats.shared.should eq(0)
  end

  it "does not let a block see the parameter types another block caused" do
    assert_type(%(
      def fold(value, &)
        memo = value
        memo = yield memo
        memo = yield memo
        memo
      end

      a = fold(1) { |x| x.is_a?(Int32) ? 'a' : 1 }
      b = fold(1) { |x| x + 1 }
      {a, b}
      ), inject_primitives: true) { tuple_of([union_of(int32, char), int32]) }
  end

  it "shares a def that yields inside a nested block call" do
    result = assert_type(%(
      def each_number(&)
        i = 0
        while i < 3
          yield i
          i += 1
        end
      end

      def each_double(&)
        each_number { |i| yield i * 2 }
      end

      a = 0
      b = 0
      each_double { |x| a += x }
      each_double { |x| b += x }
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, int32]) }
    stats = result.program.block_instance_stats
    stats.typed.should eq(2)
    stats.shared.should eq(1)
  end

  it "gives a call a private clone when its block type changes later" do
    result = assert_type(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| x }
      y = 1
      b = 0
      i = 0
      while i < 2
        b = pass(1) { |x| y }
        y = 'a'
        i += 1
      end
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, union_of(int32, char)]) }
    stats = result.program.block_instance_stats
    stats.shared.should eq(1)
    stats.diverged.should eq(1)
  end

  it "gives the sharing calls private clones when the first block's type changes later" do
    result = assert_type(%(
      def pass(value, &)
        yield value
      end

      y = 1
      a = 0
      b = 0
      i = 0
      while i < 2
        a = pass(1) { |x| y }
        b = pass(1) { |x| x }
        y = 'a'
        i += 1
      end
      {a, b}
      ), inject_primitives: true) { tuple_of([union_of(int32, char), int32]) }
    result.program.block_instance_stats.diverged.should eq(1)
  end

  it "types a new clone when the arguments of a sharing call change type" do
    assert_type(%(
      def pass(value, &)
        yield value
      end

      a = pass(1) { |x| x }
      y = 1
      b = 0
      i = 0
      while i < 2
        b = pass(y) { |x| x }
        y = 'a'
        i += 1
      end
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, union_of(int32, char)]) }
  end

  it "does not share a def that yields with a scope" do
    result = assert_type(%(
      class Foo
        def value
          1
        end
      end

      def scoped(&)
        with Foo.new yield
      end

      a = scoped { value }
      b = scoped { value }
      {a, b}
      ), inject_primitives: true) { tuple_of([int32, int32]) }
    result.program.block_instance_stats.shared.should eq(0)
  end

  it "shares a def whose block return type binds a free variable" do
    result = assert_type(%(
      class Box(T)
        def initialize(@value : T)
        end

        def value
          @value
        end
      end

      def wrap(value : T, & : T -> U) : Box(U) forall T, U
        Box(U).new(yield value)
      end

      a = wrap(1) { |x| 'a' }
      b = wrap(1) { |x| 'b' }
      c = wrap(1) { |x| x }
      {a.value, b.value, c.value}
      ), inject_primitives: true) { tuple_of([char, char, int32]) }
    stats = result.program.block_instance_stats
    stats.typed.should eq(2)
    stats.shared.should eq(1)
  end

  it "does not share a def that yields a value typed by the block's free variable" do
    result = assert_type(%(
      def chain(value : T, & : -> U) forall T, U
        first = yield value
        pointer = Pointer(U).malloc(1_u64)
        yield pointer.value
        first
      end

      a = chain(1) { |x| 'a' }
      b = chain(1) { |x| 'b' }
      {a, b}
      ), inject_primitives: true) { tuple_of([char, char]) }
    result.program.block_instance_stats.shared.should eq(0)
  end

  it "reports an error inside the block of a sharing call" do
    assert_error %(
      def pass(value, &)
        yield value
      end

      pass(1) { |x| x }
      pass(1) { |x| x.unknown_method }
      ), "undefined method 'unknown_method' for Int32"
  end

  it "reports too many block parameters for a sharing call" do
    assert_error %(
      def pass(value, &)
        yield value
      end

      pass(1) { |x| x }
      pass(1) { |x, y| x }
      ), "too many block parameters (given 2, expected maximum 1)"
  end

  it "types a private clone per call when sharing is off" do
    program = Crystal::Program.new
    program.share_block_instances = false
    node = parse(%(
      def pass(value, &)
        yield value
      end

      pass(1) { |x| x }
      pass(1) { |x| x }
      ))
    program.semantic(program.normalize(node))
    program.block_instance_stats.typed.should eq(0)
    program.block_instance_stats.shared.should eq(0)
  end
end
