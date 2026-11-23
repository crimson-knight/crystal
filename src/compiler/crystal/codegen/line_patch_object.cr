require "./line_patch"

module Crystal::LinePatch
  # Why an object file cannot be patched; the module is generated instead.
  class Refusal < Exception
  end

  # The section names the patcher works with, without the `__` or `.` prefix
  # of the file format.
  enum SectionKind
    DebugLine
    DebugInfo
    DebugAbbrev
    DebugLineStr
    DebugStr
    Text
    Other
  end

  # One section of an object file: where its contents are in the file, and
  # its relocations as offsets into the section.
  class Section
    getter name : String
    getter kind : SectionKind
    getter file_offset : Int64
    getter size : Int64
    # Index of the section header (ELF) or of the section in its segment's
    # list (Mach-O), for the writer.
    getter index : Int32
    # Whether the section holds the program's constant or variable data
    # (not code, debug info, symbols or relocations): where the message of
    # a failing cast keeps its `file:line:column`.
    getter? holds_data : Bool

    def initialize(@name, @kind, @file_offset, @size, @index, @holds_data = false)
    end
  end

  # An object file in a format the patcher can read and rewrite: Mach-O
  # (64-bit, little endian) or ELF (64-bit, little endian).
  abstract class ObjectFile
    getter bytes : Bytes
    getter list_of_sections = [] of Section

    def initialize(@bytes)
    end

    def self.parse(bytes : Bytes) : ObjectFile
      raise Refusal.new("the object file is too small") if bytes.size < 64
      magic = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[0, 4])
      if magic == MachOFile::MAGIC_64
        MachOFile.new(bytes)
      elsif bytes[0, 4] == Bytes[0x7f, 'E'.ord, 'L'.ord, 'F'.ord]
        ElfFile.new(bytes)
      else
        raise Refusal.new("not a 64-bit little-endian Mach-O or ELF object file")
      end
    end

    def section?(kind : SectionKind) : Section?
      found = nil
      @list_of_sections.each do |section|
        next unless section.kind == kind
        raise Refusal.new("several #{section.name} sections") if found
        found = section
      end
      found
    end

    def contents(section : Section) : Bytes
      @bytes[section.file_offset, section.size]
    end

    # The 32-bit value at *offset* of *section* as the linker will see it:
    # the addend of a relocation there (ELF), or the stored value.
    abstract def relocated_u32(section : Section, offset : Int32) : UInt32

    # Writes *value* where `relocated_u32` reads it, in *bytes* (a copy of
    # this file with the same layout).
    abstract def write_relocated_u32(bytes : Bytes, section : Section, offset : Int32, value : UInt32) : Nil

    # A new file with *section*'s contents replaced by *new_contents*, and the
    # relocations of the section moved by *translate_offset* (an offset in
    # the old contents to the one in the new contents).
    abstract def with_section_contents(section : Section, new_contents : Bytes,
                                       translate_offset : Proc(Int64, Int64?)) : Bytes

    # The bytes of every machine code section, by name.
    def code_sections : Hash(String, Bytes)
      @list_of_sections.select(&.kind.text?).to_h { |section| {section.name, contents(section)} }
    end

    # The bytes of every data section (see `Section#holds_data?`), by name.
    def data_sections : Hash(String, Bytes)
      @list_of_sections.select(&.holds_data?).to_h { |section| {section.name, contents(section)} }
    end

    protected def u16(offset : Int) : UInt16
      IO::ByteFormat::LittleEndian.decode(UInt16, @bytes[offset, 2])
    end

    protected def u32(offset : Int) : UInt32
      IO::ByteFormat::LittleEndian.decode(UInt32, @bytes[offset, 4])
    end

    protected def u64(offset : Int) : UInt64
      IO::ByteFormat::LittleEndian.decode(UInt64, @bytes[offset, 8])
    end

    protected def self.put_u32(bytes : Bytes, offset : Int, value : Int) : Nil
      IO::ByteFormat::LittleEndian.encode(value.to_u32, bytes[offset, 4])
    end

    protected def self.put_u64(bytes : Bytes, offset : Int, value : Int) : Nil
      IO::ByteFormat::LittleEndian.encode(value.to_u64, bytes[offset, 8])
    end

    protected def self.align_up(value : Int64, alignment : Int64) : Int64
      (value + alignment - 1) // alignment * alignment
    end
  end

  # A Mach-O object file (`MH_OBJECT`): one segment that holds every
  # section, then the relocations, the symbol table and the string table.
  class MachOFile < ObjectFile
    MAGIC_64              = 0xfeedfacf_u32
    LC_SEGMENT_64         =       0x19_u32
    LC_SYMTAB             =        0x2_u32
    LC_DYSYMTAB           =        0xb_u32
    LC_DATA_IN_CODE       =       0x29_u32
    LC_LINKER_OPTIMIZE    =       0x2e_u32
    LC_BUILD_VERSION      =       0x32_u32
    LC_LINKER_OPTION      =       0x2d_u32
    LIST_OF_VERSION_MINS  = [0x24_u32, 0x25_u32, 0x2f_u32, 0x30_u32]
    SECTION_HEADER_SIZE   =       80
    SEGMENT_COMMAND_SIZE  =       72
    SECTION_TYPE_MASK     = 0xff_u32
    ZEROFILL_SECTION_TYPE = [0x1_u32, 0xc_u32, 0x12_u32]
    S_ATTR_DEBUG          = 0x02000000_u32

    # Where the segment command starts, and where each section header is.
    @segment_offset = 0
    @list_of_section_header_offsets = [] of Int32

    def initialize(bytes : Bytes)
      super(bytes)
      command_count = u32(16)
      offset = 32
      command_count.times do
        command = u32(offset)
        command_size = u32(offset + 4).to_i32
        raise Refusal.new("a load command runs past the file") if command_size < 8 || offset + command_size > bytes.size
        case command
        when LC_SEGMENT_64
          raise Refusal.new("an object file with several segments") unless @list_of_section_header_offsets.empty?
          @segment_offset = offset
          u32(offset + 64).times do |index|
            header_offset = offset + SEGMENT_COMMAND_SIZE + index * SECTION_HEADER_SIZE
            @list_of_section_header_offsets << header_offset
            name = section_name(header_offset)
            segment_name = String.new(bytes[header_offset + 16, 16]).rstrip('\0')
            kind = section_kind(segment_name, name)
            section_type = u32(header_offset + 64) & SECTION_TYPE_MASK
            holds_data = kind.other? && segment_name != "__DWARF" && segment_name != "__LD" && !ZEROFILL_SECTION_TYPE.includes?(section_type)
            @list_of_sections << Section.new(name, kind, u32(header_offset + 48).to_i64, u64(header_offset + 40).to_i64, index.to_i32, holds_data)
          end
        when LC_SYMTAB, LC_DYSYMTAB, LC_DATA_IN_CODE, LC_LINKER_OPTIMIZE, LC_BUILD_VERSION, LC_LINKER_OPTION
        else
          raise Refusal.new("an unknown Mach-O load command 0x#{command.to_s(16)}") unless LIST_OF_VERSION_MINS.includes?(command)
        end
        offset += command_size
      end
    end

    private def section_name(header_offset : Int32) : String
      String.new(@bytes[header_offset, 16]).rstrip('\0')
    end

    private def section_kind(segment_name : String, name : String) : SectionKind
      case {segment_name, name}
      when {"__DWARF", "__debug_line"}     then SectionKind::DebugLine
      when {"__DWARF", "__debug_info"}     then SectionKind::DebugInfo
      when {"__DWARF", "__debug_abbrev"}   then SectionKind::DebugAbbrev
      when {"__DWARF", "__debug_line_str"} then SectionKind::DebugLineStr
      when {"__DWARF", "__debug_str"}      then SectionKind::DebugStr
      when {"__TEXT", "__text"}            then SectionKind::Text
      else                                      SectionKind::Other
      end
    end

    # Mach-O object files keep DWARF offsets between sections unrelocated.
    def relocated_u32(section : Section, offset : Int32) : UInt32
      u32(section.file_offset + offset)
    end

    def write_relocated_u32(bytes : Bytes, section : Section, offset : Int32, value : UInt32) : Nil
      ObjectFile.put_u32(bytes, section.file_offset + offset, value)
    end

    def with_section_contents(section : Section, new_contents : Bytes,
                              translate_offset : Proc(Int64, Int64?)) : Bytes
      header_offset = @list_of_section_header_offsets[section.index]
      old_end = section.file_offset + section.size
      new_end = section.file_offset + new_contents.size
      if new_contents.size == section.size
        new_bytes = @bytes.dup
        new_contents.copy_to(new_bytes + section.file_offset)
        move_relocations(new_bytes, header_offset, translate_offset, 0_i64)
        return new_bytes
      end

      # The section changes size: it must be the last one, in the file and
      # in memory, so nothing else in the segment moves. Zero-fill sections
      # (`__common`, `__thread_bss`: the main module's globals) have no
      # bytes in the file and sit at the end of memory; a debug section,
      # which the linker does not place, then moves past them in memory.
      section_address = u64(header_offset + 32)
      is_debug_section = (u32(header_offset + 64) & S_ATTR_DEBUG) != 0
      moves_past_zero_fill = false
      @list_of_section_header_offsets.each do |other_header_offset|
        next if other_header_offset == header_offset
        other_type = u32(other_header_offset + 64) & SECTION_TYPE_MASK
        other_size = u64(other_header_offset + 40)
        next if other_size == 0
        if u64(other_header_offset + 32) >= section_address
          unless is_debug_section && ZEROFILL_SECTION_TYPE.includes?(other_type)
            raise Refusal.new("#{section.name} is not the last section in memory")
          end
          moves_past_zero_fill = true
        end
        next if ZEROFILL_SECTION_TYPE.includes?(other_type)
        if u32(other_header_offset + 48) >= section.file_offset
          raise Refusal.new("#{section.name} is not the last section in the file")
        end
      end

      # Everything after the section (relocations, symbols, strings) moves by
      # a multiple of 8, so it keeps its alignment.
      list_of_tail_offsets = tail_offset_fields
      tail_start = list_of_tail_offsets.compact_map { |(_, value)| value > 0 ? value : nil }.min? || ObjectFile.align_up(old_end, 8_i64)
      raise Refusal.new("data overlaps the end of #{section.name}") if tail_start < old_end
      shift = ObjectFile.align_up(new_end - tail_start, 8_i64)
      shift = -((tail_start - new_end) // 8 * 8) if new_end <= tail_start

      new_size = @bytes.size + shift
      new_bytes = Bytes.new(new_size)
      @bytes[0, section.file_offset].copy_to(new_bytes)
      new_contents.copy_to(new_bytes + section.file_offset)
      tail = @bytes[tail_start, @bytes.size - tail_start]
      tail.copy_to(new_bytes + (tail_start + shift))

      list_of_tail_offsets.each do |(field_offset, value)|
        next unless value >= tail_start
        ObjectFile.put_u32(new_bytes, field_offset, value + shift)
      end
      ObjectFile.put_u64(new_bytes, header_offset + 40, new_contents.size)
      if moves_past_zero_fill
        memory_end_of_others = @list_of_section_header_offsets.max_of do |other_header_offset|
          other_header_offset == header_offset ? 0_u64 : u64(other_header_offset + 32) + u64(other_header_offset + 40)
        end
        alignment = 1_i64 << u32(header_offset + 52)
        ObjectFile.put_u64(new_bytes, header_offset + 32, ObjectFile.align_up(memory_end_of_others.to_i64, alignment))
      end

      # The segment covers the new end.
      segment_file_offset = u64(@segment_offset + 40)
      segment_address = u64(@segment_offset + 24)
      file_end = 0_u64
      memory_end = 0_u64
      @list_of_section_header_offsets.each do |other_header_offset|
        size = other_header_offset == header_offset ? new_contents.size.to_u64 : u64(other_header_offset + 40)
        address = IO::ByteFormat::LittleEndian.decode(UInt64, new_bytes[other_header_offset + 32, 8])
        memory_end = Math.max(memory_end, address + size)
        other_type = u32(other_header_offset + 64) & SECTION_TYPE_MASK
        next if ZEROFILL_SECTION_TYPE.includes?(other_type)
        file_end = Math.max(file_end, u32(other_header_offset + 48).to_u64 + size)
      end
      ObjectFile.put_u64(new_bytes, @segment_offset + 32, memory_end - segment_address)
      ObjectFile.put_u64(new_bytes, @segment_offset + 48, file_end - segment_file_offset)

      move_relocations(new_bytes, header_offset, translate_offset, shift)
      new_bytes
    end

    # The file offsets in load commands that point past the sections: each
    # as the place of the field and its value.
    private def tail_offset_fields : Array({Int32, Int64})
      list_of_fields = [] of {Int32, Int64}
      add = ->(field_offset : Int32, count : UInt32) do
        value = u32(field_offset).to_i64
        list_of_fields << {field_offset, value} if count > 0 && value > 0
      end
      @list_of_section_header_offsets.each do |header_offset|
        add.call(header_offset + 56, u32(header_offset + 60))
      end
      offset = 32
      u32(16).times do
        command = u32(offset)
        case command
        when LC_SYMTAB
          add.call(offset + 8, u32(offset + 12))
          add.call(offset + 16, u32(offset + 20))
        when LC_DYSYMTAB
          {32, 40, 48, 56, 64, 72}.each { |field| add.call(offset + field, u32(offset + field + 4)) }
        when LC_DATA_IN_CODE, LC_LINKER_OPTIMIZE
          add.call(offset + 8, u32(offset + 12))
        end
        offset += u32(offset + 4).to_i32
      end
      list_of_fields
    end

    # Moves the relocations of the section whose header is at
    # *header_offset* (in *new_bytes*, whose tail moved by *shift*).
    private def move_relocations(new_bytes : Bytes, header_offset : Int32, translate_offset : Proc(Int64, Int64?), shift : Int64) : Nil
      relocation_count = u32(header_offset + 60)
      return if relocation_count == 0
      table_offset = u32(header_offset + 56).to_i64
      table_offset += shift if shift != 0
      relocation_count.times do |index|
        entry_offset = table_offset + index * 8
        address = IO::ByteFormat::LittleEndian.decode(UInt32, new_bytes[entry_offset, 4])
        raise Refusal.new("a scattered relocation") if address & 0x80000000_u32 != 0
        new_address = translate_offset.call(address.to_i64)
        raise Refusal.new("a relocation inside rewritten bytes") unless new_address
        ObjectFile.put_u32(new_bytes, entry_offset, new_address)
      end
    end
  end

  # An ELF relocatable object file (64-bit, little endian).
  class ElfFile < ObjectFile
    SHT_RELA = 4_u32
    SHT_REL  = 9_u32

    @section_header_offset = 0_i64
    @section_header_size = 64
    @list_of_types = [] of UInt32
    @list_of_infos = [] of UInt32
    # The addends of the RELA relocations of each section, by offset.
    @addends_by_section = {} of Int32 => Hash(Int64, Int64)

    def initialize(bytes : Bytes)
      super(bytes)
      raise Refusal.new("not a 64-bit little-endian ELF file") unless bytes[4] == 2 && bytes[5] == 1
      raise Refusal.new("not a relocatable ELF file") unless u16(16) == 1
      @section_header_offset = u64(40).to_i64
      @section_header_size = u16(58).to_i32
      section_count = u16(60).to_i32
      names_index = u16(62).to_i32
      raise Refusal.new("an ELF file with extended section numbering") if section_count == 0
      names_offset = u64(header(names_index) + 24).to_i64
      section_count.times do |index|
        header_offset = header(index)
        name = c_string(names_offset + u32(header_offset))
        type = u32(header_offset + 4)
        @list_of_types << type
        @list_of_infos << u32(header_offset + 44)
        kind = case name
               when ".debug_line"     then SectionKind::DebugLine
               when ".debug_info"     then SectionKind::DebugInfo
               when ".debug_abbrev"   then SectionKind::DebugAbbrev
               when ".debug_line_str" then SectionKind::DebugLineStr
               when ".debug_str"      then SectionKind::DebugStr
               else
                 name == ".text" || name.starts_with?(".text.") ? SectionKind::Text : SectionKind::Other
               end
        size = type == 8_u32 ? 0_i64 : u64(header_offset + 32).to_i64
        # PROGBITS sections that are allocated (SHF_ALLOC) and not code.
        holds_data = kind.other? && type == 1_u32 && (u64(header_offset + 8) & 0x2_u64) != 0 && (u64(header_offset + 8) & 0x4_u64) == 0
        @list_of_sections << Section.new(name, kind, u64(header_offset + 24).to_i64, size, index, holds_data)
      end
    end

    private def header(index : Int32) : Int64
      @section_header_offset + index * @section_header_size
    end

    private def c_string(offset : Int64) : String
      finish = offset
      while finish < @bytes.size && @bytes[finish] != 0
        finish += 1
      end
      String.new(@bytes[offset, finish - offset])
    end

    # The relocation sections that apply to the section at *index*.
    private def relocation_section_indexes(index : Int32) : Array(Int32)
      list_of_indexes = [] of Int32
      @list_of_types.each_with_index do |type, other_index|
        next unless type == SHT_RELA || type == SHT_REL
        list_of_indexes << other_index if @list_of_infos[other_index] == index
      end
      list_of_indexes
    end

    private def addends(section : Section) : Hash(Int64, Int64)
      @addends_by_section[section.index] ||= begin
        addends_by_offset = {} of Int64 => Int64
        relocation_section_indexes(section.index).each do |relocation_index|
          raise Refusal.new("REL relocations in #{section.name}") if @list_of_types[relocation_index] == SHT_REL
          relocation_section = @list_of_sections[relocation_index]
          (relocation_section.size // 24).times do |entry|
            entry_offset = relocation_section.file_offset + entry * 24
            addends_by_offset[u64(entry_offset).to_i64] = u64(entry_offset + 16).to_i64!
          end
        end
        addends_by_offset
      end
    end

    def relocated_u32(section : Section, offset : Int32) : UInt32
      if addend = addends(section)[offset.to_i64]?
        addend.to_u32
      else
        u32(section.file_offset + offset)
      end
    end

    def write_relocated_u32(bytes : Bytes, section : Section, offset : Int32, value : UInt32) : Nil
      relocation_section_indexes(section.index).each do |relocation_index|
        relocation_section = @list_of_sections[relocation_index]
        (relocation_section.size // 24).times do |entry|
          entry_offset = relocation_section.file_offset + entry * 24
          next unless u64(entry_offset).to_i64 == offset
          ObjectFile.put_u64(bytes, entry_offset + 16, value.to_u64)
          return
        end
      end
      ObjectFile.put_u32(bytes, section.file_offset + offset, value)
    end

    def with_section_contents(section : Section, new_contents : Bytes,
                              translate_offset : Proc(Int64, Int64?)) : Bytes
      if new_contents.size == section.size
        new_bytes = @bytes.dup
        new_contents.copy_to(new_bytes + section.file_offset)
      else
        # The new contents go at the end of the file; the section header
        # points there. Nothing else moves.
        contents_offset = ObjectFile.align_up(@bytes.size.to_i64, 16_i64)
        new_bytes = Bytes.new(contents_offset + new_contents.size)
        @bytes.copy_to(new_bytes)
        new_contents.copy_to(new_bytes + contents_offset)
        ObjectFile.put_u64(new_bytes, header(section.index) + 24, contents_offset)
        ObjectFile.put_u64(new_bytes, header(section.index) + 32, new_contents.size)
      end

      relocation_section_indexes(section.index).each do |relocation_index|
        relocation_section = @list_of_sections[relocation_index]
        (relocation_section.size // 24).times do |entry|
          entry_offset = relocation_section.file_offset + entry * 24
          old_offset = IO::ByteFormat::LittleEndian.decode(UInt64, new_bytes[entry_offset, 8]).to_i64
          new_offset = translate_offset.call(old_offset)
          raise Refusal.new("a relocation inside rewritten bytes") unless new_offset
          ObjectFile.put_u64(new_bytes, entry_offset, new_offset)
        end
      end
      new_bytes
    end
  end
end
