require "../../spec_helper"

# `@[Override]` and strict files (see
# `src/compiler/crystal/semantic/strict_files.cr`).

private STRICT = %(
  require "strict"
  )

describe "Semantic: @[Override]" do
  it "accepts a marked redefinition in a reopened type" do
    assert_type(%(
      class Greeter
        def greet
          1
        end
      end

      class Greeter
        @[Override]
        def greet
          'a'
        end
      end

      Greeter.new.greet
      )) { char }
  end

  it "accepts a marked override of an inherited method" do
    assert_type(%(
      class Greeter
        def greet
          1
        end
      end

      class Loud < Greeter
        @[Override]
        def greet
          'a'
        end
      end

      Loud.new.greet
      )) { char }
  end

  it "rejects a marked def that replaces and overrides nothing" do
    assert_error %(
      class Greeter
        @[Override]
        def greet
          1
        end
      end
      ), "'greet' is marked @[Override], but Greeter has no earlier definition of it and inherits no method with that name"
  end

  it "leaves unmarked redefinitions alone outside strict files" do
    assert_type(%(
      class Greeter
        def greet
          1
        end
      end

      class Greeter
        def greet
          'a'
        end
      end

      Greeter.new.greet
      )) { char }
  end

  describe "in a strict file" do
    it "reports an unmarked redefinition" do
      assert_error STRICT + %(
        class Greeter
          def greet : Int32
            1
          end
        end

        class Greeter
          def greet : Char
            'a'
          end
        end
        ), "Greeter#greet is already defined"
    end

    it "reports an unmarked override of an inherited method" do
      assert_error STRICT + %(
        class Greeter
          def greet : Int32
            1
          end
        end

        class Loud < Greeter
          def greet : Char
            'a'
          end
        end
        ), "Loud#greet overrides Greeter#greet"
    end

    it "reports an unmarked override of a method from an included module" do
      assert_error STRICT + %(
        module Polite
          def greet : Int32
            1
          end
        end

        class Greeter
          include Polite

          def greet : Char
            'a'
          end
        end
        ), "Greeter#greet overrides Polite#greet"
    end

    it "reports an unmarked redefinition of a class method" do
      assert_error STRICT + %(
        class Greeter
          def self.build : Int32
            1
          end

          def self.build : Int32
            2
          end
        end
        ), "Greeter.build is already defined"
    end

    it "accepts marked redefinitions and overrides" do
      assert_type(STRICT + %(
        class Greeter
          def greet : Int32
            1
          end
        end

        class Greeter
          @[Override]
          def greet : Char
            'a'
          end
        end

        class Loud < Greeter
          @[Override]
          def greet : String
            "a"
          end
        end

        {Greeter.new.greet, Loud.new.greet}
        )) { tuple_of([char, string]) }
    end

    it "accepts a new overload with a different signature" do
      assert_type(STRICT + %(
        class Greeter
          def greet(times : Int32) : Int32
            1
          end
        end

        class Loud < Greeter
          def greet(name : String) : Char
            'a'
          end
        end

        Loud.new.greet("a")
        )) { char }
    end

    it "accepts an unmarked implementation of an abstract def" do
      assert_type(STRICT + %(
        abstract class Greeter
          abstract def greet : Char
        end

        class Loud < Greeter
          def greet : Char
            'a'
          end
        end

        Loud.new.greet
        )) { char }
    end

    it "accepts unmarked initialize methods" do
      assert_type(STRICT + %(
        class Greeter
          def initialize
          end
        end

        class Loud < Greeter
          def initialize
          end
        end

        Loud.new
        )) { types["Loud"] }
    end

    it "leaves defs a macro generated alone" do
      assert_type(STRICT + %(
        macro define_greet(value)
          def greet
            {{value}}
          end
        end

        class Greeter
          define_greet 1
          define_greet 'a'
        end

        Greeter.new.greet
        )) { char }
    end

    it "requires a type restriction on every parameter" do
      assert_error STRICT + %(
        def greet(name) : Int32
          1
        end
        ), "strict file: method 'greet' needs a type restriction on parameter 'name'"
    end

    it "requires a return type" do
      assert_error STRICT + %(
        def greet(name : String)
          1
        end
        ), "strict file: method 'greet' needs a return type"
    end

    it "types every qualifying def once without an annotation" do
      program = semantic(STRICT + %(
        class Record
        end

        class First < Record
        end

        class Second < Record
        end

        def read(record : Record) : Int32
          1
        end

        read(First.new)
        read(Second.new)
        )).program
      program.type_once_typed.should eq(1)
      program.type_once_reused.should eq(1)
    end

    it "types a def that yields per caller, as in an ordinary file" do
      assert_type(STRICT + %(
        def twice(value : Int32, & : Int32 -> Char) : Char
          yield value
        end

        twice(1) { |x| 'a' }
        )) { char }
    end
  end

  describe "the first-line marker" do
    it "is read from the first line of a file" do
      File.tempfile("strict", ".cr") do |file|
        file.print "# crystal: strict\nclass Foo\nend\n"
        file.flush
        Crystal::Program.strict_marker?(file.path).should be_true
        location = Crystal::Location.new(file.path, 2, 1)
        Crystal::Program.new.strict_file?(location).should be_true
      end
    end

    it "is absent from an ordinary file" do
      File.tempfile("ordinary", ".cr") do |file|
        file.print "class Foo\nend\n# crystal: strict\n"
        file.flush
        Crystal::Program.strict_marker?(file.path).should be_false
      end
    end
  end
end
