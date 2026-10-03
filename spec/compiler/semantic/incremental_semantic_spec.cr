require "../../spec_helper"

# Differential tests: typing a program, applying an edit with
# `IncrementalSemantic` must give the same typed methods as typing the
# edited program from scratch.

private def compile_typed(dir : String, files : Hash(String, String), prelude = "empty", strict = true) : Program
  files.each do |name, source|
    path = File.join(dir, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
  end
  main = File.join(dir, "main.cr")

  compiler = Compiler.new
  compiler.prelude = prelude
  compiler.no_codegen = true
  compiler.incremental = false
  compiler.color = false
  result = compiler.compile_configure_program(Compiler::Source.new(main, File.read(main)), "fake-no-build") do |program|
    program.strict_signatures_root = dir if strict
    program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
  end
  result.program
end

# Types *before*, applies the edit to *after* incrementally and compares with
# typing *after* from scratch.
private def assert_incremental(before : Hash(String, String), after : Hash(String, String), prelude = "empty", strict = true, file = __FILE__, line = __LINE__)
  with_tempfile("incremental_semantic") do |dir|
    Dir.mkdir_p(dir)
    program = compile_typed(dir, before, prelude, strict)
    sources = before.to_h { |name, source| {File.join(dir, name), source} }

    incremental = IncrementalSemantic.new(program, sources)
    incremental.apply(after.to_h { |name, source| {File.join(dir, name), source} })

    expected = IncrementalSemantic.typed_methods(compile_typed(dir, after, prelude, strict), dir)
    actual = IncrementalSemantic.typed_methods(program, dir)
    expected.should_not be_empty

    # The incremental program may keep methods only the old bodies called.
    expected.each do |key, description|
      actual[key]?.should eq(description), file: file, line: line
    end
    incremental
  end
end

private def assert_unsupported(before : Hash(String, String), after : Hash(String, String), message : String, strict = true, file = __FILE__, line = __LINE__)
  with_tempfile("incremental_semantic") do |dir|
    Dir.mkdir_p(dir)
    program = compile_typed(dir, before, strict: strict)
    sources = before.to_h { |name, source| {File.join(dir, name), source} }
    expect_raises(IncrementalSemantic::Unsupported, message, file: file, line: line) do
      IncrementalSemantic.new(program, sources).apply(after.to_h { |name, source| {File.join(dir, name), source} })
    end
  end
end

describe IncrementalSemantic do
  it "types an edited method body again" do
    incremental = assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo(x : Int32) : Int32
          x + 1
        end

        foo(1)
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def foo(x : Int32) : Int32
          x + 2
        end

        foo(1)
        CRYSTAL
    incremental.retyped.map(&.name).should eq(["foo"])
  end

  it "types a method edited twice" do
    with_tempfile("incremental_semantic_twice") do |dir|
      Dir.mkdir_p(dir)
      main = File.join(dir, "main.cr")
      versions = (1..3).map { |i| %(require "primitives"\n\ndef foo : Int32\n  #{i}\nend\n\nfoo\n) }
      program = compile_typed(dir, {"main.cr" => versions[0]})
      incremental = IncrementalSemantic.new(program, {main => versions[0]})

      incremental.apply({main => versions[1]})
      incremental.retyped.size.should eq(1)
      incremental.apply({main => versions[2]})
      incremental.retyped.size.should eq(1)

      expected = IncrementalSemantic.typed_methods(compile_typed(dir, {"main.cr" => versions[2]}), dir)
      IncrementalSemantic.typed_methods(program, dir).should eq(expected)
    end
  end

  it "types again an instantiation called with named arguments" do
    incremental = assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo(x : Int32, y : Int32 = 2) : Int32
          x + y
        end

        foo(1)
        foo(x: 1, y: 3)
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def foo(x : Int32, y : Int32 = 2) : Int32
          x * y
        end

        foo(1)
        foo(x: 1, y: 3)
        CRYSTAL
    # `foo(1)` uses an expansion with a copy of the body, `foo(x: 1, y: 3)` the def
    incremental.retyped.map(&.name).should eq(["foo", "foo"])
  end

  it "undoes an edit with an error, so the fix is incremental too" do
    with_tempfile("incremental_semantic_undo") do |dir|
      Dir.mkdir_p(dir)
      main = File.join(dir, "main.cr")
      source = ->(body : String) { %(require "primitives"\n\ndef foo(x : Int32) : Int32\n  #{body}\nend\n\nfoo(1)\n) }
      program = compile_typed(dir, {"main.cr" => source.call("x + 1")})
      incremental = IncrementalSemantic.new(program, {main => source.call("x + 1")})

      expect_raises(Crystal::CodeError) do
        incremental.apply({main => source.call("x.no_such_method")})
      end
      incremental.consistent?.should be_true

      incremental.apply({main => source.call("x * 2")})
      incremental.retyped.size.should eq(1)

      expected = IncrementalSemantic.typed_methods(compile_typed(dir, {"main.cr" => source.call("x * 2")}), dir)
      IncrementalSemantic.typed_methods(program, dir).should eq(expected)
    end
  end

  it "adds a method and types the body that calls it" do
    incremental = assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        class Calc
          def run : Int32
            1
          end
        end

        Calc.new.run
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        class Calc
          def run : Int32
            twice(1)
          end

          private def twice(x : Int32) : Int32
            x * 2
          end
        end

        Calc.new.run
        CRYSTAL
    incremental.retyped.map(&.name).should eq(["run"])
  end

  it "adds a method to a module between others" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        module Outer
          module Util
            extend self

            def a(x : Int32) : Int32
              x
            end

            def b(x : Int32) : Int32
              x
            end
          end
        end

        Outer::Util.a(1)
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        module Outer
          module Util
            extend self

            def a(x : Int32) : Int32
              c(x)
            end

            def c(x : Int32) : Int32
              x + 1
            end

            def b(x : Int32) : Int32
              x
            end
          end
        end

        Outer::Util.a(1)
        CRYSTAL
  end

  it "needs a full compilation for an added method overriding another" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nclass A\n  def foo : Int32\n    1\n  end\nend\nclass B < A\nend\nB.new.foo\n)},
      {"main.cr" => %(require "primitives"\nclass A\n  def foo : Int32\n    1\n  end\nend\nclass B < A\n  def foo : Int32\n    2\n  end\nend\nB.new.foo\n)},
      "overrides or overloads")
  end

  it "needs a full compilation for an added method checked with responds_to?" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nclass A\nend\nA.new.responds_to?(:foo)\n)},
      {"main.cr" => %(require "primitives"\nclass A\n  def foo : Int32\n    1\n  end\nend\nA.new.responds_to?(:foo)\n)},
      "responds_to?")
  end

  it "needs a full compilation for an added method of a type macros look at" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nclass A\n  def bar : Int32\n    {{ @type.methods.size }}\n  end\nend\nA.new.bar\n)},
      {"main.cr" => %(require "primitives"\nclass A\n  def bar : Int32\n    {{ @type.methods.size }}\n  end\n\n  def foo : Int32\n    1\n  end\nend\nA.new.bar\n)},
      "looks at the methods")
  end

  it "needs a full compilation when an edit assigns an instance variable a new type" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nclass A\n  @x = 1\n  def set : Nil\n    @x = 2\n  end\nend\nA.new.set\n)},
      {"main.cr" => %(require "primitives"\nclass A\n  @x = 1\n  def set : Nil\n    @x = 'a'\n  end\nend\nA.new.set\n)},
      "new type")
  end

  it "finds a moved method by its new location on the next edit" do
    with_tempfile("incremental_semantic_moved") do |dir|
      Dir.mkdir_p(dir)
      main = File.join(dir, "main.cr")
      v1 = %(require "primitives"\ndef a : Int32\n  1\nend\ndef b : Int32\n  2\nend\na\nb\n)
      v2 = %(require "primitives"\ndef a : Int32\n  x = 1\n  x\nend\ndef b : Int32\n  2\nend\na\nb\n)
      v3 = %(require "primitives"\ndef a : Int32\n  x = 1\n  x\nend\ndef b : Int32\n  3\nend\na\nb\n)
      program = compile_typed(dir, {"main.cr" => v1})
      incremental = IncrementalSemantic.new(program, {main => v1})
      incremental.apply({main => v2})
      incremental.apply({main => v3})
      incremental.retyped.map(&.name).should eq(["b"])

      expected = IncrementalSemantic.typed_methods(compile_typed(dir, {"main.cr" => v3}), dir)
      IncrementalSemantic.typed_methods(program, dir).should eq(expected)
    end
  end

  it "instantiates methods the new body calls" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def helper(x : Int32) : Int32
          x
        end

        def foo(x : Int32) : Int32
          x
        end

        foo(1)
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def helper(x : Int32) : Int32
          x
        end

        def foo(x : Int32) : Int32
          helper(x) + helper(2)
        end

        foo(1)
        CRYSTAL
  end

  it "keeps the declared type when the body's type changes" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo : Int32 | Char
          1
        end

        x = foo
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def foo : Int32 | Char
          'a'
        end

        x = foo
        CRYSTAL
  end

  # https://forum.crystal-lang.org/t/8718/10
  it "types a body that starts returning nil, as declared" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo(x : Int32) : Int32?
          x + 1
        end

        if y = foo(3)
          y + 1
        end
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def foo(x : Int32) : Int32?
          return nil if x == 0
          x + 1
        end

        if y = foo(3)
          y + 1
        end
        CRYSTAL
  end

  it "types the instantiations of each owner and argument types" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        class Foo
          def initialize(@x : Int32)
          end

          def value(y) : Int32
            @x
          end
        end

        class Bar < Foo
        end

        Foo.new(1).value(1)
        Bar.new(2).value('a')
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        class Foo
          def initialize(@x : Int32)
          end

          def value(y) : Int32
            @x + 10
          end
        end

        class Bar < Foo
        end

        Foo.new(1).value(1)
        Bar.new(2).value('a')
        CRYSTAL
  end

  it "edits a method in a required file" do
    assert_incremental(
      {
        "main.cr"     => %(require "primitives"\nrequire "./lib_code"\nLibCode.run),
        "lib_code.cr" => <<-CRYSTAL,
          module LibCode
            def self.run : Int32
              1 + 1
            end
          end
          CRYSTAL
      },
      {
        "main.cr"     => %(require "primitives"\nrequire "./lib_code"\nLibCode.run),
        "lib_code.cr" => <<-CRYSTAL,
          module LibCode
            def self.run : Int32
              2 * 3
            end
          end
          CRYSTAL
      })
  end

  it "moves the methods below an edit that adds lines" do
    incremental = assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo : Int32
          1
        end

        def bar : Int32
          2
        end

        foo
        bar
        CRYSTAL
      {"main.cr" => <<-CRYSTAL})
        require "primitives"

        def foo : Int32
          a = 1
          a + 1
        end

        def bar : Int32
          2
        end

        foo
        bar
        CRYSTAL
    incremental.retyped.map(&.name).sort.should eq(["bar", "foo"])
  end

  it "works with the prelude" do
    assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        def greet(name : String) : String
          "Hello, \#{name}"
        end

        greet("x")
        CRYSTAL
      {"main.cr" => <<-CRYSTAL}, prelude: "prelude")
        def greet(name : String) : String
          [name, name.upcase].join(" and ")
        end

        greet("x")
        CRYSTAL
  end

  it "needs a full compilation when more than bodies changed" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\ndef foo : Int32\n  1\nend\nfoo)},
      {"main.cr" => %(require "primitives"\ndef foo(x = 1) : Int32\n  1\nend\nfoo)},
      "more than method bodies changed")
  end

  it "types again a method outside strict code when its type stays" do
    assert_incremental(
      {"main.cr" => %(require "primitives"\nrequire "./lib/dep"\nfoo), "lib/dep.cr" => %(def foo : Int32\n  1\nend)},
      {"main.cr" => %(require "primitives"\nrequire "./lib/dep"\nfoo), "lib/dep.cr" => %(def foo : Int32\n  2\nend)})
  end

  it "types again a method without a return type when its type stays" do
    incremental = assert_incremental(
      {"main.cr" => <<-CRYSTAL},
        require "primitives"

        def foo(x)
          x + 1
        end

        def bar
          foo(1) * 2
        end

        bar
        CRYSTAL
      {"main.cr" => <<-CRYSTAL}, strict: false)
        require "primitives"

        def foo(x)
          x * 3
        end

        def bar
          foo(1) * 2
        end

        bar
        CRYSTAL
    incremental.retyped.map(&.name).should eq(["foo"])
    incremental.full_codegen_reason.should be_nil
  end

  it "needs a full compilation when an inferred return type changes" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\ndef foo(x)\n  x + 1\nend\nfoo(1)\n)},
      {"main.cr" => %(require "primitives"\ndef foo(x)\n  x > 0 ? x : nil\nend\nfoo(1)\n)},
      "now has type", strict: false)
  end

  it "needs a full codegen for a trivial body without the firewall" do
    incremental = assert_incremental(
      {"main.cr" => %(require "primitives"\ndef foo\n  1\nend\nfoo\n)},
      {"main.cr" => %(require "primitives"\ndef foo\n  2\nend\nfoo\n)}, strict: false)
    incremental.full_codegen_reason.should_not be_nil
  end

  it "needs a full compilation for a method that yields" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\ndef foo : Int32\n  yield 1\nend\nfoo { |x| x }\n)},
      {"main.cr" => %(require "primitives"\ndef foo : Int32\n  yield 2\nend\nfoo { |x| x }\n)},
      "typed together with its callers")
  end

  it "needs a full compilation for a method expanded with a copy of its body" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\ndef foo(*xs : Int32) : Int32\n  1\nend\nfoo(1, 2)\n)},
      {"main.cr" => %(require "primitives"\ndef foo(*xs : Int32) : Int32\n  2\nend\nfoo(1, 2)\n)},
      "typed together with its callers")
  end

  it "needs a full compilation when the type would change" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nlib LibX\n  fun x : NoReturn\nend\ndef foo : Int32\n  1\nend\nfoo)},
      {"main.cr" => %(require "primitives"\nlib LibX\n  fun x : NoReturn\nend\ndef foo : Int32\n  LibX.x\nend\nfoo)},
      "now has type NoReturn")
  end
end
