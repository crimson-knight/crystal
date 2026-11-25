module Crystal::InferReuse
  # What a build read from outside the compiler: the text of every source
  # file it parsed, where each `require` led, and what its macros read from
  # the environment and the file system. A later build can reuse the typed
  # program only when all of it reads the same, apart from the method bodies
  # `BodyEdit` accepts.
  class SourceRecord
    # A `require` and the files it found.
    record RequireResult, filename : String, relative_to : String?, list_of_found_files : Array(String)

    # The source lines of a method whose body a macro read (`stringify`, `id`,
    # `body` and the like): an edit inside them could change macro output.
    record DefBodyRead, filename : String, name : String, first_line : Int32, last_line : Int32

    getter text_by_filename = {} of String => String
    getter list_of_requires = [] of RequireResult
    getter env_value_by_name = {} of String => String?
    getter content_by_read_file = {} of String => String?
    getter existence_by_checked_file = {} of String => Bool
    getter output_by_command = {} of String => String?
    getter list_of_def_body_reads = [] of DefBodyRead

    # A program a macro ran (`run`), with its arguments and output (`nil`
    # when it failed); a later build runs it again and compares.
    record ProgramRun, filename : String, list_of_arguments : Array(String), output : String?
    getter list_of_program_runs = [] of ProgramRun

    # When the build that typed the program read its sources, or a later
    # build that reused it compared them: a file modified after this moment
    # may hold something the program has not seen (see `Retyper`). Kept as
    # Unix milliseconds, a plain number a type-inference snapshot
    # (`InferPersist`) holds as it is; the truncation only moves the moment
    # earlier, so no change is missed.
    @sources_checked_at_unix_ms : Int64 = Time.utc.to_unix_ms

    def sources_checked_at : Time
      Time.unix_ms(@sources_checked_at_unix_ms)
    end

    def sources_checked_at=(time : Time) : Time
      @sources_checked_at_unix_ms = time.to_unix_ms
      time
    end

    # Why no later build may reuse this program (a macro read something this
    # record cannot compare), or `nil`.
    getter blocked_reason : String?

    def add_source(filename : String, text : String) : Nil
      @text_by_filename[filename] = text
    end

    def add_require(filename : String, relative_to : String?, list_of_found_files : Array(String)?) : Nil
      @list_of_requires << RequireResult.new(filename, relative_to, list_of_found_files || [] of String)
    end

    def add_env_read(name : String, value : String?) : Nil
      @env_value_by_name[name] = value unless @env_value_by_name.has_key?(name)
    end

    def add_file_read(filename : String, content : String?) : Nil
      @content_by_read_file[filename] = content unless @content_by_read_file.has_key?(filename)
    end

    def add_file_check(filename : String, exists : Bool) : Nil
      @existence_by_checked_file[filename] = exists unless @existence_by_checked_file.has_key?(filename)
    end

    # The output of a command a macro ran (`nil` when it failed); a later
    # build runs it again and compares.
    def add_command_output(command : String, output : String?) : Nil
      @output_by_command[command] = output unless @output_by_command.has_key?(command)
    end

    def add_def_body_read(filename : String, name : String, first_line : Int32, last_line : Int32) : Nil
      read = DefBodyRead.new(filename, name, first_line, last_line)
      @list_of_def_body_reads << read unless @list_of_def_body_reads.includes?(read)
    end

    def add_program_run(filename : String, list_of_arguments : Array(String), output : String?) : Nil
      run = ProgramRun.new(filename, list_of_arguments, output)
      @list_of_program_runs << run unless @list_of_program_runs.includes?(run)
    end

    # Source lines whose line number macro output holds (`line_number`, a
    # `__LINE__` default argument of a macro): a later build may not move them.
    getter line_reads_by_filename = {} of String => Set(Int32)

    # Names a `responds_to?` asked about: a method of that name added or
    # removed can change what it answers.
    getter responds_to_names = Set(String).new

    # Types a macro asked `overrides?` about, by object id.
    getter overrides_read_type_by_id = {} of UInt64 => Type

    # Every macro expansion that read a list of methods (`methods`,
    # `all_methods`, `has_method?`), to run again when a method is added or
    # removed (see `MethodListReplay`).
    getter list_of_method_list_expansions = [] of MethodListExpansion
    getter method_list_frames = MethodListFrames.new
    # Set while a build server runs an expansion again.
    property method_list_replay : MethodListReplay? = nil
    # Whether every type and method of the program was declared (the
    # `finished` hooks and type inference run after that).
    property? declarations_complete = false

    def add_line_read(location : Location?) : Nil
      return unless location
      filename = location.filename
      return unless filename.is_a?(String)
      (@line_reads_by_filename[filename] ||= Set(Int32).new) << location.line_number
    end

    # Names of methods typed once per call (with a block), outside the
    # instance caches a build server searches.
    getter uncached_call_names = Set(String).new

    def add_uncached_call(name : String) : Nil
      @uncached_call_names << name
    end

    def add_responds_to(name : String) : Nil
      @responds_to_names << name
    end

    def add_overrides_read(type : Type) : Nil
      @overrides_read_type_by_id[type.object_id] ||= type
    end

    def add_method_list_read(read : MethodListRead) : Nil
      expansion = @method_list_frames.current
      unless expansion
        block("a macro read the methods of #{read.type} outside a macro expansion")
        return
      end
      @list_of_method_list_expansions << expansion if expansion.list_of_reads.empty?
      expansion.list_of_reads << read
    end

    # Moves the recorded lines of *filename* to their place in its new text.
    def shift_lines(filename : String, shift : Location::LineShift) : Nil
      return if shift.identity?
      @list_of_def_body_reads.map! do |read|
        next read unless read.filename == filename
        DefBodyRead.new(read.filename, read.name, shift.apply(read.first_line), shift.apply(read.last_line))
      end
      if lines = @line_reads_by_filename[filename]?
        @line_reads_by_filename[filename] = lines.map { |line| shift.apply(line) }.to_set
      end
    end

    def block(reason : String) : Nil
      @blocked_reason ||= reason
    end
  end
end
