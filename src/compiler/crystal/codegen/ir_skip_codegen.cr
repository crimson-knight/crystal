require "./codegen"
require "./ir_skip"

# The code generator's side of `IrSkip`: recording the trace of each
# function it generates, and matching the functions a candidate module is
# asked for with the build before.
class Crystal::CodeGenVisitor
  # The trace of each function that is being generated, innermost last.
  # `nil` stands for code whose requests belong to no function's trace: a
  # function of the main module, or a definition made there on demand.
  @ir_trace_frames = [] of IrSkip::Frame?

  # The functions that matched the build before in a module that is
  # generated after all, until they are generated, by name.
  @ir_skip_late_pending = {} of String => {IrSkip::AcceptedFun, ModuleInfo}

  # How many candidate modules were generated after all so far.
  @ir_skip_invalidation_count = 0

  @ir_skip_walker : IrSkip::KeyWalker?
  @ir_skip_last_walk : {String, IrSkip::Walk}?

  private def ir_skip_session : IrSkip::Session?
    @single_module ? nil : @program.ir_skip
  end

  # The key of the function named *mangled_name* and what its code refers to.
  private def ir_skip_walk(mangled_name : String, target_def : Def, self_type : Type) : IrSkip::Walk
    if (last_walk = @ir_skip_last_walk) && last_walk[0] == mangled_name
      return last_walk[1]
    end

    walker = @ir_skip_walker ||= IrSkip::KeyWalker.new(@program, IrSkip::TypeDescriptors.new(@program),
      @owner_shape_sharing, keeps_local_names: @debug.variables?)
    started_at = Time.instant
    walk = walker.walk(mangled_name, target_def, self_type)
    if session = ir_skip_session
      session.stats.key_seconds += (Time.instant - started_at).total_seconds
    end
    @ir_skip_last_walk = {mangled_name, walk}
    walk
  end

  # Starts the trace of a function that is about to be generated into
  # *fun_module_info*. Only a function of a type's module *records* one.
  private def begin_ir_trace_frame(mangled_name : String, target_def : Def, self_type : Type,
                                   fun_module_info : ModuleInfo, records : Bool) : IrSkip::Frame?
    return nil unless ir_skip_session

    if !records || fun_module_info.same?(@main_module_info) || fun_module_info.same?(@fun_signatures)
      @ir_trace_frames << nil
      return nil
    end

    walk = ir_skip_walk(mangled_name, target_def, self_type)
    frame = IrSkip::Frame.new(walk)
    # The functions of a module are kept in the order they are asked for,
    # which is the order the next build asks for them in: a function that
    # this one asks for comes after it.
    recorded_fun = IrSkip::RecordedFun.new(mangled_name, walk.code_key, walk.line_key, false, frame.list_of_trace_entries)
    fun_module_info.list_of_recorded_funs << recorded_fun
    frame.recorded_fun = recorded_fun
    if plan = fun_module_info.ir_skip_plan
      frame.previous_fun = plan.recorded.list_of_funs[plan.position]?
      plan.position += 1
    end
    @ir_trace_frames << frame
    frame
  end

  # Ends the trace started by `begin_ir_trace_frame` and keeps it with the
  # function's key for the next build.
  private def end_ir_trace_frame(frame : IrSkip::Frame?, mangled_name : String, fun_module_info : ModuleInfo) : Nil
    return unless session = ir_skip_session

    @ir_trace_frames.pop
    return unless frame

    walk = frame.walk
    stats = session.stats
    stats.generated_functions += 1
    if blocker = walk.blocker
      stats.unkeyable_functions += 1
      stats.count_cause(stats.first_unkeyable_causes, blocker)
    elsif cause = frame.unreplayable_cause
      stats.unreplayable_functions += 1
      stats.count_cause(stats.first_unreplayable_causes, cause)
    end
    return unless recorded_fun = frame.recorded_fun
    recorded_fun.replayable = walk.keyable? && frame.unreplayable_cause.nil?

    return unless plan = fun_module_info.ir_skip_plan

    previous_fun = frame.previous_fun
    if plan.invalidated?
      # Tells a module in which only source positions moved from one that
      # changed in more.
      if plan.source_position_only? && !(previous_fun && previous_fun.name == mangled_name && previous_fun.code_key == walk.code_key)
        plan.source_position_only = false
      end
    elsif session.verify?
      verify_generated_fun(session, plan, fun_module_info, previous_fun, recorded_fun, walk)
    end
  end

  # In verification every function is generated. A candidate module stays
  # one while its functions match the build before, and a function that
  # matches must leave the trace the build before recorded.
  private def verify_generated_fun(session : IrSkip::Session, plan : IrSkip::UnitPlan, fun_module_info : ModuleInfo,
                                   previous_fun : IrSkip::RecordedFun?, recorded_fun : IrSkip::RecordedFun,
                                   walk : IrSkip::Walk) : Nil
    if mismatch = ir_skip_mismatch(previous_fun, recorded_fun.name, walk)
      plan.invalidate(mismatch[0], mismatch[1])
      return
    end
    return unless previous_fun

    if previous_fun.list_of_trace_entries != recorded_fun.list_of_trace_entries
      session.stats.list_of_verification_failures << "#{fun_module_info.name}: the key of #{recorded_fun.name} matched, but its trace differs from the recorded one"
    end
  end

  # Why the function named *mangled_name*, with the key of *walk*, is not
  # the function *previous_fun* that the build before generated at this
  # position, or `nil` when it is.
  private def ir_skip_mismatch(previous_fun : IrSkip::RecordedFun?, mangled_name : String,
                               walk : IrSkip::Walk) : {IrSkip::RegenerationReason, String}?
    if previous_fun.nil?
      {IrSkip::RegenerationReason::FunctionList, "#{mangled_name} was added"}
    elsif previous_fun.name != mangled_name
      {IrSkip::RegenerationReason::FunctionList, "#{mangled_name} is asked for where #{previous_fun.name} was"}
    elsif blocker = walk.blocker
      {IrSkip::RegenerationReason::Unkeyable, "#{mangled_name}: #{blocker}"}
    elsif previous_fun.code_key != walk.code_key
      {IrSkip::RegenerationReason::Code, mangled_name}
    elsif previous_fun.line_key != walk.line_key
      {IrSkip::RegenerationReason::SourcePosition, mangled_name}
    end
  end

  # Matches the function named *mangled_name*, which *module_info* is asked
  # for, with the build before. Returns its declaration when it matched and
  # its trace was replayed: the function needs no code. Returns `nil` when
  # the function must be generated; the module is then no candidate any
  # more, and the functions it matched before were generated.
  private def skip_ir_generation_of(module_info : ModuleInfo, mangled_name : String, target_def : Def,
                                    self_type : Type) : LLVMTypedFunction?
    return nil unless plan = module_info.ir_skip_plan
    return nil if plan.invalidated?
    return nil unless session = ir_skip_session
    return nil if session.verify?

    walk = ir_skip_walk(mangled_name, target_def, self_type)
    previous_fun = plan.next_recorded_fun
    if mismatch = ir_skip_mismatch(previous_fun, mangled_name, walk)
      invalidate_ir_skip_plan(module_info, plan, mismatch[0], mismatch[1])
      return nil
    end
    return nil unless previous_fun

    signature = declare_fun_signature_only(mangled_name, target_def, self_type)
    plan.list_of_accepted << IrSkip::AcceptedFun.new(mangled_name, target_def, self_type, previous_fun)
    plan.position += 1

    started_at = Time.instant
    failure = replay_ir_trace(previous_fun, walk)
    session.stats.replay_seconds += (Time.instant - started_at).total_seconds
    if failure
      invalidate_ir_skip_plan(module_info, plan, IrSkip::RegenerationReason::Replay, "#{mangled_name}: #{failure}") unless plan.invalidated?
      return nil
    end
    session.stats.replayed_functions += 1
    signature
  end

  # Declares the function named *mangled_name* among the function
  # signatures, without a body: what a module that calls it declares it from.
  private def declare_fun_signature_only(mangled_name : String, target_def : Def, self_type : Type) : LLVMTypedFunction
    signatures = fun_signatures
    if existing_signature = typed_fun?(signatures, mangled_name)
      return existing_signature
    end

    old_llvm_mod = @llvm_mod
    old_module_info = @module_info
    old_llvm_context = @llvm_context
    old_llvm_typer = @llvm_typer
    # A signature needs no debug info, and nothing would finish it.
    old_debug = @debug
    @debug = Debug::None

    with_cloned_context do
      context.type = self_type
      context.vars = LLVMVars.new
      context.block_context = nil

      @llvm_mod = signatures.mod
      @module_info = signatures
      @llvm_context = @llvm_mod.context
      @llvm_typer = signatures.typer

      codegen_fun_signature(mangled_name, target_def, self_type, false, false)
      signature = LLVMTypedFunction.new(context.fun_type, context.fun)

      @llvm_mod = old_llvm_mod
      @module_info = old_module_info
      @llvm_context = old_llvm_context
      @llvm_typer = old_llvm_typer
      @debug = old_debug
      signature
    end
  end

  # Repeats what generating the function of *recorded_fun* asked of the
  # rest of the program. Returns why it cannot, or `nil` when it did.
  private def replay_ir_trace(recorded_fun : IrSkip::RecordedFun, walk : IrSkip::Walk) : String?
    recorded_fun.list_of_trace_entries.each do |entry|
      case entry.kind
      in .fun?
        callee = walk.list_of_callees[entry.subject_index]?
        return "a callee of the trace is not among the callees of the def" unless callee

        request_target_def_fun(callee[0], callee[1])
      in .type_id?
        type = ir_trace_type?(walk, entry.subject_index, entry.text)
        return "a type of the trace is not known" unless type

        type_id_global_in_main(type)
      in .match?
        type = ir_trace_type?(walk, entry.subject_index, entry.text)
        unless type.is_a?(UnionType) || type.is_a?(VirtualType) || type.is_a?(VirtualMetaclassType)
          return "a type of the trace is not known"
        end

        match_fun_in_main(type)
      in .const_pointer?
        const = walk.list_of_consts[entry.subject_index]?
        return "a constant of the trace is not among the constants of the def" unless const
        return "#{const} is in another state than when the trace was recorded" unless (const.needs_init_flag? ? 1 : 0) == entry.detail

        request_const_pointer_in_main(const)
      in .class_var_pointer?
        class_var = walk.list_of_class_vars[entry.subject_index]?
        return "a class variable of the trace is not among the class variables of the def" unless class_var
        return "#{class_var.name} is in another state than when the trace was recorded" unless ir_class_var_state(class_var) == entry.detail

        request_class_var_pointer_in_main(class_var)
      in .metaclass?
        metaclass_fun_in_main
      in .check_proc_is_not_closure?
        check_proc_is_not_closure_fun_in_main
      in .class_name_map?
        @uses_type_id_to_class_name_map = true
      in .c_malloc?
        fetch_typed_fun(@main_mod, "malloc") do
          LLVM::Type.function([main_llvm_context_size_t], @main_llvm_context.void_pointer)
        end
      in .c_realloc?
        fetch_typed_fun(@main_mod, "realloc") do
          LLVM::Type.function([@main_llvm_context.void_pointer, main_llvm_context_size_t], @main_llvm_context.void_pointer)
        end
      in .proc_literal?
        proc_literal = walk.list_of_proc_literals[entry.subject_index]?
        proc_self_type = walk.list_of_types[entry.detail]?
        fun_literal_name = entry.text
        return "a proc literal of the trace is not among the proc literals of the def" unless proc_literal && proc_self_type && fun_literal_name

        unless typed_fun?(@main_mod, fun_literal_name)
          set_proc_literal_def_type(proc_literal)
          with_cloned_context do
            context.type = proc_self_type
            codegen_fun fun_literal_name, proc_literal.def, proc_self_type, fun_module_info: @main_module_info, is_fun_literal: true, is_closure: false
          end
        end
      end
    end
    nil
  end

  private def ir_trace_type?(walk : IrSkip::Walk, type_index : Int32, llvm_name : String?) : Type?
    return walk.list_of_types[type_index]? if type_index >= 0
    return nil unless llvm_name

    @ir_skip_walker.try(&.descriptors.type_named?(llvm_name))
  end

  # What a trace remembers of the state of *class_var* when it was read.
  private def ir_class_var_state(class_var : MetaTypeVar) : Int32
    class_var.no_init_flag? ? 1 : 0
  end

  # Generates *module_info* after all: the functions it matched so far,
  # in the order they were asked for, and from now on every function it
  # is asked for.
  private def invalidate_ir_skip_plan(module_info : ModuleInfo, plan : IrSkip::UnitPlan,
                                      reason : IrSkip::RegenerationReason, detail : String) : Nil
    plan.invalidate(reason, detail)
    plan.position = 0
    @ir_skip_invalidation_count += 1
    list_of_accepted = plan.list_of_accepted
    return if list_of_accepted.empty?

    module_info.late_generated = true
    list_of_accepted.each { |accepted| @ir_skip_late_pending[accepted.name] = {accepted, module_info} }
    list_of_accepted.each { |accepted| generate_late_pending_fun(accepted.name) }
  end

  # Generates the function named *mangled_name* if it is one that matched
  # the build before in a module that is generated after all.
  private def generate_late_pending_fun(mangled_name : String) : Nil
    return unless pending = @ir_skip_late_pending.delete(mangled_name)

    accepted, module_info = pending
    make_module_resident(module_info)
    use_module(module_info)
    pin_module(module_info)
    codegen_fun(accepted.name, accepted.typed_def, accepted.self_type, fun_module_info: module_info)
    unpin_module(module_info)
    ir_skip_session.try { |session| session.stats.late_generated_functions += 1 }
  end

  # Called when every function was asked for. A candidate module that was
  # asked for fewer functions than the build before generated into it is
  # generated after all.
  private def finish_ir_skip : Nil
    return unless session = ir_skip_session
    return if session.verify?

    loop do
      list_of_incomplete = @modules.values.select do |module_info|
        (plan = module_info.ir_skip_plan) && !plan.invalidated? && !plan.complete?
      end
      break if list_of_incomplete.empty?

      list_of_incomplete.each do |module_info|
        plan = module_info.ir_skip_plan
        next unless plan && !plan.invalidated? && !plan.complete?

        missing_count = plan.recorded.list_of_funs.size - plan.list_of_accepted.size
        invalidate_ir_skip_plan(module_info, plan, IrSkip::RegenerationReason::FunctionList,
          "#{missing_count} functions are no longer asked for")
      end
    end
  end

  private def current_ir_trace_frame : IrSkip::Frame?
    @ir_trace_frames.last?
  end

  # Notes that the function being generated asks for the function of
  # *target_def*.
  private def record_ir_fun_request(target_def : Def, self_type : Type) : Nil
    return unless frame = current_ir_trace_frame

    if callee_index = frame.callee_index?(target_def, self_type)
      frame.add(IrSkip::TraceKind::Fun, callee_index)
    else
      frame.unreplayable("a call to #{target_def.name} that the walk of the def did not list")
    end
  end

  # Notes a request to the main module that is about *type*.
  private def record_ir_type_effect(kind : IrSkip::TraceKind, type : Type) : Nil
    return unless frame = current_ir_trace_frame

    if type_index = frame.type_index?(type)
      frame.add(kind, type_index)
    else
      frame.add(kind, -1, 0, type.llvm_name)
    end
  end

  # Notes a request to the main module that is about nothing in particular.
  private def record_ir_effect(kind : IrSkip::TraceKind) : Nil
    current_ir_trace_frame.try &.add(kind, 0)
  end

  private def record_ir_const_pointer(const : Const) : Nil
    return unless frame = current_ir_trace_frame

    if const_index = frame.walk.list_of_consts.index(&.same?(const))
      frame.add(IrSkip::TraceKind::ConstPointer, const_index, const.needs_init_flag? ? 1 : 0)
    else
      frame.unreplayable("a read of the constant #{const} that the walk of the def did not list")
    end
  end

  private def record_ir_class_var_pointer(class_var : MetaTypeVar) : Nil
    return unless frame = current_ir_trace_frame

    if class_var_index = frame.walk.list_of_class_vars.index(&.same?(class_var))
      frame.add(IrSkip::TraceKind::ClassVarPointer, class_var_index, ir_class_var_state(class_var))
    else
      frame.unreplayable("a read of the class variable #{class_var.name} that the walk of the def did not list")
    end
  end

  private def record_ir_proc_literal(node : ProcLiteral, fun_literal_name : String, is_closure : Bool) : Nil
    return unless frame = current_ir_trace_frame

    if is_closure
      frame.unreplayable("a closure")
      return
    end
    proc_literal_index = frame.walk.list_of_proc_literals.index(&.same?(node))
    self_type_index = frame.type_index?(context.type)
    if proc_literal_index && self_type_index
      frame.add(IrSkip::TraceKind::ProcLiteral, proc_literal_index, self_type_index, fun_literal_name)
    else
      frame.unreplayable("a proc literal that the walk of the def did not list")
    end
  end

  # Notes that the function being generated asked the main module for
  # something no trace can repeat.
  private def mark_ir_trace_unreplayable(cause : String) : Nil
    current_ir_trace_frame.try &.unreplayable(cause)
  end
end
