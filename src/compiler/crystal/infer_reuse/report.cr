module Crystal::InferReuse
  # What a build child decided, written as JSON to the file named by
  # `CRYSTAL_INFER_REUSE_REPORT` (nothing when it is unset). Each build
  # overwrites the report of the build before.
  struct Report
    include JSON::Serializable

    getter? reused : Bool
    getter reason : String
    # The process that becomes the build server when this build succeeds.
    getter server_pid : Int64 = ::Process.pid
    property retype_seconds : Float64? = nil
    property changed_methods : Int32? = nil
    property added_methods : Int32? = nil
    property removed_methods : Int32? = nil
    property candidate_calls : Int32? = nil
    property candidate_seconds : Float64? = nil
    property replayed_expansions : Int32? = nil
    property retyped_instances : Int32? = nil
    property new_typed_defs : Int32? = nil
    # Programs a macro ran (`run`) that were run again, and how long that took.
    property program_runs : Int32? = nil
    property program_run_seconds : Float64? = nil
    property build_child_footprint_bytes : UInt64? = nil
    property verify_seconds : Float64? = nil
    property verified_defs : Int32? = nil
    property verify_differences : Int32? = nil
    # Set when the program was loaded from a snapshot (`InferPersist`).
    property snapshot_load_seconds : Float64? = nil
    property snapshot_bytes : Int64? = nil

    def initialize(@reused, @reason)
    end

    def write : Nil
      filename = ENV[REPORT_VARIABLE]?.presence || return
      File.write(filename, to_json)
    end
  end

  # The physical footprint of a process in bytes, as Activity Monitor shows
  # it (macOS only; `nil` elsewhere).
  module Footprint
    {% if flag?(:darwin) %}
      lib LibProc
        RUSAGE_INFO_V4 = 4

        # `struct rusage_info_v4`: a 16-byte UUID, then 64-bit counters.
        struct RusageInfoV4
          uuid : UInt8[16]
          counters : UInt64[40]
        end

        # The same binding as `LibDarwinProcessUsage` (gc_tuning.cr): one C
        # function may be bound with one signature only.
        fun proc_pid_rusage(pid : Int32, flavor : Int32, buffer : Void*) : Int32
      end

      PHYS_FOOTPRINT_INDEX              =  7
      LIFETIME_MAX_PHYS_FOOTPRINT_INDEX = 28

      def self.of(pid : Int) : UInt64?
        info = LibProc::RusageInfoV4.new
        return nil unless LibProc.proc_pid_rusage(pid.to_i32, LibProc::RUSAGE_INFO_V4, pointerof(info).as(Void*)) == 0
        info.counters[PHYS_FOOTPRINT_INDEX]
      end

      def self.lifetime_max_of(pid : Int) : UInt64?
        info = LibProc::RusageInfoV4.new
        return nil unless LibProc.proc_pid_rusage(pid.to_i32, LibProc::RUSAGE_INFO_V4, pointerof(info).as(Void*)) == 0
        info.counters[LIFETIME_MAX_PHYS_FOOTPRINT_INDEX]
      end
    {% else %}
      def self.of(pid : Int) : UInt64?
        nil
      end

      def self.lifetime_max_of(pid : Int) : UInt64?
        nil
      end
    {% end %}
  end
end
