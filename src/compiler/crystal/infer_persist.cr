require "json"
require "./infer_reuse"
require "./infer_persist/*"

# Type-inference reuse from the cache folder, for a fresh compiler process
# (`CRYSTAL_INFER_PERSIST=1` with `crystal build --incremental`).
#
# The build server (`InferReuse`) keeps the typed program in a process. A CI
# runner has no such process: it restores the cache folder and runs a new
# compiler. Here the program, as type inference left it, is written to the
# cache folder after a successful build (`SnapshotWriter`), and the next
# fresh process with the same compiler build, argument list, working
# directory and compiler environment reads it back (`SnapshotReader`) instead
# of typing the whole program. The build server's `InferReuse::Retyper` then
# decides on the edit exactly as it does in the server: it re-types the
# changed methods, or refuses, in which case this process runs itself again
# with loading turned off and types the program fresh.
#
# The snapshot holds the program's objects, not a memory image: its file is
# about a third of the live heap, and loading it gives back the live data of
# the program without the garbage type inference leaves behind. It does not
# make the program smaller: the whole typed program is in memory after the
# load, as after type inference.
module Crystal::InferPersist
  # The environment variable that turns persisted type inference on.
  ENABLE_VARIABLE = "CRYSTAL_INFER_PERSIST"
  # Internal: set by a process that loaded a snapshot whose reuse was
  # refused, for the process it runs to type the program fresh.
  NO_LOAD_VARIABLE = "CRYSTAL_INFER_PERSIST_NO_LOAD"
  # `fork` (the default) writes the snapshot in a forked process while code
  # generation goes on; `sync` writes it before code generation.
  SAVE_MODE_VARIABLE = "CRYSTAL_INFER_PERSIST_SAVE"

  FILENAME = "infer_program.bin"
  MAGIC    = "CRINFP01"
  # The version of the file layout; a file of another version is not read.
  FORMAT_VERSION = 1

  # The class number of strings in a snapshot.
  STRING_CLASS = 0

  # Classes whose objects are written as `nil`: state that only code
  # generation fills in, which the loading process makes again when it needs
  # it (lazy getters on `Program`), and the macro text store, whose texts
  # move into their virtual files.
  DROPPED = %w(Crystal::MacroSourceStore Crystal::LLVMTyper Crystal::LLVMId Crystal::StableNumbering LLVM::TargetMachine)

  class Error < Crystal::Error
  end

  # Whether this process was run again, after a refused reuse, to type the
  # program fresh. Taken out of the environment once.
  class_getter? load_disabled : Bool = !ENV.delete(NO_LOAD_VARIABLE).nil?

  def self.enabled? : Bool
    ENV[ENABLE_VARIABLE]? == "1"
  end

  # What a snapshot starts with: what must match before anything is loaded.
  struct Header
    include JSON::Serializable

    getter format_version : Int32
    getter compiler_identity : String
    getter list_of_arguments : Array(String)
    getter working_directory : String
    getter env : Hash(String, String)

    def initialize(@list_of_arguments, @working_directory, @env)
      @format_version = FORMAT_VERSION
      @compiler_identity = IrSkip.compiler_identity
    end

    def self.current(list_of_arguments : Array(String)) : Header
      new(list_of_arguments, Dir.current, InferReuse.comparable_env(ENV.to_h))
    end

    # Why a build with *current* can't use a snapshot with this header, or
    # `nil` when it may try.
    def mismatch(current : Header) : String?
      return "the snapshot has another file format" unless format_version == current.format_version
      return "the snapshot was written by another compiler build" unless compiler_identity == current.compiler_identity
      return "the argument list differs" unless list_of_arguments == current.list_of_arguments
      return "the working directory differs" unless working_directory == current.working_directory
      unless env == current.env
        names = (env.keys + current.env.keys).uniq.reject { |name| env[name]? == current.env[name]? }
        return "the environment differs (#{names.join(", ")})"
      end
      nil
    end
  end

  # The objects a snapshot holds: the kept program and the location tables
  # its nodes need.
  class Roots
    getter kept : InferReuse::KeptProgram
    getter location_tables : Location::Tables

    def initialize(@kept, @location_tables)
    end
  end
end
