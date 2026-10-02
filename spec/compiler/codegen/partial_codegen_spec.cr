require "../../spec_helper"

# Builds *before*, edits it to *after* with `IncrementalSemantic`, generates
# code again with `Compiler#codegen_again` and runs the result. Returns the
# reason a full codegen was needed (`nil` if only the changed modules were
# generated) and the program's output.
private def rebuild_partially(before : String, after : String) : {String?, String}
  with_tempfile("partial_codegen_sources") do |dir|
    Dir.mkdir_p(dir)
    main = File.join(dir, "main.cr")
    File.write(main, before)

    with_temp_executable "partial_codegen" do |output|
      compiler = create_spec_compiler
      compiler.incremental = false
      sources = [Compiler::Source.new(main, before)]
      result = compiler.compile_configure_program(sources, output) do |program|
        program.strict_signatures_root = dir
        program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
        program.codegen_snapshot = Program::CodegenSnapshot.new
      end

      program = result.program
      new_instances = program.collected_def_instances = [] of Def
      incremental = IncrementalSemantic.new(program, {main => before})
      incremental.apply({main => after})
      program.collected_def_instances = nil

      changed_types = (incremental.retyped + new_instances).map(&.owner)
      reason = compiler.codegen_again(result, [Compiler::Source.new(main, after)], output, changed_types)
      {reason, Process.run(output, output: :pipe) { |process| process.output.gets_to_end }}
    end
  end
end

describe "Code gen: partial codegen" do
  it "generates only the module of an edited method" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Greeter
        def greet(name : String) : String
          "Hello, " + name
        end
      end

      class Other
        def value : Int32
          1
        end
      end

      puts Greeter.new.greet("x"), Other.new.value
      CRYSTAL
      class Greeter
        def greet(name : String) : String
          "Bye, " + name
        end
      end

      class Other
        def value : Int32
          1
        end
      end

      puts Greeter.new.greet("x"), Other.new.value
      CRYSTAL
    reason.should be_nil
    output.should eq("Bye, x\n1\n")
  end

  it "generates new instantiations the edited method calls" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Calc
        def twice(x : Int32) : Int32
          x * 2
        end

        def run : Int32
          twice(1)
        end

        def helper(x : Int32) : Int32
          x + 100
        end
      end

      puts Calc.new.run
      CRYSTAL
      class Calc
        def twice(x : Int32) : Int32
          x * 2
        end

        def run : Int32
          twice(1) + helper(1)
        end

        def helper(x : Int32) : Int32
          x + 100
        end
      end

      puts Calc.new.run
      CRYSTAL
    reason.should be_nil
    output.should eq("103\n")
  end

  it "falls back to a full codegen for a new symbol" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Namer
        def name : String
          :one.to_s
        end
      end

      puts Namer.new.name
      CRYSTAL
      class Namer
        def name : String
          :two.to_s
        end
      end

      puts Namer.new.name
      CRYSTAL
    reason.should eq("new symbols")
    output.should eq("two\n")
  end

  it "falls back to a full codegen for a new type" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Holder(T)
        def initialize(@value : T)
        end

        def value : T
          @value
        end
      end

      class Maker
        def make : Int32
          Holder.new(1).value
        end
      end

      puts Maker.new.make
      CRYSTAL
      class Holder(T)
        def initialize(@value : T)
        end

        def value : T
          @value
        end
      end

      class Maker
        def make : Int32
          Holder.new(2_i64).value.to_i32
        end
      end

      puts Maker.new.make
      CRYSTAL
    reason.should_not be_nil
    output.should eq("2\n")
  end
end
