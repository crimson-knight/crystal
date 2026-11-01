require "./basic_block"

struct LLVM::BasicBlockCollection
  include Enumerable(LLVM::BasicBlock)

  def initialize(@function : Function)
  end

  def append(name = "")
    context = LibLLVM.get_module_context(LibLLVM.get_global_parent(@function))
    BasicBlock.new LibLLVM.append_basic_block_in_context(context, @function, name)
  end

  def append(name = "", &)
    context = LibLLVM.get_module_context(LibLLVM.get_global_parent(@function))
    block = append name
    # builder = Builder.new(LibLLVM.create_builder_in_context(context), LLVM::Context.new(context, dispose_on_finalize: false))
    builder = Builder.new(LibLLVM.create_builder_in_context(context))
    builder.position_at_end block
    yield builder
    block
  ensure
    # The builder is not registered with its context, so dispose of it here:
    # it must not outlive a context that is disposed explicitly.
    builder.try &.dispose
  end

  def each(&) : Nil
    bb = LibLLVM.get_first_basic_block(@function)
    while bb
      yield LLVM::BasicBlock.new bb
      bb = LibLLVM.get_next_basic_block(bb)
    end
  end

  def []?(name : String)
    find(&.name.==(name))
  end

  def [](name : String)
    self[name]? || raise IndexError.new
  end

  def last?
    block = nil
    each do |current_block|
      block = current_block
    end
    block
  end
end
