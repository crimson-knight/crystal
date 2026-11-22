require "../../spec_helper"

describe "Semantic: ReferenceStorage" do
  it "errors if T is a struct type" do
    assert_error <<-CRYSTAL, "Can't instantiate ReferenceStorage(T) with T = Foo (T must be a reference type)"
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
      end

      struct Foo
        @x = 1
      end

      ReferenceStorage(Foo)
      CRYSTAL
  end

  it "errors if T is a value type" do
    assert_error <<-CRYSTAL, "Can't instantiate ReferenceStorage(T) with T = Int32 (T must be a reference type)"
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
      end

      ReferenceStorage(Int32)
      CRYSTAL
  end

  it "errors if T is a union type" do
    assert_error <<-CRYSTAL, "Can't instantiate ReferenceStorage(T) with T = (Bar | Foo) (T must be a reference type)"
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
      end

      class Foo
      end

      class Bar
      end

      ReferenceStorage(Foo | Bar)
      CRYSTAL
  end

  it "errors if T is a nilable type" do
    assert_error <<-CRYSTAL, "Can't instantiate ReferenceStorage(T) with T = (Foo | Nil) (T must be a reference type)"
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
      end

      class Foo
      end

      ReferenceStorage(Foo?)
      CRYSTAL
  end

  it "accepts a class that has subclasses" do
    assert_type(<<-CRYSTAL) { types["Foo"].metaclass }
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
        def t
          T
        end
      end

      class Foo
      end

      class Bar < Foo
      end

      ReferenceStorage(Foo).new.t
      CRYSTAL
  end

  it "accepts a generic class that has a generic subclass" do
    assert_type(<<-CRYSTAL) { generic_class("Foo", int32).metaclass }
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
        def t
          T
        end
      end

      class Foo(T)
      end

      class Bar(T) < Foo(T)
      end

      ReferenceStorage(Foo(Int32)).new.t
      CRYSTAL
  end

  it "allows a different name" do
    assert_type(<<-CRYSTAL) { types["Foo"].metaclass }
      @[Primitive(:ReferenceStorageType)]
      struct MyRef(U) < Value
        def u
          U
        end
      end

      class Foo
      end

      MyRef(Foo).new.u
      CRYSTAL
  end

  it "adds ReferenceStorage to Value.subclasses once (#15677)" do
    assert_type(<<-CRYSTAL) { bool }
      @[Primitive(:ReferenceStorageType)]
      struct ReferenceStorage(T) < Value
      end

      {{ Value.subclasses.select(&.<=(ReferenceStorage)).size == 1 ? true : nil }}
      CRYSTAL
  end
end
