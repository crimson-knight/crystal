require "./codegen"

module Crystal
  # Settings and counters for keeping only a bounded set of LLVM modules in
  # memory during IR generation.
  #
  # In multi-module mode every type gets an LLVM module in an LLVM context of
  # its own, and a large program has thousands of them. With a `ModuleSpill`
  # the code generator keeps resident only the modules it is generating code
  # into right now, plus the most recently used idle ones, as many as fit
  # under *resident_ir_bytes* of estimated IR and under *resident_limit*
  # modules. The least recently used idle module is written to its bitcode
  # file and its context is disposed; it is parsed back from that file when
  # code generation needs it again.
  class ModuleSpill
    # An estimate of the memory LLVM holds for a module, from what is cheap
    # to count. The factors come from the Grant 300-model program: its
    # modules took about 10 GB for 31 million built instructions
    # (see notes/spill-v2.md of the memory-ceiling work).
    BYTES_PER_MODULE              = 65_536_i64
    BYTES_PER_BUILT_INSTRUCTION   =    300_i64
    BYTES_PER_LOADED_BITCODE_BYTE =     10_i64

    # How many idle modules stay in memory (0: as many as fit in the bytes).
    getter resident_limit : Int32

    # How many bytes of estimated IR stay in memory (0: no limit in bytes).
    getter resident_ir_bytes : Int64

    # The largest estimate of the IR in memory at once.
    getter peak_resident_ir_bytes = 0_i64

    # How many instructions the code generator built into spillable modules.
    getter built_instruction_count = 0_i64

    # How many bytes of bitcode were written and read back.
    getter written_bitcode_bytes = 0_i64
    getter reloaded_bitcode_bytes = 0_i64

    # The time spent writing and reading bitcode.
    getter write_time = Time::Span.zero
    getter reload_time = Time::Span.zero

    # How many structs of reloaded modules got their body from the Crystal
    # type, and the names of those whose loaded body differs from it (see
    # `LLVMTyper#named_struct`; the list should stay empty).
    getter completed_struct_count = 0
    getter list_of_mismatched_struct_names = [] of String

    # The target triple written into every spilled module.
    getter target_triple : String

    # How many times a module was dropped from memory.
    getter spill_count = 0

    # How many of those spills had to write the module's bitcode (a module
    # that did not change since it was loaded is dropped without a write).
    getter write_count = 0

    # How many times a spilled module was parsed back from its bitcode.
    getter reload_count = 0

    # The largest number of modules that were in memory at once.
    getter peak_resident_count = 0

    def initialize(@resident_limit : Int32, @resident_ir_bytes : Int64, @target_triple : String, &@bitcode_path : String -> String)
    end

    def limits_module_count? : Bool
      @resident_limit > 0
    end

    def limits_ir_bytes? : Bool
      @resident_ir_bytes > 0
    end

    # The bitcode file of the module of the type named *module_name*.
    def bitcode_path(module_name : String) : String
      @bitcode_path.call(module_name)
    end

    # The number of idle modules left in memory when the limit is exceeded.
    # Going a little below the limit spills in small batches.
    def idle_count_after_spilling : Int32
      (@resident_limit - @resident_limit // 8).clamp(1..)
    end

    # The estimated IR left in memory when the limit is exceeded.
    def ir_bytes_after_spilling : Int64
      @resident_ir_bytes - @resident_ir_bytes // 8
    end

    def record_spill(built_instruction_count : Int64) : Nil
      @spill_count += 1
      @built_instruction_count += built_instruction_count
    end

    def record_built_instructions(built_instruction_count : Int64) : Nil
      @built_instruction_count += built_instruction_count
    end

    def record_write(bitcode_bytes : Int64, time : Time::Span) : Nil
      @write_count += 1
      @written_bitcode_bytes += bitcode_bytes
      @write_time += time
    end

    def record_reload(bitcode_bytes : Int64, time : Time::Span) : Nil
      @reload_count += 1
      @reloaded_bitcode_bytes += bitcode_bytes
      @reload_time += time
    end

    def record_resident(count : Int32, ir_bytes : Int64) : Nil
      @peak_resident_count = count if count > @peak_resident_count
      @peak_resident_ir_bytes = ir_bytes if ir_bytes > @peak_resident_ir_bytes
    end

    # Takes over the struct counters of the typer of a reloaded module that
    # is about to be dropped.
    def record_typer(typer : LLVMTyper) : Nil
      @completed_struct_count += typer.completed_struct_count
      typer.list_of_mismatched_struct_names.each do |name|
        @list_of_mismatched_struct_names << name if @list_of_mismatched_struct_names.size < 20
      end
    end
  end

  class CodeGenVisitor
    # An LLVM module of the program, with every handle the code generator
    # keeps into the module's LLVM context. A spilled module has none of
    # them: its bitcode is in the file at `#spill_path`.
    class ModuleInfo
      # The name of the type this module belongs to (empty for the main module).
      getter name : String

      @mod : LLVM::Module?
      @typer : LLVMTyper?
      @builder : CrystalLLVMBuilder?

      # The types of the functions looked up or added through
      # `CodeGenVisitor#typed_fun?` and `CodeGenVisitor#add_typed_fun`.
      getter fun_types = {} of String => LLVM::Type

      # The string constants of this module.
      getter strings = {} of String => LLVM::Value

      # Debug metadata is cached per module, so that metadata of one module
      # is never used in another one.
      getter debug_files = {} of DebugFilename => LibLLVM::MetadataRef
      getter debug_types = {} of Type => LibLLVM::MetadataRef?
      getter fun_metadatas = {} of LLVM::Function => Array(FunMetadata)
      property di_builder : DIBuilder?

      # True once the module flags that announce debug info were added.
      property? has_debug_info_flags = false

      # How many code generation frames are using this module. A module in
      # use is never spilled.
      property pin_count = 0

      # The value of the code generator's use clock when this module was
      # last asked for.
      property last_used_at = 0_i64

      # True if the module differs from the bitcode at `#spill_path`.
      property? changed_since_spill = true

      # The bitcode file of this module, once it was spilled.
      property spill_path : String?

      # The size of the bitcode this module was last parsed from (0 for a
      # module that was never spilled).
      property loaded_bitcode_bytes = 0_i64

      # The estimate of this module's IR that is part of the code
      # generator's total (see `CodeGenVisitor#account_module_ir`).
      property accounted_ir_bytes = 0_i64

      def initialize(@name : String, @mod : LLVM::Module, @typer : LLVMTyper)
      end

      def mod : LLVM::Module
        @mod || raise "BUG: LLVM module #{@name.inspect} is used while spilled to disk"
      end

      def typer : LLVMTyper
        @typer || raise "BUG: LLVM typer of module #{@name.inspect} is used while spilled to disk"
      end

      def builder : CrystalLLVMBuilder
        @builder || raise "BUG: LLVM builder of module #{@name.inspect} is used before it exists"
      end

      def builder=(@builder : CrystalLLVMBuilder)
      end

      def resident? : Bool
        !@mod.nil?
      end

      def idle? : Bool
        @pin_count == 0
      end

      # How many instructions were built into this module since it was
      # created or last parsed from bitcode.
      def built_instruction_count : Int64
        @builder.try(&.instruction_count) || 0_i64
      end

      # An estimate of the memory LLVM holds for this module.
      def estimated_ir_bytes : Int64
        ModuleSpill::BYTES_PER_MODULE +
          built_instruction_count * ModuleSpill::BYTES_PER_BUILT_INSTRUCTION +
          @loaded_bitcode_bytes * ModuleSpill::BYTES_PER_LOADED_BITCODE_BYTE
      end

      # Hands this spilled module the module parsed back from its bitcode.
      def attach(@mod : LLVM::Module, @typer : LLVMTyper) : Nil
        @changed_since_spill = false
      end

      # Drops every handle into the module's context. The caller disposes
      # the context.
      def detach : Nil
        @mod = nil
        @typer = nil
        @builder = nil
        @di_builder = nil
        @fun_types.clear
        @strings.clear
        @debug_files.clear
        @debug_types.clear
        @fun_metadatas.clear
        @changed_since_spill = false
      end
    end

    # When set, idle modules are spilled to disk (see `ModuleSpill`).
    property module_spill : ModuleSpill?

    # The modules that are in memory, except the main one (it always is).
    @resident_modules = [] of ModuleInfo
    @idle_resident_module_count = 0
    @module_use_clock = 0_i64

    # The sum of `ModuleInfo#accounted_ir_bytes` of the modules in memory.
    @resident_ir_bytes = 0_i64

    # A module that only holds declarations: one for each function that was
    # declared in a module other than its own. With it, the next module that
    # calls such a function declares it without reading the function's own
    # module, which may be on disk by then. It is never compiled.
    @fun_signatures : ModuleInfo?

    private def fun_signatures : ModuleInfo
      @fun_signatures ||= begin
        llvm_context = LLVM::Context.new
        llvm_mod = configure_module(llvm_context.new_module("function_signatures"))
        signatures = ModuleInfo.new("(function signatures)", llvm_mod, LLVMTyper.new(@program, llvm_context, data_layout: llvm_mod.data_layout))
        signatures.pin_count = 1
        signatures
      end
    end

    # The declaration recorded for the function named *mangled_name*, if any.
    private def known_fun_signature?(mangled_name : String) : LLVMTypedFunction?
      return nil unless @module_spill

      typed_fun?(fun_signatures, mangled_name)
    end

    # Records the signature of *func*, a function of *fun_module_info* that
    # another module just declared.
    private def record_fun_signature(fun_module_info : ModuleInfo, mangled_name : String, func : LLVMTypedFunction) : Nil
      return unless @module_spill
      # The main module is always in memory.
      return if fun_module_info.same?(@main_module_info)

      signatures = fun_signatures
      declare_fun(mangled_name, func, signatures) unless typed_fun?(signatures, mangled_name)
    end

    # The module that `@llvm_mod` or `@main_mod` is.
    private def module_info_of(mod : LLVM::Module) : ModuleInfo
      if mod == @llvm_mod
        @module_info
      elsif mod == @main_mod
        @main_module_info
      else
        raise "BUG: #{mod.name} is neither the current module nor the main one"
      end
    end

    # Keeps *module_info* in memory until the matching `unpin_module`.
    def pin_module(module_info : ModuleInfo) : Nil
      module_info.pin_count += 1
      @idle_resident_module_count -= 1 if module_info.pin_count == 1
    end

    def unpin_module(module_info : ModuleInfo) : Nil
      module_info.pin_count -= 1
      if module_info.pin_count == 0
        @idle_resident_module_count += 1
        # Code is only generated into a pinned module, so this is where a
        # module's growth becomes known.
        account_module_ir(module_info)
      end
    end

    # Brings the total of estimated IR in memory up to date with
    # *module_info*, a module in memory.
    private def account_module_ir(module_info : ModuleInfo) : Nil
      return unless @module_spill
      return if module_info.same?(@main_module_info) || module_info.same?(@fun_signatures)

      estimated_ir_bytes = module_info.estimated_ir_bytes
      @resident_ir_bytes += estimated_ir_bytes - module_info.accounted_ir_bytes
      module_info.accounted_ir_bytes = estimated_ir_bytes
    end

    private def new_module_info(type_name : String) : ModuleInfo
      llvm_context = LLVM::Context.new
      # LLVM::Context.register(llvm_context, type_name)

      llvm_mod = configure_module(llvm_context.new_module(type_name))
      llvm_typer = LLVMTyper.new(@program, llvm_context, data_layout: llvm_mod.data_layout)

      module_info = ModuleInfo.new(type_name, llvm_mod, llvm_typer)
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
      module_info
    end

    private def module_became_resident(module_info : ModuleInfo) : Nil
      @resident_modules << module_info
      @idle_resident_module_count += 1
      account_module_ir(module_info)
      @module_spill.try &.record_resident(@resident_modules.size + 1, @resident_ir_bytes)
    end

    # Makes sure *module_info* is in memory, marks it as the most recently used
    # module and spills the least recently used idle modules if there are
    # more of them than the limit allows.
    #
    # A handle into another module than *module_info* is only safe to keep across
    # this call if that module is pinned.
    private def use_module(module_info : ModuleInfo) : Nil
      spill = @module_spill
      return unless spill
      return if module_info.same?(@main_module_info)

      reload_module(module_info, spill) unless module_info.resident?
      module_info.last_used_at = (@module_use_clock += 1)

      spill.record_resident(@resident_modules.size + 1, @resident_ir_bytes)
      if too_many_idle_modules?(spill) || too_much_resident_ir?(spill)
        spill_idle_modules(spill, keeping: module_info)
      end
    end

    private def too_many_idle_modules?(spill : ModuleSpill) : Bool
      spill.limits_module_count? && @idle_resident_module_count > spill.resident_limit
    end

    private def too_much_resident_ir?(spill : ModuleSpill) : Bool
      spill.limits_ir_bytes? && @resident_ir_bytes > spill.resident_ir_bytes
    end

    # Spills the least recently used idle modules until the modules in
    # memory are a little below both limits. Modules in use stay, however
    # large they are.
    private def spill_idle_modules(spill : ModuleSpill, keeping : ModuleInfo) : Nil
      list_of_idle_modules = @resident_modules.select { |module_info| module_info.idle? && !module_info.same?(keeping) }
      list_of_idle_modules.sort_by!(&.last_used_at)
      list_of_idle_modules.each do |module_info|
        # *keeping* is idle too and stays, so it takes one of the places.
        count_is_low_enough = !spill.limits_module_count? || @idle_resident_module_count <= spill.idle_count_after_spilling
        ir_is_small_enough = !spill.limits_ir_bytes? || @resident_ir_bytes <= spill.ir_bytes_after_spilling
        break if count_is_low_enough && ir_is_small_enough

        spill_module(module_info, spill)
      end
    end

    private def spill_module(module_info : ModuleInfo, spill : ModuleSpill) : Nil
      finish_module_debug_info(module_info) unless @debug.none?

      mod = module_info.mod
      # A module that did not change since it was parsed from its file is
      # dropped without writing it again.
      if module_info.changed_since_spill?
        mod.target = spill.target_triple
        path = module_info.spill_path ||= spill.bitcode_path(module_info.name)
        write_time = Time.measure do
          unless mod.write_bitcode_to_file(path) == 0
            raise "BUG: failed to write the LLVM bitcode of #{module_info.name.inspect} to #{path}"
          end
        end
        spill.record_write(File.size(path), write_time)
      end

      spill.record_spill(module_info.built_instruction_count)
      spill.record_typer(module_info.typer)
      @resident_ir_bytes -= module_info.accounted_ir_bytes
      module_info.accounted_ir_bytes = 0_i64

      context = mod.context
      module_info.detach
      context.dispose

      @resident_modules.delete(module_info)
      @idle_resident_module_count -= 1
    end

    # Adds the counters of the modules that are in memory when IR
    # generation ends to the spill statistics.
    def record_resident_modules_in_spill_statistics : Nil
      return unless spill = @module_spill

      @resident_modules.each do |module_info|
        spill.record_typer(module_info.typer)
        spill.record_built_instructions(module_info.built_instruction_count)
      end
    end

    private def reload_module(module_info : ModuleInfo, spill : ModuleSpill) : Nil
      path = module_info.spill_path || raise "BUG: LLVM module #{module_info.name.inspect} is neither in memory nor on disk"

      llvm_context = LLVM::Context.new
      started_at = Time.instant
      bitcode = LLVM::MemoryBuffer.from_file(path)
      begin
        llvm_mod = LLVM::Module.parse(bitcode, llvm_context)
      ensure
        bitcode.dispose
      end
      # A parsed module is named after its file. The name goes into debug
      # info, so the module gets back the one it was created with.
      llvm_mod.name = module_info.name
      module_info.loaded_bitcode_bytes = File.size(path)
      spill.record_reload(module_info.loaded_bitcode_bytes, Time.instant - started_at)

      module_info.attach(llvm_mod, LLVMTyper.new(@program, llvm_context, adopts_existing_structs: true, data_layout: llvm_mod.data_layout))
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
    end
  end
end
