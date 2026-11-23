module Crystal::InferReuse
  # Decides whether a build can reuse the kept program and, when it can,
  # re-types the instances of every method whose body changed.
  #
  # Reuse needs all of:
  #
  # * the same argument list, working directory and compiler environment
  #   (`InferReuse.comparable_env`) as the build that typed the program;
  # * every program (`run`), command, environment variable, file and file
  #   check a macro read giving the same answer;
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

    @list_of_file_edits = [] of FileEdit
    @list_of_changed_defs = [] of FileEdit::ChangedDef
    @added_def_count = 0
    @candidate_call_count = 0
    @candidate_seconds = 0.0
    @replayed_expansion_count = 0
    @removed_def_count = 0
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
        Decision.new(true, decision_reason)
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
      report.added_methods = @added_def_count
      report.candidate_calls = @candidate_call_count
      report.candidate_seconds = @candidate_seconds
      report.replayed_expansions = @replayed_expansion_count
      report.removed_methods = @removed_def_count
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

    private def decision_reason : String
      String.build do |io|
        io << @list_of_changed_defs.size << " method bodies changed, " << @retyped_instance_count << " instances re-typed"
        io << ", " << @added_def_count << " methods added" if @added_def_count > 0
        io << ", " << @removed_def_count << " methods removed" if @removed_def_count > 0
        moved = @list_of_file_edits.count { |edit| !edit.line_shift.identity? }
        io << ", lines moved in " << moved << " files" if moved > 0
      end
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
      unless record.list_of_program_runs.empty?
        # Compile each program again when its source changed (the compile
        # cache on disk knows), rather than run the build's own copy.
        program.compiled_macros_cache.clear
        record.list_of_program_runs.each do |run|
          current = begin
            result = program.macro_run(run.filename, run.list_of_arguments)
            result.status.success? ? result.stdout : nil
          rescue ex
            raise Refusal.new("a macro program #{run.filename} no longer compiles or runs: #{ex.message}")
          end
          raise Refusal.new("a macro ran #{run.filename}, whose output changed") unless current == run.output
        end
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
        @list_of_file_edits << FileEdit.compare(program, filename, old_text, new_text)
      end
      @list_of_changed_defs = @list_of_file_edits.flat_map(&.list_of_changed_defs)

      @list_of_file_edits.each do |edit|
        record.list_of_def_body_reads.each do |read|
          next unless read.filename == edit.filename
          edit.list_of_changed_defs.each do |changed|
            next if read.last_line < changed.old_line || changed.old_last_line + 1 < read.first_line
            raise Refusal.new("a macro read the body of method '#{read.name}' (#{read.filename}:#{read.first_line}), which changed")
          end
          edit.list_of_removed_defs.each do |removed|
            next if read.last_line < removed.old_first_line || removed.old_last_line < read.first_line
            raise Refusal.new("a macro read the body of method '#{read.name}' (#{read.filename}:#{read.first_line}), which was removed")
          end
        end
        record.line_reads_by_filename[edit.filename]?.try &.each do |line|
          if edit.replaced_line?(line) || edit.line_shift.offset_at(line) != 0
            raise Refusal.new("a macro read the line number of #{edit.filename}:#{line}, which moved")
          end
        end
      end
    end

    private def retype_changed_defs : Nil
      return if @list_of_file_edits.empty?

      def_by_location = program_defs_by_location(@list_of_file_edits.map(&.filename).to_set)
      types_before = program.after_inference_types.size
      generic_instances_before = program.generic_instance_count
      class_var_initializers_before = program.class_var_initializers.size

      # Everything that reads locations of the kept program runs before its
      # lines move.
      list_of_retypes = @list_of_changed_defs.map do |changed|
        program_def = find_program_def(def_by_location, changed.old_def.name, changed.filename, changed.old_line, changed.old_column)
        raise Refusal.new("method '#{program_def.name}' of #{changed.filename}:#{changed.old_line} is not the parsed one") unless program_def.name == changed.new_def.name
        check_eligible(program_def, changed)
        {program_def, changed}
      end
      list_of_removals = @list_of_file_edits.flat_map(&.list_of_removed_defs).map do |removed|
        program_def = find_program_def(def_by_location, removed.old_def.name, removed.filename, removed.old_line, removed.old_column)
        {program_def, removed}
      end
      list_of_removed_instances = list_of_removals.flat_map { |(program_def, removed)| removable_instances(program_def, removed) }
      list_of_candidate_calls = candidate_calls(@list_of_file_edits.flat_map(&.list_of_added_defs).map(&.new_def.name).to_set)

      @list_of_file_edits.each do |edit|
        edit.shift_program_lines
        @kept.record.shift_lines(edit.filename, edit.line_shift)
      end

      new_typed_defs = program.infer_reuse_new_typed_defs = [] of Def

      list_of_removals.each { |(program_def, _)| remove_def(program_def) }
      list_of_removed_instances.each { |(container, key)| container.delete_def_instance(key) }
      @removed_def_count = list_of_removals.size

      list_of_added = @list_of_file_edits.flat_map(&.list_of_added_defs).map { |added| add_def(added) }
      @added_def_count = list_of_added.size
      check_calls_keep_their_targets(list_of_candidate_calls, list_of_added)
      check_method_listings(list_of_added, list_of_removals.map { |(program_def, _)| program_def })

      list_of_retypes.each do |(program_def, changed)|
        new_body = program.normalize(changed.new_def.clone).as(Def).body
        program_def.body = new_body
        instances_of(program_def).each do |(container, key, typed_def)|
          retype(program_def, container, key, typed_def)
          @retyped_instance_count += 1
        end
      end
      program.infer_reuse_new_typed_defs = nil

      # A method of a generic type is re-typed in each instance the kept
      # program has; an edit that now needs another generic instance types
      # fresh.
      if list_of_retypes.any? { |(program_def, _)| generic_owner?(program_def.owner) } && program.generic_instance_count != generic_instances_before
        raise Refusal.new("re-typing a method of a generic type made new generic instances")
      end

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

      @list_of_file_edits.each do |edit|
        text = File.read(edit.filename)
        @kept.record.add_source(edit.filename, text)
      end
    end

    # The program's def at *line* and *column* of *filename*, as the kept
    # program's locations read before its lines move.
    private def find_program_def(def_by_location : Hash({String, Int32, Int32}, Def), name : String, filename : String, line : Int32, column : Int32) : Def
      key = {filename, line, column}
      found = def_by_location[key]?
      # The parsed nodes still hold methods a build server removed since.
      found = nil if found && !declared?(found)
      found || program_def_in_types(name, key) ||
        raise Refusal.new("can't find method '#{name}' of #{filename}:#{line} in the program")
    end

    # The method may be re-typed alone only when nothing outside its typed
    # instances depends on its body.
    private def check_eligible(program_def : Def, changed : FileEdit::ChangedDef) : Nil
      name = "'#{program_def.name}'"
      refuse = ->(why : String) { raise Refusal.new("method #{name} #{why}") }

      owner = program_def.owner
      refuse.call("belongs to a generic instance") if owner.is_a?(GenericInstanceType)
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
        if reason = checker.reason
          refuse.call(reason)
        end
      end
    end

    # The typed instances of *program_def*, a method the edit removes, with
    # the types that keep them. Only bodies the edit replaces may call it.
    private def removable_instances(program_def : Def, removed : FileEdit::RemovedDef) : Array({DefInstanceContainer, DefInstanceKey})
      name = "'#{program_def.name}'"
      refuse = ->(why : String) { raise Refusal.new("removed method #{name} #{why}") }
      refuse.call("is an initializer or a hook") if program_def.name.in?(LIFECYCLE_NAMES)
      refuse.call("is written by a macro") if program_def.macro_def?
      refuse.call("is abstract") if program_def.abstract?
      refuse.call("redefines or is redefined by another method") if program_def.previous || program_def.next
      owner = program_def.owner
      refuse.call("is a top-level method") if owner.is_a?(Program) || owner.is_a?(FileModule)
      check_name_not_queried(program_def.name, owner, refuse)

      instances_of(program_def).map do |(container, key, typed_def)|
        typed_def.each_observer do |observer|
          location = observer.location.try(&.expanded_location)
          unless observer.is_a?(Call) && location && in_replaced_body?(location)
            refuse.call("is still called (#{location || observer.class.name})")
          end
        end
        {container, key}
      end
    end

    # Initializers, finalizers and other methods the language calls on its
    # own: adding or removing one never reuses the kept program.
    LIFECYCLE_NAMES = {"initialize", "new", "finalize", "allocate", "method_missing", "previous_def", "super"}

    # Refuses when something the kept program computed asked whether a method
    # named *name* exists: a `responds_to?`, a macro that asked `overrides?`
    # of a type related to *owner*, or a call typed without the instance
    # cache (the scan in `#candidate_calls` would not see it). Macros that
    # listed methods are run again (`#check_method_listings`).
    private def check_name_not_queried(name : String, owner : Type, refuse : String ->) : Nil
      record = @kept.record
      refuse.call("is named in a responds_to?") if record.responds_to_names.includes?(name)
      refuse.call("has the name of a method typed once per call") if record.uncached_call_names.includes?(name)
      owner_instance = owner.metaclass? ? owner.instance_type : owner
      record.overrides_read_type_by_id.each_value do |read_type|
        read_instance = read_type.metaclass? ? read_type.instance_type : read_type
        refuse.call("belongs to #{owner_instance}, which a macro asked overrides? about (#{read_type})") if related?(read_instance, owner_instance)
      end
    end

    # Runs again every macro expansion that listed methods of a type whose
    # list the added or removed methods change, with each read answered as
    # the original build would have answered it with the edit, and refuses
    # unless each produces the text it produced before.
    private def check_method_listings(list_of_added : Array(Def), list_of_removed : Array(Def)) : Nil
      return if list_of_added.empty? && list_of_removed.empty?
      record = @kept.record
      record.list_of_method_list_expansions.each do |expansion|
        affected_added = list_of_added.select do |added_def|
          declared_before?(added_def, expansion) && expansion.list_of_reads.any? { |read| read_includes?(read, added_def) }
        end
        affected_removed = list_of_removed.select do |removed_def|
          expansion.list_of_reads.any? do |read|
            read.list_of_defs.any?(&.same?(removed_def)) || (read.kind == "has_method?" && read.name == removed_def.name)
          end
        end
        next if affected_added.empty? && affected_removed.empty?

        place = expansion.site.try(&.expanded_location)
        output = expansion.output || raise Refusal.new("a macro that listed methods (#{place}) left no output")
        record.method_list_replay = MethodListReplay.new(expansion.list_of_reads, affected_added, affected_removed)
        new_output = begin
          expansion.rerun
        rescue ex : Refusal
          raise ex
        rescue ex
          raise Refusal.new("a macro that listed methods (#{place}) raised when run again: #{ex.message}")
        ensure
          record.method_list_replay = nil
        end
        unless new_output == output
          raise Refusal.new("a macro that listed methods (#{place}) writes other code with the edit")
        end
        # The next edit compares against the lists this build would have read.
        replay = MethodListReplay.new(expansion.list_of_reads, affected_added, affected_removed)
        expansion.list_of_reads.map! { |read| replay.edited(read) }
        @replayed_expansion_count += 1
      end
    end

    # Whether a list of methods *read* would hold *a_def*.
    private def read_includes?(read : MethodListRead, a_def : Def) : Bool
      if read.kind == "has_method?"
        read.name == a_def.name && MethodListReplay.lists?(read.type, "all_methods", a_def.owner)
      else
        MethodListReplay.lists?(read.type, read.kind, a_def.owner)
      end
    end

    # Whether *a_def* was declared when *expansion* ran: always during type
    # inference; at the top level, when it comes before the expansion in the
    # same file (a method in another file counts as declared).
    private def declared_before?(a_def : Def, expansion : MethodListExpansion) : Bool
      return true if expansion.after_top_level?
      site = expansion.site.try(&.expanded_location) || return true
      location = a_def.location || return true
      return true unless site.filename == location.filename
      location.line_number < site.line_number
    end

    private def related?(type : Type, other : Type) : Bool
      type = type.devirtualize
      other = other.devirtualize
      type.implements?(other) || other.implements?(type)
    end

    # Whether *location* (in a source file) is inside a method body the edit
    # replaces, or a method it removes: the typed nodes there are thrown away.
    private def in_replaced_body?(location : Location) : Bool
      filename = location.filename
      return false unless filename.is_a?(String)
      @list_of_file_edits.any? { |edit| edit.filename == filename && edit.replaced_line?(location.line_number) }
    end

    # The calls of the kept program that resolved to a method named one of
    # *names*, outside the bodies the edit replaces, with that name: a method
    # added with such a name may change what they resolve to.
    private def candidate_calls(names : Set(String)) : Array({Call, String})
      result = [] of {Call, String}
      return result if names.empty?

      started = Time.instant
      seen = Set(UInt64).new
      visited = Set(UInt64).new
      roots = [program.as(Type)]
      program.file_modules.each_value { |file_module| roots << file_module }
      roots.each do |root|
        each_type(root, visited) do |type|
          next unless type.is_a?(DefInstanceContainer)
          list_of_instances = type.def_instances?
          list_of_block_instances = type.block_def_instances?
          list_of_instances.try &.each_value do |typed_def|
            next unless names.includes?(typed_def.name)
            typed_def.each_observer do |observer|
              next unless observer.is_a?(Call) && seen.add?(observer.object_id)
              location = observer.location.try(&.expanded_location)
              next if location && in_replaced_body?(location)
              result << {observer, typed_def.name}
            end
          end
          list_of_block_instances.try &.each_value do |list_of_typed_defs|
            list_of_typed_defs.each do |typed_def|
              raise Refusal.new("a method named '#{typed_def.name}' is typed with blocks") if names.includes?(typed_def.name)
            end
          end
        end
      end
      @candidate_call_count = result.size
      @candidate_seconds = (Time.instant - started).total_seconds
      result
    end

    # Refuses when a call outside the replaced bodies may resolve to one of
    # the added methods: when it was typed with a receiver type related to
    # the new method's owner and a lookup with its argument types now finds
    # the new method.
    private def check_calls_keep_their_targets(list_of_candidates : Array({Call, String}), list_of_added : Array(Def)) : Nil
      list_of_added.each do |added_def|
        list_of_candidates.each do |(call, target_name)|
          next unless target_name == added_def.name
          place = call.location.try(&.expanded_location)
          unless call.name == target_name
            raise Refusal.new("new method '#{added_def.name}' may change what `#{call.name}` at #{place} resolves to")
          end
          call.each_target_def do |target_def|
            receiver_type = target_def.owner
            if receiver_type.is_a?(Program) || receiver_type.is_a?(FileModule)
              raise Refusal.new("new method '#{added_def.name}' may take over the call to top-level '#{target_name}' at #{place}")
            end
            next unless related?(receiver_type, added_def.owner)
            list_of_lookup_types = [receiver_type]
            list_of_lookup_types << added_def.owner unless receiver_type.devirtualize.implements?(added_def.owner)
            list_of_lookup_types.each do |lookup_type|
              if finds_def?(lookup_type, call, added_def)
                raise Refusal.new("new method '#{added_def.name}' matches the call at #{place}")
              end
            end
          end
        end
      end
    end

    # Whether looking up *call*, with the argument types it was typed with,
    # in *lookup_type* finds *a_def*.
    private def finds_def?(lookup_type : Type, call : Call, a_def : Def) : Bool
      list_of_arg_types = call.args.map do |arg|
        raise Refusal.new("a call to '#{call.name}' with a splat may resolve to the new method") if arg.is_a?(Splat) || arg.is_a?(DoubleSplat)
        arg.type? || return true
      end
      named_args_types = NamedArgumentType.from_args(call.named_args)
      signature = CallSignature.new(call.name, list_of_arg_types, call.block, named_args_types)
      matches = lookup_type.lookup_matches(signature)
      matches.matches.try(&.any?(&.def.same?(a_def))) || false
    rescue ex : Refusal
      raise ex
    rescue ex
      raise Refusal.new("looking up the call to '#{call.name}' again raised #{ex.class}: #{ex.message}")
    end

    # Adds a method the new text defines to the type its classes and modules
    # name, as the top-level pass would have.
    private def add_def(added : FileEdit::AddedDef) : Def
      a_def = added.new_def
      name = "'#{a_def.name}'"
      refuse = ->(why : String) { raise Refusal.new("new method #{name} #{why}") }

      raise Refusal.new("new method #{name} is a top-level method") if added.list_of_scopes.empty?
      scope_type = program.as(Type)
      added.list_of_scopes.each do |scope|
        path, type_vars = case scope
                          when ClassDef  then {scope.name, scope.type_vars}
                          when ModuleDef then {scope.name, scope.type_vars}
                          else                refuse.call("is inside a #{scope.class_desc}")
                          end
        refuse.call("belongs to a generic type") if type_vars
        current = path.global? ? program.as(Type) : scope_type
        path.names.each do |part|
          current = current.types?.try(&.[part]?) || refuse.call("belongs to #{path}, which the program does not have")
        end
        scope_type = current
      end

      target = case receiver = a_def.receiver
               when Nil
                 scope_type
               when Var
                 refuse.call("has a receiver other than self") unless receiver.name == "self"
                 scope_type.metaclass
               else
                 refuse.call("has a receiver other than self")
               end
      target = target.as?(ModuleType) || refuse.call("is not in a class or module")
      refuse.call("belongs to a generic type") if target.is_a?(GenericType) || (target.metaclass? && target.instance_type.is_a?(GenericType))
      refuse.call("belongs to a lib") if target.is_a?(LibType)
      refuse.call("is an initializer or a hook") if a_def.name.in?(LIFECYCLE_NAMES)
      refuse.call("takes a block") if a_def.block_arg || a_def.block_arity || a_def.uses_block_arg?
      refuse.call("is abstract") if a_def.abstract?
      refuse.call("is written by a macro") if a_def.macro_def?
      refuse.call("is in a strict file") if program.strict_file?(a_def.location)
      if target.metaclass.as?(ModuleType).try &.hooks.try &.any?(&.kind.method_added?)
        refuse.call("runs a method_added hook")
      end
      checker = BodyChecker.new
      a_def.body.accept checker
      a_def.args.each { |arg| arg.default_value.try &.accept checker }
      if reason = checker.reason
        refuse.call(reason)
      end
      check_name_not_queried(a_def.name, target, refuse)

      normalized = program.normalize(a_def).as?(Def) || refuse.call("does not normalize to a method")
      replaced = target.add_def(normalized)
      refuse.call("replaces a method of the same signature") if replaced
      normalized.set_type(program.nil)
      normalized
    end

    private def generic_owner?(owner : Type) : Bool
      owner.is_a?(GenericType) || (owner.metaclass? && owner.instance_type.is_a?(GenericType))
    end

    # Whether *program_def* is one of its owner's methods.
    private def declared?(program_def : Def) : Bool
      owner = program_def.owner?.try(&.as?(ModuleType)) || return false
      owner.defs.try(&.[program_def.name]?).try(&.any?(&.def.same?(program_def))) || false
    end

    # Takes *program_def* out of its owner's methods.
    private def remove_def(program_def : Def) : Nil
      owner = program_def.owner.as?(ModuleType) || raise Refusal.new("removed method '#{program_def.name}' has no module owner")
      defs = owner.defs || return
      list = defs[program_def.name]? || return
      list.reject! { |item| item.def.same?(program_def) }
      defs.delete(program_def.name) if list.empty?
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

    # The program's def named *name* at *key* (file, line, column), from the
    # types that hold it: for a file whose parsed nodes the program no longer
    # reaches from its main node.
    private def program_def_in_types(name : String, key : {String, Int32, Int32}) : Def?
      visited = Set(UInt64).new
      roots = [program.as(Type)]
      program.file_modules.each_value { |file_module| roots << file_module }
      found = nil
      roots.each do |root|
        each_type(root, visited) do |type|
          next if found
          type.defs.try &.[name]?.try &.each do |item|
            item_location = item.def.location
            next unless item_location
            found = item.def if {item_location.filename, item_location.line_number, item_location.column_number} == key
          end
        end
      end
      found
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
          list_of_instances = type.def_instances?
          list_of_block_instances = type.block_def_instances?
          list_of_instances.try &.each do |key, typed_def|
            result << {type, key, typed_def} if key.def_object_id == program_def.object_id
          end
          list_of_block_instances.try &.each_key do |key|
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
