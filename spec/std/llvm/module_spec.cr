require "spec"
require "llvm"

describe LLVM::Module do
  describe "#sort_by_name" do
    it "orders the global variables by name, definitions before declarations" do
      context = LLVM::Context.new
      mod = context.new_module("sorted_globals")
      mod.globals.add(context.int32, "zeta_type_id")
      mod.globals.add(context.int32, "omega_counter").initializer = context.int32.const_int(7)
      mod.globals.add(context.int32, "alpha_type_id")
      mod.globals.add(context.int32, "beta_counter").initializer = context.int32.const_int(3)

      mod.sort_by_name

      list_of_names = mod.to_s.lines.compact_map { |line| line.match(/^@(\w+) =/).try(&.[1]) }
      list_of_names.should eq(%w(beta_counter omega_counter alpha_type_id zeta_type_id))
    end

    it "orders the functions by name, definitions before declarations" do
      context = LLVM::Context.new
      mod = context.new_module("sorted_functions")
      function_type = LLVM::Type.function([] of LLVM::Type, context.void)
      list_of_definitions = %w(zeta_init alpha_init).map { |name| mod.functions.add(name, function_type) }
      mod.functions.add("callee_declared", function_type)
      list_of_definitions.each do |function|
        builder = context.new_builder
        builder.position_at_end(function.basic_blocks.append)
        builder.ret
      end
      mod.functions.add("another_declared", function_type)

      mod.sort_by_name

      list_of_names = mod.to_s.lines.compact_map { |line| line.match(/^(?:define|declare) void @(\w+)/).try(&.[1]) }
      list_of_names.should eq(%w(alpha_init zeta_init another_declared callee_declared))
    end
  end
end
