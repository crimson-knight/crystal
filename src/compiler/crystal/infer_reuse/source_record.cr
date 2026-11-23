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

    def block(reason : String) : Nil
      @blocked_reason ||= reason
    end
  end
end
