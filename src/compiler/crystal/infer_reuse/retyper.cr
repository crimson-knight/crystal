module Crystal::InferReuse
  # Decides whether a build can reuse the kept program and, when it can,
  # re-types the instances of every method whose body changed.
  #
  # Reuse needs all of:
  #
  # * the same argument list, working directory and environment (apart from
  #   `PER_BUILD_VARIABLES`) as the build that typed the program;
  # * no macro that ran a program (`run`), and every command, environment
  #   variable, file and file check a macro read giving the same answer;
  # * no warning from the kept build (a reused build would repeat it);
  # * every `require` finding the same files, and every changed file a
  #   `BodyEdit` of methods `#check_eligible` accepts;
  # * each re-typed instance getting the same type, the same "raises" flag
  #   and the same closure flags as before, with no new class variable
  #   initializer.
  #
  # Anything else, and any error while re-typing, refuses the reuse: the
  # build child then execs a fresh compiler, so what this class changed in
  # its copy of the program is thrown away with it.
  class Retyper
    record Decision, reused : Bool, reason : String do
      def reused? : Bool
        reused
      end
    end

    @list_of_changed_defs = [] of BodyEdit::ChangedDef
    @retyped_instance_count = 0
    @new_typed_def_count = 0

    def initialize(@kept : KeptProgram, @request : BuildRequest)
    end

    def program : Program
      @kept.program
    end

    def run : Decision
      started = Time.instant
      decision = begin
        check_build_matches
        check_sources
        retype_changed_defs
        Decision.new(true, "#{@list_of_changed_defs.size} method bodies changed, #{@retyped_instance_count} instances re-typed")
      rescue ex : Refusal
        Decision.new(false, ex.message || "refused")
      rescue ex : Exception
        Decision.new(false, "re-typing raised #{ex.class}: #{ex.message}")
      end
      seconds = (Time.instant - started).total_seconds
      if program.progress_tracker.stats?
        STDOUT.puts "Semantic (infer reuse): #{decision.reused? ? "reused" : "not reused"} in #{seconds.round(3)} s: #{decision.reason}"
      end

      report = Report.new(decision.reused?, decision.reason)
      report.retype_seconds = seconds
      report.changed_methods = @list_of_changed_defs.size
      report.retyped_instances = @retyped_instance_count
      report.new_typed_defs = @new_typed_def_count
      report.build_child_footprint_bytes = Footprint.of(::Process.pid)
      if decision.reused? && ENV[VERIFY_VARIABLE]? == "1"
        verify(report)
      else
        report.write
      end
      decision
    end

    # Types the whole program again in a fresh compiler and compares the
    # digests of what code generation can reach (`TypedProgramDigest`). A
    # difference fails the build, and the server keeps its old program.
    private def verify(report : Report) : Nil
      started = Time.instant
      reused_digest = TypedProgramDigest.new(program, @kept.node)
      fresh_digest = Verification.fresh_digest(@request)
      differences = reused_digest.differences(fresh_digest)
      report.verify_seconds = (Time.instant - started).total_seconds
      report.verified_defs = reused_digest.digests_by_def_name.size
      report.verify_differences = differences.size
      report.write
      if program.progress_tracker.stats?
        STDOUT.puts "Semantic (infer reuse verification): #{reused_digest.digests_by_def_name.size} typed defs compared, #{differences.size} differ"
      end
      return if differences.empty?

      STDERR.puts "Error: infer reuse verification failed: #{differences.size} typed defs differ from a fresh type check"
      differences.first(20).each { |name| STDERR.puts "  #{name}" }
      exit 1
    end

    private def check_build_matches : Nil
      raise Refusal.new("the argument list differs") unless @request.argv == @kept.argv
      raise Refusal.new("the working directory differs") unless @request.working_directory == @kept.working_directory
      unless InferReuse.comparable_env(@request.env) == InferReuse.comparable_env(@kept.env)
        names = (@request.env.keys + @kept.env.keys).uniq.reject { |name| @request.env[name]? == @kept.env[name]? }
        raise Refusal.new("the environment differs (#{InferReuse.comparable_env(names.to_h { |name| {name, ""} }).keys.join(", ")})")
      end
      if reason = @kept.record.blocked_reason
        raise Refusal.new(reason)
      end
      unless @kept.compiler.warnings.infos.empty?
        raise Refusal.new("the kept build has warnings")
      end
    end

    # Everything the kept build read must read the same, except method bodies.
    private def check_sources : Nil
      record = @kept.record

      record.list_of_requires.each do |result|
        found = begin
          program.find_in_path(result.filename, result.relative_to)
        rescue
          nil
        end
        unless (found || [] of String) == result.list_of_found_files
          raise Refusal.new("require \"#{result.filename}\" finds other files")
        end
      end

      record.env_value_by_name.each do |name, value|
        raise Refusal.new("a macro read environment variable #{name}, which changed") unless ENV[name]? == value
      end
      record.content_by_read_file.each do |filename, content|
        current = File.exists?(filename) ? File.read(filename) : nil
        raise Refusal.new("a macro read #{filename}, which changed") unless current == content
      end
      record.output_by_command.each do |command, output|
        current = begin
          text = `#{command}`
          $?.success? ? text : nil
        rescue
          nil
        end
        raise Refusal.new("a macro ran `#{command}`, whose output changed") unless current == output
      end
      record.existence_by_checked_file.each do |filename, exists|
        raise Refusal.new("a macro checked #{filename}, which changed") unless File.exists?(filename) == exists
      end

      program.requires.each do |filename|
        raise Refusal.new("no text kept for #{filename}") unless record.text_by_filename.has_key?(filename)
      end

      record.text_by_filename.each do |filename, old_text|
        new_text = begin
          File.read(filename)
        rescue ex : IO::Error
          raise Refusal.new("can't read #{filename}: #{ex.message}")
        end
        next if new_text == old_text
        @list_of_changed_defs.concat BodyEdit.compare(program, filename, old_text, new_text)
      end
    end

    private def retype_changed_defs : Nil
      return if @list_of_changed_defs.empty?

      def_by_location = program_defs_by_location(@list_of_changed_defs.map(&.filename).to_set)
      types_before = program.after_inference_types.size
      class_var_initializers_before = program.class_var_initializers.size
      new_typed_defs = program.infer_reuse_new_typed_defs = [] of Def

      list_of_retypes = @list_of_changed_defs.map do |changed|
        location = changed.old_def.location.not_nil!
        program_def = def_by_location[{location.filename, location.line_number, location.column_number}]? ||
                      raise Refusal.new("can't find method '#{changed.old_def.name}' of #{location} in the program")
        raise Refusal.new("method '#{program_def.name}' of #{location} is not the parsed one") unless program_def.name == changed.new_def.name
        check_eligible(program_def, changed)
        {program_def, changed}
      end

      list_of_retypes.each do |(program_def, changed)|
        new_body = program.normalize(changed.new_def.clone).as(Def).body
        program_def.body = new_body
        instances_of(program_def).each do |(container, key, typed_def)|
          retype(program_def, container, key, typed_def)
          @retyped_instance_count += 1
        end
      end
      program.infer_reuse_new_typed_defs = nil

      unless program.class_var_initializers.size == class_var_initializers_before
        raise Refusal.new("re-typing added class variable initializers")
      end
      finish_new_types(types_before)
      fix_missing_types(new_typed_defs)
      @new_typed_def_count = new_typed_defs.size
      RecursiveStructChecker.new(program).run

      unless @kept.compiler.warnings.infos.empty?
        raise Refusal.new("re-typing produced warnings")
      end

      @list_of_changed_defs.each do |changed|
        text = File.read(changed.filename)
        @kept.record.add_source(changed.filename, text)
      end
    end

    # The method may be re-typed alone only when nothing outside its typed
    # instances depends on its body.
    private def check_eligible(program_def : Def, changed : BodyEdit::ChangedDef) : Nil
      name = "'#{program_def.name}'"
      refuse = ->(why : String) { raise Refusal.new("method #{name} #{why}") }

      owner = program_def.owner
      refuse.call("belongs to a generic type") if owner.is_a?(GenericType) || owner.is_a?(GenericInstanceType)
      refuse.call("belongs to a generic type") if owner.metaclass? && owner.instance_type.is_a?(GenericType)
      refuse.call("is an initializer") if program_def.name.in?("initialize", "new", "finalize")
      refuse.call("takes a block") if program_def.block_arg || program_def.block_arity || program_def.uses_block_arg?
      refuse.call("has default values, a splat or free variables") if program_def.splat_index || program_def.double_splat ||
                                                                      program_def.free_vars || program_def.args.any?(&.default_value)
      refuse.call("is written by a macro") if program_def.macro_def?
      refuse.call("assigns a special variable") if program_def.assigns_special_var? || changed.new_def.assigns_special_var?
      refuse.call("is a primitive or a lib function") if program_def.is_a?(External) || program_def.body.is_a?(Primitive)
      {program_def.body, changed.old_def.body, changed.new_def.body}.each do |body|
        checker = BodyChecker.new
        body.accept checker
        refuse.call(checker.reason.not_nil!) if checker.reason
      end
    end

    # The program's own definitions in *filenames*, by location.
    private def program_defs_by_location(filenames : Set(String)) : Hash({String, Int32, Int32}, Def)
      result = {} of {String, Int32, Int32} => Def
      visited = Set(UInt64).new
      collect_program_defs(@kept.node, filenames, visited, result)
      result
    end

    private def collect_program_defs(node : ASTNode, filenames : Set(String), visited : Set(UInt64), result : Hash({String, Int32, Int32}, Def)) : Nil
      return unless visited.add?(node.object_id)

      case node
      when Expressions
        node.expressions.each { |expression| collect_program_defs(expression, filenames, visited, result) }
      when FileNode
        collect_program_defs(node.node, filenames, visited, result) if filenames.includes?(node.filename)
      when Require
        node.expanded.try { |expanded| collect_program_defs(expanded, filenames, visited, result) }
      when ClassDef
        collect_program_defs(node.body, filenames, visited, result)
      when ModuleDef
        collect_program_defs(node.body, filenames, visited, result)
      when VisibilityModifier
        collect_program_defs(node.exp, filenames, visited, result)
      when Def
        if (location = node.location) && (filename = location.filename).is_a?(String) && filenames.includes?(filename)
          result[{filename, location.line_number, location.column_number}] = node
        end
      end
    end

    # Every typed instance of *program_def*, with the type that keeps it and
    # its instantiation key.
    private def instances_of(program_def : Def) : Array({DefInstanceContainer, DefInstanceKey, Def})
      result = [] of {DefInstanceContainer, DefInstanceKey, Def}
      visited = Set(UInt64).new
      roots = [program.as(Type)]
      program.file_modules.each_value { |file_module| roots << file_module }
      roots.each do |root|
        each_type(root, visited) do |type|
          next unless type.is_a?(DefInstanceContainer)
          type.@def_instances.try &.each do |key, typed_def|
            result << {type, key, typed_def} if key.def_object_id == program_def.object_id
          end
          type.@block_def_instances.try &.each_key do |key|
            raise Refusal.new("method '#{program_def.name}' has instances typed with a block") if key.def_object_id == program_def.object_id
          end
        end
      end
      result
    end

    private def each_type(type : Type, visited : Set(UInt64), &block : Type ->) : Nil
      return unless visited.add?(type.object_id)

      block.call(type)
      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| each_type(instance, visited, &block) }
      end
      type.types?.try &.each_value { |nested| each_type(nested, visited, &block) }
      each_type(type.metaclass, visited, &block) unless type.metaclass?
      if virtual_type = type.existing_virtual_type
        each_type(virtual_type, visited, &block)
      end
    end

    # Types the new body for the instance *old_typed_def* and puts the new
    # typed def in its place, for its callers and in the instance cache.
    private def retype(program_def : Def, container : DefInstanceContainer, key : DefInstanceKey, old_typed_def : Def) : Nil
      raise Refusal.new("method '#{program_def.name}' has an instance with named arguments") if key.named_args
      raise Refusal.new("method '#{program_def.name}' has an instance typed with a block") if key.block_type

      list_of_callers = [] of Call
      old_typed_def.each_observer do |observer|
        unless observer.is_a?(Call) && observer.target_defs.try(&.any?(&.same?(old_typed_def)))
          raise Refusal.new("method '#{program_def.name}' is observed by a #{observer.class.name}")
        end
        list_of_callers << observer
      end
      caller = list_of_callers.first? || raise Refusal.new("method '#{program_def.name}' has an instance without callers")

      arg_types = key.arg_types
      self_type = nil
      if arg_types.size == program_def.args.size + 1
        self_type = arg_types.first
        arg_types = arg_types[1..]
      elsif arg_types.size != program_def.args.size
        raise Refusal.new("method '#{program_def.name}' has an instance with another number of arguments")
      end
      match_owner = old_typed_def.owner
      lookup_self_type = self_type || match_owner
      context = MatchContext.new(match_owner, program_def.owner)
      match = Match.new(program_def, arg_types, context)

      typed_def, typed_def_args = caller.prepare_typed_def_with_args(program_def, match_owner, lookup_self_type, arg_types, nil, nil)
      typed_def.type_once = old_typed_def.type_once?
      container.add_def_instance(key, typed_def)
      if typed_def_return_type = typed_def.return_type
        caller.check_return_type(typed_def, typed_def_return_type, match, match_owner)
      end

      visitor = MainVisitor.new(program, typed_def_args, typed_def)
      visitor.match_context = context
      visitor.untyped_def = program_def
      visitor.call = caller
      visitor.scope = lookup_self_type
      visitor.path_lookup = context.defining_type
      typed_def.body.accept visitor
      visitor.release_inference_state if program.release_inference_state?

      program.cleanup_transformer.transform_typed_def(typed_def)

      unless typed_def.type?.same?(old_typed_def.type?)
        raise Refusal.new("method '#{program_def.name}' now returns #{typed_def.type?}, it returned #{old_typed_def.type?}")
      end
      unless typed_def.raises? == old_typed_def.raises? &&
             typed_def.closure? == old_typed_def.closure? &&
             typed_def.self_closured? == old_typed_def.self_closured? &&
             typed_def.captured_block? == old_typed_def.captured_block?
        raise Refusal.new("method '#{program_def.name}' changed whether it raises or makes a closure")
      end
      if typed_def.special_vars
        raise Refusal.new("method '#{program_def.name}' assigns a special variable")
      end

      list_of_callers.each(&.retarget(old_typed_def, typed_def))
      program.infer_reuse_new_typed_defs.try &.<< typed_def
    end

    # New types with instance variable initializers get the cleanup every
    # type got at the end of type inference.
    private def finish_new_types(types_before : Int32) : Nil
      transformer = program.cleanup_transformer
      program.after_inference_types.each_with_index do |type, index|
        next if index < types_before
        program.cleanup_type(type, transformer)
      end
    end

    private def fix_missing_types(new_typed_defs : Array(Def)) : Nil
      fixer = FixMissingTypes.new(program, only: Set(Def).new.compare_by_identity.concat(new_typed_defs))
      new_typed_defs.each { |typed_def| fixer.fix_typed_def(typed_def) }
    end
  end

  # Looks for what a method body must not hold when it is re-typed alone:
  # assignments to instance, class and global variables (other files read
  # their types), macro code, and `yield`.
  class BodyChecker < Visitor
    getter reason : String?

    def visit(node : ASTNode) : Bool
      true
    end

    def visit(node : Assign | OpAssign) : Bool
      check_target(node.target)
      true
    end

    def visit(node : MultiAssign) : Bool
      node.targets.each { |target| check_target(target) }
      true
    end

    def visit(node : TypeDeclaration | UninitializedVar) : Bool
      check_target(node.var)
      true
    end

    def visit(node : MacroExpression | MacroIf | MacroFor | MacroLiteral | MacroVerbatim) : Bool
      @reason ||= "has macro code in its body"
      false
    end

    def visit(node : Yield) : Bool
      @reason ||= "yields"
      true
    end

    private def check_target(target : ASTNode) : Nil
      case target
      when InstanceVar
        @reason ||= "assigns instance variable #{target.name}"
      when ClassVar
        @reason ||= "assigns class variable #{target.name}"
      when Global
        @reason ||= "assigns global variable #{target.name}"
      end
    end
  end
end
