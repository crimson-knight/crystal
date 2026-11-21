require "../../spec_helper"

# Runs the block with the typed node pools on, and puts the setting back.
# Every pool starts a new chunk first, so the nodes an example makes one
# after the other never fall on two sides of a chunk boundary.
private def with_node_pools(&)
  was_enabled = Crystal::NodePool.enabled?
  Crystal::NodePool.enabled = true
  Crystal::NodePool.list_of_pools.each &.start_stage(0)
  begin
    yield
  ensure
    Crystal::NodePool.enabled = was_enabled
  end
end

private def address_of(node : ASTNode) : Int64
  node.as(Void*).address.to_i64!
end

describe "Crystal::NodePool" do
  it "gives consecutive instances of one class consecutive slots" do
    with_node_pools do
      first = Var.new("first")
      second = Var.new("second")
      third = Var.new("third")

      slot_bytes = Var::NODE_POOL.slot_bytes
      slot_bytes.should eq((instance_sizeof(Var) + 7) & ~7)
      (address_of(second) - address_of(first)).should eq(slot_bytes)
      (address_of(third) - address_of(second)).should eq(slot_bytes)
    end
  end

  it "keeps instances of different classes in different pools" do
    with_node_pools do
      first_var = Var.new("first")
      call = Call.new("call")
      second_var = Var.new("second")

      (address_of(second_var) - address_of(first_var)).should eq(Var::NODE_POOL.slot_bytes)
      (address_of(call) - address_of(first_var)).abs.should be >= Var::NODE_POOL.slot_bytes
    end
  end

  it "leaves the class, the fields and the identity of a pooled node as they are" do
    with_node_pools do
      call = Call.new(Var.new("receiver"), "name", [Var.new("argument")] of ASTNode)

      call.class.should eq(Call)
      call.should be_a(ASTNode)
      call.name.should eq("name")
      call.obj.as(Var).name.should eq("receiver")
      call.args.size.should eq(1)
      call.same?(call).should be_true
      call.object_id.should eq(call.as(Void*).address)

      copy = call.clone
      copy.same?(call).should be_false
      copy.should eq(call)

      shallow_copy = call.dup
      shallow_copy.same?(call).should be_false
      shallow_copy.class.should eq(Call)
      shallow_copy.obj.should be(call.obj)
    end
  end

  it "runs the instance variable initializers of a pooled node" do
    with_node_pools do
      meta_var = MetaVar.new("variable")
      meta_var.name.should eq("variable")
      meta_var.type?.should be_nil
      meta_var.closured?.should be_false
    end
  end

  it "leaves subclasses of a pooled class to the collector" do
    with_node_pools do
      first = Var.new("first")
      documented = DocumentedVar.new("documented", "doc")
      second = Var.new("second")

      documented.class.should eq(DocumentedVar)
      documented.doc.should eq("doc")
      (address_of(second) - address_of(first)).should eq(Var::NODE_POOL.slot_bytes)
    end
  end

  it "keeps a node the collector reaches only through a pointer into the chunk" do
    with_node_pools do
      list_of_nodes = Array(ASTNode).new(20_000) do |index|
        Call.new(Var.new("receiver#{index}"), "name#{index}")
      end
      3.times { GC.collect }
      # Garbage that would reuse the nodes' memory if a chunk had been freed.
      50_000.times { |index| "filler#{index}" * 3 }

      list_of_nodes.each_with_index do |node, index|
        call = node.as(Call)
        call.name.should eq("name#{index}")
        call.obj.as(Var).name.should eq("receiver#{index}")
      end
    end
  end

  it "puts a codegen-read variable and an inference-only variable in different pools" do
    with_node_pools do
      first = MetaVar.new("first")
      Crystal::NodePool.allocating_for_codegen = true
      kept = MetaVar.new("kept")
      Crystal::NodePool.allocating_for_codegen = false
      second = MetaVar.new("second")

      (address_of(second) - address_of(first)).should eq(MetaVar::INFERENCE_NODE_POOL.slot_bytes)
      kept.name.should eq("kept")
    end
  end

  it "starts a new chunk for each pool when a stage starts" do
    with_node_pools do
      before_stage = Var.new("before")
      Crystal::NodePool.list_of_pools.each &.start_stage(0)
      after_stage = Var.new("after")

      (address_of(after_stage) - address_of(before_stage)).should_not eq(Var::NODE_POOL.slot_bytes)
      before_stage.name.should eq("before")
      after_stage.name.should eq("after")
    end
  end

  it "types and runs a program whose nodes come from the pools" do
    with_node_pools do
      run(%(
        require "prelude"

        class Shape
          def initialize(@side : Int32)
          end

          def area
            @side * @side
          end
        end

        class Rectangle < Shape
          def initialize(side : Int32, @other_side : Int32)
            super(side)
          end

          def area
            @side * @other_side
          end
        end

        def total_area(list_of_shapes)
          total = 0
          list_of_shapes.each { |shape| total += shape.area }
          total
        end

        list_of_shapes = [Shape.new(3), Rectangle.new(2, 5)] of Shape
        value = total_area(list_of_shapes)
        text = value > 10 ? "large" : "small"
        "\#{value} \#{text}"
        )).to_string.should eq("19 large")
    end
  end
end
