require "./codegen"
require "./cached_object_record"

module Crystal
  # Settings and counters for keeping only a bounded amount of LLVM IR in
  # memory during IR generation.
  #
  # In multi-module mode every type gets an LLVM module in an LLVM context of
  # its own, and a large program has thousands of them. With a `ModuleSpill`
  # the code generator keeps in memory only the modules it is generating
  # code into right now, plus the most recently used idle ones, as many as
  # fit under *resident_ir_bytes* of estimated IR and under *resident_limit*
  # modules. The least recently used idle module is written to a bitcode
  # file and its context is disposed.
  #
  # A module on disk is never read back during IR generation. When a type
  # whose module is on disk gets another function, the type gets a new,
  # empty module: the next *part* of its module. Functions of the parts on
  # disk are external declarations there, like the functions of any other
  # module. The parts of a type are linked into one module again when its
  # object file is built, so every byte of IR is written once and the
  # optimizer sees the module it would have seen without spilling.
  class ModuleSpill
    # An estimate of the memory LLVM holds for a module, from what is cheap
    # to count: a fixed amount for the context with its types and
    # declarations, and an amount for each instruction the code generator
    # built (instructions carry their operands and debug locations).
    #
    # Measured on a program of 300 Grant models (7,962 modules, 35.6 million
    # instructions, about 10 GB of IR): about 280 bytes per instruction, and
    # about 230 KB per module in memory on top of that.
    BYTES_PER_MODULE            = 262_144_i64
    BYTES_PER_BUILT_INSTRUCTION =     300_i64

    # How many idle modules stay in memory (0: as many as fit in the bytes).
    getter resident_limit : Int32

    # How many bytes of estimated IR stay in memory (0: no limit in bytes).
    getter resident_ir_bytes : Int64

    # The target triple written into every spilled module.
    getter target_triple : String

    # How many bytes of estimated IR are spilled between two requests to the
    # C allocator to return its free pages to the OS (0: never asked).
    # `CRYSTAL_MALLOC_RELIEF_MB` sets it for measuring.
    property malloc_relief_bytes : Int64 = (ENV["CRYSTAL_MALLOC_RELIEF_MB"]?.try(&.to_i64?) || 0_i64) * 1024 * 1024

    # The largest number of modules that were in memory at once, and the
    # largest estimate of their IR.
    getter peak_resident_count = 0
    getter peak_resident_ir_bytes = 0_i64

    # How many instructions the code generator built into spillable modules.
    getter built_instruction_count = 0_i64

    # How many module parts were written to disk, their size and the time
    # it took: turning the modules into bitcode, hashing the bitcode, and
    # putting it in files.
    getter spill_count = 0
    getter written_bitcode_bytes = 0_i64
    getter write_time = Time::Span.zero
    getter bitcode_time = Time::Span.zero
    getter hash_time = Time::Span.zero

    # How many types have a module of more than one part.
    getter multi_part_module_count = 0

    # How many functions of spilled parts have a recorded signature.
    getter recorded_signature_count = 0

    def record_signature : Nil
      @recorded_signature_count += 1
    end

    def initialize(@resident_limit : Int32, @resident_ir_bytes : Int64, @target_triple : String, &@bitcode_path : String, Int32 -> String)
    end

    def limits_module_count? : Bool
      @resident_limit > 0
    end

    def limits_ir_bytes? : Bool
      @resident_ir_bytes > 0
    end

    # The bitcode file of part *part_index* of the module of the type named
    # *module_name*.
    def bitcode_path(module_name : String, part_index : Int32) : String
      @bitcode_path.call(module_name, part_index)
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

    def record_spill(bitcode_bytes : Int64, bitcode_time : Time::Span, hash_time : Time::Span,
                     write_time : Time::Span, part_index : Int32) : Nil
      @spill_count += 1
      @written_bitcode_bytes += bitcode_bytes
      @bitcode_time += bitcode_time
      @hash_time += hash_time
      @write_time += write_time
      @multi_part_module_count += 1 if part_index == 1
    end

    def record_built_instructions(built_instruction_count : Int64) : Nil
      @built_instruction_count += built_instruction_count
    end

    def record_resident(count : Int32, ir_bytes : Int64) : Nil
      @peak_resident_count = count if count > @peak_resident_count
      @peak_resident_ir_bytes = ir_bytes if ir_bytes > @peak_resident_ir_bytes
    end
  end

  class CodeGenVisitor
    # The LLVM module of a type, with every handle the code generator keeps
    # into the module's LLVM context.
    #
    # With a `ModuleSpill` the module can consist of several parts: the ones
    # in the files of `#list_of_spill_paths`, and the one in memory, if any.
    class ModuleInfo
      # The name of the type this module belongs to (empty for the main module).
      getter name : String

      @mod : LLVM::Module?
      @typer : LLVMTyper?
      @builder : CrystalLLVMBuilder?

      # The types of the functions looked up or added through
      # `CodeGenVisitor#typed_fun?` and `CodeGenVisitor#add_typed_fun`.
      getter fun_types = {} of String => LLVM::Type

      # The names of the functions that were generated into the part in memory.
      getter list_of_generated_fun_names = [] of String

      # The string constants of this module.
      getter strings = {} of String => LLVM::Value

      # Debug metadata is cached per module, so that metadata of one module
      # is never used in another one.
      getter debug_files = {} of DebugFilename => LibLLVM::MetadataRef
      getter debug_types = {} of Type => LibLLVM::MetadataRef?
      getter fun_metadatas = {} of LLVM::Function => Array(FunMetadata)
      property di_builder : DIBuilder?

      # How many code generation frames are using this module. A module in
      # use is never spilled.
      property pin_count = 0

      # The value of the code generator's use clock when this module was
      # last asked for.
      property last_used_at = 0_i64

      # The bitcode files of the parts of this module that were spilled, in
      # the order they were written.
      getter list_of_spill_paths = [] of String

      # The hash of the bitcode in each of those files (`BitcodeHash.of_part`).
      # Empty when there is no hash function.
      getter list_of_spill_part_hashes = [] of String

      # The estimate of this module's IR that is part of the code
      # generator's total (see `CodeGenVisitor#account_module_ir`).
      property accounted_ir_bytes = 0_i64

      # How many instructions were built into the parts on disk.
      getter spilled_instruction_count = 0_i64

      # The modules that hold the functions this type got after this module
      # reached the size limit of one object file (see
      # `CodeGenVisitor#module_segment_instructions`), oldest first. Only
      # the type's first module has any.
      getter list_of_later_segments = [] of ModuleInfo

      def initialize(@name : String, @mod : LLVM::Module, @typer : LLVMTyper)
      end

      def mod : LLVM::Module
        @mod || raise "BUG: LLVM module #{@name.inspect} is used while it is on disk"
      end

      def typer : LLVMTyper
        @typer || raise "BUG: LLVM typer of module #{@name.inspect} is used while the module is on disk"
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

      # How many instructions were built into the part in memory.
      def built_instruction_count : Int64
        @builder.try(&.instruction_count) || 0_i64
      end

      # How many instructions were built into this module, in memory and on
      # disk.
      def generated_instruction_count : Int64
        @spilled_instruction_count + built_instruction_count
      end

      # The module the type's next function is generated into: the newest
      # segment, or this module while the type has one module.
      def latest_segment : ModuleInfo
        @list_of_later_segments.last? || self
      end

      # An estimate of the memory LLVM holds for the part in memory.
      def estimated_ir_bytes : Int64
        ModuleSpill::BYTES_PER_MODULE + built_instruction_count * ModuleSpill::BYTES_PER_BUILT_INSTRUCTION
      end

      # Hands this module, whose earlier parts are all on disk, a new part.
      def attach(@mod : LLVM::Module, @typer : LLVMTyper) : Nil
      end

      # Drops every handle into the context of the part in memory. The
      # caller disposes the context.
      def detach : Nil
        @spilled_instruction_count += built_instruction_count
        @mod = nil
        @typer = nil
        @builder = nil
        @di_builder = nil
        @fun_types.clear
        @list_of_generated_fun_names.clear
        @strings.clear
        @debug_files.clear
        @debug_types.clear
        @fun_metadatas.clear
      end
    end

    # When set, idle modules are spilled to disk (see `ModuleSpill`).
    property module_spill : ModuleSpill?

    # The size limit of one type's module, in built instructions (0: no
    # limit). A type that reaches it gets a further module, a *segment*, for
    # the functions generated from then on, and each segment is compiled to
    # an object file of its own. A segment is a module like any other: its
    # functions are external definitions, and the other segments declare
    # the ones they call. The limit is checked when a function is about to
    # be generated, so a type's segments hold the same functions in every
    # build that generates the type's functions in the same order.
    property module_segment_instructions = 0_i64

    # The name of segment *segment_index* (1 for the second module) of the
    # type named *type_name*. No type name contains a `#`.
    def self.segment_module_name(type_name : String, segment_index : Int32) : String
      "#{type_name}##{segment_index + 1}"
    end

    # The function named *mangled_name* in one of the segments of
    # *first_module_info* that are in memory, newest segment first.
    private def typed_fun_in_segments?(first_module_info : ModuleInfo, mangled_name : String) : LLVMTypedFunction?
      first_module_info.list_of_later_segments.reverse_each do |segment|
        next unless segment.resident?
        if func = typed_fun?(segment, mangled_name)
          return func
        end
      end
      first_module_info.resident? ? typed_fun?(first_module_info, mangled_name) : nil
    end

    # The module the next function of the type of *first_module_info* is
    # generated into: the type's newest segment, or a new one when that
    # reached the size limit.
    private def segment_for_next_fun(first_module_info : ModuleInfo) : ModuleInfo
      latest_segment = first_module_info.latest_segment
      return latest_segment if @module_segment_instructions <= 0 || first_module_info.same?(@main_module_info)
      return latest_segment if latest_segment.generated_instruction_count < @module_segment_instructions

      list_of_later_segments = first_module_info.list_of_later_segments
      segment_name = CodeGenVisitor.segment_module_name(first_module_info.name, list_of_later_segments.size + 1)
      segment = new_module_info(segment_name)
      @modules[segment_name] = segment
      list_of_later_segments << segment
      segment
    end

    # The modules that are in memory, except the main one (it always is).
    @resident_modules = [] of ModuleInfo
    @idle_resident_module_count = 0
    @module_use_clock = 0_i64

    # The sum of `ModuleInfo#accounted_ir_bytes` of the modules in memory.
    @resident_ir_bytes = 0_i64

    # The estimated IR spilled since the C allocator was last asked to
    # return its free pages (see `return_freed_ir_memory_to_os`).
    @ir_bytes_freed_since_relief = 0_i64

    # A module that only holds declarations: one for each function of a
    # module part on disk. A module that calls such a function declares it
    # from here. It is never compiled, and only exists once a module was
    # spilled.
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
      return nil unless signatures = @fun_signatures

      typed_fun?(signatures, mangled_name)
    end

    # Records the signature of *func*, a function of a module part that is
    # about to be spilled.
    private def record_fun_signature(mangled_name : String, func : LLVMTypedFunction) : Nil
      signatures = fun_signatures
      return if typed_fun?(signatures, mangled_name)

      declare_fun(mangled_name, func, signatures)
      @module_spill.try &.record_signature
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
      llvm_mod, llvm_typer = new_module_and_typer(type_name)
      module_info = ModuleInfo.new(type_name, llvm_mod, llvm_typer)
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
      module_info
    end

    # An empty module for the type named *type_name*, in a context of its own.
    private def new_module_and_typer(type_name : String) : {LLVM::Module, LLVMTyper}
      llvm_context = LLVM::Context.new
      # LLVM::Context.register(llvm_context, type_name)

      llvm_mod = configure_module(llvm_context.new_module(type_name))
      {llvm_mod, LLVMTyper.new(@program, llvm_context, data_layout: llvm_mod.data_layout)}
    end

    private def module_became_resident(module_info : ModuleInfo) : Nil
      @resident_modules << module_info
      @idle_resident_module_count += 1
      account_module_ir(module_info)
    end

    # Makes sure *module_info* has a part in memory, marks it as the most
    # recently used module and spills the least recently used idle modules
    # if more IR is in memory than the limits allow.
    #
    # A handle into another module than *module_info* is only safe to keep
    # across this call if that module is pinned.
    def use_module(module_info : ModuleInfo) : Nil
      spill = @module_spill
      return unless spill
      return if module_info.same?(@main_module_info)

      start_next_part(module_info) unless module_info.resident?
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

    # Writes the part of *module_info* that is in memory to its bitcode
    # file and frees it. *finishes_debug_info* is false for a module whose
    # debug info is complete already.
    private def spill_module(module_info : ModuleInfo, spill : ModuleSpill, finishes_debug_info : Bool = true) : Nil
      # Whoever calls one of this part's functions from now on declares it
      # from its signature.
      module_info.list_of_generated_fun_names.each do |mangled_name|
        generated_fun = typed_fun?(module_info, mangled_name)
        raise "BUG: #{mangled_name} was generated into #{module_info.name.inspect} but is not there" unless generated_fun

        record_fun_signature(mangled_name, generated_fun)
      end

      finish_module_debug_info(module_info) if finishes_debug_info && !@debug.none?

      mod = module_info.mod
      mod.target = spill.target_triple
      part_index = module_info.list_of_spill_paths.size
      path = spill.bitcode_path(module_info.name, part_index)
      bitcode_started_at = Time.instant
      bitcode = mod.write_bitcode_to_memory_buffer
      begin
        bitcode_bytes = bitcode.to_slice
        hash_started_at = Time.instant
        part_hash = BitcodeHash.of_part(bitcode_bytes)
        write_started_at = Time.instant
        File.write(path, bitcode_bytes)
        module_info.list_of_spill_paths << path
        module_info.list_of_spill_part_hashes << part_hash if part_hash
        spill.record_spill(bitcode_bytes.size.to_i64, hash_started_at - bitcode_started_at,
          write_started_at - hash_started_at, Time.instant - write_started_at, part_index)
      ensure
        bitcode.dispose
      end
      spill.record_built_instructions(module_info.built_instruction_count)

      freed_ir_bytes = module_info.accounted_ir_bytes
      @resident_ir_bytes -= freed_ir_bytes
      module_info.accounted_ir_bytes = 0_i64

      context = mod.context
      module_info.detach
      context.dispose

      @resident_modules.delete(module_info)
      @idle_resident_module_count -= 1
      return_freed_ir_memory_to_os(freed_ir_bytes)
      trace_peak("spill") if spill.spill_count % 500 == 0
    end

    # The C allocator keeps the memory of a disposed context for later
    # allocations. Every `ModuleSpill#malloc_relief_bytes` of estimated IR
    # freed, it is asked to hand its free pages back to the OS.
    private def return_freed_ir_memory_to_os(freed_ir_bytes : Int64) : Nil
      {% if flag?(:darwin) %}
        relief_bytes = @module_spill.try(&.malloc_relief_bytes) || 0_i64
        return unless relief_bytes > 0

        @ir_bytes_freed_since_relief += freed_ir_bytes
        if @ir_bytes_freed_since_relief >= relief_bytes
          @ir_bytes_freed_since_relief = 0_i64
          LibDarwinMalloc.malloc_zone_pressure_relief(nil, 0)
        end
      {% end %}
    end

    # Gives *module_info*, whose parts are all on disk, a new part in memory.
    private def start_next_part(module_info : ModuleInfo) : Nil
      llvm_mod, llvm_typer = new_module_and_typer(module_info.name)
      module_info.attach(llvm_mod, llvm_typer)
      module_info.builder = new_builder(module_info)
      module_became_resident(module_info)
    end

    # Called when IR generation is over and every module in memory is
    # complete and verified. A module that has parts on disk gets its last
    # part written there too: its compilation unit is then a list of files.
    def spill_last_parts_of_spilled_modules : Nil
      return unless spill = @module_spill

      @resident_modules.dup.each do |module_info|
        if module_info.list_of_spill_paths.empty?
          spill.record_built_instructions(module_info.built_instruction_count)
        else
          spill_module(module_info, spill, finishes_debug_info: false)
        end
      end
    end
  end
end
