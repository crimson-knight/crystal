module Crystal
  # Holds the text of macro expansions in a file instead of the heap.
  #
  # Every macro expansion keeps its text in a `VirtualFile`, and only error
  # messages and tools read it again. A program of 300 Grant models expands
  # 60,070 macros into 123 MB of text, which stays in the heap through all
  # of type inference, the stage that sets the compiler's memory peak. The
  # store writes each text to an unnamed temporary file when the expansion
  # is made and reads it back when it is asked for.
  #
  # Each `Program` has a store of its own (see `Program#macro_source_store`),
  # and every `VirtualFile` keeps a reference to its store: the file is
  # closed, and its disk space freed, once neither the program nor any of
  # its virtual files (an error may outlive its program) are left, so a
  # long-running process that compiles again and again does not keep the
  # text of every compilation.
  #
  # `CRYSTAL_MACRO_SOURCE_IN_MEMORY=1` keeps the texts in the heap.
  class MacroSourceStore
    # Texts shorter than this stay in the heap: the record of a stored text
    # costs about as much.
    SMALLEST_STORED_BYTESIZE = 256

    record Entry, offset : Int64, bytesize : Int32

    class_getter?(enabled : Bool) { ENV["CRYSTAL_MACRO_SOURCE_IN_MEMORY"]? != "1" }

    # A new store, or `nil` when the texts stay in the heap or no temporary
    # file could be made.
    def self.open : MacroSourceStore?
      return nil unless enabled?

      file = File.tempfile("crystal-macro-sources")
      {% unless flag?(:win32) %}
        # Unnamed: the system removes it when the compiler exits.
        file.delete
      {% end %}
      new(file)
    rescue IO::Error | File::Error
      nil
    end

    @mutex = Mutex.new
    @written_bytesize = 0_i64

    def initialize(@file : File)
      {% if flag?(:win32) %}
        at_exit { @file.delete rescue nil }
      {% end %}
    end

    # Writes *text* and returns where it is, or `nil` when it stays in the
    # heap (too short, or the write failed).
    def store(text : String) : Entry?
      return nil if text.bytesize < SMALLEST_STORED_BYTESIZE

      @mutex.synchronize do
        offset = @written_bytesize
        @file.pos = offset
        @file.write(text.to_slice)
        @file.flush
        @written_bytesize += text.bytesize
        Entry.new(offset, text.bytesize)
      end
    rescue IO::Error
      nil
    end

    def read(entry : Entry) : String
      @mutex.synchronize do
        @file.pos = entry.offset
        String.new(entry.bytesize) do |buffer|
          @file.read_fully(Slice.new(buffer, entry.bytesize))
          {entry.bytesize, 0}
        end
      end
    end
  end
end
