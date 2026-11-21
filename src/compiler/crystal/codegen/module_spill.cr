require "./codegen"

module Crystal
  # Settings and counters for keeping only a bounded set of LLVM modules in
  # memory during IR generation.
  #
  # In multi-module mode every type gets an LLVM module in an LLVM context of
  # its own, and a large program has thousands of them. With a `ModuleSpill`
  # the code generator keeps resident only the modules it is generating code
  # into right now, plus the *resident_limit* most recently used idle ones.
  # The least recently used idle module is written to its bitcode file and
  # its context is disposed; it is parsed back from that file when code
  # generation needs it again.
  class ModuleSpill
    # How many idle modules stay in memory.
    getter resident_limit : Int32

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

    def initialize(@resident_limit : Int32, @target_triple : String, &@bitcode_path : String -> String)
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

    def record_spill(wrote_bitcode : Bool) : Nil
      @spill_count += 1
      @write_count += 1 if wrote_bitcode
    end

    def record_reload : Nil
      @reload_count += 1
    end

    def record_resident_count(count : Int32) : Nil
      @peak_resident_count = count if count > @peak_resident_count
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

    # A module that only holds declarations: one for each function that was
    # declared in a module other than its own. With it, the next module that
    # calls such a function declares it without reading the function's own
    # module, which may be on disk by then. It is never compiled.
    @fun_signatures : ModuleInfo?

    private def fun_signatures : ModuleInfo
      @fun_signatures ||= begin
        llvm_context = LLVM::Context.new
        signatures = ModuleInfo.new("(function signatures)", llvm_context.new_module("function_signatures"), LLVMTyper.new(@program, llvm_context))
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
      @idle_resident_module_count += 1 if module_info.pin_count == 0
    end

    private def new_module_info(type_name : String) : ModuleInfo
      llvm_context = LLVM::Context.new
      # LLVM::Context.register(llvm_context, type_name)

      llvm_typer = LLVMTyper.new(@program, llvm_context)
      llvm_mod = configure_module(llvm_context.new_module(type_name))

      module_info = ModuleInfo.new(type_name, llvm_mod, llvm_typer)
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
      module_info
    end

    private def module_became_resident(module_info : ModuleInfo) : Nil
      @resident_modules << module_info
      @idle_resident_module_count += 1
      @module_spill.try &.record_resident_count(@resident_modules.size + 1)
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

      if @idle_resident_module_count > spill.resident_limit
        spill_idle_modules(spill, keeping: module_info)
      end
    end

    private def spill_idle_modules(spill : ModuleSpill, keeping : ModuleInfo) : Nil
      list_of_idle_modules = @resident_modules.select { |module_info| module_info.idle? && !module_info.same?(keeping) }
      list_of_idle_modules.sort_by!(&.last_used_at)
      # *keeping* is idle too and stays, so it takes one of the places.
      spill_count = list_of_idle_modules.size + 1 - spill.idle_count_after_spilling
      list_of_idle_modules.first(spill_count.clamp(0..)).each do |module_info|
        spill_module(module_info, spill)
      end
    end

    private def spill_module(module_info : ModuleInfo, spill : ModuleSpill) : Nil
      finish_module_debug_info(module_info) unless @debug.none?

      mod = module_info.mod
      wrote_bitcode = module_info.changed_since_spill?
      if wrote_bitcode
        mod.target = spill.target_triple
        mod.verify if ENV["CRYSTAL_VERIFY_SPILLED_MODULES"]?
        path = module_info.spill_path ||= spill.bitcode_path(module_info.name)
        unless mod.write_bitcode_to_file(path) == 0
          raise "BUG: failed to write the LLVM bitcode of #{module_info.name.inspect} to #{path}"
        end
      end

      context = mod.context
      module_info.detach
      context.dispose

      @resident_modules.delete(module_info)
      @idle_resident_module_count -= 1
      spill.record_spill(wrote_bitcode)
    end

    private def reload_module(module_info : ModuleInfo, spill : ModuleSpill) : Nil
      path = module_info.spill_path || raise "BUG: LLVM module #{module_info.name.inspect} is neither in memory nor on disk"

      llvm_context = LLVM::Context.new
      bitcode = LLVM::MemoryBuffer.from_file(path)
      begin
        llvm_mod = LLVM::Module.parse(bitcode, llvm_context)
      ensure
        bitcode.dispose
      end

      module_info.attach(llvm_mod, LLVMTyper.new(@program, llvm_context, adopts_existing_structs: true))
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
      spill.record_reload
    end
  end
end
