require "json"

module Crystal::Watch
  # Lets another program (an editor, an AI coding agent) tell `crystal watch`
  # and `crystal run` when to build, through files in `.crystal-watch/` in
  # the project:
  #
  # * `hold`: while it exists the watcher doesn't build; changes pile up.
  #   An agent creates it before editing (`crystal watch hold`) and removes
  #   it when done (`crystal watch release`), so the many intermediate states
  #   of a multi-file edit aren't compiled. A hold that wasn't renewed for
  #   `HOLD_TIMEOUT` is ignored, so a forgotten one doesn't stop builds.
  # * `request`: writing a token to it asks the watcher to build what changed
  #   (or nothing, if nothing did) and report back (`crystal watch build`).
  # * `status.json`: written by the watcher after each step: its state, the
  #   number of the last build, the last request it answered and the errors
  #   of the last build.
  module Coordination
    DIR          = ".crystal-watch"
    HOLD_TIMEOUT = 10.minutes

    def self.dir(root : String) : String
      File.join(root, DIR)
    end

    def self.hold_file(root : String) : String
      File.join(dir(root), "hold")
    end

    def self.request_file(root : String) : String
      File.join(dir(root), "request")
    end

    def self.status_file(root : String) : String
      File.join(dir(root), "status.json")
    end

    # Creates the directory, ignored by git.
    def self.setup(root : String) : Nil
      Dir.mkdir_p(dir(root))
      gitignore = File.join(dir(root), ".gitignore")
      File.write(gitignore, "*\n") unless File.exists?(gitignore)
    end

    def self.hold(root : String, reason : String) : Nil
      setup(root)
      File.write(hold_file(root), reason)
    end

    def self.release(root : String) : Nil
      File.delete?(hold_file(root))
    end

    # The reason of the hold in effect, or `nil`.
    def self.held?(root : String) : String?
      info = File.info?(hold_file(root))
      return nil unless info
      return nil if Time.utc - info.modification_time > HOLD_TIMEOUT

      reason = File.read(hold_file(root)) rescue ""
      reason.presence || "held"
    end

    def self.request(root : String, token : String) : Nil
      setup(root)
      File.write(request_file(root), token)
    end

    def self.requested(root : String) : String?
      (File.read(request_file(root)) rescue nil).try(&.strip.presence)
    end

    struct Status
      include JSON::Serializable

      # `compiling`, `held`, `ok` or `failed`.
      property state : String
      # Number of the last finished build.
      property build : Int32
      # The last request token answered.
      property request : String?
      property pid : Int64
      property updated_at : Time
      property message : String?
      # Errors of the last build, without colors.
      property errors : String?

      def initialize(@state, @build, @request, @pid, @updated_at, @message = nil, @errors = nil)
      end

      def finished? : Bool
        state.in?("ok", "failed")
      end
    end

    def self.write_status(root : String, status : Status) : Nil
      setup(root)
      path = status_file(root)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, status.to_pretty_json)
      File.rename(temp, path)
    rescue IO::Error
      # Best effort: never fail a build because of the status file
    end

    def self.read_status(root : String) : Status?
      Status.from_json(File.read(status_file(root)))
    rescue IO::Error | JSON::ParseException
      nil
    end
  end
end
