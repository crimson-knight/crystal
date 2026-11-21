require "../../spec_helper"

# `@[TypeOnce]` types a method once, against the types its signature
# declares (see `src/compiler/crystal/semantic/type_once.cr`).

private RECORDS = %(
  class Record
    def initialize(@id : Int32)
    end

    def id : Int32
      @id
    end
  end

  class First < Record
  end

  class Second < Record
  end

  class Third < Record
  end
  )

private def type_once_counts(code : String) : {Int32, Int32}
  program = semantic(RECORDS + code, inject_primitives: true).program
  {program.type_once_typed, program.type_once_reused}
end

describe "Semantic: @[TypeOnce]" do
  it "types a parameter restricted to a base class once for every subclass passed" do
    type_once_counts(%(
      @[TypeOnce]
      def read(record : Record) : Int32
        record.id
      end

      read(First.new(1))
      read(Second.new(2))
      read(Third.new(3))
      )).should eq({1, 2})
  end

  it "types the parameter as the declared class and its subclasses" do
    assert_type(RECORDS + %(
      @[TypeOnce]
      def pass(record : Record) : Record
        record
      end

      pass(First.new(1))
      ), inject_primitives: true) { types["Record"].virtual_type }
  end

  it "keeps one copy per caller type without the annotation" do
    type_once_counts(%(
      def read(record : Record) : Int32
        record.id
      end

      read(First.new(1))
      read(Second.new(2))
      )).should eq({0, 0})
  end

  it "types self as the declaring class for an inherited instance method" do
    result = semantic(RECORDS + %(
      class Record
        @[TypeOnce]
        def doubled : Int32
          id * 2
        end
      end

      First.new(1).doubled
      Second.new(2).doubled
      Third.new(3).doubled
      ), inject_primitives: true)
    result.program.type_once_typed.should eq(1)
    result.program.type_once_reused.should eq(2)
    record = result.program.types["Record"]
    record.virtual_type.as(Crystal::DefInstanceContainer).def_instances.count { |_, typed_def| typed_def.name == "doubled" }.should eq(1)
  end

  it "types self as the including class for a method of a module" do
    type_once_counts(%(
      module Named
        @[TypeOnce]
        def label(prefix : String) : String
          prefix
        end
      end

      class Record
        include Named
      end

      First.new(1).label("a")
      Second.new(2).label("b")
      Record.new(3).label("c")
      )).should eq({1, 2})
  end

  it "keeps one copy per unrelated class that includes the module" do
    type_once_counts(%(
      module Named
        @[TypeOnce]
        def label(prefix : String) : String
          prefix
        end
      end

      class Left
        include Named
      end

      class Right
        include Named
      end

      Left.new.label("a")
      Right.new.label("b")
      )).should eq({0, 0})
  end

  it "keeps self as the receiver in a struct" do
    type_once_counts(%(
      abstract struct Value
        @[TypeOnce]
        def zero : Int32
          0
        end
      end

      struct Small < Value
      end

      struct Large < Value
      end

      Small.new.zero
      Large.new.zero
      )).should eq({0, 0})
  end

  it "types a parameter restricted to a metaclass once for every class passed" do
    type_once_counts(%(
      @[TypeOnce]
      def table_of(model : Record.class) : Int32
        1
      end

      table_of(First)
      table_of(Second)
      table_of(Record)
      )).should eq({1, 2})
  end

  it "types a union parameter once for every member passed" do
    type_once_counts(%(
      @[TypeOnce]
      def size_of(value : Int32 | String | Nil) : Int32
        value.is_a?(Int32) ? value : 0
      end

      size_of(1)
      size_of("a")
      size_of(nil)
      size_of(1 == 1 ? 1 : nil)
      )).should eq({1, 3})
  end

  it "checks the body against the declared type, not the caller's" do
    assert_error(RECORDS + %(
      class First < Record
        def only_first : Int32
          1
        end
      end

      @[TypeOnce]
      def read(record : Record) : Int32
        record.only_first
      end

      read(First.new(1))
      ), "undefined method 'only_first' for Record", inject_primitives: true)
  end

  it "keeps the usual copies for a call that dispatches over a union receiver" do
    result = semantic(RECORDS + %(
      class Record
        @[TypeOnce]
        def doubled : Int32
          id * 2
        end
      end

      class Other
        def doubled : Int32
          0
        end
      end

      value = 1 == 1 ? First.new(1) : Other.new
      value.doubled
      ), inject_primitives: true)
    result.program.type_once_typed.should eq(0)
  end

  it "picks overloads the same way with and without the annotation" do
    assert_type(RECORDS + %(
      @[TypeOnce]
      def kind(record : Record) : Int32
        1
      end

      def kind(record : First) : Char
        'a'
      end

      {kind(First.new(1)), kind(Second.new(2))}
      ), inject_primitives: true) { tuple_of([char, int32]) }
  end

  it "accepts a compatibility declaration of the annotation" do
    type_once_counts(%(
      annotation TypeOnce
      end

      @[TypeOnce]
      def read(record : Record) : Int32
        record.id
      end

      read(First.new(1))
      read(Second.new(2))
      )).should eq({1, 1})
  end

  describe "errors" do
    it "requires a restriction on every parameter" do
      assert_error %(
        @[TypeOnce]
        def read(record) : Int32
          1
        end
        ), "@[TypeOnce] method 'read' needs a type restriction on parameter 'record'"
    end

    it "requires a return type" do
      assert_error %(
        @[TypeOnce]
        def read(record : Int32)
          1
        end
        ), "@[TypeOnce] method 'read' needs a return type"
    end

    it "rejects free variables" do
      assert_error %(
        @[TypeOnce]
        def read(record : T) : Int32 forall T
          1
        end
        ), "@[TypeOnce] method 'read' can't have free variables (forall T)"
    end

    it "rejects a splat parameter" do
      assert_error %(
        @[TypeOnce]
        def read(*records : Int32) : Int32
          1
        end
        ), "@[TypeOnce] method 'read' can't have a splat parameter"
    end

    it "rejects a method that yields" do
      assert_error %(
        @[TypeOnce]
        def read(record : Int32, &) : Int32
          yield record
        end
        ), "@[TypeOnce] method 'read' can't yield"
    end

    it "requires the types of a captured block" do
      assert_error %(
        @[TypeOnce]
        def read(record : Int32, &block) : Int32
          block.call(record)
        end
        ), "@[TypeOnce] method 'read' needs the block's input and output types"
    end

    it "rejects macro expressions in the body" do
      assert_error %(
        class Record
          @[TypeOnce]
          def read : Int32
            {{ @type.instance_vars.size }}
          end
        end
        ), "@[TypeOnce] method 'read' can't have macro expressions in its body"
    end

    it "rejects an abstract def" do
      assert_error %(
        abstract class Record
          @[TypeOnce]
          abstract def read : Int32
        end
        ), "@[TypeOnce] method 'read' can't be abstract"
    end

    it "rejects initialize" do
      assert_error %(
        class Record
          @[TypeOnce]
          def initialize(@id : Int32) : Nil
          end
        end
        ), "@[TypeOnce] method 'initialize' can't be 'initialize'"
    end

    it "rejects an instance variable only a subclass has" do
      assert_error(RECORDS + %(
        class First < Record
          @extra : Int32 = 1
        end

        class Record
          @[TypeOnce]
          def extra : Int32
            @extra
          end
        end

        First.new(1).extra
        ), "@extra", inject_primitives: true)
    end
  end
end
