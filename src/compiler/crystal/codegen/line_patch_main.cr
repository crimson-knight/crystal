require "json"
require "llvm"
require "./line_patch"
require "./line_patch_dwarf"
require "./cached_object_record"

module Crystal::LinePatch
  # Line patching for the main module.
  #
  # IR generation skips type modules whose inputs did not change, but the
  # main module is generated in every build: it holds the program's
  # top-level code, the constant initializers and the definitions the other
  # modules ask it for. When lines move in a file the main module has code
  # from, its bitcode changes with the line numbers alone, and its object
  # (the largest one of an optimized build) was compiled again.
  #
  # The main module's text tells whether only lines moved: its textual IR,
  # with every position in a changed file mapped back to the line it had in
  # the build before, is the text of the module the cached object was built
  # from. Then the cached object gets its debug lines patched, as the
  # objects of type modules do (see `LinePatch`), instead of a new compile.
  #
  # The digest of the main module's text sits in `<object>.lines` next to
  # the object, with the bitcode hash it belongs to; it counts only while the
  # object's hash record (`CachedObjectRecord`) names the same hash.
  module MainModule
    SIDECAR_EXTENSION = ".lines"

    # What the cache knows of the text of the main module its object was
    # built from.
    struct Sidecar
      include JSON::Serializable

      getter module_hash : String
      getter text_digest : String

      def initialize(@module_hash, @text_digest)
      end

      # The sidecar of *object_filename*, if there is a readable one.
      def self.read?(object_filename : String) : Sidecar?
        filename = "#{object_filename}#{SIDECAR_EXTENSION}"
        return nil unless File.file?(filename)
        from_json(File.read(filename))
      rescue IO::Error | JSON::ParseException
        nil
      end

      def write(object_filename : String) : Nil
        File.write("#{object_filename}#{SIDECAR_EXTENSION}", to_json)
      end
    end

    # The digests of one module text: as it is, and with the positions of
    # the changed files mapped back to the build before (`nil` when a
    # position cannot be mapped: it is on an edited line, or in a file whose
    # lines moved in unknown ways).
    record Digests, text_digest : String, mapped_text_digest : String?, mapping_failure : String?

    # Computes the digests of the text of *llvm_mod*. *maps* gives the
    # changed files; without any, the mapped digest is the plain one.
    def self.digests(llvm_mod : LLVM::Module, maps : Maps?) : Digests?
      {% if LibLLVM::IS_LT_150 %}
        nil
      {% else %}
        text_pointer = LibLLVM.print_module_to_string(llvm_mod)
        begin
          text = Slice.new(text_pointer, LibC.strlen(text_pointer))
          TextNormalizer.new(text, maps).digests
        ensure
          LibLLVM.dispose_message(text_pointer)
        end
      {% end %}
    end

    # Hashes a module text twice in one pass: as it is, and with the line
    # numbers of positions in changed files mapped back to the build before.
    #
    # Positions are the `line:` and `scopeLine:` fields of debug metadata
    # (their file is the node's `file:`, or for a `DILocation` its scope's)
    # and the `file:line:column` texts that end a string constant (the
    # message of a failing cast), which `DwarfPatcher` rewrites in the data
    # of the object. Everything else must be the same text.
    private class TextNormalizer
      @file_slot_by_slot = {} of Int32 => Int32
      @scope_slot_by_location_slot = {} of Int32 => Int32
      @filename_by_file_slot = {} of Int32 => String
      @list_of_message_patterns = [] of {Bytes, String}

      def initialize(@text : Bytes, @maps : Maps?)
      end

      def digests : Digests?
        maps = @maps
        plain = LLVM::Blake3.new
        mapped = LLVM::Blake3.new
        mapping_failure = nil
        has_changes = !maps.nil? && !maps.empty?
        if has_changes && maps
          collect_scopes
          maps.maps_by_filename.each_key do |filename|
            if escaped = escaped_ir_string(filename)
              @list_of_message_patterns << {"#{escaped}:".to_slice, filename}
            end
          end
        end

        each_line do |line|
          plain.update(line)
          next if mapping_failure
          unless has_changes
            mapped.update(line)
            next
          end
          result = map_line(line)
          if result.is_a?(String)
            mapping_failure = result
          else
            mapped.update(result)
          end
        end
        plain_digest = plain.hexfinal
        if mapping_failure
          Digests.new(plain_digest, nil, mapping_failure)
        else
          Digests.new(plain_digest, has_changes ? mapped.hexfinal : plain_digest, nil)
        end
      end

      # Yields each line of the text with its newline.
      private def each_line(& : Bytes ->) : Nil
        start = 0
        while start < @text.size
          newline = @text[start, @text.size - start].index('\n'.ord.to_u8)
          finish = newline ? start + newline + 1 : @text.size
          yield @text[start, finish - start]
          start = finish
        end
      end

      # Reads which file each metadata node with a position belongs to.
      private def collect_scopes : Nil
        each_line do |line|
          next unless metadata_line?(line)
          string = String.new(line)
          slot = metadata_slot(string) || next
          if string.includes?("!DIFile(")
            filename = field_string(string, "filename") || next
            directory = field_string(string, "directory") || ""
            @filename_by_file_slot[slot] = directory.empty? || directory == "." || filename.starts_with?('/') ? filename : File.join(directory, filename)
          elsif string.includes?("!DILocation(")
            if scope = reference_field(string, "scope")
              @scope_slot_by_location_slot[slot] = scope
            end
          elsif file = reference_field(string, "file")
            @file_slot_by_slot[slot] = file
          end
        end
      end

      # The line with its positions mapped back, or why it cannot be.
      private def map_line(line : Bytes) : Bytes | String
        if metadata_line?(line)
          return line unless contains?(line, "line: ".to_slice)
          map_metadata_line(String.new(line))
        elsif !line.empty? && line[0] == '@'.ord
          map_message_line(line)
        else
          line
        end
      end

      private def map_metadata_line(string : String) : Bytes | String
        slot = metadata_slot(string) || return string.to_slice
        filename = filename_of(slot, string) || return string.to_slice
        maps = @maps || return string.to_slice
        return string.to_slice unless maps.changed?(filename)
        map = maps.map_of?(filename) || return "a position in #{filename}, whose lines moved in unknown ways"

        failure = nil
        mapped = string.gsub(/\b(line|scopeLine): (\d+)/) do |match|
          line_number = $~[2].to_i
          if old_line = map.unmap?(line_number)
            "#{$~[1]}: #{old_line}"
          else
            failure ||= "a position on an edited line of #{filename}"
            match
          end
        end
        failure || mapped.to_slice
      end

      # The file of the metadata node in *slot*: its own `file:`, a
      # location's scope's, or a file node's own name.
      private def filename_of(slot : Int32, string : String) : String?
        file_slot =
          if scope = @scope_slot_by_location_slot[slot]?
            @file_slot_by_slot[scope]?
          else
            @file_slot_by_slot[slot]?
          end
        file_slot ? @filename_by_file_slot[file_slot]? : nil
      end

      # Maps the `file:line:column` texts that end a string constant, the
      # same texts `DwarfPatcher#patch_messages` rewrites in the object.
      private def map_message_line(line : Bytes) : Bytes | String
        return line if @list_of_message_patterns.empty?
        maps = @maps || return line
        output = nil
        @list_of_message_patterns.each do |(pattern, filename)|
          source = output || line
          search_from = 0
          written_until = 0
          rewritten = IO::Memory.new
          changed = false
          while found = index_of(source, pattern, search_from)
            line_start = found + pattern.size
            search_from = line_start
            line_end = digits_end(source, line_start)
            next if line_end == line_start || line_end >= source.size || source[line_end] != ':'.ord
            column_end = digits_end(source, line_end + 1)
            next unless column_end > line_end + 1 && ends_string?(source, column_end)
            map = maps.map_of?(filename) || return "a message in #{filename}, whose lines moved in unknown ways"
            line_number = String.new(source[line_start, line_end - line_start]).to_i
            old_line = map.unmap?(line_number) || return "a message on an edited line of #{filename}"
            rewritten.write(source[written_until, line_start - written_until])
            rewritten << old_line
            written_until = line_end
            changed = true
          end
          if changed
            rewritten.write(source[written_until, source.size - written_until])
            output = rewritten.to_slice
          end
        end
        output || line
      end

      # Whether a NUL that ends a string constant (`\00` in the text)
      # follows *position*.
      private def ends_string?(source : Bytes, position : Int32) : Bool
        position + 3 <= source.size && source[position] == '\\'.ord && source[position + 1] == '0'.ord && source[position + 2] == '0'.ord
      end

      private def metadata_line?(line : Bytes) : Bool
        line.size > 1 && line[0] == '!'.ord && '0'.ord <= line[1] <= '9'.ord
      end

      private def metadata_slot(string : String) : Int32?
        finish = string.index(' ') || return nil
        string[1...finish].to_i?
      end

      private def reference_field(string : String, name : String) : Int32?
        marker = "#{name}: !"
        start = string.index(marker) || return nil
        start += marker.size
        finish = start
        while finish < string.size && string[finish].ascii_number?
          finish += 1
        end
        string[start...finish].to_i?
      end

      # The value of a string field of a metadata node, unescaped.
      private def field_string(string : String, name : String) : String?
        marker = "#{name}: \""
        start = string.index(marker) || return nil
        start += marker.size
        finish = string.index('"', start) || return nil
        unescape_ir_string(string[start...finish])
      end

      # LLVM prints a byte outside printable ASCII, a quote or a backslash
      # as `\XX`.
      private def unescape_ir_string(escaped : String) : String
        return escaped unless escaped.includes?('\\')
        String.build do |io|
          bytes = escaped.to_slice
          index = 0
          while index < bytes.size
            if bytes[index] == '\\'.ord && index + 2 < bytes.size && (value = String.new(bytes[index + 1, 2]).to_u8?(16))
              io.write_byte(value)
              index += 3
            else
              io.write_byte(bytes[index])
              index += 1
            end
          end
        end
      end

      # *text* as LLVM prints it inside `c"..."`.
      private def escaped_ir_string(text : String) : String?
        String.build do |io|
          text.each_byte do |byte|
            if 0x20 <= byte <= 0x7e && byte != '"'.ord && byte != '\\'.ord
              io.write_byte(byte)
            else
              io << '\\' << byte.to_s(16, upcase: true).rjust(2, '0')
            end
          end
        end
      end

      private def contains?(source : Bytes, pattern : Bytes) : Bool
        !index_of(source, pattern, 0).nil?
      end

      private def index_of(source : Bytes, pattern : Bytes, start : Int32) : Int32?
        position = start
        while position + pattern.size <= source.size
          candidate = source[position, source.size - position].index(pattern[0]) || return nil
          position += candidate
          return nil if position + pattern.size > source.size
          return position if source[position, pattern.size] == pattern
          position += 1
        end
        nil
      end

      private def digits_end(source : Bytes, start : Int32) : Int32
        position = start
        while position < source.size && '0'.ord <= source[position] <= '9'.ord
          position += 1
        end
        position
      end
    end

    # Patches the main module's cached *object_filename* with *maps*.
    # Returns the patched bytes, or why the object cannot be patched.
    def self.patch_object(object_filename : String, maps : Maps) : Bytes | String
      return "its object file is missing" unless File.file?(object_filename)
      bytes = File.read(object_filename).to_slice
      DwarfPatcher.new(maps).patch(ObjectFile.parse(bytes)).bytes
    rescue refusal : Refusal
      refusal.message || "refused"
    rescue error : IO::Error | IndexError
      "the object file could not be read: #{error.message}"
    end
  end
end
