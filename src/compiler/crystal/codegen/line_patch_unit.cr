require "json"
require "./line_patch_dwarf"
require "./cached_object_record"

module Crystal::LinePatch
  # The patched object of a module, waiting next to the cached one until
  # the object stage puts it in place (`Compiler::CompilationUnit`).
  class PatchedObject
    # The patched file, or `nil` when no line of the object moved: the
    # cached object stays as it is.
    getter pending_filename : String?
    # What the manifest and the hash record say the object was built from:
    # the recorded part hashes combined with the hash of the patched object.
    getter list_of_part_hashes : Array(String)
    getter changed_row_count : Int32
    getter changed_attribute_count : Int32

    def initialize(@pending_filename, @list_of_part_hashes, @changed_row_count, @changed_attribute_count)
    end

    def unchanged? : Bool
      @pending_filename.nil?
    end

    # Deletes the patched file when it is not used.
    def discard : Nil
      @pending_filename.try { |filename| File.delete?(filename) }
    end
  end

  # Makes the patched objects of a build, from the cached objects.
  class UnitPatcher
    PENDING_EXTENSION = ".linepatch"

    getter maps : Maps

    # *object_filename_of* gives the cached object file of a module name.
    def initialize(@maps : Maps, @object_filename_of : Proc(String, String))
    end

    # Patches the cached object of the module *unit_name*, built from the
    # bitcode *recorded_unit* records. Returns the patched object, or why
    # it cannot be patched.
    def patch(unit_name : String, recorded_unit : IrSkip::RecordedUnit) : PatchedObject | String
      object_filename = @object_filename_of.call(unit_name)
      return "its object file is missing" unless File.file?(object_filename)

      bytes = File.read(object_filename).to_slice
      result = DwarfPatcher.new(@maps).patch(ObjectFile.parse(bytes))
      if result.changed_row_count == 0 && result.changed_attribute_count == 0 && result.changed_message_count == 0
        return PatchedObject.new(nil, recorded_unit.list_of_part_hashes, 0, 0)
      end

      object_hash = BitcodeHash.of_part(result.bytes) || return "no hash function"
      list_of_part_hashes = recorded_unit.list_of_part_hashes.map do |part_hash|
        BitcodeHash.of_part("line patch|#{part_hash}|#{object_hash}".to_slice) || return "no hash function"
      end
      pending_filename = "#{object_filename}#{PENDING_EXTENSION}"
      File.write(pending_filename, result.bytes)
      PatchedObject.new(pending_filename, list_of_part_hashes, result.changed_row_count, result.changed_attribute_count)
    rescue refusal : Refusal
      refusal.message || "refused"
    rescue error : IO::Error | IndexError
      "the object file could not be read: #{error.message}"
    end
  end

  # Verification (`CRYSTAL_LINE_PATCH_VERIFY=1`): every module is generated
  # and compiled as without line patching, and each module that would have
  # been patched is patched from its cached object as well. The two objects
  # must have the same machine code, the same data (where cast messages keep
  # their `file:line:column`) and the same `llvm-dwarfdump --debug-line
  # --debug-info` output.
  module Verification
    # One patched object and the object compiled fresh for the same module.
    struct Check
      include JSON::Serializable

      getter unit_name : String
      getter patched_filename : String
      getter fresh_filename : String

      def initialize(@unit_name, @patched_filename, @fresh_filename)
      end
    end

    # Whether verification is on.
    def self.enabled? : Bool
      ENV["CRYSTAL_LINE_PATCH_VERIFY"]? == "1"
    end

    # The `llvm-dwarfdump` that verification runs: `CRYSTAL_LLVM_DWARFDUMP`,
    # the one next to `llvm-config` (`LLVM_CONFIG`), or one on the `PATH`.
    def self.dwarfdump : String?
      if explicit = ENV["CRYSTAL_LLVM_DWARFDUMP"]?.presence
        return explicit
      end
      if llvm_config = ENV["LLVM_CONFIG"]?.presence
        candidate = File.join(File.dirname(llvm_config), "llvm-dwarfdump")
        if found = Process.find_executable(candidate)
          return found
        end
      end
      if found = Process.find_executable("llvm-dwarfdump")
        return found
      end
      {"21", "20", "19", "18"}.each do |version|
        if found = Process.find_executable("llvm-dwarfdump-#{version}")
          return found
        end
      end
      nil
    end

    # Compares each patched object with the fresh one. Returns the
    # differences found, one line per module; deletes the patched files.
    def self.run(list_of_checks : Array(Check)) : Array(String)
      return [] of String if list_of_checks.empty?
      tool = dwarfdump
      unless tool
        list_of_checks.each { |check| File.delete?(check.patched_filename) }
        return ["llvm-dwarfdump was not found (set CRYSTAL_LLVM_DWARFDUMP)"]
      end

      list_of_failures = [] of String
      list_of_checks.each do |check|
        if failure = compare(tool, check)
          list_of_failures << "#{check.unit_name}: #{failure}"
        end
      ensure
        File.delete?(check.patched_filename)
      end
      list_of_failures
    end

    private def self.compare(tool : String, check : Check) : String?
      patched = ObjectFile.parse(File.read(check.patched_filename).to_slice)
      fresh = ObjectFile.parse(File.read(check.fresh_filename).to_slice)
      return "the machine code differs" unless patched.code_sections == fresh.code_sections
      return "the data differs" unless patched.data_sections == fresh.data_sections

      patched_dump = dump(tool, check.patched_filename)
      fresh_dump = dump(tool, check.fresh_filename)
      return "llvm-dwarfdump failed" unless patched_dump && fresh_dump
      return nil if patched_dump == fresh_dump

      list_of_patched_lines = patched_dump.lines
      list_of_fresh_lines = fresh_dump.lines
      index = list_of_patched_lines.zip?(list_of_fresh_lines).index { |(patched_line, fresh_line)| patched_line != fresh_line } || 0
      "the debug info differs at dump line #{index + 1}: patched #{list_of_patched_lines[index]?.inspect}, fresh #{list_of_fresh_lines[index]?.inspect}"
    rescue refusal : Refusal
      "an object could not be read: #{refusal.message}"
    end

    # The dump without its first line, which names the file.
    private def self.dump(tool : String, filename : String) : String?
      output = IO::Memory.new
      status = Process.run(tool, ["--debug-line", "--debug-info", filename], output: output, error: Process::Redirect::Close)
      return nil unless status.success?
      output.to_s.lines(chomp: false).skip(1).join
    end
  end
end
