require "./line_patch_object"

module Crystal::LinePatch
  # Rewrites the line numbers in the DWARF of an object file by the line
  # maps of a build: the rows of the line program (`.debug_line`) and the
  # `DW_AT_decl_line` and `DW_AT_call_line` attributes (`.debug_info`).
  #
  # The line program is re-encoded the way LLVM's `MCDwarfLineAddr::encode`
  # encodes it, so the patched object reads like one LLVM would emit for the
  # moved lines. Every group of opcodes that is re-encoded must first give
  # its original bytes back when encoded with its original deltas; a line
  # program encoded any other way is refused. Attributes keep their form: a
  # line that no longer fits the form (line 255 to 256 in `DW_FORM_data1`)
  # is refused, as are forms the patcher does not know.
  class DwarfPatcher
    DW_LNS_COPY             = 1_u8
    DW_LNS_ADVANCE_PC       = 2_u8
    DW_LNS_ADVANCE_LINE     = 3_u8
    DW_LNS_SET_FILE         = 4_u8
    DW_LNS_CONST_ADD_PC     = 8_u8
    DW_LNS_FIXED_ADVANCE_PC = 9_u8
    DW_LNE_END_SEQUENCE     = 1_u8
    DW_LNE_SET_ADDRESS      = 2_u8

    DW_AT_STMT_LIST = 0x10_u64
    DW_AT_DECL_FILE = 0x3a_u64
    DW_AT_DECL_LINE = 0x3b_u64
    DW_AT_CALL_FILE = 0x58_u64
    DW_AT_CALL_LINE = 0x59_u64

    DW_FORM_IMPLICIT_CONST = 0x21_u64

    # What one line table says about its files.
    class LineTable
      getter version : UInt16
      # The full path of each file, by the index the program and the debug
      # info use.
      getter paths_by_index = {} of UInt64 => String

      def initialize(@version)
      end
    end

    # The result: the new file, and how many line numbers changed.
    record Result, bytes : Bytes, changed_row_count : Int32, changed_attribute_count : Int32,
      changed_message_count : Int32 = 0

    def initialize(@maps : Maps)
    end

    def patch(object : ObjectFile) : Result
      line_section = object.section?(SectionKind::DebugLine)
      raise Refusal.new("no line table") unless line_section
      info_section = object.section?(SectionKind::DebugInfo)

      rewriter = LineProgramRewriter.new(object, line_section, object.contents(line_section), @maps)
      new_line_contents = rewriter.rewrite
      bytes = object.bytes.dup
      changed_message_count = patch_messages(object, bytes)
      changed_attribute_count = 0
      if info_section && !rewriter.list_of_tables.empty?
        info_contents = bytes[info_section.file_offset, info_section.size]
        changed_attribute_count = patch_info(object, info_section, info_contents, rewriter.list_of_tables)
      end
      if rewriter.changed_row_count > 0
        patched_object = ObjectFile.parse(bytes)
        new_line_section = patched_object.section?(SectionKind::DebugLine) || raise Refusal.new("no line table")
        bytes = patched_object.with_section_contents(new_line_section, new_line_contents, rewriter.offset_translation)
      end
      Result.new(bytes, rewriter.changed_row_count, changed_attribute_count, changed_message_count)
    end

    # Rewrites, in place, the `file:line:column` texts in the data sections
    # (the message of a failing cast) whose file changed. Returns how many
    # changed. A line whose new number has another count of digits would
    # change the size of the string, and refuses the object.
    private def patch_messages(object : ObjectFile, bytes : Bytes) : Int32
      changed_count = 0
      list_of_changed_paths = @maps.maps_by_filename.keys
      return 0 if list_of_changed_paths.empty?
      object.list_of_sections.each do |section|
        next unless section.holds_data?
        contents = bytes[section.file_offset, section.size]
        list_of_changed_paths.each do |path|
          pattern = "#{path}:".to_slice
          position = 0
          while found = index_of(contents, pattern, position)
            position = found + pattern.size
            line_start = position
            line_end = digits_end(contents, line_start)
            next if line_end == line_start || line_end >= contents.size || contents[line_end] != ':'.ord
            column_end = digits_end(contents, line_end + 1)
            next if column_end == line_end + 1 || column_end >= contents.size || contents[column_end] != 0
            line = String.new(contents[line_start, line_end - line_start]).to_i
            map = @maps.map_of?(path) || raise Refusal.new("a message in a file whose lines moved in unknown ways")
            new_line = map.map?(line) || raise Refusal.new("a message on an edited line")
            next if new_line == line
            new_text = new_line.to_s
            raise Refusal.new("a message whose line changes its number of digits") unless new_text.bytesize == line_end - line_start
            new_text.to_slice.copy_to(contents + line_start)
            changed_count += 1
          end
        end
      end
      changed_count
    end

    private def index_of(contents : Bytes, pattern : Bytes, start : Int32) : Int32?
      first = pattern[0]
      position = start
      while position + pattern.size <= contents.size
        candidate = contents[position, contents.size - position].index(first)
        return nil unless candidate
        position += candidate
        return nil if position + pattern.size > contents.size
        return position if contents[position, pattern.size] == pattern
        position += 1
      end
      nil
    end

    private def digits_end(contents : Bytes, start : Int32) : Int32
      position = start
      while position < contents.size && '0'.ord <= contents[position] <= '9'.ord
        position += 1
      end
      position
    end

    # Rewrites `DW_AT_decl_line` and `DW_AT_call_line` in place. Returns
    # how many changed.
    private def patch_info(object : ObjectFile, info_section : Section, contents : Bytes,
                           list_of_tables : Array({Int64, LineTable})) : Int32
      abbrev_section = object.section?(SectionKind::DebugAbbrev)
      raise Refusal.new("debug info without abbreviations") unless abbrev_section
      abbrev_contents = object.contents(abbrev_section)
      tables_by_offset = list_of_tables.to_h
      changed_count = 0
      unit_offset = 0
      while unit_offset < contents.size
        cursor = Cursor.new(contents, unit_offset)
        unit_length = cursor.u32
        raise Refusal.new("64-bit DWARF") if unit_length >= 0xfffffff0_u32
        unit_end = unit_offset + 4 + unit_length.to_i32
        version = cursor.u16
        if version >= 5
          unit_type = cursor.u8
          raise Refusal.new("a unit of type #{unit_type}") unless unit_type == 1 || unit_type == 3
          address_size = cursor.u8
          abbrev_offset = object.relocated_u32(info_section, cursor.position)
          cursor.u32
        elsif version >= 2
          abbrev_offset = object.relocated_u32(info_section, cursor.position)
          cursor.u32
          address_size = cursor.u8
        else
          raise Refusal.new("DWARF version #{version}")
        end
        abbreviations = Abbreviations.parse(abbrev_contents, abbrev_offset.to_i32)

        table = nil.as(LineTable?)
        while cursor.position < unit_end
          code = cursor.uleb
          next if code == 0
          abbreviation = abbreviations[code]? || raise Refusal.new("an unknown abbreviation code #{code}")
          file_index = nil.as(UInt64?)
          abbreviation.list_of_attributes.each do |(attribute, form, implicit_value)|
            value_offset = cursor.position
            case attribute
            when DW_AT_STMT_LIST
              table = tables_by_offset[object.relocated_u32(info_section, value_offset).to_i64]?
              skip_form(cursor, form, address_size, version)
            when DW_AT_DECL_FILE, DW_AT_CALL_FILE
              file_index = form == DW_FORM_IMPLICIT_CONST ? implicit_value.to_u64! : read_unsigned(cursor, form)
            when DW_AT_DECL_LINE, DW_AT_CALL_LINE
              raise Refusal.new("a line attribute shared by its abbreviation (DW_FORM_implicit_const)") if form == DW_FORM_IMPLICIT_CONST
              line = read_unsigned(cursor, form)
              new_line = map_declaration_line(table, file_index, line)
              if new_line != line
                write_unsigned(contents, value_offset, form, new_line)
                changed_count += 1
              end
            else
              skip_form(cursor, form, address_size, version)
            end
          end
        end
        unit_offset = unit_end
      end
      changed_count
    end

    private def map_declaration_line(table : LineTable?, file_index : UInt64?, line : UInt64) : UInt64
      return line unless table && file_index
      path = table.paths_by_index[file_index]?
      return line unless path && @maps.changed?(path)

      map = @maps.map_of?(path) || raise Refusal.new("a declaration in a file whose lines moved in unknown ways")
      new_line = map.map?(line.to_i32) || raise Refusal.new("a declaration on an edited line")
      new_line.to_u64
    end

    private def read_unsigned(cursor : Cursor, form : UInt64) : UInt64
      case form
      when 0x0b_u64 then cursor.u8.to_u64
      when 0x05_u64 then cursor.u16.to_u64
      when 0x06_u64 then cursor.u32.to_u64
      when 0x07_u64 then cursor.u64
      when 0x0f_u64 then cursor.uleb
      else
        raise Refusal.new("a line or file attribute in form 0x#{form.to_s(16)}")
      end
    end

    private def write_unsigned(contents : Bytes, offset : Int32, form : UInt64, value : UInt64) : Nil
      case form
      when 0x0b_u64
        raise Refusal.new("a line that no longer fits DW_FORM_data1") if value > UInt8::MAX
        contents[offset] = value.to_u8
      when 0x05_u64
        raise Refusal.new("a line that no longer fits DW_FORM_data2") if value > UInt16::MAX
        IO::ByteFormat::LittleEndian.encode(value.to_u16, contents[offset, 2])
      when 0x06_u64
        raise Refusal.new("a line that no longer fits DW_FORM_data4") if value > UInt32::MAX
        IO::ByteFormat::LittleEndian.encode(value.to_u32, contents[offset, 4])
      when 0x07_u64
        IO::ByteFormat::LittleEndian.encode(value, contents[offset, 8])
      else
        cursor = Cursor.new(contents, offset)
        cursor.uleb
        old_size = cursor.position - offset
        encoded = Leb.unsigned(value)
        raise Refusal.new("a line whose LEB128 encoding changes length in the debug info") unless encoded.size == old_size
        encoded.copy_to(contents + offset)
      end
    end

    private def skip_form(cursor : Cursor, form : UInt64, address_size : UInt8, version : UInt16) : Nil
      case form
      when 0x01_u64                                                                                then cursor.skip(address_size.to_i32)
      when 0x03_u64                                                                                then cursor.skip(cursor.u16.to_i32)
      when 0x04_u64                                                                                then cursor.skip(cursor.u32.to_i32)
      when 0x05_u64, 0x12_u64, 0x26_u64, 0x2a_u64                                                  then cursor.skip(2)
      when 0x06_u64, 0x0e_u64, 0x13_u64, 0x17_u64, 0x1c_u64, 0x1d_u64, 0x1f_u64, 0x28_u64, 0x2c_u64 then cursor.skip(4)
      when 0x07_u64, 0x14_u64, 0x20_u64, 0x24_u64                                                  then cursor.skip(8)
      when 0x08_u64                                                                                then cursor.c_string
      when 0x09_u64, 0x18_u64                                                                      then cursor.skip(cursor.uleb.to_i32)
      when 0x0a_u64                                                                                then cursor.skip(cursor.u8.to_i32)
      when 0x0b_u64, 0x0c_u64, 0x11_u64, 0x25_u64, 0x29_u64                                        then cursor.skip(1)
      when 0x0d_u64                                                                                then cursor.sleb
      when 0x0f_u64, 0x15_u64, 0x1a_u64, 0x1b_u64, 0x22_u64, 0x23_u64, 0x1f01_u64, 0x1f02_u64      then cursor.uleb
      when 0x10_u64                                                                                then cursor.skip(version <= 2 ? address_size.to_i32 : 4)
      when 0x16_u64                                                                                then skip_form(cursor, cursor.uleb, address_size, version)
      when 0x19_u64, DW_FORM_IMPLICIT_CONST                                                        then nil
      when 0x1e_u64                                                                                then cursor.skip(16)
      when 0x27_u64, 0x2b_u64                                                                      then cursor.skip(3)
      else
        raise Refusal.new("an unknown attribute form 0x#{form.to_s(16)}")
      end
    end

    # The abbreviation table of a unit: for each code, its attributes as
    # attribute, form and implicit value.
    module Abbreviations
      record Abbreviation, list_of_attributes : Array({UInt64, UInt64, Int64})

      def self.parse(contents : Bytes, offset : Int32) : Hash(UInt64, Abbreviation)
        abbreviations = {} of UInt64 => Abbreviation
        cursor = Cursor.new(contents, offset)
        loop do
          code = cursor.uleb
          break if code == 0
          cursor.uleb # tag
          cursor.u8   # has children
          list_of_attributes = [] of {UInt64, UInt64, Int64}
          loop do
            attribute = cursor.uleb
            form = cursor.uleb
            break if attribute == 0 && form == 0
            implicit_value = form == DW_FORM_IMPLICIT_CONST ? cursor.sleb : 0_i64
            list_of_attributes << {attribute, form, implicit_value}
          end
          abbreviations[code] = Abbreviation.new(list_of_attributes)
        end
        abbreviations
      end
    end

    # Reads the line programs of a `.debug_line` section and writes them
    # again with mapped lines.
    class LineProgramRewriter
      getter list_of_tables = [] of {Int64, LineTable}
      getter changed_row_count = 0

      # Runs of bytes copied unchanged: old offset, new offset, size.
      @list_of_copied_runs = [] of {Int64, Int64, Int64}
      @output = IO::Memory.new

      def initialize(@object : ObjectFile, @section : Section, @contents : Bytes, @maps : Maps)
      end

      # An old offset in the section to the new one, when the byte at that
      # offset was copied unchanged.
      def offset_translation : Proc(Int64, Int64?)
        list_of_runs = @list_of_copied_runs
        ->(old_offset : Int64) do
          index = list_of_runs.bsearch_index { |run| run[0] > old_offset }
          index = index ? index - 1 : list_of_runs.size - 1
          run = index >= 0 ? list_of_runs[index] : nil
          run && old_offset < run[0] + run[2] ? run[1] + (old_offset - run[0]) : nil
        end
      end

      def rewrite : Bytes
        unit_offset = 0
        while unit_offset < @contents.size
          unit_offset = rewrite_unit(unit_offset)
        end
        @output.to_slice
      end

      private def copy(start : Int, finish : Int) : Nil
        return if finish <= start
        new_start = @output.pos.to_i64
        last = @list_of_copied_runs.last?
        if last && last[0] + last[2] == start && last[1] + last[2] == new_start
          @list_of_copied_runs[-1] = {last[0], last[1], last[2] + (finish - start)}
        else
          @list_of_copied_runs << {start.to_i64, new_start, (finish - start).to_i64}
        end
        @output.write(@contents[start, finish - start])
      end

      private def rewrite_unit(unit_offset : Int32) : Int32
        cursor = Cursor.new(@contents, unit_offset)
        unit_length = cursor.u32
        raise Refusal.new("64-bit DWARF") if unit_length >= 0xfffffff0_u32
        unit_end = unit_offset + 4 + unit_length.to_i32
        raise Refusal.new("a line table runs past its section") if unit_end > @contents.size
        version = cursor.u16
        raise Refusal.new("line table version #{version}") unless 2 <= version <= 5
        if version >= 5
          address_size = cursor.u8
          cursor.u8 # segment selector size
        else
          address_size = 8_u8
        end
        header_length = cursor.u32
        program_start = cursor.position + header_length.to_i32
        cursor.u8                 # minimum instruction length
        cursor.u8 if version >= 4 # maximum operations per instruction
        cursor.u8                 # default is_stmt
        line_base = cursor.u8.to_i8!.to_i64
        line_range = cursor.u8.to_i64
        opcode_base = cursor.u8
        raise Refusal.new("a line table with line_range 0") if line_range == 0
        list_of_standard_lengths = Array(UInt8).new(opcode_base.to_i32 - 1) { cursor.u8 }
        table = LineTable.new(version)
        if version >= 5
          read_v5_files(cursor, table)
        else
          read_v4_files(cursor, table)
        end
        @list_of_tables << {unit_offset.to_i64, table}

        unit_output_start = @output.pos
        # The header is copied; its length field is written again at the end.
        copy(unit_offset, program_start)
        encoding = Encoding.new(line_base, line_range, opcode_base.to_i64)
        rewrite_program(Cursor.new(@contents, program_start), unit_end, encoding, list_of_standard_lengths, table, address_size)
        new_unit_length = @output.pos - unit_output_start - 4
        if new_unit_length != unit_length
          if unit_offset > 0 || unit_end < @contents.size
            raise Refusal.new("several line tables, one of which changes length")
          end
          saved_position = @output.pos
          @output.pos = unit_output_start
          @output.write_bytes(new_unit_length.to_u32, IO::ByteFormat::LittleEndian)
          @output.pos = saved_position
          # The length field is no longer a copy of the old one.
          split_copied_run(unit_offset.to_i64, 4_i64)
        end
        unit_end
      end

      # Takes the bytes at *start* (old offset) out of the copied runs.
      private def split_copied_run(start : Int64, size : Int64) : Nil
        index = @list_of_copied_runs.index { |run| run[0] <= start && start + size <= run[0] + run[2] }
        return unless index
        run = @list_of_copied_runs[index]
        list_of_parts = [] of {Int64, Int64, Int64}
        list_of_parts << {run[0], run[1], start - run[0]} if start > run[0]
        after = run[0] + run[2] - (start + size)
        list_of_parts << {start + size, run[1] + (start + size - run[0]), after} if after > 0
        @list_of_copied_runs[index, 1] = list_of_parts
      end

      private def read_v4_files(cursor : Cursor, table : LineTable) : Nil
        list_of_directories = [""]
        loop do
          directory = cursor.c_string
          break if directory.empty?
          list_of_directories << directory
        end
        index = 1_u64
        loop do
          name = cursor.c_string
          break if name.empty?
          directory_index = cursor.uleb
          cursor.uleb # modification time
          cursor.uleb # length
          table.paths_by_index[index] = join(list_of_directories[directory_index]? || "", name)
          index += 1
        end
      end

      private def read_v5_files(cursor : Cursor, table : LineTable) : Nil
        list_of_directories = read_v5_entries(cursor).map { |entry| entry[0] || "" }
        read_v5_entries(cursor).each_with_index do |entry, index|
          name = entry[0]
          next unless name
          directory_index = entry[1]
          directory = directory_index ? (list_of_directories[directory_index]? || "") : ""
          table.paths_by_index[index.to_u64] = join(directory, name)
        end
      end

      # Each entry of a DWARF 5 directory or file table, as its path and its
      # directory index.
      private def read_v5_entries(cursor : Cursor) : Array({String?, Int32?})
        list_of_formats = Array({UInt64, UInt64}).new(cursor.u8.to_i32) { {cursor.uleb, cursor.uleb} }
        Array({String?, Int32?}).new(cursor.uleb.to_i32) do
          path = nil.as(String?)
          directory_index = nil.as(Int32?)
          list_of_formats.each do |(content_type, form)|
            case form
            when 0x08_u64 # DW_FORM_string
              value = cursor.c_string
              path = value if content_type == 1
            when 0x1f_u64, 0x0e_u64 # DW_FORM_line_strp, DW_FORM_strp
              string_offset = @object.relocated_u32(@section, cursor.position)
              cursor.u32
              if content_type == 1
                kind = form == 0x1f_u64 ? SectionKind::DebugLineStr : SectionKind::DebugStr
                strings = @object.section?(kind) || raise Refusal.new("a file name in a missing string section")
                path = Cursor.new(@object.contents(strings), string_offset.to_i32).c_string
              end
            when 0x0b_u64
              value = cursor.u8.to_i32
              directory_index = value if content_type == 2
            when 0x05_u64
              value = cursor.u16.to_i32
              directory_index = value if content_type == 2
            when 0x0f_u64
              value = cursor.uleb.to_i32
              directory_index = value if content_type == 2
            when 0x06_u64 then cursor.u32
            when 0x07_u64 then cursor.u64
            when 0x1e_u64 then cursor.skip(16)
            when 0x09_u64 then cursor.skip(cursor.uleb.to_i32)
            else
              raise Refusal.new("a file entry in form 0x#{form.to_s(16)}")
            end
          end
          {path, directory_index}
        end
      end

      private def join(directory : String, name : String) : String
        return name if directory.empty? || name.starts_with?('/')
        "#{directory}/#{name}"
      end

      # Copies the program, rewriting each group of opcodes that ends in a
      # row whose line delta changes.
      private def rewrite_program(cursor : Cursor, unit_end : Int32, encoding : Encoding,
                                  list_of_standard_lengths : Array(UInt8), table : LineTable,
                                  address_size : UInt8) : Nil
        old_line = 1_i64
        new_line = 1_i64
        file = 1_u64
        group = Group.new(cursor.position)
        while cursor.position < unit_end
          op_start = cursor.position
          opcode = cursor.u8
          if opcode >= encoding.opcode_base
            adjusted_opcode = opcode.to_i64 - encoding.opcode_base
            group.add_advance(op_start)
            group.address_units += adjusted_opcode // encoding.line_range
            group.line_delta += encoding.line_base + adjusted_opcode % encoding.line_range
            old_line, new_line = finish_row(group, cursor.position, old_line, new_line, file, table, encoding)
            group = Group.new(cursor.position)
            next
          end
          case opcode
          when 0_u8
            length = cursor.uleb.to_i32
            sub_start = cursor.position
            sub_opcode = length > 0 ? cursor.u8 : 0_u8
            case sub_opcode
            when DW_LNE_END_SEQUENCE
              # The end row's line is not encoded: copied as is.
              cursor.position = sub_start + length
              copy(group.start, cursor.position)
              old_line = 1_i64
              new_line = 1_i64
              file = 1_u64
              group = Group.new(cursor.position)
              next
            when DW_LNE_SET_ADDRESS
              raise Refusal.new("an address of another size") unless length - 1 == address_size
              group.add_set_address(sub_start + length)
            else
              group.add_prefix
            end
            cursor.position = sub_start + length
          when DW_LNS_COPY
            group.add_advance(op_start)
            old_line, new_line = finish_row(group, cursor.position, old_line, new_line, file, table, encoding)
            group = Group.new(cursor.position)
          when DW_LNS_ADVANCE_PC
            group.add_advance(op_start)
            group.address_units += cursor.uleb.to_i64
          when DW_LNS_ADVANCE_LINE
            group.add_advance(op_start)
            group.line_delta += cursor.sleb
          when DW_LNS_SET_FILE
            group.add_prefix
            file = cursor.uleb
          when DW_LNS_CONST_ADD_PC
            group.add_advance(op_start)
            group.address_units += (255_i64 - encoding.opcode_base) // encoding.line_range
          when DW_LNS_FIXED_ADVANCE_PC
            group.add_advance(op_start)
            cursor.u16
            group.unknown_encoding = true
          else
            group.add_prefix
            list_of_standard_lengths[opcode - 1].times { cursor.uleb }
          end
        end
        raise Refusal.new("a line program that does not end with a sequence end") unless group.start == unit_end
      end

      # A row was emitted by the opcodes of *group*, which end at *finish*.
      # Writes the group, re-encoded when the row's line moved differently
      # from the row before. Returns the old and new line after the row.
      private def finish_row(group : Group, finish : Int32, old_line : Int64, new_line : Int64,
                             file : UInt64, table : LineTable, encoding : Encoding) : {Int64, Int64}
        row_old_line = old_line + group.line_delta
        row_new_line = map_line(table, file, row_old_line)
        new_delta = row_new_line - new_line
        if new_delta == group.line_delta
          copy(group.start, finish)
          return {row_old_line, row_new_line}
        end

        raise Refusal.new("a row whose opcodes LLVM would not emit") if group.unknown_encoding?
        # The set-address opcode (the first row of a sequence) is copied; the
        # line and address advance after it is encoded again.
        encoding_start = group.set_address_end || group.advance_start || raise Refusal.new("a row without advance opcodes")
        original = @contents[encoding_start, finish - encoding_start]
        unless encoding.encode(group.line_delta, group.address_units) == original
          raise Refusal.new("a row encoded in a way the patcher does not know")
        end
        copy(group.start, encoding_start)
        @output.write(encoding.encode(new_delta, group.address_units))
        @changed_row_count += 1
        {row_old_line, row_new_line}
      end

      private def map_line(table : LineTable, file : UInt64, line : Int64) : Int64
        path = table.paths_by_index[file]?
        return line unless path && @maps.changed?(path)
        map = @maps.map_of?(path) || raise Refusal.new("a row in a file whose lines moved in unknown ways")
        new_line = map.map?(line.to_i32) || raise Refusal.new("a row on an edited line")
        new_line.to_i64
      end
    end

    # The opcodes that make one row of the line table.
    class Group
      getter start : Int32
      # Where the opcodes that move the address and the line begin (after
      # file, column and flag opcodes).
      getter advance_start : Int32?
      # Where the set-address opcode of the group ends, if it has one.
      getter set_address_end : Int32?
      property line_delta = 0_i64
      property address_units = 0_i64
      property? unknown_encoding = false

      def initialize(@start)
      end

      def add_prefix : Nil
        # A file, column or flag opcode after the address moved is not how
        # LLVM orders them.
        @unknown_encoding = true if @advance_start || @set_address_end
      end

      def add_set_address(op_end : Int32) : Nil
        @unknown_encoding = true if @advance_start || @set_address_end
        @set_address_end = op_end
        @address_units = 0_i64
      end

      def add_advance(op_start : Int32) : Nil
        @advance_start ||= op_start
      end
    end

    # LLVM's encoding of a line and address advance (`MCDwarfLineAddr::encode`).
    struct Encoding
      getter line_base : Int64
      getter line_range : Int64
      getter opcode_base : Int64

      def initialize(@line_base, @line_range, @opcode_base)
      end

      def encode(line_delta : Int64, address_units : Int64) : Bytes
        io = IO::Memory.new
        maximum_special_address = (255_i64 - @opcode_base) // @line_range
        needs_copy = false
        biased_delta = line_delta - @line_base
        if biased_delta < 0 || biased_delta >= @line_range || biased_delta + @opcode_base > 255
          io.write_byte(DW_LNS_ADVANCE_LINE)
          io.write(Leb.signed(line_delta))
          line_delta = 0_i64
          biased_delta = 0_i64 - @line_base
          needs_copy = true
        end
        if line_delta == 0 && address_units == 0
          io.write_byte(DW_LNS_COPY)
          return io.to_slice
        end
        opcode_bias = biased_delta + @opcode_base
        if address_units < 256 + maximum_special_address
          opcode = opcode_bias + address_units * @line_range
          if opcode <= 255
            io.write_byte(opcode.to_u8)
            return io.to_slice
          end
          opcode = opcode_bias + (address_units - maximum_special_address) * @line_range
          if opcode <= 255
            io.write_byte(DW_LNS_CONST_ADD_PC)
            io.write_byte(opcode.to_u8)
            return io.to_slice
          end
        end
        io.write_byte(DW_LNS_ADVANCE_PC)
        io.write(Leb.unsigned(address_units.to_u64))
        io.write_byte(needs_copy ? DW_LNS_COPY : opcode_bias.to_u8)
        io.to_slice
      end
    end
  end

  # LEB128 encoding.
  module Leb
    def self.unsigned(value : UInt64) : Bytes
      io = IO::Memory.new
      loop do
        byte = (value & 0x7f).to_u8
        value >>= 7
        if value != 0
          io.write_byte(byte | 0x80)
        else
          io.write_byte(byte)
          break
        end
      end
      io.to_slice
    end

    def self.signed(value : Int64) : Bytes
      io = IO::Memory.new
      loop do
        byte = (value & 0x7f).to_u8
        value >>= 7
        done = (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0)
        io.write_byte(done ? byte : byte | 0x80)
        break if done
      end
      io.to_slice
    end
  end

  # Reads little-endian values and LEB128 numbers from bytes.
  class Cursor
    property position : Int32

    def initialize(@bytes : Bytes, @position : Int32)
    end

    private def take(size : Int32) : Bytes
      raise Refusal.new("DWARF data runs past its section") if size < 0 || @position + size > @bytes.size
      slice = @bytes[@position, size]
      @position += size
      slice
    end

    def skip(size : Int32) : Nil
      take(size)
    end

    def u8 : UInt8
      take(1)[0]
    end

    def u16 : UInt16
      IO::ByteFormat::LittleEndian.decode(UInt16, take(2))
    end

    def u32 : UInt32
      IO::ByteFormat::LittleEndian.decode(UInt32, take(4))
    end

    def u64 : UInt64
      IO::ByteFormat::LittleEndian.decode(UInt64, take(8))
    end

    def uleb : UInt64
      result = 0_u64
      shift = 0
      loop do
        byte = u8
        raise Refusal.new("an LEB128 number of more than 64 bits") if shift > 63
        result |= (byte & 0x7f).to_u64 << shift
        shift += 7
        break if byte & 0x80 == 0
      end
      result
    end

    def sleb : Int64
      result = 0_i64
      shift = 0
      byte = 0_u8
      loop do
        byte = u8
        raise Refusal.new("an LEB128 number of more than 64 bits") if shift > 63
        result |= (byte & 0x7f).to_i64 << shift
        shift += 7
        break if byte & 0x80 == 0
      end
      result |= -(1_i64 << shift) if shift < 64 && byte & 0x40 != 0
      result
    end

    def c_string : String
      finish = @position
      while finish < @bytes.size && @bytes[finish] != 0
        finish += 1
      end
      raise Refusal.new("a string runs past its section") if finish >= @bytes.size
      value = String.new(@bytes[@position, finish - @position])
      @position = finish + 1
      value
    end
  end
end
