module Crystal::InferReuse
  # The files under a folder that changed since a moment: those whose
  # modification time is later. Used to tell whether the programs the
  # kept build's macros ran (`run`) can have read anything new.
  class ChangedFiles
    # A folder holding more entries than this is not walked: everything
    # counts as changed.
    MAXIMUM_ENTRY_COUNT = 200_000

    # Folders never walked: version control data.
    SKIPPED_FOLDER_NAMES = {".git", ".hg", ".svn"}

    getter list_of_paths = [] of String

    # Whether the walk stopped at `MAXIMUM_ENTRY_COUNT`.
    getter? overflowed = false

    @entry_count = 0

    def initialize(@since : Time, @list_of_excluded_paths : Array(String))
    end

    # Walks *folder*. Symbolic links are not followed.
    def self.under(folder : String, since : Time, list_of_excluded_paths : Array(String)) : ChangedFiles
      changed_files = new(since, list_of_excluded_paths)
      changed_files.walk(folder)
      changed_files
    end

    protected def walk(folder : String) : Nil
      Dir.each_child(folder) do |name|
        return if @overflowed
        @entry_count += 1
        if @entry_count > MAXIMUM_ENTRY_COUNT
          @overflowed = true
          return
        end
        path = File.join(folder, name)
        file_info = File.info?(path, follow_symlinks: false) || next
        if file_info.directory?
          walk(path) unless SKIPPED_FOLDER_NAMES.includes?(name)
        elsif file_info.file? && file_info.modification_time > @since && !@list_of_excluded_paths.includes?(path)
          @list_of_paths << path
        end
      end
    rescue File::Error
      # A folder that went away or cannot be read holds nothing that changed.
    end
  end
end
