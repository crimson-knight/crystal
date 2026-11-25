require "../../spec_helper"

# Programs whose receiver-free methods share one typed copy run the same as
# with a copy for each receiver (`CRYSTAL_SHARE_RECEIVER_FREE=0`).

private MODELS = %(
  require "prelude"

  module Reporting
    def report(label : String, count : Int32) : String
      "\#{label}=\#{count * 2}"
    end
  end

  class Model
    include Reporting

    def initialize(@id : Int32)
    end

    def id : Int32
      @id
    end

    def double(value : Int32) : Int32
      value * 2
    end
  end

  class First < Model
  end

  class Second < Model
    def initialize(@id : Int32, @extra : String)
    end
  end

  class Third < Second
  end
  )

describe "Code gen: receiver-free copies" do
  it "runs an inherited method shared by subclasses of different layouts" do
    run(MODELS + %(
      [First.new(1).double(1), Second.new(2, "x").double(2), Third.new(3, "y").double(3)].join(",")
      )).to_string.should eq("2,4,6")
  end

  it "runs a module's method shared by its including classes and generic instances" do
    run(MODELS + %(
      class Holder(T)
        include Reporting
      end

      [First.new(1).report("a", 1), Second.new(2, "x").report("b", 2), Holder(Int32).new.report("c", 3), Holder(String).new.report("d", 4)].join(",")
      )).to_string.should eq("a=2,b=4,c=6,d=8")
  end

  it "runs a shared method called without a receiver from a subclass's own method" do
    run(MODELS + %(
      class Second
        def quadruple(value : Int32) : Int32
          double(double(value))
        end
      end

      Second.new(1, "x").quadruple(3) + Third.new(1, "y").quadruple(1) + First.new(1).double(1)
      )).to_i.should eq(18)
  end

  it "runs a shared method called on a virtual receiver" do
    run(MODELS + %(
      list = [First.new(1), Second.new(2, "x")] of Model
      total = 0
      list.each { |model| total += model.double(model.id) }
      total + First.new(5).double(1)
      )).to_i.should eq(8)
  end

  it "runs a shared class method" do
    run(MODELS + %(
      class Model
        def self.scale(value : Int32) : Int32
          value * 10
        end
      end

      First.scale(1) + Second.scale(2) + Third.scale(3)
      )).to_i.should eq(60)
  end

  it "runs a shared class method on a generic metaclass" do
    run(MODELS + %(
      class Holder(T)
        def self.scale(value : Int32) : Int32
          value * 10
        end
      end

      Holder(Int32).scale(1) + Holder(String).scale(2)
      )).to_i.should eq(30)
  end

  it "calls the receiver's own method where a call without a receiver finds one" do
    run(MODELS + %(
      def shout(value : Int32) : String
        "top \#{value}"
      end

      class Model
        def loud(value : Int32) : String
          shout(value)
        end
      end

      class Third
        def shout(value : Int32) : String
          "third \#{value}"
        end
      end

      [First.new(1).loud(1), Second.new(2, "x").loud(2), Third.new(3, "y").loud(3)].join(",")
      )).to_string.should eq("top 1,top 2,third 3")
  end

  it "raises from a shared method with the caller's handler" do
    run(MODELS + %(
      class Model
        def checked(value : Int32) : Int32
          raise "bad \#{value}" if value < 0
          value
        end
      end

      begin
        First.new(1).checked(1) + Second.new(2, "x").checked(-2)
        "none"
      rescue ex
        ex.message.not_nil!
      end
      )).to_string.should eq("bad -2")
  end

  it "generates a shared copy typed first for a class that is never created" do
    run(MODELS + %(
      class Ghost < Model
      end

      def no_ghost : Ghost?
        nil
      end

      ghost_value = no_ghost.try &.double(1)
      (ghost_value || 0) + First.new(2).double(3) + Second.new(1, "x").double(4)
      )).to_i.should eq(14)
  end
end
