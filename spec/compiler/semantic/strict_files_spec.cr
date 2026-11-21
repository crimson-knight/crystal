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

    it "reports an unmarked override of an inherited class method" do
      assert_error STRICT + %(
        class Greeter
          def self.build : Int32
            1
          end
        end

        class Loud < Greeter
          def self.build : Int32
            2
          end
        end
        ), "Loud.build overrides Greeter.build"
    end

    it "reports an unmarked override of a method the superclass defines later in the source" do
      assert_error STRICT + %(
        class Greeter
        end

        class Loud < Greeter
          def greet : Char
            'a'
          end
        end

        class Greeter
          def greet : Int32
            1
          end
        end
        ), "Loud#greet overrides Greeter#greet"
    end

    it "accepts a marked override of a method the superclass defines later in the source" do
      assert_type(STRICT + %(
        class Greeter
        end

        class Loud < Greeter
          @[Override]
          def greet : Char
            'a'
          end
        end

        class Greeter
          def greet : Int32
            1
          end
        end

        Loud.new.greet
        )) { char }
    end

    it "accepts overloads: the same name with different argument types, in one type and in a subclass" do
      assert_no_warning STRICT + %(
        class Greeter
          def greet(times : Int32) : Int32
            1
          end

          def greet(name : String) : Char
            'a'
          end

          def greet(name : String, times : Int32) : Char
            'b'
          end
        end

        class Loud < Greeter
          def greet(loud : Bool) : Char
            'c'
          end
        end

        Loud.new.greet("a")
        Loud.new.greet(true)
        )
    end

    it "reports an unmarked implementation of an abstract def" do
      assert_error STRICT + %(
        abstract class Greeter
          abstract def greet : Char
        end

        class Loud < Greeter
          def greet : Char
            'a'
          end
        end
        ), "Loud#greet overrides Greeter#greet"
    end

    it "accepts a marked implementation of an abstract def" do
      assert_type(STRICT + %(
        abstract class Greeter
          abstract def greet : Char
        end

        class Loud < Greeter
          @[Override]
          def greet : Char
            'a'
          end
        end

        Loud.new.greet
        )) { char }
    end

    it "reports an unmarked initialize with the argument types of an inherited one" do
      assert_error STRICT + %(
        class Greeter
          def initialize
          end
        end

        class Loud < Greeter
          def initialize
          end
        end
        ), "Loud#initialize overrides Greeter#initialize"
    end

    it "accepts a marked initialize, and an unmarked one with other argument types" do
      assert_type(STRICT + %(
        class Greeter
          def initialize
          end
        end

        class Loud < Greeter
          @[Override]
          def initialize
          end

          def initialize(volume : Int32)
          end
        end

        Loud.new(1)
        )) { types["Loud"] }
    end

    {"to_s", "inspect", "==", "hash"}.each do |name|
      it "has no exemption for #{name}" do
        assert_error STRICT + %(
          class Greeter
            def #{name}(other : Int32) : Int32
              1
            end
          end

          class Loud < Greeter
            def #{name}(other : Int32) : Int32
              2
            end
          end
          ), "Loud##{name} overrides Greeter##{name}"
      end
    end

    it "leaves defs a macro generated alone" do
      assert_no_warning STRICT + %(
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
        )
    end

    it "types every qualifying def once without an annotation" do
      result = semantic(STRICT + %(
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
        ))
      result.program.type_once_typed.should eq(1)
      result.program.type_once_reused.should eq(1)
      result.program.warnings.infos.should be_empty
    end

    describe "warnings" do
      it "warns about a parameter and a return type that are not written out, and types the method as today" do
        code = STRICT + %(
          def greet(name)
            name
          end

          {greet(1), greet('a')}
          )
        assert_warning code, "strict file: method 'greet' is typed for each caller, as in an ordinary file. To have it typed once, write the type of parameter 'name' (for example `name : String`); the return type (for example `def greet(...) : String`)"
        assert_type(code) { tuple_of([int32, char]) }
      end

      it "warns about a missing return type alone" do
        assert_warning STRICT + %(
          class Greeter
            def greet(name : String)
              1
            end
          end
          ), "strict file: method 'Greeter#greet' is typed for each caller, as in an ordinary file. To have it typed once, write the return type (for example `def greet(...) : String`)"
      end

      it "names a class method with a dot" do
        assert_warning STRICT + %(
          class Greeter
            def self.build(name) : Int32
              1
            end
          end
          ), "strict file: method 'Greeter.build' is typed for each caller"
      end

      it "warns about a method that yields" do
        code = STRICT + %(
          def twice(value : Int32, & : Int32 -> Char) : Char
            yield value
          end

          twice(1) { |x| 'a' }
          )
        assert_warning code, "strict file: method 'twice' is typed for each caller, as in an ordinary file. To have it typed once, write a typed block parameter that the method calls in place of `yield` (for example `&block : String -> String` and `block.call(value)`)"
        assert_type(code) { char }
      end

      it "warns about a method with macro expressions that read @type" do
        assert_warning STRICT + %(
          class Greeter
            def kind : Int32
              {{ @type.instance_vars.size }}
            end
          end
          ), "strict file: method 'Greeter#kind' is typed for each caller, as in an ordinary file. To have it typed once, write the body without macro expressions that read `@type`, the concrete receiver: let a macro write the whole method, or call a method for the value"
      end

      it "types a method once when its macro expressions do not read @type" do
        result = semantic(STRICT + %(
          class Record
          end

          class First < Record
          end

          class Second < Record
          end

          def read(record : Record) : Int32
            {{ 1 }}
          end

          read(First.new)
          read(Second.new)
          ))
        result.program.warnings.infos.should be_empty
        result.program.type_once_typed.should eq(1)
      end

      it "warns about a splat that collects arguments and about free variables" do
        assert_warning STRICT + %(
          def read(*records : T) : Int32 forall T
            1
          end
          ), "To have it typed once, write a typed collection parameter in place of the splat '*records' (for example `records : Array(String)`); the types the method accepts in place of the free variables (forall T)"
      end

      it "warns about a block parameter without a type" do
        assert_warning STRICT + %(
          class Greeter
            def each_name(&block) : Int32
              block.call
              1
            end
          end
          ), "strict file: method 'Greeter#each_name' is typed for each caller, as in an ordinary file. To have it typed once, write the type of block parameter 'block' (for example `&block : String -> String`)"
      end

      it "warns about a block parameter type without a return type" do
        assert_warning STRICT + %(
          def each_name(&block : Int32 ->) : Int32
            block.call(1)
            1
          end
          ), "To have it typed once, write the return type of block parameter 'block' (for example `&block : String -> String`)"
      end

      it "accepts a block parameter with its type written out, and types the method once" do
        result = semantic(STRICT + %(
          class Record
          end

          class First < Record
          end

          class Second < Record
          end

          def read(record : Record, &block : Int32 -> Int32) : Int32
            block.call(1)
          end

          read(First.new) { |x| x }
          read(Second.new) { |x| x }
          ), inject_primitives: true)
        result.program.warnings.infos.should be_empty
        result.program.type_once_typed.should eq(1)
        result.program.type_once_reused.should eq(1)
      end

      it "accepts a block parameter typed through an alias, and types the method once" do
        result = semantic(STRICT + %(
          class Record
          end

          class First < Record
          end

          class Second < Record
          end

          def read(record : Record, &block : Transform) : Int32
            block.call(1)
          end

          alias Transform = Int32 -> Int32

          read(First.new) { |x| x }
          read(Second.new) { |x| x }
          ), inject_primitives: true)
        result.program.warnings.infos.should be_empty
        result.program.type_once_typed.should eq(1)
        result.program.type_once_reused.should eq(1)
      end

      it "warns about a block parameter restricted to a type that is not a proc" do
        assert_warning STRICT + %(
          def each_name(&block : Int32) : Int32
            block.call
            1
          end
          ), "write a proc type for block parameter 'block' (for example `&block : String -> String`)"
      end

      it "asks initialize for its parameter types only" do
        assert_warning STRICT + %(
          class Greeter
            def initialize(name)
            end
          end
          ), "strict file: method 'Greeter#initialize' leaves types unstated. Write the type of parameter 'name' (for example `name : String`)"
      end

      it "accepts an initialize with typed parameters that yields" do
        assert_no_warning STRICT + %(
          class Greeter
            def initialize(name : Int32, &)
              yield name
            end
          end
          )
      end

      it "asks an abstract def for its types" do
        assert_warning STRICT + %(
          abstract class Greeter
            abstract def greet(name)
          end
          ), "strict file: method 'Greeter#greet' leaves types unstated. Write the type of parameter 'name' (for example `name : String`); the return type (for example `def greet(...) : String`)"
      end

      it "gives one warning for each method" do
        warnings_result(STRICT + %(
          def first(name)
          end

          def second(name) : Int32
            1
          end

          def third(name : Int32) : Int32
            1
          end
          )).size.should eq(2)
      end

      it "stays an error for a missing @[Override] on a method that also leaves types out" do
        assert_error STRICT + %(
          class Greeter
            def greet(name)
              1
            end
          end

          class Greeter
            def greet(name)
              2
            end
          end
          ), "Greeter#greet is already defined"
      end

      it "does not warn in an ordinary file" do
        assert_no_warning %(
          def greet(name, &block)
            yield name
          end

          greet(1) { |x| x }
          )
      end
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
