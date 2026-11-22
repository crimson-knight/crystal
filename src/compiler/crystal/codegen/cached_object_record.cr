require "json"
require "llvm"

module Crystal
  # The content hash of a module's LLVM bitcode: what decides whether the
  # object file an earlier build left for the module is reused.
  #
  # The hash is BLAKE3 with a 256-bit result, from LLVM (15 and later). With
  # an older LLVM there is no hash, and the bitcode itself is compared with
  # the cached bitcode file.
  module BitcodeHash
    # The hash of the bitcode of one module part, or `nil` without BLAKE3.
    def self.of_part(bitcode : Bytes) : String?
      {% if LibLLVM::IS_LT_150 %}
        nil
      {% else %}
        LLVM::Blake3.hexdigest(bitcode)
      {% end %}
    end

    # The hash of a whole module: one hash over the hashes of its parts, in
    # the order the parts are linked. A module that stayed in memory is one
    # part. `nil` without BLAKE3.
    def self.of_module(list_of_part_hashes : Array(String)) : String?
      {% if LibLLVM::IS_LT_150 %}
        nil
      {% else %}
        hasher = LLVM::Blake3.new
        hasher.update("#{list_of_part_hashes.size} parts\n".to_slice)
        list_of_part_hashes.each do |part_hash|
          hasher.update(part_hash.to_slice)
          hasher.update("\n".to_slice)
        end
        hasher.hexfinal
      {% end %}
    end
  end

  # What the cache directory knows about the object files of one compilation
  # unit: the hash of the bitcode they were built from. It is the file
  # `<unit>.hash` next to the unit's object file.
  #
  # The record is written once the object files are in place, and deleted
  # before anything changes the unit's object or bitcode files. A record
  # therefore describes the files beside it for as long as it is there, in a
  # cache directory only this compiler writes to. The stamps (size and
  # modification time) cover a compiler without records writing to the same
  # directory: the files it replaces no longer match the record.
  struct CachedObjectRecord
    include JSON::Serializable

    FILE_EXTENSION = ".hash"

    # The size and modification time of a file.
    struct FileStamp
      include JSON::Serializable

      getter byte_size : Int64
      getter modified_at_unix_ns : Int64

      def initialize(@byte_size, @modified_at_unix_ns)
      end

      # The stamp of the file named *filename*, or `nil` when there is no
      # such file.
      def self.of?(filename : String) : FileStamp?
        info = File.info?(filename)
        return nil unless info && info.file?

        new(info.size, info.modification_time.to_unix_ns.to_i64)
      end
    end

    # One part of the module's bitcode: its hash and its cached file.
    struct BitcodePart
      include JSON::Serializable

      getter content_hash : String
      getter file_stamp : FileStamp

      def initialize(@content_hash, @file_stamp)
      end
    end

    # The hash of the module's bitcode (`BitcodeHash.of_module`).
    getter module_hash : String

    # The module's parts, in the order they are linked.
    getter list_of_bitcode_parts : Array(BitcodePart)

    # The stamps of the unit's object files, in their order.
    getter list_of_object_stamps : Array(FileStamp)

    # A name no other record has: two records are equal only when they are
    # the same record.
    getter written_as : String

    def initialize(@module_hash, @list_of_bitcode_parts, @list_of_object_stamps, @written_as)
    end

    # The record in the file named *filename*, or `nil` when there is none
    # that can be read.
    def self.read?(filename : String) : CachedObjectRecord?
      from_json(File.read(filename))
    rescue File::Error | JSON::ParseException
      nil
    end

    # Writes the record of the objects in *list_of_object_filenames*, built
    # from the bitcode files in *list_of_bitcode_filenames*, whose contents
    # hash to *list_of_part_hashes*. Without a hash, or when one of the
    # files is missing, no record is left.
    def self.write(filename : String, list_of_part_hashes : Array(String),
                   list_of_bitcode_filenames : Array(String), list_of_object_filenames : Array(String)) : Nil
      File.delete?(filename)
      module_hash = BitcodeHash.of_module(list_of_part_hashes)
      return unless module_hash && list_of_part_hashes.size == list_of_bitcode_filenames.size

      list_of_bitcode_parts = [] of BitcodePart
      list_of_part_hashes.each_with_index do |part_hash, part_index|
        file_stamp = FileStamp.of?(list_of_bitcode_filenames[part_index])
        return unless file_stamp

        list_of_bitcode_parts << BitcodePart.new(part_hash, file_stamp)
      end

      list_of_object_stamps = [] of FileStamp
      list_of_object_filenames.each do |object_filename|
        object_stamp = FileStamp.of?(object_filename)
        return unless object_stamp && object_stamp.byte_size > 0

        list_of_object_stamps << object_stamp
      end

      written_as = "#{Process.pid}-#{Time.utc.to_unix_ns}-#{Random::Secure.hex(8)}"
      record = new(module_hash, list_of_bitcode_parts, list_of_object_stamps, written_as)
      # Renamed into place: a reader finds a whole record or none.
      temporary_filename = "#{filename}.#{Process.pid}.tmp"
      File.write(temporary_filename, record.to_json)
      File.rename(temporary_filename, filename)
    end

    # Whether the files named *list_of_object_filenames* are the object
    # files this record was written for.
    def describes_objects?(list_of_object_filenames : Array(String)) : Bool
      return false unless list_of_object_filenames.size == @list_of_object_stamps.size

      list_of_object_filenames.each_with_index.all? do |(object_filename, object_index)|
        object_stamp = FileStamp.of?(object_filename)
        !object_stamp.nil? && object_stamp.byte_size > 0 && object_stamp == @list_of_object_stamps[object_index]
      end
    end
  end
end
