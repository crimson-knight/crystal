module Crystal::InferReuse
  # What the programs a build's macros ran (`run`) can have read, from their
  # file names and arguments: the folder tree of each program (its own
  # source), the files and folders its arguments name, and the files next to
  # an argument file (a template's layout).
  #
  # The build server (`Retyper`) and a plain incremental build (`Compiler`)
  # both ask it whether a file that changed since a build can change what one
  # of those programs prints. A program that reads other files, the clock or
  # the network is not covered.
  class ProgramRunInputs
    @program_folders = Set(String).new
    @argument_paths = Set(String).new
    @argument_folders = Set(String).new
    @sibling_folders = Set(String).new

    # Each run is the program's file name and its arguments; relative names
    # are relative to *working_directory*, the folder the build ran in.
    def initialize(list_of_runs : Enumerable({String, Array(String)}), working_directory : String)
      list_of_runs.each do |(filename, list_of_arguments)|
        @program_folders << File.dirname(File.expand_path(filename, working_directory))
        list_of_arguments.each do |argument|
          path = File.expand_path(argument, working_directory)
          if File.directory?(path)
            @argument_folders << path
          elsif @argument_paths.add?(path)
            @sibling_folders << File.dirname(path)
          end
        end
      end
    end

    # Why the change of one of *list_of_changed_paths* can change what a
    # program prints, or `nil` when none can. The block says whether a path is
    # a Crystal source the build compares on its own: such a file next to an
    # argument file does not count.
    def reason_to_run_again(list_of_changed_paths : Array(String), & : String -> Bool) : String?
      list_of_changed_paths.each do |path|
        return "#{path} changed, and a macro program takes it as an argument" if @argument_paths.includes?(path)
        folder = File.dirname(path)
        if @sibling_folders.includes?(folder) && !yield(path)
          return "#{path} changed, next to a file a macro program takes as an argument"
        end
        while folder.size > 1
          return "#{path} changed, in the folder of a macro program (#{folder})" if @program_folders.includes?(folder)
          return "#{path} changed, in a folder a macro program takes as an argument (#{folder})" if @argument_folders.includes?(folder)
          parent = File.dirname(folder)
          break if parent == folder
          folder = parent
        end
      end
      nil
    end
  end
end
