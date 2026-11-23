require "../../spec_helper"

# A typed-once method of a generic class with a bounded type parameter is
# typed once for every instance (see
# `src/compiler/crystal/semantic/generic_type_once.cr`).

private RECORDS = %(
  class Record
    def self.kind : Int32
      0
    end
  end

  class First < Record
    def self.kind : Int32
      1
    end
  end

  class Second < Record
    def self.kind : Int32
      2
    end
  end

  class Third < Record
  end
  )

private BOX = RECORDS + %(
  @[TypeBound(T, Record)]
  class Box(T)
    def initialize(@count : Int32)
    end
  end
  )

# The number of typed copies of *def_name* across every instance of
# *generic_name*, its metaclasses included.
private def typed_copies(program : Crystal::Program, generic_name : String, def_name : String) : Int32
  generic = program.types[generic_name].as(Crystal::GenericClassType)
  generic.instantiated_types.sum do |instance|
    owners = [instance, instance.metaclass] of Crystal::Type
    owners.sum do |owner|
      container = owner.as(Crystal::DefInstanceContainer)
      container.def_instances.count { |_, typed_def| typed_def.name == def_name }
    end
  end
end

private def copies(code : String, def_name : String, generic_name = "Box") : Int32
  typed_copies(semantic(code, inject_primitives: true).program, generic_name, def_name)
end

describe "Semantic: typed once for every instance of a generic class" do
  it "types a method once for every instance whose argument is within the bound" do
    copies(BOX + %(
      class Box(T)
        @[TypeOnce]
        def total(extra : Int32) : Int32
          @count + extra
        end
      end

      Box(First).new(1).total(1)
      Box(Second).new(2).total(2)
      Box(Third).new(3).total(3)
      ), "total").should eq(1)
  end

  it "keeps one copy per instance without a bound" do
    copies(RECORDS + %(
      class Box(T)
        def initialize(@count : Int32)
        end

        @[TypeOnce]
        def total(extra : Int32) : Int32
          @count + extra
        end
      end

      Box(First).new(1).total(1)
      Box(Second).new(2).total(2)
      ), "total").should eq(2)
  end

  it "types the bounded parameter as the bound's virtual metaclass" do
    assert_type(BOX + %(
      class Box(T)
        @[TypeOnce]
        def kind : Int32
          T.kind
        end

        @[TypeOnce]
        def model : Record.class
          T
        end
      end

      Box(First).new(1).kind
      Box(Second).new(1).model
      ), inject_primitives: true) { types["Record"].virtual_type.metaclass }
  end

  it "shares a copy between instances that differ only in a bounded argument" do
    copies(RECORDS + %(
      @[TypeBound(K, Record)]
      class Pair(K, V)
        def initialize(@value : V)
        end

        @[TypeOnce]
        def size : Int32
          1
        end
      end

      Pair(First, Int32).new(1).size
      Pair(Second, Int32).new(2).size
      Pair(Third, Char).new('a').size
      ), "size", "Pair").should eq(2)
  end

  it "keeps one copy per instance when an instance variable's layout differs between instances" do
    code = RECORDS + %(
      @[TypeBound(T, Record)]
      class Holder(T)
        def initialize(@item : T | Int32)
        end

        @[TypeOnce]
        def one : Int32
          1
        end
      end

      Holder(First).new(1).one
      Holder(Second).new(2).one
      )
    typed_copies(semantic(code, inject_primitives: true).program, "Holder", "one").should eq(2)
    assert_warning code, "method 'Holder(T)#one' is typed for each instance of Holder(T), as before. To have it typed once for every instance, give @item a type with the same layout in every instance"
  end

  it "keeps one copy per instance when the method reads an instance variable whose type mentions the parameter" do
    code = RECORDS + %(
      @[TypeBound(T, Record)]
      class Holder(T)
        def initialize(@items : Array(T))
        end

        @[TypeOnce]
        def present : Bool
          !@items.nil?
        end
      end

      Holder(First).new(Array(First).new).present
      Holder(Second).new(Array(Second).new).present
      )
    typed_copies(semantic(code, inject_primitives: true).program, "Holder", "present").should eq(2)
    assert_warning code, "read @items through a method typed for each instance: its type depends on the type argument (Array(First) in Holder(First))"
  end

it "types once a method that only sets an instance variable whose type mentions the parameter to nil" do
  copies(RECORDS + %(
    @[TypeBound(T, Record)]
    class Holder(T)
      def initialize(@item : T?, @callback : Proc(T, Int32)?)
      end

      @[TypeOnce]
      def forget : Nil
        @item = nil
      end
    end

    Holder(First).new(nil, nil).forget
    Holder(Second).new(nil, nil).forget
    ), "forget", "Holder").should eq(1)
end

it "types once a method that reads an instance variable whose type is the bounded parameter" do
  copies(RECORDS + %(
    @[TypeBound(T, Record)]
    class Holder(T)
      def initialize(@item : T)
      end

      @[TypeOnce]
      def present : Bool
        !@item.nil?
      end
    end

    Holder(First).new(First.new).present
    Holder(Second).new(Second.new).present
    ), "present", "Holder").should eq(1)
end

it "keeps one copy per instance when the method writes an instance variable whose type is the bounded parameter" do
  assert_warning RECORDS + %(
    @[TypeBound(T, Record)]
    class Holder(T)
      def initialize(@item : T)
      end

      @[TypeOnce]
      def replace(other : Record) : Nil
        @item = other.as(T)
        nil
      end
    end

    Holder(First).new(First.new).replace(First.new)
    ), "Holder(T)#replace"
end

  it "keeps one copy per instance when the return type mentions the parameter" do
    code = BOX + %(
      class Box(T)
        @[TypeOnce]
        def make : T
          T.new
        end
      end

      Box(First).new(1).make
      Box(Second).new(2).make
      )
    typed_copies(semantic(code, inject_primitives: true).program, "Box", "make").should eq(2)
    assert_warning code, "write the return type of 'make' without T"
  end

  it "keeps one copy per instance when the parameter is used as a type in the body" do
    assert_warning BOX + %(
      class Box(T)
        @[TypeOnce]
        def first?(value : Record) : Bool
          value.is_a?(T)
        end
      end

      Box(First).new(1).first?(First.new)
      ), "write the check is_a?(T) without T"
  end

  it "keeps one copy per instance when self is passed on" do
    assert_warning BOX + %(
      def take(value) : Int32
        1
      end

      class Box(T)
        @[TypeOnce]
        def hand : Int32
          take(self)
        end
      end

      Box(First).new(1).hand
      ), "use `self` only as the receiver of calls"
  end

  it "follows the methods the copy calls on self" do
    code = BOX + %(
      class Box(T)
        def count : Int32
          @count
        end

        def kind : Int32
          T.kind
        end

        @[TypeOnce]
        def sum : Int32
          count + kind
        end
      end

      Box(First).new(1).sum
      Box(Second).new(2).sum
      Box(Third).new(3).sum
      )
    program = semantic(code, inject_primitives: true).program
    typed_copies(program, "Box", "sum").should eq(1)
    typed_copies(program, "Box", "kind").should eq(1)
  end

  it "keeps one copy per instance when a method the copy calls reads the parameter as a type" do
    assert_warning BOX + %(
      class Box(T)
        def check(value : Record) : Bool
          value.is_a?(T)
        end

        @[TypeOnce]
        def ok : Bool
          check(Record.new)
        end
      end

      Box(First).new(1).ok
      ), "write the check is_a?(T) without T"
  end

  it "gives each caller its own instance back from a method that returns self" do
    code = BOX + %(
    class Box(T)
      def bump : Nil
        @count = @count + 1
      end

      @[TypeOnce]
      def step! : self
        bump
        self
      end

      @[TypeOnce]
      def twice! : self
        step!.step!
      end
    end

    Box(First).new(1).twice!
    Box(Second).new(2).twice!
    )
    program = semantic(code, inject_primitives: true).program
    typed_copies(program, "Box", "twice!").should eq(1)
    typed_copies(program, "Box", "step!").should eq(1)
    assert_type(code, inject_primitives: true) { generic_class("Box", types["Second"]) }
  end

  it "keeps one copy per instance when a method that returns self passes its result on" do
    assert_warning BOX + %(
    def take(value) : Int32
      1
    end

    class Box(T)
      @[TypeOnce]
      def step! : self
        self
      end

      @[TypeOnce]
      def hand : Int32
        take(step!)
      end
    end

    Box(First).new(1).hand
    ), "use the result of 'step!' (it is `self`) only to call methods on, or drop it"
  end

  it "keeps one copy per instance when a method that declares self returns something else" do
    assert_warning BOX + %(
    class Box(T)
      @[TypeOnce]
      def other! : self
        Box(T).new(1)
      end
    end

    Box(First).new(1).other!
    ), "return `self` from every exit of 'other!'"
  end

  it "types a class method once for every instance" do
    copies(BOX + %(
      class Box(T)
        @[TypeOnce]
        def self.unit(count : Int32) : Int32
          count + 1
        end
      end

      Box(First).unit(1)
      Box(Second).unit(2)
      Box(Third).unit(3)
      ), "unit").should eq(1)
  end

  it "keeps one copy per instance for a class method that reads the parameter" do
    code = BOX + %(
      class Box(T)
        @[TypeOnce]
        def self.kind : Int32
          T.kind
        end
      end

      Box(First).kind
      Box(Second).kind
      )
    typed_copies(semantic(code, inject_primitives: true).program, "Box", "kind").should eq(2)
    assert_warning code, "read T in an instance method, or pass the class as a parameter"
  end

  it "shares the copy with a subclass of an instance that overrides nothing it calls" do
    copies(BOX + %(
      class Box(T)
        def count : Int32
          @count
        end

        @[TypeOnce]
        def twice : Int32
          count * 2
        end
      end

      class FirstBox < Box(First)
      end

      box = FirstBox.new(1).as(Box(First))
      box.twice
      Box(Second).new(2).twice
      ), "twice").should eq(1)
  end

  it "keeps one copy per instance when a subclass of an instance overrides a method the copy calls" do
    assert_warning BOX + %(
      class Box(T)
        def count : Int32
          @count
        end

        @[TypeOnce]
        def twice : Int32
          count
        end
      end

      class FirstBox < Box(First)
        @[Override]
        def count : Int32
          7
        end
      end

      box = FirstBox.new(1).as(Box(First))
      box.twice
      ), "leave 'count' as it is in FirstBox"
  end

  it "types a fully typed method of a strict file once for every instance" do
    program = semantic(%(
      require "strict"

      class Item
      end

      class Book < Item
      end

      class Song < Item
      end

      @[TypeBound(T, Item)]
      class Shelf(T)
        def initialize(@count : Int32)
        end

        def total(extra : Int32) : Int32
          @count + extra
        end
      end

      Shelf(Book).new(1).total(1)
      Shelf(Song).new(2).total(2)
      ), inject_primitives: true).program
    typed_copies(program, "Shelf", "total").should eq(1)
  end

  describe "@[TypeBound]" do
    it "requires a class as the bound" do
      assert_error RECORDS + %(
        struct Point
        end

        @[TypeBound(T, Point)]
        class Box(T)
          @[TypeOnce]
          def one : Int32
            1
          end
        end

        Box(Point).new.one
        ), "the bound of T must be a class", inject_primitives: true
    end

    it "requires the name of a type parameter" do
      assert_error RECORDS + %(
        @[TypeBound(U, Record)]
        class Box(T)
          @[TypeOnce]
          def one : Int32
            1
          end
        end

        Box(First).new.one
        ), "Box(T) has no type parameter U", inject_primitives: true
    end

    it "keeps one copy per instance whose argument is outside the bound" do
      copies(BOX + %(
        class Other
        end

        class Box(T)
          @[TypeOnce]
          def one : Int32
            1
          end
        end

        Box(First).new(1).one
        Box(Other).new(2).one
        Box(Int32).new(3).one
        ), "one").should eq(3)
    end
  end
end
