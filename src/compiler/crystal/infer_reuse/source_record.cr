module Crystal::InferReuse
  # What a build read from outside the compiler: the text of every source
  # file it parsed, where each `require` led, and what its macros read from
  # the environment and the file system. A later build can reuse the typed
  # program only when all of it reads the same, apart from the method bodies
  # `BodyEdit` accepts.
  class SourceRecord
    # A `require` and the files it found.
    record RequireResult, filename : String, relative_to : String?, list_of_found_files : Array(String)

    getter text_by_filename = {} of String => String
    getter list_of_requires = [] of RequireResult
    getter env_value_by_name = {} of String => String?
    getter content_by_read_file = {} of String => String?
    getter existence_by_checked_file = {} of String => Bool
    getter output_by_command = {} of String => String?

    # Why no later build may reuse this program (a macro ran a program, or
    # read something this record cannot compare), or `nil`.
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

    def block(reason : String) : Nil
      @blocked_reason ||= reason
    end
  end
end
