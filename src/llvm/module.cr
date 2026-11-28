class LLVM::Module
  # We let a module store a reference to the context so that if
  # someone is still holding a reference to the module but not to
  # the context, the context won't be disposed (if the context is disposed,
  # the module will no longer be valid and segfaults will happen)

  getter context : Context

  def self.parse(memory_buffer : MemoryBuffer, context : Context) : self
    LibLLVM.parse_bitcode_in_context2(context, memory_buffer, out module_ref)
    raise "BUG: failed to parse LLVM bitcode from memory buffer" unless module_ref
    new(module_ref, context)
  end

  def initialize(@unwrap : LibLLVM::ModuleRef, @context : Context)
    @owned = false
  end

  def name : String
    bytes = LibLLVM.get_module_identifier(self, out bytesize)
    String.new(Slice.new(bytes, bytesize))
  end

  def name=(name : String)
    LibLLVM.set_module_identifier(self, name, name.bytesize)
  end

  def target=(target)
    LibLLVM.set_target(self, target)
  end

  def data_layout=(data : TargetData)
    LibLLVM.set_module_data_layout(self, data)
  end

  # The data layout of this module. It belongs to the module: it is valid
  # as long as the module is, and the struct layouts it caches are those of
  # this module's context only.
  def data_layout : TargetData
    TargetData.new(LibLLVM.get_module_data_layout(self))
  end

  def append_inline_asm(asm_string : String)
    LibLLVM.append_module_inline_asm(self, asm_string, asm_string.bytesize)
  end

  def dump
    LibLLVM.dump_module(self)
  end

  def functions
    FunctionCollection.new(self)
  end

  def globals
    GlobalCollection.new(self)
  end

  def add_flag(module_flag : LibLLVM::ModuleFlagBehavior, key : String, val : Int32)
    add_flag(module_flag, key, @context.int32.const_int(val))
  end

  def add_flag(module_flag : LibLLVM::ModuleFlagBehavior, key : String, val : Value)
    LibLLVM.add_module_flag(
      self,
      module_flag,
      key,
      key.bytesize,
      LibLLVM.value_as_metadata(val.to_unsafe)
    )
  end

  def write_bitcode_to_file(filename : String)
    LibLLVM.write_bitcode_to_file self, filename
  end

  @[Deprecated("ThinLTO is no longer supported; use `#write_bitcode_to_file` instead")]
  def write_bitcode_with_summary_to_file(filename : String)
    LibLLVM.write_bitcode_to_file self, filename
  end

  def write_bitcode_to_memory_buffer
    MemoryBuffer.new(LibLLVM.write_bitcode_to_memory_buffer self)
  end

  # Whether `#split_to_bitcode` can split this module: it needs LLVM 17 or
  # later, and a module without module-level assembly.
  # Moves the function declarations to the end of the module, ordered by
  # name, so the bitcode does not depend on the order they were made in.
  def sort_function_declarations_by_name : Nil
    LibLLVMExt.sort_function_declarations_by_name(self)
  end

  # Orders the functions and the global variables by name, definitions
  # first and then declarations, so the bitcode does not depend on the
  # order they were made in.
  def sort_by_name : Nil
    LibLLVMExt.sort_by_name(self)
  end

  def can_be_split? : Bool
    LibLLVMExt.module_can_be_split(self) != 0
  end

  # Splits this module into *parts* modules and yields each part's index and
  # bitcode, in order, as soon as the part is written. The receiver owns the
  # buffer: it parses it into a context of its own (so the part can be
  # compiled on another thread) and disposes of it.
  #
  # This module is changed in place: local definitions become external
  # symbols with hidden visibility, so references across parts resolve at link
  # time. Private definitions and internal variables are renamed with a
  # `__crystal_private.` prefix (kept out of the linked output's symbol
  # table), internal functions whose names are plain C identifiers with a
  # `__crystal_local.` prefix, and the other functions (Crystal method names)
  # keep their names.
  #
  # Returns `false`, yielding nothing and leaving the module unchanged, when
  # `#can_be_split?` is false. An exception raised by the
  # block is re-raised once the split is over (the block runs inside LLVM,
  # which an exception must not unwind through); later parts are disposed of.
  def split_to_bitcode(parts : Int32, &block : Int32, MemoryBuffer ->) : Bool
    handoff = SplitHandoff.new(block)
    produced = LibLLVMExt.split_module_to_bitcode(self, parts, ->(data, index, buffer) {
      Box(SplitHandoff).unbox(data).receive(index.to_i32, MemoryBuffer.new(buffer))
    }, Box.box(handoff))
    if failure = handoff.failure
      raise failure
    end
    produced > 0
  end

  # Moves the functions of the namespaces named by *list_of_prefixes* out of
  # this unoptimized module into an island module and returns the island's
  # bitcode, so the two modules can be optimized and compiled on two threads.
  # The receiver owns the buffer: it parses it into a context of its own and
  # disposes of it.
  #
  # The island holds every defined function whose name, after an optional
  # leading `*` or `~`, starts with one of the prefixes (such as
  # `"Regex::Mica::"`), and every function that only island functions call.
  # Each module also gets `available_externally` copies of the small
  # functions (at most *import_instruction_limit* instructions, followed
  # *import_depth* levels deep) it calls in the other, and the island copies
  # of the constants it reads, so inlining across the boundary is kept. Global
  # variables stay in this module.
  #
  # This module is changed in place: the island's functions become
  # declarations (or `available_externally` copies) here, and every
  # definition one module refers to in the other is promoted the way
  # `#split_to_bitcode` promotes local definitions.
  #
  # Returns `nil`, leaving the module unchanged, when no function belongs to
  # the island or `#can_be_split?` is false.
  def split_off_island_to_bitcode(list_of_prefixes : Enumerable(String), import_instruction_limit : Int32,
                                  import_depth : Int32) : MemoryBuffer?
    list_of_prefix_pointers = list_of_prefixes.map(&.to_unsafe)
    buffer = LibLLVMExt.split_off_island_to_bitcode(self, list_of_prefix_pointers, list_of_prefix_pointers.size,
      import_instruction_limit, import_depth)
    MemoryBuffer.new(buffer) unless buffer.null?
  end

  # The names of the functions and global variables this module declares and
  # uses (intrinsics left out): what another object of the link must define.
  def list_of_referenced_declaration_names : Array(String)
    list_of_names = [] of String
    LibLLVMExt.for_each_referenced_declaration(self, ->(data, name, length) {
      Box(Array(String)).unbox(data) << String.new(name, length)
      nil
    }, Box.box(list_of_names))
    list_of_names
  end

  # Makes local again (internal, default visibility) each definition that
  # `#split_off_island_to_bitcode` promoted in this module and that is not
  # named in *list_of_referenced_names*, the declarations the other module
  # of the split still uses once optimized. A pass such as `globaldce` can
  # then remove the ones this module no longer uses either.
  #
  # Returns how many definitions were made local.
  def internalize_unreferenced_promotions(list_of_referenced_names : Array(String)) : Int32
    list_of_name_pointers = list_of_referenced_names.map(&.to_unsafe)
    LibLLVMExt.internalize_unreferenced_promotions(self, list_of_name_pointers, list_of_name_pointers.size).to_i32
  end

  # Receives the parts of `#split_to_bitcode` without letting an exception
  # escape into LLVM.
  private class SplitHandoff
    getter failure : Exception?

    def initialize(@receiver : Proc(Int32, MemoryBuffer, Nil))
    end

    def receive(index : Int32, bitcode : MemoryBuffer) : Nil
      if @failure
        bitcode.dispose
        return
      end
      @receiver.call(index, bitcode)
    rescue ex
      bitcode.dispose
      @failure = ex
    end
  end

  # Moves everything *other* defines or declares into this module, as a
  # linker does: a declaration here is replaced by the definition there.
  # Both modules must be in the same context. *other* is destroyed.
  def link(other : Module) : Nil
    raise "BUG: failed to link LLVM module #{other.name} into #{name}" unless LibLLVM.link_modules2(self, other) == 0
  end

  def write_bitcode_to_fd(fd : Int, should_close = false, buffered = false)
    LibLLVM.write_bitcode_to_fd(self, fd, should_close ? 1 : 0, buffered ? 1 : 0)
  end

  def verify
    error = LibLLVM.verify_module(self, LLVM::VerifierFailureAction::ReturnStatusAction, out message)
    begin
      if error == 1
        raise "Module validation failed: #{String.new(message)}"
      end
    ensure
      LibLLVM.dispose_message(message)
    end
  end

  def print_to_file(filename)
    if LibLLVM.print_module_to_file(self, filename, out error_msg) != 0
      raise LLVM.string_and_dispose(error_msg)
    end
    self
  end

  {% unless LibLLVM::IS_LT_170 %}
    @[Deprecated("The legacy pass manager was removed in LLVM 17. Use `LLVM::PassBuilderOptions` instead")]
  {% end %}
  def new_function_pass_manager
    FunctionPassManager.new LibLLVM.create_function_pass_manager_for_module(self)
  end

  def ==(other : self)
    @unwrap == other.@unwrap
  end

  def to_s(io : IO) : Nil
    LLVM.to_io(LibLLVM.print_module_to_string(self), io)
    self
  end

  def to_unsafe
    @unwrap
  end

  def take_ownership(&)
    if @owned
      yield
    else
      @owned = true
    end
  end
end
