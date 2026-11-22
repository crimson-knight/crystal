require "json"

module Crystal
  # The numbers an incremental build keeps from the build before it, so that
  # the code generated for a module is the same in both builds unless
  # something the module itself uses changed.
  #
  # Two things are kept, in `FILENAME` in the cache directory of the program:
  #
  # * The id of every type (see `LLVMId`). A type keeps its id; a type that
  #   is new gets an id after all the kept ones.
  # * How many functions each bitcode part of a spilled module holds (see
  #   `ModuleSpill`). A module is cut into parts at the same functions again.
  #
  # Neither is ever trusted for correctness: any kept number that cannot be
  # used is replaced, and whether an object file is reused is still decided
  # by comparing bitcode.
  class StableNumbering
    include JSON::Serializable

    FILENAME = "stable_numbering.json"

    # The id of every type, by `LLVMId.stable_key`.
    property type_ids_by_stable_key : Hash(String, Int32) = {} of String => Int32

    # The number of functions in each part of a spilled module, by module name.
    property list_of_part_fun_counts_by_module_name : Hash(String, Array(Int32)) = {} of String => Array(Int32)

    def initialize
    end

    # The numbering the last build left in *cache_dir*, or an empty one.
    def self.load(cache_dir : String) : StableNumbering
      path = File.join(cache_dir, FILENAME)
      return new unless File.file?(path)

      from_json(File.read(path))
    rescue JSON::ParseException | IO::Error
      new
    end

    # Writes this numbering to *cache_dir*. The file is replaced in one step,
    # so a build that is stopped leaves the old or the new numbering.
    def save(cache_dir : String) : Nil
      Dir.mkdir_p(cache_dir)
      path = File.join(cache_dir, FILENAME)
      pending_path = "#{path}.#{Process.pid}.tmp"
      File.write(pending_path, to_json)
      File.rename(pending_path, path)
    rescue IO::Error
      # The numbering only saves work in the next build.
      pending_path.try { |pending| File.delete?(pending) }
    end
  end

  class Program
    # Set by the compiler for an incremental build: the numbering of the
    # build before it, updated by code generation with the numbers of this
    # build. While it is set, local LLVM values are unnamed (their names
    # carry program-wide counters such as `__temp_123`).
    property stable_numbering : StableNumbering?
  end
end
