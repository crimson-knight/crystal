require "../../spec_helper"

# Builds *before*, edits it to *after* with `IncrementalSemantic`, generates
# code again with `Compiler#codegen_again` and runs the result. Returns the
# reason a full codegen was needed (`nil` if only the changed modules were
# generated) and the program's output.
private def rebuild_partially(before : String, after : String, strict = true) : {String?, String}
  with_tempfile("partial_codegen_sources") do |dir|
    Dir.mkdir_p(dir)
    main = File.join(dir, "main.cr")
    File.write(main, before)

    with_temp_executable "partial_codegen" do |output|
      compiler = create_spec_compiler
      compiler.incremental = false
      sources = [Compiler::Source.new(main, before)]
      result = compiler.compile_configure_program(sources, output) do |program|
        program.strict_signatures_root = dir if strict
        program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
        program.codegen_snapshot = Program::CodegenSnapshot.new
      end

      program = result.program
      new_instances = program.collected_def_instances = [] of Def
      incremental = IncrementalSemantic.new(program, {main => before})
      incremental.apply({main => after})
      program.collected_def_instances = nil

      after_sources = [Compiler::Source.new(main, after)]
      reason =
        if full_reason = incremental.full_codegen_reason
          compiler.codegen_again(result, after_sources, output)
          full_reason
        else
          changed_types = (incremental.retyped + new_instances).map(&.owner)
          compiler.codegen_again(result, after_sources, output, changed_types)
        end
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

  it "regenerates callers of a method returning a literal" do
    # Codegen inlines trivial bodies at call sites, except behind the return
    # type firewall: the caller in another module must see the new literal.
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Model
        def name : String
          "old"
        end
      end

      class View
        def render(model : Model) : String
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new)
      CRYSTAL
      class Model
        def name : String
          "new"
        end
      end

      class View
        def render(model : Model) : String
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new)
      CRYSTAL
    reason.should be_nil
    output.should eq("<new>\n")
  end

  it "falls back to a full codegen for an instance variable getter" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL)
      class Model
        def initialize(@name : String)
        end

        def name : String
          @name
        end
      end

      class View
        def render(model : Model) : String
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new("x"))
      CRYSTAL
      class Model
        def initialize(@name : String)
        end

        def name : String
          @name.upcase
        end
      end

      class View
        def render(model : Model) : String
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new("x"))
      CRYSTAL
    reason.should_not be_nil
    output.should eq("<X>\n")
  end

  it "generates only the changed module without strict signatures" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL, strict: false)
      class Greeter
        def greet(name)
          "Hello, " + name
        end
      end

      puts Greeter.new.greet("x")
      CRYSTAL
      class Greeter
        def greet(name)
          "Bye, " + name
        end
      end

      puts Greeter.new.greet("x")
      CRYSTAL
    reason.should be_nil
    output.should eq("Bye, x\n")
  end

  it "regenerates the callers of an inlined literal without strict signatures" do
    reason, output = rebuild_partially(<<-CRYSTAL, <<-CRYSTAL, strict: false)
      class Model
        def name
          "old"
        end
      end

      class View
        def render(model)
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new)
      CRYSTAL
      class Model
        def name
          "new"
        end
      end

      class View
        def render(model)
          "<" + model.name + ">"
        end
      end

      puts View.new.render(Model.new)
      CRYSTAL
    reason.should_not be_nil
    output.should eq("<new>\n")
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
