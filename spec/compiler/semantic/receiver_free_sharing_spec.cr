require "../../spec_helper"

# A method whose body never consults its receiver is typed once for every
# receiver (see `src/compiler/crystal/semantic/receiver_free_sharing.cr`).

private MODELS = %(
  module Reporting
    def report(label : Int32, count : Int32) : Int32
      label + count * 2
    end
  end

  class Model
    include Reporting

    def double(value : Int32) : Int32
      value * 2
    end
  end

  class First < Model
  end

  class Second < Model
  end

  class Third < Model
  end
  )

private def shared_calls(code : String) : Int64
  semantic(MODELS + code, inject_primitives: true).program.receiver_free_shared_calls
end

describe "Semantic: receiver-free copies" do
  it "types an inherited method once for every subclass" do
    shared_calls(%(
      First.new.double(1)
      Second.new.double(2)
      Third.new.double(3)
      )).should eq(2)
  end

  it "types a module's method once for every including class" do
    shared_calls(%(
      First.new.report(1, 2)
      Second.new.report(3, 4)
      )).should eq(1)
  end

  it "types a method once for every instance of a generic class that includes its module" do
    shared_calls(%(
      class Holder(T)
        include Reporting
      end

      Holder(Int32).new.report(1, 2)
      Holder(String).new.report(3, 4)
      )).should eq(1)
  end

  it "keeps a copy per argument type" do
    shared_calls(%(
      class Model
        def pair(value)
          value
        end
      end

      First.new.pair(1)
      Second.new.pair("a")
      )).should eq(0)
  end

  it "keeps a copy per receiver when the body reads self" do
    shared_calls(%(
      class Model
        def me
          self
        end
      end

      First.new.me
      Second.new.me
      )).should eq(0)
  end

  it "keeps a copy per receiver when the body reads an instance variable" do
    shared_calls(%(
      class Model
        @count = 0

        def count
          @count
        end
      end

      First.new.count
      Second.new.count
      )).should eq(0)
  end

  it "keeps a copy per receiver when a call without a receiver finds a method of the receiver (only the called method is shared)" do
    shared_calls(%(
      class Model
        def helper
          1
        end

        def uses_helper
          helper
        end
      end

      First.new.uses_helper
      Second.new.uses_helper
      )).should eq(1)
  end

  it "keeps a copy for a receiver that defines a method a call without a receiver names" do
    program = semantic(MODELS + %(
      def shout(value : Int32) : Int32
        value
      end

      class Model
        def loud(value : Int32)
          shout(value)
        end
      end

      class Third
        def shout(value : Int32) : String
          "loud"
        end
      end

      First.new.loud(1)
      Second.new.loud(2)
      Third.new.loud(3)
      ), inject_primitives: true).program
    program.receiver_free_shared_calls.should eq(1)
  end

  it "keeps a copy per receiver when the body holds macro code" do
    shared_calls(%(
      class Model
        def name_of
          {{ @type.name.stringify }}
        end
      end

      First.new.name_of
      Second.new.name_of
      )).should eq(0)
  end

  it "keeps a copy per receiver for a method that yields" do
    shared_calls(%(
      class Model
        def each_twice(&)
          yield 1
          yield 2
        end
      end

      First.new.each_twice { |value| value }
      Second.new.each_twice { |value| value }
      )).should eq(0)
  end

  it "keeps a copy per receiver for a method with a default argument" do
    shared_calls(%(
      class Model
        def scaled(value : Int32, factor : Int32 = 3) : Int32
          value * factor
        end
      end

      First.new.scaled(1)
      Second.new.scaled(2)
      )).should eq(0)
  end

  it "keeps a copy per instance for a method of the generic class itself" do
    shared_calls(%(
      class Holder(T)
        def empty : T?
          nil
        end
      end

      Holder(Int32).new.empty
      Holder(String).new.empty
      )).should eq(0)
  end

  it "keeps the copy of each receiver for a call that dispatches" do
    shared_calls(%(
      model = 1 > 0 ? First.new : Second.new
      model.double(1)
      )).should eq(0)
  end

  it "keeps the copy of each receiver when the body calls a protected method (the protected method itself is shared)" do
    shared_calls(%(
      class Model
        protected def bump(value : Int32) : Int32
          value + 1
        end

        def poke(other : Model) : Int32
          other.bump(1)
        end
      end

      First.new.poke(Second.new)
      Second.new.poke(First.new)
      )).should eq(1)
  end

  it "gives the error a copy of its own would give when a receiver reusing the copy has no access to a protected method" do
    assert_error MODELS + %(
      class Vault < Model
        protected def secret : Int32
          1
        end
      end

      class InnerVault < Vault
      end

      class Model
        def peek(vault : Vault) : Int32
          vault.secret
        end
      end

      InnerVault.new.peek(Vault.new)
      First.new.peek(Vault.new)
      ),
      "protected method 'secret' called for Vault", inject_primitives: true
  end

  it "is the same program with sharing on as with sharing off (types of every call)" do
    result = semantic(MODELS + %(
      a = First.new.double(1)
      b = Second.new.report(2, 3)
      c = Third.new.double(4)
      {a, b, c}
      ), inject_primitives: true)
    result.node.type.to_s.should eq("Tuple(Int32, Int32, Int32)")
  end
end
