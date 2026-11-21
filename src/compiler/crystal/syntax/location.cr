require "weak_ref"

# A location of an `ASTnode`, including its filename, line number and column number.
#
# A location is one 64-bit word: the index of its filename in a table shared
# by the whole process, its line number and its column number. A node stores
# the word itself, so a location costs no object of its own.
struct Crystal::Location
  include Comparable(self)

  # Bits of the word, from the top: one bit that marks an index into the
  # overflow table, then the file index, the line number and the column number.
  private FILE_BITS   = 25
  private LINE_BITS   = 22
  private COLUMN_BITS = 16
  private OVERFLOW    = 1_u64 << 63

  # File index of a location without a filename. Index 0 is never used, so
  # the word of a location is never zero and zero can stand for "no location".
  private NO_FILENAME = 1_u32

  @@files = [nil, nil] of String | WeakRef(VirtualFile) | Nil
  @@file_indexes = {} of String => UInt32
  @@last_filename : String?
  @@last_file_index = 0_u32
  @@overflow = [] of {UInt32, Int32, Int32}
  {% if flag?(:preview_mt) %}
    @@mutex = Thread::Mutex.new
  {% end %}

  # The word that represents this location (see `.from_bits?`).
  getter bits : UInt64

  def initialize(filename : String | VirtualFile | Nil, line_number : Int32, column_number : Int32)
    file_index = Location.file_index(filename)
    if file_index < (1_u32 << FILE_BITS) && 0 <= line_number < (1 << LINE_BITS) && 0 <= column_number < (1 << COLUMN_BITS)
      @bits = (file_index.to_u64 << (LINE_BITS + COLUMN_BITS)) | (line_number.to_u64 << COLUMN_BITS) | column_number.to_u64
    else
      @bits = OVERFLOW | Location.add_overflow(file_index, line_number, column_number)
    end
  end

  protected def initialize(@bits : UInt64)
  end

  # Returns the location that *bits* represents, or `nil` when *bits* is zero.
  def self.from_bits?(bits : UInt64) : Location?
    bits == 0 ? nil : new(bits)
  end

  # Returns the word of *location*, or zero for `nil`.
  def self.bits(location : Location?) : UInt64
    location ? location.bits : 0_u64
  end

  def filename : String | VirtualFile | Nil
    Location.filename_at(unpack[0])
  end

  def line_number : Int32
    unpack[1]
  end

  def column_number : Int32
    unpack[2]
  end

  protected def unpack : {UInt32, Int32, Int32}
    bits = @bits
    if bits & OVERFLOW != 0
      Location.overflow_at((bits & ~OVERFLOW).to_i32!)
    else
      {
        (bits >> (LINE_BITS + COLUMN_BITS)).to_u32!,
        ((bits >> COLUMN_BITS) & ((1_u64 << LINE_BITS) - 1)).to_i32!,
        (bits & ((1_u64 << COLUMN_BITS) - 1)).to_i32!,
      }
    end
  end

  private def self.synchronize(&)
    {% if flag?(:preview_mt) %}
      @@mutex.synchronize { yield }
    {% else %}
      yield
    {% end %}
  end

  # Registers *file* in the filename table and returns its index. The table
  # holds the file weakly: whoever creates a `VirtualFile` keeps it alive for
  # as long as its locations are in use (the program does, for the files of
  # its macro expansions).
  def self.register(file : VirtualFile) : UInt32
    synchronize do
      @@files << WeakRef.new(file)
      (@@files.size - 1).to_u32
    end
  end

  protected def self.file_index(filename : VirtualFile) : UInt32
    filename.file_index
  end

  protected def self.file_index(filename : Nil) : UInt32
    NO_FILENAME
  end

  protected def self.file_index(filename : String) : UInt32
    synchronize do
      # The lexer asks for the same filename object once per token.
      if filename.same?(@@last_filename)
        @@last_file_index
      else
        index = @@file_indexes[filename]?
        unless index
          @@files << filename
          index = @@file_indexes[filename] = (@@files.size - 1).to_u32
        end
        @@last_filename = filename
        @@last_file_index = index
      end
    end
  end

  protected def self.filename_at(index : UInt32) : String | VirtualFile | Nil
    file = synchronize { @@files[index]? }
    file.is_a?(WeakRef(VirtualFile)) ? file.value : file
  end

  protected def self.add_overflow(file_index : UInt32, line_number : Int32, column_number : Int32) : UInt64
    synchronize do
      @@overflow << {file_index, line_number, column_number}
      (@@overflow.size - 1).to_u64
    end
  end

  protected def self.overflow_at(index : Int32) : {UInt32, Int32, Int32}
    synchronize { @@overflow[index] }
  end

  def ==(other : Location) : Bool
    return true if @bits == other.bits
    # Two words can only stand for the same location when one of them is in
    # the overflow table.
    return false if (@bits | other.bits) & OVERFLOW == 0
    unpack == other.unpack
  end

  def hash(hasher)
    unpack.hash(hasher)
  end

  # Returns a location from a string representation. Used by compiler tools like
  # `context` and `implementations`.
  def self.parse(cursor : String, *, expand : Bool = false) : self
    file_and_line, _, col = cursor.rpartition(':')
    file, _, line = file_and_line.rpartition(':')

    raise ArgumentError.new "cursor location must be file:line:column" if file.empty? || line.empty? || col.empty?

    file = File.expand_path(file) if expand

    line_number = line.to_i? || 0
    if line_number <= 0
      raise ArgumentError.new "line must be a positive integer, not #{line}"
    end

    column_number = col.to_i? || 0
    if column_number <= 0
      raise ArgumentError.new "column must be a positive integer, not #{col}"
    end

    new(file, line_number, column_number)
  end

  # Returns the directory name of this location's filename. If
  # the filename is a VirtualFile, this is invoked on its expanded
  # location.
  def dirname : String?
    original_filename.try { |filename| File.dirname(filename) }
  end

  # Returns the Location whose filename is a String, not a VirtualFile,
  # traversing virtual file expanded locations.
  def expanded_location
    case filename = self.filename
    when String
      self
    when VirtualFile
      filename.expanded_location.try &.expanded_location
    else
      nil
    end
  end

  # Returns the Location whose filename is a String, not a VirtualFile,
  # traversing virtual file expanded locations leading to the original user source code
  def macro_location
    case filename = self.filename
    when String
      self
    when VirtualFile
      filename.macro.location.try(&.macro_location)
    else
      nil
    end
  end

  # Returns the filename of the `expanded_location`
  def original_filename
    expanded_location.try &.filename.as?(String)
  end

  def between?(min, max)
    return false unless min && max

    min <= self && self <= max
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def to_s(io : IO) : Nil
    io << filename << ':' << line_number << ':' << column_number
  end

  def pretty_print(pp)
    pp.text to_s
  end

  def <=>(other)
    self_file = self.filename
    other_file = other.filename
    if self_file.is_a?(String) && other_file.is_a?(String) && self_file == other_file
      {line_number, column_number} <=> {other.line_number, other.column_number}
    else
      nil
    end
  end

  def equals?(other)
    return false unless (self.filename || "") == (other.filename || "")
    return false unless line_number == other.line_number
    return false unless column_number == other.column_number
    true
  end

  # Returns the number of lines between start and finish locations.
  def self.lines(start, finish)
    return unless start && finish && start.filename == finish.filename
    start, finish = finish, start if finish < start

    finish.line_number - start.line_number + 1
  end
end
