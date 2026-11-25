module Crystal
  # What `crystal tool strict` reads from a program after type inference: the
  # defs declared in the files it converts, with the owner each was added to
  # and the def it replaced, and every typed copy of those defs with the
  # types it was typed for.
  #
  # The recorder exists only while the tool runs (`Program#strict_tool_recorder`);
  # an ordinary build records nothing.
  class StrictToolRecorder
    # A def written in one of the converted files, as `TopLevelVisitor` added
    # it to *owner*; *replaced* is the earlier def with the same name and
    # argument types that it replaced, if any.
    record Declaration, a_def : Def, owner : ModuleType, replaced : Def?

    # One typed copy of a def: the receiver and the types of the arguments
    # passed by position (in parameter order) and by name, the type of a
    # captured block, and the typed copy itself (its type is the return type).
    record Instance,
      receiver : Type,
      arg_types : Array(Type),
      named_arg_types : Array(NamedArgumentType)?,
      block_arg_type : Type?,
      typed_def : Def

    getter declarations = [] of Declaration

    @instances = Hash(Def, Array(Instance)).new.compare_by_identity

    # *filenames* are the expanded paths of the files being converted.
    def initialize(@filenames : Set(String))
    end

    def records?(a_def : Def) : Bool
      filename = a_def.location.try(&.filename)
      filename.is_a?(String) && @filenames.includes?(filename)
    end

    # Every def a declaration added, in any file (by object id): the defs the
    # strict checks compare against, as opposed to the `new` and `initialize`
    # the compiler adds later.
    getter declared_def_ids = Set(UInt64).new

    def record_declaration(a_def : Def, owner : ModuleType, replaced : Def?) : Nil
      declared_def_ids << a_def.object_id
      return unless records?(a_def)
      declarations << Declaration.new(a_def, owner, replaced)
    end

    def record_instance(untyped_def : Def, receiver : Type, arg_types : Array(Type),
                        named_arg_types : Array(NamedArgumentType)?, block_arg_type : Type?,
                        typed_def : Def) : Nil
      return unless records?(untyped_def)
      list = @instances[untyped_def] ||= [] of Instance
      list << Instance.new(receiver, arg_types, named_arg_types, block_arg_type, typed_def)
    end

    def instances_of(a_def : Def) : Array(Instance)
      @instances[a_def]? || [] of Instance
    end

    # The first macro each def called without a receiver, by untyped def.
    @macro_calls = Hash(Def, Call).new.compare_by_identity

    def record_macro_call(untyped_def : Def, call : Call) : Nil
      return unless records?(untyped_def)
      @macro_calls[untyped_def] ||= call
    end

    def macro_call_of(a_def : Def) : Call?
      @macro_calls[a_def]?
    end
  end

  class Program
    # Set by `crystal tool strict` before type inference; `nil` otherwise.
    property strict_tool_recorder : StrictToolRecorder?

    # Source text to use in place of the file on disk, by expanded filename:
    # `crystal tool strict` type-checks its edits without writing them.
    property source_overrides : Hash(String, String)?

    # The source of the required file *filename*: its override, or the file.
    def read_source(filename : String) : String
      source_overrides.try(&.[filename]?) || File.read(filename)
    end
  end
end
