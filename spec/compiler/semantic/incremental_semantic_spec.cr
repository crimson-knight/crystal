require "../../spec_helper"

# Differential tests: typing a program, applying an edit with
# `IncrementalSemantic` must give the same typed methods as typing the
# edited program from scratch.

private def compile_typed(dir : String, files : Hash(String, String), prelude = "empty") : Program
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
    program.strict_signatures_root = dir
    program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
  end
  result.program
end

# Types *before*, applies the edit to *after* incrementally and compares with
# typing *after* from scratch.
private def assert_incremental(before : Hash(String, String), after : Hash(String, String), prelude = "empty", file = __FILE__, line = __LINE__)
  with_tempfile("incremental_semantic") do |dir|
    Dir.mkdir_p(dir)
    program = compile_typed(dir, before, prelude)
    sources = before.to_h { |name, source| {File.join(dir, name), source} }

    incremental = IncrementalSemantic.new(program, sources)
    incremental.apply(after.to_h { |name, source| {File.join(dir, name), source} })

    expected = IncrementalSemantic.typed_methods(compile_typed(dir, after, prelude), dir)
    actual = IncrementalSemantic.typed_methods(program, dir)
    expected.should_not be_empty

    # The incremental program may keep methods only the old bodies called.
    expected.each do |key, description|
      actual[key]?.should eq(description), file: file, line: line
    end
    incremental
  end
end

private def assert_unsupported(before : Hash(String, String), after : Hash(String, String), message : String, file = __FILE__, line = __LINE__)
  with_tempfile("incremental_semantic") do |dir|
    Dir.mkdir_p(dir)
    program = compile_typed(dir, before)
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

  it "needs a full compilation for code outside strict mode" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nrequire "./lib/dep"\nfoo), "lib/dep.cr" => %(def foo : Int32\n  1\nend)},
      {"main.cr" => %(require "primitives"\nrequire "./lib/dep"\nfoo), "lib/dep.cr" => %(def foo : Int32\n  2\nend)},
      "isn't strict code")
  end

  it "needs a full compilation for a method that yields" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\ndef foo : Int32\n  yield 1\nend\nfoo { |x| x }\n)},
      {"main.cr" => %(require "primitives"\ndef foo : Int32\n  yield 2\nend\nfoo { |x| x }\n)},
      "typed together with its callers")
  end

  it "needs a full compilation when the type would change" do
    assert_unsupported(
      {"main.cr" => %(require "primitives"\nlib LibX\n  fun x : NoReturn\nend\ndef foo : Int32\n  1\nend\nfoo)},
      {"main.cr" => %(require "primitives"\nlib LibX\n  fun x : NoReturn\nend\ndef foo : Int32\n  LibX.x\nend\nfoo)},
      "now has type NoReturn")
  end
end
