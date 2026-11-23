# A VirtualFile is used as a Location's filename when
# expanding a macro. It contains the macro expanded source
# code so the user can debug it as if there was a file in the
# filesystem with those contents.
class Crystal::VirtualFile
  # The macro that produced this VirtualFile
  getter macro : Macro

  # The expanded source code of the macro, while it is kept in the heap.
  # A longer text is kept in the `MacroSourceStore` instead.
  @source : String?

  # Where the expanded source code is in the `MacroSourceStore`.
  @stored_source : MacroSourceStore::Entry?

  # The location where the macro was expanded (where the macro was invoked).
  getter expanded_location : Location?

  # The virtual files of the program that is being compiled.
  #
  # Locations refer to a virtual file through a table that holds it weakly,
  # and the program keeps its virtual files alive. An error can outlive its
  # program, and printing it reads the virtual files its locations point at,
  # so every `CodeError` keeps a reference to this list.
  class_property current_program_files : Array(VirtualFile)?

  # The index of this file in the table that locations refer to.
  getter file_index : UInt32 = 0_u32

  # The store that holds the expanded source code, if one does.
  @source_store : MacroSourceStore?

  def initialize(@macro : Macro, source : String, @expanded_location : Location?, source_store : MacroSourceStore? = nil)
    @file_index = Location.register(self)
    if source_store && (stored_source = source_store.store(source))
      @source_store = source_store
      @stored_source = stored_source
    else
      @source = source
    end
  end

  # The expanded source code of the macro (empty once released).
  def source : String
    source_store = @source_store
    stored_source = @stored_source
    return source_store.read(stored_source) if source_store && stored_source

    @source || ""
  end

  # The expanded source code if it is kept in the heap, for the memory census.
  def source_in_heap : String?
    @source
  end

  # Drops the expanded source code. Only error messages read it, to show
  # the expansion an error is in; after this they show the macro's name and
  # the place it was expanded.
  def release_source : Nil
    @source = nil
    @stored_source = nil
    @source_store = nil
  end

  def to_s(io : IO) : Nil
    io << "expanded macro: " << @macro.name
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp)
    pp.text inspect
  end
end
