require "../../spec_helper"

# A dispatch leaves out the branches for types the program never creates
# (see `Crystal::DispatchPrune`). Each example checks which functions code
# generation emits and that the program still computes the right value.

private GREETERS = <<-CRYSTAL
  module Greeter
    abstract def greet : Int32
  end

  class Plain
    include Greeter

    # Not a literal, so the def gets a function of its own.
    def greet : Int32
      value = 1
      value
    end
  end

  class NeverMade
    include Greeter

    def greet : Int32
      only_through_never_made
    end

    def only_through_never_made : Int32
      2
    end
  end

  CRYSTAL

# The names of the functions code generation emits for *code* with
# pruning on.
private def generated_function_names(code : String, flags = "prune_dispatch") : Array(String)
  result = semantic(code, inject_primitives: true, flags: flags)
  visitor = Crystal::CodeGenVisitor.new(result.program, result.node, single_module: true, debug: Crystal::Debug::None)
  visitor.accept result.node
  visitor.process_finished_hooks
  visitor.finish
  list_of_names = [] of String
  visitor.modules.each_value do |info|
    info.mod.functions.each { |function| list_of_names << function.name }
  end
  list_of_names
end

private def analysis_of(code : String) : Crystal::DispatchPrune::Analysis
  result = semantic(code, inject_primitives: true, flags: "prune_dispatch")
  result.program.analyze_dispatch_prune(result.node).should_not be_nil
end

private def with_forgotten_type(name : String, &)
  ENV["CRYSTAL_PRUNE_DISPATCH_FORGET"] = name
  yield
ensure
  ENV.delete("CRYSTAL_PRUNE_DISPATCH_FORGET")
end

describe "Code gen: dispatch pruning" do
  it "is off with -Dno_prune_dispatch" do
    code = GREETERS + %(
      list = Pointer(Greeter).malloc(1_u64)
      list.value = Plain.new
      list.value.greet
      )
    generated_function_names(code, flags: "no_prune_dispatch").any?(&.includes?("NeverMade#greet")).should be_true
  end

  it "leaves out the includer of a module that nothing creates" do
    code = GREETERS + %(
      list = Pointer(Greeter).malloc(1_u64)
      list.value = Plain.new
      list.value.greet
      )
    list_of_names = generated_function_names(code)
    list_of_names.any?(&.includes?("Plain#greet")).should be_true
    list_of_names.any?(&.includes?("NeverMade#greet")).should be_false
    list_of_names.any?(&.includes?("only_through_never_made")).should be_false
    analysis_of(code).stats.pruned_targets.should eq(1)
    run(code, flags: ["prune_dispatch"]).to_i.should eq(1)
  end

  it "keeps a type created only through a macro" do
    code = GREETERS + %(
      macro make(name)
        {{name}}.new
      end

      list = Pointer(Greeter).malloc(2_u64)
      list.value = Plain.new
      (list + 1_i64).value = make(NeverMade)
      list.value.greet &+ (list + 1_i64).value.greet
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_true
    run(code, flags: ["prune_dispatch"]).to_i.should eq(3)
  end

  it "keeps every type of a union of metaclasses that `new` is called on" do
    code = GREETERS + %(
      class Other
        include Greeter

        def greet : Int32
          value = 10
          value
        end
      end

      def pick(index : Int32)
        index == 0 ? Plain : Other
      end

      klass = pick(1)
      greeter = klass.new
      list = Pointer(Greeter).malloc(1_u64)
      list.value = greeter
      list.value.greet
      )
    list_of_names = generated_function_names(code)
    list_of_names.any?(&.includes?("Other#greet")).should be_true
    list_of_names.any?(&.includes?("Plain#greet")).should be_true
    list_of_names.any?(&.includes?("NeverMade#greet")).should be_false
    run(code, flags: ["prune_dispatch"]).to_i.should eq(10)
  end

  it "keeps a type created through `allocate`" do
    code = GREETERS + %(
      list = Pointer(Greeter).malloc(2_u64)
      list.value = Plain.new
      (list + 1_i64).value = NeverMade.allocate
      list.value.greet &+ (list + 1_i64).value.greet
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_true
    run(code, flags: ["prune_dispatch"]).to_i.should eq(3)
  end

  it "keeps a type a pointer is cast to" do
    code = GREETERS + %(
      list = Pointer(Greeter).malloc(2_u64)
      list.value = Plain.new
      (list + 1_i64).value = Plain.new.as(Void*).as(NeverMade)
      list.value.greet
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_true
  end

  it "keeps a type made by an instance variable initializer of a created type" do
    code = GREETERS + %(
      class Holder
        @greeter : Greeter = NeverMade.new

        def greeter
          @greeter
        end
      end

      list = Pointer(Greeter).malloc(2_u64)
      list.value = Plain.new
      (list + 1_i64).value = Holder.new.greeter
      list.value.greet &+ (list + 1_i64).value.greet
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_true
    run(code, flags: ["prune_dispatch"]).to_i.should eq(3)
  end

  it "keeps a type created in a branch that a later created type opens" do
    code = GREETERS + %(
      class Late
        include Greeter

        def greet : Int32
          list = Pointer(Greeter).malloc(1_u64)
          list.value = NeverMade.new
          list.value.greet &+ 100
        end
      end

      list = Pointer(Greeter).malloc(1_u64)
      list.value = Plain.new
      first = list.value.greet
      list.value = Late.new
      first &+ list.value.greet
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_true
    run(code, flags: ["prune_dispatch"]).to_i.should eq(103)
  end

  it "leaves out a branch selected by an argument type nothing creates" do
    code = GREETERS + %(
      def describe(greeter : Plain) : Int32
        greeter.greet
      end

      def describe(greeter : NeverMade) : Int32
        greeter.greet &+ 50
      end

      list = Pointer(Greeter).malloc(1_u64)
      list.value = Plain.new
      describe(list.value)
      )
    generated_function_names(code).any?(&.includes?("NeverMade#greet")).should be_false
    run(code, flags: ["prune_dispatch"]).to_i.should eq(1)
  end

  it "leaves out a call on a class nothing creates, behind is_a?" do
    code = GREETERS + %(
      list = Pointer(Greeter).malloc(1_u64)
      list.value = Plain.new
      greeter = list.value
      if greeter.is_a?(NeverMade)
        greeter.only_through_never_made
      else
        greeter.greet
      end
      )
    generated_function_names(code).any?(&.includes?("only_through_never_made")).should be_false
    analysis_of(code).stats.dead_calls.should eq(1)
    run(code, flags: ["prune_dispatch"]).to_i.should eq(1)
  end

  it "stops a development build with an unreachable type error when a left out type arrives" do
    code = %(
      require "prelude"
      #{GREETERS}
      list = [Plain.new, NeverMade.new] of Greeter
      list.sum(&.greet)
      )
    with_forgotten_type("NeverMade") do
      with_temp_executable("dispatch_prune_fallback") do |executable|
        compiler = create_spec_compiler
        compiler.flags << "prune_dispatch"
        compiler.compile Crystal::Compiler::Source.new("fallback.cr", code), executable
        output = IO::Memory.new
        status = Process.run(executable, output: output, error: output)
        status.exit_code.should eq(70)
        output.to_s.should contain("Unreachable type: a value of type NeverMade reached the call to `greet`")
      end
    end
  end

  it "stops at a branch check mode keeps, when a left out type takes it" do
    code = %(
      require "prelude"
      #{GREETERS}
      list = [Plain.new, NeverMade.new] of Greeter
      list.sum(&.greet)
      )
    with_forgotten_type("NeverMade") do
      with_temp_executable("dispatch_prune_check") do |executable|
        compiler = create_spec_compiler
        compiler.flags << "prune_dispatch_check"
        compiler.compile Crystal::Compiler::Source.new("check.cr", code), executable
        output = IO::Memory.new
        status = Process.run(executable, output: output, error: output)
        status.exit_code.should eq(70)
        output.to_s.should contain("Unreachable type: a value of type NeverMade")
      end
    end
  end

  it "runs a program in check mode when no left out type arrives" do
    code = %(
      require "prelude"
      #{GREETERS}
      list = [Plain.new, Plain.new] of Greeter
      list.sum(&.greet)
      )
    run(code, flags: ["prune_dispatch_check"]).to_i.should eq(2)
  end

  it "generates the program again in an incremental build when an edit creates a type that was left out" do
    with_tempfile("dispatch_prune_incremental") do |directory|
      Dir.mkdir_p(directory)
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      source = GREETERS + %(list = [Plain.new] of Greeter\nputs list.sum(&.greet)\n)
      build = ->(text : String, turn : Int32) do
        File.write(program, text)
        File.touch(program, Time.utc + (turn * 5).seconds)
        compiler = Crystal::Compiler.new
        compiler.incremental = true
        compiler.n_threads = 2
        compiler.flags << "prune_dispatch"
        compiler.compile(Crystal::Compiler::Source.new(program, text), executable)
        compiler.last_ir_skip_stats || raise "the build kept no keys"
      end

      build.call(source, 1)
      Process.capture(executable).should eq("1\n")

      # The same program again: every module can be skipped.
      stats = build.call(source, 2)
      stats.skipped_units.should be > 10
      Process.capture(executable).should eq("1\n")

      # `NeverMade` is created now: the left out branch must come back.
      stats = build.call(source.sub("[Plain.new]", "[Plain.new, NeverMade.new]"), 3)
      stats.skipped_units.should eq(0)
      Process.capture(executable).should eq("3\n")

      # And goes again when nothing creates it any more.
      build.call(source, 4)
      Process.capture(executable).should eq("1\n")
    end
  end
end
