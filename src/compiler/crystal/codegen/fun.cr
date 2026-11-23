require "./codegen"

class Crystal::CodeGenVisitor
  def typed_fun?(mod : LLVM::Module, name : String) : LLVMTypedFunction?
    typed_fun?(module_info_of(mod), name)
  end

  def typed_fun?(module_info : ModuleInfo, name : String) : LLVMTypedFunction?
    if func = module_info.mod.functions[name]?
      LLVMTypedFunction.new(module_info.fun_types[name], func)
    end
  end

  def add_typed_fun(mod : LLVM::Module, name : String, type : LLVM::Type) : LLVMTypedFunction
    add_typed_fun(module_info_of(mod), name, type)
  end

  def add_typed_fun(module_info : ModuleInfo, name : String, type : LLVM::Type) : LLVMTypedFunction
    func = module_info.mod.functions.add(name, type)
    module_info.fun_types[name] = type
    LLVMTypedFunction.new(type, func)
  end

  def fetch_typed_fun(mod : LLVM::Module, name : String, & : -> LLVM::Type) : LLVMTypedFunction
    typed_fun?(mod, name) || add_typed_fun(mod, name, yield)
  end

  def target_def_fun(target_def, self_type) : LLVMTypedFunction
    record_ir_fun_request(target_def, self_type)
    resolve_target_def_fun(target_def, self_type, declares_in_current_module: true) ||
      raise "BUG: #{target_def.name} was not declared in the module that calls it"
  end

  # Makes sure the function of *target_def* exists (generated, or matched
  # with the build before, see `IrSkip`), without declaring it in the module
  # code is being generated into. Replaying a trace asks this way.
  def request_target_def_fun(target_def, self_type) : Nil
    resolve_target_def_fun(target_def, self_type, declares_in_current_module: false)
  end

  private def resolve_target_def_fun(target_def, self_type, declares_in_current_module : Bool) : LLVMTypedFunction?
    if (sharing = @owner_shape_sharing) && (representative = sharing.representative?(target_def))
      unless self_type.same?(target_def.owner)
        raise "BUG: #{target_def.name} shares the function of another def but is called with self type #{self_type} instead of its owner #{target_def.owner}"
      end
      target_def = representative
      self_type = representative.owner
    end

    mangled_name = target_def.mangled_name(@program, self_type)

    # Matched with the build before, in a module that is generated after
    # all: it is generated now, as it would have been when it was first
    # asked for.
    generate_late_pending_fun(mangled_name) unless @ir_skip_late_pending.empty?

    if existing_declaration = declaration_of_known_fun?(mangled_name, declares_in_current_module)
      return existing_declaration[0]
    end

    # The function is in a part of its type's modules that is in memory, or
    # it is generated now, into the type's newest module. Reading a function
    # to declare it does not count as a use of its module: a module is kept
    # in memory for the functions it is about to get, not for the ones it has.
    existing_module_info = @single_module ? @main_module_info : existing_type_module_info?(self_type)
    if existing_module_info && (func = typed_fun_in_segments?(existing_module_info, mangled_name))
      return declares_in_current_module ? declare_in_current_module(mangled_name, func) : nil
    end
    # Deep in a chain of functions that each call the next, every module of
    # the chain is pinned (`codegen_fun` holds values of it), however large
    # it is. From `DEFERRED_GENERATION_DEPTH` on, a new function is only
    # declared here, from its signature, and generated once the outermost
    # function is done (see `generate_deferred_funs`). The type's module is
    # made then too: a module made now would stay in memory, empty, until
    # its first function.
    if defers_generation_of?(target_def)
      func = declare_deferred_fun(mangled_name, target_def, self_type)
      if @deferred_fun_names.add?(mangled_name)
        @list_of_deferred_funs << DeferredFun.new(mangled_name, target_def, self_type)
        @module_spill.try &.record_deferred_fun
      end
      return declares_in_current_module ? declare_in_current_module(mangled_name, func) : nil
    end

    first_module_info = existing_module_info || type_module_info(self_type)
    declared_fun = generate_target_def_fun(mangled_name, target_def, self_type, first_module_info, declares_in_current_module)
    generate_deferred_funs if @codegen_fun_depth == 0
    declared_fun
  end

  private def generate_target_def_fun(mangled_name, target_def, self_type, first_module_info : ModuleInfo,
                                      declares_in_current_module : Bool, deferred : Bool = false) : LLVMTypedFunction?
    self_type_module_info = segment_for_next_fun(first_module_info, mangled_name)

    # A module that matches the build before gets no code: the function is
    # declared and its trace replayed.
    invalidation_count = @ir_skip_invalidation_count
    if skipped_fun = skip_ir_generation_of(self_type_module_info, mangled_name, target_def, self_type)
      return declares_in_current_module ? declare_in_current_module(mangled_name, skipped_fun) : nil
    end
    if invalidation_count != @ir_skip_invalidation_count
      # Modules were generated after all in the meantime, and this function
      # may be among what they generated. A deferred function is known by
      # its signature until it is generated.
      if !deferred && (existing_declaration = declaration_of_known_fun?(mangled_name, declares_in_current_module))
        return existing_declaration[0]
      end
      if (func = typed_fun_in_segments?(first_module_info, mangled_name)) && !func.func.basic_blocks.empty?
        return declares_in_current_module ? declare_in_current_module(mangled_name, func) : nil
      end
    end

    # Declaring the new function here reads it from its module, which must
    # stay in memory until then.
    make_module_resident(self_type_module_info)
    use_module(self_type_module_info)
    pin_module(self_type_module_info)
    func = codegen_fun(mangled_name, target_def, self_type, fun_module_info: self_type_module_info)
    declared_fun = declares_in_current_module ? check_mod_fun(self_type_module_info, mangled_name, func) : nil
    unpin_module(self_type_module_info)
    declared_fun
  end

  # A function whose generation was put off (see `defers_generation_of?`).
  record DeferredFun, mangled_name : String, target_def : Def, self_type : Type

  # The nesting depth of `codegen_fun` from which new functions are
  # deferred. A Grant app of 300 models chains 300 of them (a function of
  # each model calls one of the next model), which pinned 860 MB of IR.
  DEFERRED_GENERATION_DEPTH = 8

  @list_of_deferred_funs = Deque(DeferredFun).new
  @deferred_fun_names = Set(String).new
  @codegen_fun_depth = 0
  @generates_deferred_funs = false

  # Whether `CRYSTAL_DEFER_DEEP_CODEGEN=0` turned deferring off.
  class_getter?(defers_deep_generation : Bool) { ENV["CRYSTAL_DEFER_DEEP_CODEGEN"]? != "0" }

  # Not in an incremental build: there a module is compared with the build
  # before by the order its functions were asked for in, and a build that
  # skips unchanged modules nests calls to other depths than the build
  # before did, so deferring would change that order and nothing would be
  # reused.
  private def defers_generation_of?(target_def) : Bool
    return false unless @module_spill && CodeGenVisitor.defers_deep_generation?
    return false if ir_skip_session || @program.stable_numbering
    return false if @single_module || @debug.variables? || target_def.is_a?(External)
    @codegen_fun_depth >= DEFERRED_GENERATION_DEPTH
  end

  # Declares the function of *target_def* in the function-signature module,
  # from which callers declare it, without generating it.
  private def declare_deferred_fun(mangled_name, target_def, self_type) : LLVMTypedFunction
    if known_signature = known_fun_signature?(mangled_name)
      return known_signature
    end

    signatures = fun_signatures
    old_llvm_mod = @llvm_mod
    old_module_info = @module_info
    old_llvm_context = @llvm_context
    old_llvm_typer = @llvm_typer
    begin
      with_cloned_context do
        @llvm_mod = signatures.mod
        @module_info = signatures
        @llvm_context = @llvm_mod.context
        @llvm_typer = signatures.typer
        codegen_fun_signature(mangled_name, target_def, self_type, false, false)
        LLVMTypedFunction.new(context.fun_type, context.fun)
      end
    ensure
      @llvm_mod = old_llvm_mod
      @module_info = old_module_info
      @llvm_context = old_llvm_context
      @llvm_typer = old_llvm_typer
    end
  end

  # Generates the deferred functions, and the ones they defer in turn.
  # Called when no function is being generated, and before IR generation
  # finishes.
  def generate_deferred_funs : Nil
    return if @generates_deferred_funs || @list_of_deferred_funs.empty?

    @generates_deferred_funs = true
    begin
      while deferred = @list_of_deferred_funs.shift?
        # Generated in the meantime (`codegen_fun` forgets it).
        next unless @deferred_fun_names.includes?(deferred.mangled_name)

        generate_target_def_fun(deferred.mangled_name, deferred.target_def, deferred.self_type,
          type_module_info(deferred.self_type), declares_in_current_module: false, deferred: true)
        @deferred_fun_names.delete(deferred.mangled_name)
      end
    ensure
      @generates_deferred_funs = false
    end
  end

  # Declares *func* in the module code is being generated into, unless that
  # module has it already. Replaying a trace (see `IrSkip`) can generate
  # code into the current module late, and that code may have declared the
  # function in the meantime; a second declaration would get another name.
  private def declare_in_current_module(mangled_name : String, func : LLVMTypedFunction) : LLVMTypedFunction
    typed_fun?(@module_info, mangled_name) || declare_fun(mangled_name, func)
  end

  # The function named *mangled_name* when it needs no generating: it is in
  # the module code is being generated into, or its signature is known
  # (declared in another module before, generated into a module part that
  # is on disk by now, or matched with the build before). The tuple tells a
  # function that is known but, as asked, not declared (`nil`) from one
  # that is not known (no tuple).
  private def declaration_of_known_fun?(mangled_name : String, declares_in_current_module : Bool) : {LLVMTypedFunction?}?
    # Already defined or declared in the current module: the module of the
    # self type is not needed (it may be on disk).
    if existing_fun = typed_fun?(@module_info, mangled_name)
      return {existing_fun}
    end

    if known_signature = known_fun_signature?(mangled_name)
      return {declares_in_current_module ? declare_fun(mangled_name, known_signature) : nil}
    end

    nil
  end

  def main_fun(name)
    func = typed_fun?(@main_mod, name) || raise "BUG: #{name} is not defined"
    check_main_fun name, func
  end

  def check_main_fun(name, func : LLVMTypedFunction) : LLVMTypedFunction
    check_mod_fun @main_module_info, name, func
  end

  def check_mod_fun(module_info : ModuleInfo, name, func : LLVMTypedFunction) : LLVMTypedFunction
    if @module_info.same?(module_info)
      func
    elsif existing_fun = typed_fun?(@module_info, name)
      existing_fun
    else
      declare_fun(name, func)
    end
  end

  # Declares *func*, a function of another module, in *module_info*.
  def declare_fun(mangled_name, func : LLVMTypedFunction, module_info : ModuleInfo = @module_info) : LLVMTypedFunction
    type = module_info.typer.copy_type(func.type)
    typed_fun = add_typed_fun(module_info, mangled_name, type)

    source_fun = func.func
    new_fun = typed_fun.func
    source_fun.params.each_index do |index|
      attrs = source_fun.attributes(index + 1)
      if attrs.value != 0
        param_type = new_fun.params[index].type
        new_fun.add_attribute(attrs, index + 1, param_type)
      end
    end

    typed_fun
  end

  def codegen_fun(mangled_name, target_def, self_type, is_exported_fun = false, fun_module_info = type_module(self_type, mangled_name), is_fun_literal = false, is_closure = false)
    old_position = insert_block
    old_entry_block = @entry_block
    old_alloca_block = @alloca_block
    old_ensure_exception_handlers = @ensure_exception_handlers
    old_rescue_block = @rescue_block
    old_catch_pad = @catch_pad
    old_llvm_mod = @llvm_mod
    old_module_info = @module_info
    old_llvm_context = @llvm_context
    old_llvm_typer = @llvm_typer
    old_builder = self.builder
    old_debug_location = @current_debug_location
    old_fun = context.fun

    old_needs_value = @needs_value

    if target_def.body.is_a?(ReleasedBody)
      raise "BUG: the body of #{target_def.name} was released after its function was generated, but codegen needs it again for #{mangled_name}"
    end

    # The module gets a new function, and stays in memory while this frame
    # holds values of it.
    fun_module_info.list_of_generated_fun_names << mangled_name
    pin_module(fun_module_info)
    @deferred_fun_names.delete(mangled_name)
    @codegen_fun_depth += 1
    @peak_trace_fun_count += 1
    trace_peak("functions") if @peak_trace_fun_count % 5000 == 0

    # Proc literals and closures are numbered within their function.
    @proc_counts.delete(mangled_name)
    @closure_counts.delete(mangled_name)
    # The function of a proc literal that is generated into the module of the
    # function that holds the literal belongs to that function: what it asks
    # of the rest of the program goes into that function's trace.
    inherits_ir_trace_frame = (is_fun_literal || is_closure) && !fun_module_info.same?(@main_module_info)
    ir_trace_frame = inherits_ir_trace_frame ? nil : begin_ir_trace_frame(mangled_name, target_def, self_type, fun_module_info,
      records: !(is_fun_literal || is_closure || is_exported_fun))

    typed_function = with_cloned_context do |old_context|
      context.type = self_type
      context.vars = LLVMVars.new
      context.block_context = nil

      @llvm_mod = fun_module_info.mod
      @module_info = fun_module_info
      @llvm_context = @llvm_mod.context
      @llvm_typer = fun_module_info.typer
      @builder = fun_module_info.builder

      @ensure_exception_handlers = nil
      @rescue_block = nil
      @catch_pad = nil
      @needs_value = true

      args = codegen_fun_signature(mangled_name, target_def, self_type, is_fun_literal, is_closure)

      needs_body = !target_def.is_a?(External) || is_exported_fun
      @generated_fun_count += 1 if needs_body
      if needs_body
        emit_def_debug_metadata target_def unless @debug.none?
        set_current_debug_location target_def if @debug.line_numbers?

        {% if LibLLVM::IS_LT_150 %}
          context.fun.add_attribute LLVM::Attribute::UWTable
        {% else %}
          context.fun.add_attribute LLVM::Attribute::UWTable, value: @program.has_flag?("aarch64") ? LLVM::UWTableKind::Sync : LLVM::UWTableKind::Async
        {% end %}

        if @frame_pointers.always?
          context.fun.add_attribute "frame-pointer", value: "all"
        elsif @program.has_flag?("darwin") || @program.has_flag?("solaris")
          # Disable frame pointer elimination, as it causes issues during stack unwind
          context.fun.add_target_dependent_attribute "frame-pointer", "all"
        elsif @frame_pointers.non_leaf?
          context.fun.add_attribute "frame-pointer", value: "non-leaf"
        end

        new_entry_block

        if is_closure
          clear_current_debug_location if @debug.line_numbers?
          void_ptr = context.fun.params.first
          closure_type = llvm_typer.copy_type(context.closure_type.not_nil!)
          closure_ptr = pointer_cast void_ptr, closure_type.pointer
          setup_closure_vars target_def, context.closure_vars.not_nil!, self.context, closure_type, closure_ptr
        else
          context.reset_closure
        end

        if !is_fun_literal && self_type.passed_as_self?
          context.vars["self"] = LLVMVar.new(context.fun.params.first, self_type, true)
        end

        if is_closure
          # In the case of a closure proc literal (-> { ... }), the closure_ptr is not
          # the one of the parent context, it's the last parameter of this proc literal.
          closure_parent_context = old_context.clone
          closure_parent_context.closure_ptr = closure_ptr.not_nil!
          context.closure_parent_context = closure_parent_context
        end

        set_current_debug_location target_def if @debug.line_numbers?
        alloca_vars target_def.vars, target_def, args, context.closure_parent_context

        create_local_copy_of_fun_args(target_def, self_type, args, is_fun_literal, is_closure)

        if @debug.variables? && !target_def.naked?
          in_alloca_block do
            location = target_def.location
            context.vars.each do |name, var|
              next if var.debug_variable_created

              # Self always comes as the first parameter, unless it's a closure:
              # then it will be fetched from the closure data.
              if name == "self" && !is_closure
                declare_debug_for_function_argument(name, var.type, 1, var.pointer, location)
                # Method debug parameters are skipped as they were defined in create_local_copy_of_fun_args()
                # due to LLVM variable dominance issue in some closure cases
              elsif args.none? { |arg| arg.name == name }
                declare_variable(name, var.type, var.pointer, location, alloca_block)
              end
            end
          end
        end

        context.return_type = target_def.type?
        context.return_phi = nil

        body = target_def.body

        # If the body is a primitive it means this is a function
        # that was generated by taking a pointer to it, for example
        # `a = 1; ->a.+(Int32)`.
        # In that case we need to inline the primitive code (as usual).
        if body.is_a?(Primitive)
          primitive_params = context.fun.params.to_a

          # If self is a primitive type it's actually passed as a pointer
          # (because the closure data is a pointer) and so we must load the
          # real value first.
          if args.first.type.is_a?(PrimitiveType)
            primitive_params[0] = load(llvm_type(args.first.type), primitive_params[0])
          end

          codegen_primitive(nil, body, target_def, primitive_params)
        elsif !is_fun_literal && !is_closure && !is_exported_fun && @dispatch_prune.try(&.stubs?(target_def))
          # Its owner is a class nothing creates (see `DispatchPrune`): the
          # function only stops the program, and nothing its real body
          # calls is generated.
          @stubbed_fun_count += 1
          codegen_unreachable_type(build_string_constant(target_def.owner.to_s), target_def.name, target_def.location)
        else
          accept target_def.body
        end

        codegen_return(target_def)

        br_from_alloca_to_entry
      end

      @llvm_mod = old_llvm_mod
      @module_info = old_module_info
      @llvm_context = old_llvm_context
      @llvm_typer = old_llvm_typer
      @builder = old_builder

      # A value of the caller's context: the context of the function that
      # was just generated may be disposed while the caller still holds this.
      @last = llvm_nil
      position_at_end old_position

      @ensure_exception_handlers = old_ensure_exception_handlers
      @rescue_block = old_rescue_block
      @catch_pad = old_catch_pad
      @entry_block = old_entry_block
      @alloca_block = old_alloca_block
      @needs_value = old_needs_value

      if @debug.line_numbers?
        # set_current_debug_location associates a scope from the current fun,
        # and at this point the current one should be the old one before
        # defining the fun. We do that. We also clear the debug location
        # if there was none before.
        if old_debug_location
          new_fun = context.fun
          context.fun = old_fun
          set_current_debug_location(old_debug_location)
          context.fun = new_fun
        else
          clear_current_debug_location
        end
      end

      if @program.has_flag?("wasm32")
        if target_def.is_a?(External) && (wasm_import_module = target_def.wasm_import_module)
          context.fun.add_target_dependent_attribute("wasm-import-name", target_def.real_name)
          context.fun.add_target_dependent_attribute("wasm-import-module", wasm_import_module)
        end

        if is_exported_fun
          context.fun.add_target_dependent_attribute("wasm-export-name", mangled_name)
        end
      end

      LLVMTypedFunction.new(context.fun_type, context.fun)
    end

    end_ir_trace_frame(ir_trace_frame, mangled_name, fun_module_info) unless inherits_ir_trace_frame
    unpin_module(fun_module_info)
    @codegen_fun_depth -= 1

    # Proc literals can be generated more than once (a block inlined at
    # several `yield`s), so only plain method defs are released.
    release_typed_body(target_def) unless is_fun_literal || is_closure || is_exported_fun
    typed_function
  end

  # Released bodies between two collections that return free heap pages to
  # the OS (see `release_typed_body`).
  RELEASED_BODIES_PER_UNMAP = 50_000

  private def release_typed_body(target_def) : Nil
    return unless release_typed_bodies?
    return if target_def.is_a?(External)
    return if target_def.body.is_a?(Primitive)
    # A body that is generated in place of a call is read by every later call.
    return if CodeGenVisitor.inlines_body_at_call?(target_def, target_def.body)

    target_def.body = ReleasedBody.new
    # Cut the edges that would keep the old body reachable: the def's own
    # (it depends on its body) and those of its args and local vars.
    target_def.release_bindings
    target_def.args.each &.release_bindings
    if target_def.special_vars
      # The signature of a def with special vars (`$~`, `$?`) reads their
      # types from the vars of the def.
      target_def.vars.try &.each_value &.release_bindings(@program.nil_var)
    else
      # The local vars were read to generate the function, and by nothing
      # afterwards.
      target_def.vars = nil
    end
    @released_body_count += 1
    # Hand the freed heap back to the OS now and then, so LLVM (which
    # allocates outside the GC heap) can use it instead of it sitting free.
    if @released_bodies_per_unmap > 0 && @released_body_count % @released_bodies_per_unmap == 0
      LibGC.set_force_unmap_on_gcollect(1)
      GC.collect
      LibGC.set_force_unmap_on_gcollect(0)
    end
  end

  # Releases the bodies of the defs that share another def's function: codegen
  # never generates them. Bodies that codegen inlines at the call (a literal,
  # `self`, an instance variable, a def that takes a block) are kept.
  def release_shared_bodies : Nil
    sharing = @owner_shape_sharing
    return unless sharing && release_typed_bodies?
    sharing.each_shared_def do |typed_def, _representative|
      next if typed_def.block_arg || typed_def.block_arity
      case typed_def.body
      when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral, Var, InstanceVar,
           Primitive, ReleasedBody
        next
      end
      release_typed_body(typed_def)
      sharing.stats.released_bodies += 1
    end
  end

  def codegen_return(target_def : Def)
    # Check if this def must use the C calling convention and the return
    # value must be either casted or passed by sret
    if target_def.c_calling_convention? && target_def.abi_info?
      return_type = target_def.body.type
      if return_type.proc?
        @last = check_proc_is_not_closure(@last, return_type)
      end

      abi_info = abi_info(target_def)
      abi_ret_type = abi_info.return_type
      if cast = abi_ret_type.cast
        casted_last = pointer_cast @last, cast.pointer
        last = load cast, casted_last
        ret last
        return
      end

      if (attr = abi_ret_type.attr) && attr == LLVM::Attribute::StructRet
        store load(llvm_type(return_type), @last), context.fun.params[0]
        ret
        return
      end
    end

    codegen_return target_def.body.type?
  end

  def codegen_fun_signature(mangled_name, target_def, self_type, is_fun_literal, is_closure)
    if !is_closure && (external = target_def.c_calling_convention?)
      codegen_fun_signature_external(mangled_name, external)
    else
      codegen_fun_signature_non_external(mangled_name, target_def, self_type, is_fun_literal, is_closure)
    end
  end

  def codegen_fun_signature_non_external(mangled_name, target_def, self_type, is_fun_literal, is_closure)
    is_primitive = target_def.body.is_a?(Primitive)

    args = Array(Arg).new(target_def.args.size + 1)

    if !is_fun_literal && self_type.passed_as_self?
      args.push Arg.new("self", type: self_type)
    end

    args.concat target_def.args

    if target_def.uses_block_arg?
      block_arg = target_def.block_arg.not_nil!
      args.push Arg.new(block_arg.name, type: block_arg.type)
    end

    target_def.special_vars.try &.each do |special_var_name|
      args.push Arg.new(special_var_name, type: target_def.vars.not_nil![special_var_name].type)
    end

    llvm_args_types = args.map_with_index do |arg, i|
      arg_type = arg.type
      if arg_type.void?
        llvm_arg_type = llvm_context.int8
      else
        llvm_arg_type = llvm_type(arg_type)

        # We need an extra pointer for special vars (they always have an extra pointer)
        if arg.special_var?
          llvm_arg_type = llvm_arg_type.pointer
        end

        # Self is always passed by reference (pointer),
        # even if the type is passed by value (like a struct).
        # In case the body is a Primitive it means it's something like
        # `a = 1; ->a.+(Int32)` in which case we must use a pointer for
        # the first argument (because the closure data is a pointer).
        if i == 0 && !is_fun_literal && self_type.passed_as_self? && (self_type.passed_by_value? || (is_primitive && arg_type.is_a?(PrimitiveType)))
          llvm_arg_type = llvm_arg_type.pointer
        end
      end
      llvm_arg_type
    end

    llvm_return_type = {% if LibLLVM::IS_LT_150 %}
                         llvm_return_type(target_def.type)
                       {% else %}
                         target_def.llvm_intrinsic? ? llvm_intrinsic_return_type(target_def.type) : llvm_return_type(target_def.type)
                       {% end %}

    if is_closure
      llvm_args_types.insert(0, llvm_context.void_pointer)
      offset = 1
    else
      offset = 0
    end

    setup_context_fun(mangled_name, target_def, llvm_args_types, llvm_return_type)

    if @debug.variables?
      context.fun_debug_params.clear
      if context.fun
        context.add_fun_debug_param(get_debug_type(target_def.type))
        args.each do |arg|
          context.add_fun_debug_param(get_debug_type(arg.type))
        end
      end
    end

    if @single_module && !target_def.is_a?(External)
      context.fun.linkage = LLVM::Linkage::Internal
    end

    args.each_with_index do |arg, i|
      param = context.fun.params[i + offset]
      param.name = arg.name

      # Mark self parameter as nonnull for reference types.
      # In Crystal, calling a method on a reference type guarantees self is
      # a valid heap pointer (never null). We exclude nilable types since
      # those can legitimately be null.
      if i == 0 && !is_fun_literal && self_type.passed_as_self? &&
         self_type.reference_like? && !self_type.is_a?(NilType) &&
         !self_type.is_a?(NilableType) && !self_type.is_a?(NilableReferenceUnionType)
        context.fun.add_attribute(LLVM::Attribute::NonNull, i + offset + 1)
      end
    end

    args
  end

  def codegen_fun_signature_external(mangled_name, target_def)
    args = target_def.args.dup

    # This is the case where we declared a fun that was not used and now we
    # are defining its body.
    if existing_fun = typed_fun?(@llvm_mod, mangled_name)
      context.fun = existing_fun.func
      context.fun_type = existing_fun.type
      return args
    end

    offset = 0

    abi_info = abi_info(target_def)

    llvm_args_types = Array(LLVM::Type).new(abi_info.arg_types.size)
    abi_info.arg_types.each do |arg_type|
      case arg_type.kind
      in .direct?
        llvm_args_types << (arg_type.cast || arg_type.type)
      in .indirect?
        llvm_args_types << arg_type.type.pointer
      in .ignore?
        # ignore
      end
    end

    ret_type = abi_info.return_type
    llvm_return_type =
      case ret_type.kind
      in .direct?
        ret_type.cast || ret_type.type
      in .indirect?
        offset += 1
        llvm_args_types.insert 0, ret_type.type.pointer
        llvm_context.void
      in .ignore?
        llvm_context.void
      end

    setup_context_fun(mangled_name, target_def, llvm_args_types, llvm_return_type)

    if call_convention = target_def.call_convention
      context.fun.call_convention = call_convention
    end

    if @single_module && mangled_name.starts_with?("__crystal_")
      # FIXME: macos ld fails to link when the personality fun is internal; it
      # might work with lld so we might want to check the linker?
      unless @program.has_flag?("darwin") && mangled_name.starts_with?("__crystal_personality")
        context.fun.linkage = LLVM::Linkage::Internal
      end
    end

    i = 0
    args.each do |arg|
      param = context.fun.params[i + offset]
      param.name = arg.name

      abi_arg_type = abi_info.arg_types[i]

      if attr = abi_arg_type.attr
        context.fun.add_attribute(attr, i + offset + 1, abi_arg_type.type)
      end

      i += 1 unless abi_arg_type.kind == ABI::ArgKind::Ignore
    end

    # This is for sret
    if (attr = abi_info.return_type.attr) && attr == LLVM::Attribute::StructRet
      context.fun.add_attribute(attr, 1, abi_info.return_type.type)
    end

    args
  end

  def abi_info(external : Def)
    external.abi_info = true

    llvm_args_types = external.args.map { |arg| llvm_c_type(arg.type) }
    llvm_return_type = llvm_c_return_type(external.type)
    abi.abi_info(llvm_args_types, llvm_return_type, !llvm_return_type.void?, llvm_context)
  end

  def abi_info(external : Def, node : Call)
    llvm_args_types = node.args.map_with_index do |arg, i|
      llvm_c_type((external.args[i]? || arg).type)
    end
    llvm_return_type = llvm_c_return_type(external.type)
    abi.abi_info(llvm_args_types, llvm_return_type, !llvm_return_type.void?, llvm_context)
  end

  def setup_context_fun(mangled_name, target_def, llvm_args_types, llvm_return_type) : Nil
    fun_type = LLVM::Type.function(llvm_args_types, llvm_return_type, target_def.varargs?)
    # A deferred function may be declared in its own module already, by a
    # function of that module that called it before it was generated.
    existing_declaration = typed_fun?(@llvm_mod, mangled_name)
    typed_fun = if existing_declaration && existing_declaration.func.basic_blocks.empty?
                  existing_declaration
                else
                  add_typed_fun(@llvm_mod, mangled_name, fun_type)
                end
    context.fun = typed_fun.func
    context.fun_type = typed_fun.type

    optimize_none = @debug.variables?
    features = target_def.target_features
    cpu = target_def.target_cpu

    if optimize_none || features || cpu
      # Make it a hard boundary, disabling inlining
      context.fun.add_attribute LLVM::Attribute::NoInline

      context.fun.add_attribute LLVM::Attribute::OptimizeNone if optimize_none
      context.fun.add_target_dependent_attribute("target-features", features) if features
      context.fun.add_target_dependent_attribute("target-cpu", cpu) if cpu
    else
      context.fun.add_attribute LLVM::Attribute::AlwaysInline if target_def.always_inline?
      context.fun.add_attribute LLVM::Attribute::NoInline if target_def.no_inline?
    end

    {% unless LibLLVM::IS_LT_130 %}
      case @program.optimization_mode
      when .os? then context.fun.add_attribute LLVM::Attribute::OptimizeForSize
      when .oz? then context.fun.add_attribute LLVM::Attribute::MinSize
      end
    {% end %}

    context.fun.add_attribute LLVM::Attribute::ReturnsTwice if target_def.returns_twice?
    context.fun.add_attribute LLVM::Attribute::Naked if target_def.naked?
    context.fun.add_attribute LLVM::Attribute::NoReturn if target_def.no_returns?
  end

  def setup_closure_vars(target_def, closure_vars, context, closure_type, closure_ptr)
    if context.closure_skip_parent
      parent_context = context.closure_parent_context.not_nil!
      setup_closure_vars(target_def, parent_context.closure_vars.not_nil!, parent_context, closure_type, closure_ptr)
    else
      def_vars = target_def.vars
      closure_vars.each_with_index do |var, i|
        # A closured var in this context might have the same name as
        # a local var in another context, for example if the local var
        # was defined before the closured var. In this case, don't
        # consider the local var as closured.
        def_var = def_vars.try &.[var.name]?
        next if def_var && !def_var.closured?

        if context.fun.naked?
          debug_variable_created = false
        else
          var_offset = llvm_typer.offset_of(closure_type, i)
          debug_variable_created = declare_variable(var.name, var.type, closure_ptr, target_def.location, offset: var_offset)
        end
        var_ptr = gep(closure_type, closure_ptr, 0, i, var.name)
        self.context.vars[var.name] = LLVMVar.new(var_ptr, var.type, debug_variable_created: debug_variable_created)
      end

      if (closure_parent_context = context.closure_parent_context) &&
         (parent_vars = closure_parent_context.closure_vars)
        parent_closure_type = llvm_typer.copy_type(closure_parent_context.closure_type.not_nil!)
        parent_closure_ptr = gep(closure_type, closure_ptr, 0, closure_vars.size, "parent_ptr")
        parent_closure = load(parent_closure_type.pointer, parent_closure_ptr, "parent")
        setup_closure_vars(target_def, parent_vars, closure_parent_context, parent_closure_type, parent_closure)
      elsif closure_self = context.closure_self
        self_index = closure_vars.size + (context.closure_parent_context ? 1 : 0)
        if context.fun.naked?
          debug_variable_created = false
        else
          self_offset = llvm_typer.offset_of(closure_type, self_index)
          debug_variable_created = declare_variable("self", closure_self, closure_ptr, target_def.location, offset: self_offset)
        end
        self_value = gep(closure_type, closure_ptr, 0, self_index, "self")
        self_value = load(llvm_type(closure_self), self_value) unless closure_self.passed_by_value?
        self.context.vars["self"] = LLVMVar.new(self_value, closure_self, true, debug_variable_created: debug_variable_created)
      end
    end
  end

  def create_local_copy_of_fun_args(target_def, self_type, args, is_fun_literal, is_closure)
    offset = is_closure ? 1 : 0

    abi_info = target_def.abi_info? ? abi_info(target_def) : nil
    sret = abi_info && sret?(abi_info)
    offset += 1 if sret

    target_def_vars = target_def.vars
    args.each_with_index do |arg, i|
      param = context.fun.params[i + offset]
      if !is_fun_literal && (i == 0 && self_type.passed_as_self?)
        # here self is already in context.vars
      else
        create_local_copy_of_arg(target_def, target_def_vars, arg, param, i + offset)
      end
    end
  end

  def create_local_copy_of_block_self(self_type, call_args)
    args_base_index = 0
    if self_type.passed_as_self?
      context.vars["self"] = LLVMVar.new(call_args[0], self_type, true)
      args_base_index = 1
    end
    args_base_index
  end

  def create_local_copy_of_block_args(target_def, self_type, call_args, args_base_index)
    target_def.args.each_with_index do |arg, i|
      create_local_copy_of_arg(target_def, target_def.vars, arg, call_args[args_base_index + i], args_base_index + i)
    end
  end

  def create_local_copy_of_arg(target_def, target_def_vars, arg, value, index)
    # An argument name can be "_" in the case of a captured block,
    # and we must ignore these
    return if arg.name == "_"

    target_def_var = target_def_vars.try &.[arg.name]
    location = target_def_var.try(&.location) || target_def.location

    var_type = (target_def_var || arg).type
    return if var_type.void?

    if closure_var = context.vars[arg.name]?
      pointer = closure_var.pointer

      if arg.type.passed_by_value?
        # Create an alloca and store it there, so assign works well
        pointer2 = alloca(llvm_type(arg.type))
        store value, pointer2
        value = pointer2
      end
    else
      abi_info = target_def.abi_info? ? abi_info(target_def) : nil
      sret = abi_info && sret?(abi_info)

      # If it's an extern struct on a def that must be codegened with C ABI
      # compatibility, and it's not passed byval, we must cast the value
      if target_def.c_calling_convention? && arg.type.extern? && !context.fun.attributes(index + 1).by_val?
        # ... unless it's passed indirectly (ie. as a pointer to memory allocated by the caller)
        if abi_info.try &.arg_types[index - (sret ? 1 : 0)].kind.indirect?
          value = declare_debug_for_function_argument(arg.name, var_type, index + 1, value, location) unless target_def.naked?
          context.vars[arg.name] = LLVMVar.new(value, var_type)
        else
          pointer = alloca(llvm_type(var_type), arg.name)
          casted_pointer = pointer_cast pointer, value.type.pointer
          store value, casted_pointer
          pointer = declare_debug_for_function_argument(arg.name, var_type, index + 1, pointer, location) unless target_def.naked?
          context.vars[arg.name] = LLVMVar.new(pointer, var_type)
        end
        return
      elsif arg.special_var?
        value = declare_debug_for_function_argument(arg.name, var_type, index + 1, value, location) unless target_def.naked?
        context.vars[arg.name] = LLVMVar.new(value, var_type)
        return
      else
        # If an argument is a Proc inside a C function, we need to cast it to Proc
        fun_proc = var_type.is_a?(ProcInstanceType) && target_def.is_a?(External)

        # We don't need to create a copy of the argument if it's never
        # assigned a value inside the function.
        needs_copy = target_def_var.try &.assigned_to?
        needs_copy ||= fun_proc

        if needs_copy
          pointer = alloca(llvm_type(var_type), arg.name)
          pointer = declare_debug_for_function_argument(arg.name, var_type, index + 1, pointer, location) unless target_def.naked?

          if fun_proc
            fun_ptr = cast_to_void_pointer(value)
            value = make_fun(var_type, fun_ptr, llvm_context.void_pointer.null)
          end

          context.vars[arg.name] = LLVMVar.new(pointer, var_type)

          if arg.type.passed_by_value? && !context.fun.attributes(index + 1).by_val?
            # Create an alloca and store it there, so assign works well
            pointer2 = alloca(llvm_type(arg.type))
            store value, pointer2
            value = pointer2
          end
        else
          if arg.type.passed_by_value? && !context.fun.attributes(index + 1).by_val?
            # For pass-by-value we create an alloca so the value
            # is behind a pointer, as everywhere else
            pointer = alloca(llvm_type(var_type), arg.name)
            store value, pointer
            pointer = declare_debug_for_function_argument(arg.name, var_type, index + 1, pointer, location) unless target_def.naked?
            context.vars[arg.name] = LLVMVar.new(pointer, var_type)
            return
          else
            value = declare_debug_for_function_argument(arg.name, var_type, index + 1, value, location) unless target_def.naked?
            context.vars[arg.name] = LLVMVar.new(value, var_type, true)
            return
          end
        end
      end
    end

    assign pointer, var_type, arg.type, value
  end

  # The module of *type*, in memory. See `use_module` for how long handles
  # into other modules stay valid.
  def type_module(type, mangled_name : String? = nil) : ModuleInfo
    return @main_module_info if @single_module

    module_info = segment_for_next_fun(type_module_info(type), mangled_name)
    use_module(module_info)
    module_info
  end

  # The module of *type* if it was made already (see `type_module_info`).
  private def existing_type_module_info?(type) : ModuleInfo?
    @types_to_modules[type]? || @modules[module_type_name(type)]?.try { |module_info| @types_to_modules[type] = module_info }
  end

  private def module_type_name(type) : String
    type = type.remove_typedef
    case type
    when Nil, Program, LibType
      ""
    else
      type.instance_type.to_s
    end
  end

  private def type_module_info(type) : ModuleInfo
    @types_to_modules[type] ||= begin
      type_name = module_type_name(type)
      @modules[type_name] ||= new_module_info(type_name)
    end
  end
end
