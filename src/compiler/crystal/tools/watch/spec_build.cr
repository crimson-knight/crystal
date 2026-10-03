require "../../syntax/ast"

module Crystal
  # The program `crystal spec` compiles for *filenames* (relative to the
  # current directory): a file requiring each of them.
  def self.spec_source(filenames : Enumerable(String)) : Compiler::Source
    source = filenames.join('\n') do |filename|
      %(require "./#{::Path[filename].relative_to(Dir.current).to_posix.to_s.inspect_unquoted}")
    end
    Compiler::Source.new(File.expand_path("spec"), source)
  end

  module Watch
    # A spec program kept by the watcher for `crystal spec`: compiled once,
    # then edited incrementally like the main program.
    class SpecBuild
      getter output : String

      @result : Compiler::Result?
      @incremental : IncrementalSemantic?

      def initialize(@filenames : Array(String))
        @source = Crystal.spec_source(@filenames)
        @output = File.join(CacheDir.instance.directory_for([@source]), "spec.watch")
      end

      # Brings the executable up to date. Returns the locations of the
      # examples affected by the changes since the previous build, `nil` when
      # unknown (compiled from scratch).
      def build(compiler : Compiler) : Array(String)?
        if (incremental = @incremental) && (result = @result) && File.exists?(@output)
          changed = incremental.changed_files
          return [] of String if changed.empty?

          program = result.program
          new_instances = program.collected_def_instances = [] of Def
          begin
            changed_sources, changed_inputs = changed.partition { |filename| incremental.source?(filename) }
            incremental.apply(changed_sources.to_h { |filename| {filename, File.read(filename)} }, changed_inputs)
            if incremental.full_codegen_reason
              compiler.codegen_again(result, [@source], @output)
            else
              compiler.codegen_again(result, [@source], @output, (incremental.retyped + new_instances).map(&.owner))
            end
            return AffectedExamples.new(program, @filenames).compute(result.node, incremental.retyped + new_instances)
          rescue IncrementalSemantic::Unsupported
            # compile from scratch below
          rescue ex : CodeError
            @incremental = nil unless incremental.consistent?
            raise ex
          ensure
            program.collected_def_instances = nil
          end
        end

        @incremental = nil
        compiler.keep_typed_program = true
        result = compiler.compile_configure_program([@source], @output) do |program|
          program.instantiation_records = {} of Def => Array(Program::InstantiationRecord)
          program.codegen_snapshot = Program::CodegenSnapshot.new
        end
        @result = result
        @incremental = IncrementalSemantic.new(result.program, IncrementalSemantic.file_sources(result.program))
        nil
      end
    end

    # Which examples of a spec program run code that changed: walks the
    # program from its top level through every call, building the callers
    # of each method; then goes from the changed methods up to the `it`
    # calls of the spec files.
    #
    # The body of a proc (a proc literal, a captured block such as an `it`
    # block) runs when the proc is called, not where it's written: its calls
    # are attributed to the proc's type, whose callers are the `call`s on
    # procs of that type. The spec DSL's blocks are recognized by name: an
    # `it` block is an example; a `describe`/`context` body, a hook and any
    # other top-level code may affect any example: reaching it means all.
    class AffectedExamples
      # Callers of a method or proc type: another method, a proc type, an
      # example (`file:line`), or `nil` for code outside any example.
      alias Callee = Def | ProcInstanceType
      alias Caller = Def | ProcInstanceType | String | Nil

      @spec_files : Set(String)
      @callers = Hash(Callee, Array(Caller)).new.compare_by_identity
      @walked = Set(Def).new.compare_by_identity
      @pending = [] of Def

      def initialize(@program : Program, filenames : Array(String))
        @spec_files = filenames.map { |filename| File.expand_path(filename) }.to_set
      end

      # The affected examples' locations, or `nil` for all of them.
      def compute(main : ASTNode, changed : Array(Def)) : Array(String)?
        main.accept Walker.new(self, nil)
        while a_def = @pending.pop?
          a_def.body.accept Walker.new(self, a_def)
        end

        examples = Set(String).new
        seen = Set(Callee).new.compare_by_identity
        reached_by = Hash(Callee, Callee).new.compare_by_identity
        queue = changed.map(&.as(Callee))
        while callee = queue.pop?
          next unless seen.add?(callee)
          @callers[callee]?.try &.each do |caller|
            case caller
            in Def, ProcInstanceType
              reached_by[caller] = callee unless reached_by.has_key?(caller)
              queue << caller
            in String
              examples << caller
            in Nil
              debug_chain(callee, reached_by) if ENV["CRYSTAL_AFFECTED_DEBUG"]?
              return nil
            end
          end
        end
        examples.to_a.sort!
      end

      private def debug_chain(callee : Callee, reached_by) : Nil
        chain = [callee]
        while previous = reached_by[chain.last]?
          chain << previous
        end
        STDERR.puts "[affected] reaches code outside examples: " + chain.join(" <- ") { |item|
          item.is_a?(Def) ? "#{item.owner}##{item.name} (#{item.location})" : item.to_s
        }
      end

      protected def calls(target : Callee, caller : Caller) : Nil
        (@callers[target] ||= [] of Caller) << caller
        @pending << target if target.is_a?(Def) && @walked.add?(target)
      end

      protected def example?(call : Call) : String?
        return nil unless call.name == "it" && call.block
        return nil unless (location = call.location) && (filename = location.original_filename)
        return nil unless @spec_files.includes?(filename)

        "#{Crystal.relative_filename(filename)}:#{location.line_number}"
      end

      private class Walker < Visitor
        def initialize(@examples : AffectedExamples, @caller : Caller)
        end

        # Blocks of the spec DSL: `describe` and `context` bodies run when the
        # specs load, hooks around every example: code outside examples.
        SPEC_GROUPS = {"describe", "context", "before_each", "after_each", "around_each", "before_all", "after_all", "around_all"}

        def visit(node : Call)
          if block = node.block
            # An example's block
            example = @examples.example?(node)
            if example || SPEC_GROUPS.includes?(node.name)
              node.obj.try &.accept self
              node.args.each &.accept self
              node.target_defs.try &.each { |target| @examples.calls(target, @caller) }
              block.body.accept Walker.new(@examples, example)
              return false
            end
          end

          node.target_defs.try &.each { |target| @examples.calls(target, @caller) }

          # Calling a proc runs the bodies of the procs of its type
          if node.name == "call" && (obj_type = node.obj.try(&.type?))
            each_proc_type(obj_type) { |proc_type| @examples.calls(proc_type, @caller) }
          end

          # A captured block is a proc: its body runs when the proc is called
          if (block = node.block) && (fun_literal = block.fun_literal) && (proc_type = fun_literal.type?.as?(ProcInstanceType))
            node.obj.try &.accept self
            node.args.each &.accept self
            node.named_args.try &.each &.accept self
            block.body.accept Walker.new(@examples, proc_type)
            return false
          end
          true
        end

        def visit(node : ProcLiteral)
          if proc_type = node.type?.as?(ProcInstanceType)
            node.def.body.accept Walker.new(@examples, proc_type)
            false
          else
            true
          end
        end

        def visit(node : ProcPointer)
          if (proc_type = node.type?.as?(ProcInstanceType)) && (call = node.call?)
            call.target_defs.try &.each { |target| @examples.calls(target, proc_type) }
            call.obj.try &.accept self
            false
          else
            true
          end
        end

        def visit(node : ASTNode)
          true
        end

        private def each_proc_type(type : Type, &)
          if type.is_a?(UnionType)
            type.union_types.each { |union_type| yield union_type if union_type.is_a?(ProcInstanceType) }
          elsif type.is_a?(ProcInstanceType)
            yield type
          end
        end
      end
    end
  end
end
