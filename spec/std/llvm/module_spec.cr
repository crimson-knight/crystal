require "spec"
require "llvm"

describe LLVM::Module do
  describe "#sort_global_declarations_by_name" do
    it "moves the global declarations after the definitions, in name order" do
      context = LLVM::Context.new
      mod = context.new_module("sorted_globals")
      mod.globals.add(context.int32, "zeta_type_id")
      defined = mod.globals.add(context.int32, "defined_counter")
      defined.initializer = context.int32.const_int(7)
      mod.globals.add(context.int32, "alpha_type_id")

      mod.sort_global_declarations_by_name

      list_of_names = mod.to_s.lines.compact_map { |line| line.match(/^@(\w+) =/).try(&.[1]) }
      list_of_names.should eq(%w(defined_counter alpha_type_id zeta_type_id))
    end
  end
end
