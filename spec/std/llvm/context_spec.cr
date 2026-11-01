require "spec"
require "llvm"

describe LLVM::Context do
  describe "#dispose" do
    it "can be called more than once" do
      context = LLVM::Context.new
      context.new_module("disposed")
      context.new_builder

      context.dispose
      context.dispose
    end

    it "leaves a context it does not own alive" do
      owner = LLVM::Context.new
      borrowed = LLVM::Context.new(owner.to_unsafe, dispose_on_finalize: false)

      borrowed.dispose

      owner.int(32).const_int(42).to_s.should eq("i32 42")
    end
  end
end
