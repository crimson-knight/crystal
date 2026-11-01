require "spec"
require "llvm"

describe LLVM::TargetMachine do
  describe "#dispose" do
    it "can be called more than once" do
      LLVM.init_native_target
      triple = LLVM.default_target_triple
      target_machine = LLVM::Target.from_triple(triple).create_target_machine(triple)

      target_machine.dispose
      target_machine.dispose
    end
  end
end
