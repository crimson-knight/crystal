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

    # A request to the watcher: build the main program (`build`), or build
    # the spec program of *files* (`spec`) and answer in `response_file`.
    struct Request
      include JSON::Serializable

      getter token : String
      getter kind : String = "build"
      getter files : Array(String) = [] of String

      def initialize(@token, @kind = "build", @files = [] of String)
      end
    end

    def self.request(root : String, token : String) : Nil
      request(root, Request.new(token))
    end

    def self.request(root : String, request : Request) : Nil
      setup(root)
      File.write(request_file(root), request.to_json)
    end

    # The last request made, `nil` if none.
    def self.read_request(root : String) : Request?
      raw = (File.read(request_file(root)) rescue nil).try(&.strip.presence)
      return nil unless raw
      raw.starts_with?('{') ? Request.from_json(raw) : Request.new(raw)
    rescue JSON::ParseException
      nil
    end

    def self.requested(root : String) : String?
      read_request(root).try(&.token)
    end

    # The answer to a `spec` request.
    struct Response
      include JSON::Serializable

      property ok : Bool
      property binary : String?
      property message : String
      property errors : String?
      # Locations (`file:line`) of the examples affected by what changed since
      # the previous build of the same specs; `nil` when unknown (the spec
      # program was compiled from scratch).
      property affected : Array(String)?

      def initialize(@ok, @binary, @message, @errors = nil, @affected = nil)
      end
    end

    def self.response_file(root : String, token : String) : String
      File.join(dir(root), "response-#{token}.json")
    end

    def self.write_response(root : String, token : String, response : Response) : Nil
      path = response_file(root, token)
      temp = "#{path}.tmp"
      File.write(temp, response.to_json)
      File.rename(temp, path)
    rescue IO::Error
    end

    # Takes the response to the request *token*, `nil` while there's none.
    def self.take_response(root : String, token : String) : Response?
      path = response_file(root, token)
      response = Response.from_json(File.read(path))
      File.delete?(path)
      response
    rescue IO::Error | JSON::ParseException
      nil
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
      # The program file built, and where its executable is.
      property main : String?
      property binary : String?

      def initialize(@state, @build, @request, @pid, @updated_at, @message = nil, @errors = nil, @main = nil, @binary = nil)
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
