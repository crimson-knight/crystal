require "json"
require "socket"
require "crystal/digest/sha1"
require "./infer_reuse/*"

# Type-inference reuse between builds (`CRYSTAL_INFER_REUSE=1` with
# `crystal build --incremental`).
#
# A build server keeps the program of the last successful build as it was
# right after type inference. When the next build changes only method
# bodies, a forked copy of the server re-types the instances of those methods
# and generates code from the program it already has; any other change, or
# anything the reuse cannot prove unchanged, types the whole program again
# in a fresh compiler process, as a build without the server would.
#
# Processes, for one build:
#
# * the client: `crystal build ...` as the user ran it. It sends its argument
#   list, working directory and environment to the server and prints what the
#   build prints (`Client`).
# * the server: holds the typed program, or nothing yet (`Server`). It forks a
#   *build child* for each request and relays the child's output.
# * the build child: re-types the edit in its copy of the program (`Retyper`)
#   or execs a fresh compiler (`Server#run_fresh_build`). Either way it then
#   forks a *code generation child*, which continues the ordinary build from
#   the end of type inference, and waits for it. When that build succeeds the
#   build child becomes the server for the next build and the old server
#   exits; when it fails, the old server keeps its program.
#
# Code generation therefore never runs in a process whose program is kept,
# and the memory releases code generation makes stay on.
module Crystal::InferReuse
  # The environment variable that turns the build server on.
  ENABLE_VARIABLE = "CRYSTAL_INFER_REUSE"
  # Set to `1` to type the whole program again after a reuse and fail the
  # build when the reused typing differs (see `TypedProgramDigest`).
  VERIFY_VARIABLE = "CRYSTAL_INFER_REUSE_VERIFY"
  # A JSON file the build child writes its decision and counts to.
  REPORT_VARIABLE = "CRYSTAL_INFER_REUSE_REPORT"
  # Seconds an idle server waits for its next build before it exits.
  IDLE_VARIABLE = "CRYSTAL_INFER_SERVER_IDLE_SECONDS"
  # Internal: the server's listening socket and status pipe, for a compiler
  # process the server started (`Server#run_fresh_build`).
  HANDOFF_VARIABLE = "CRYSTAL_INFER_SERVER_HANDOFF"
  # Internal: where the fresh type check of a verification writes its digest.
  DIGEST_VARIABLE = "CRYSTAL_INFER_REUSE_DIGEST"

  # Type inference reads the environment in two ways: through macros (`env`,
  # recorded in `SourceRecord` and compared there) and through the
  # compiler's own settings below. Two builds may reuse one typed program
  # only when these read the same; the rest of the environment reaches only
  # code generation and linking, which every build runs with its own.
  COMPARED_VARIABLES = {"HOME", "XDG_CACHE_HOME", "LOCALAPPDATA", "USE_PCRE1", "MACOSX_DEPLOYMENT_TARGET"}

  # The compiler's own variables that may differ between two builds that
  # reuse one typed program.
  PER_BUILD_VARIABLES = {
    "CRYSTAL_WORKERS", REPORT_VARIABLE, VERIFY_VARIABLE, "CRYSTAL_IR_SKIP_REPORT", "CRYSTAL_IR_SKIP_VERIFY",
    # How a type-inference snapshot is written (`InferPersist`), not what it holds.
    "CRYSTAL_INFER_PERSIST_SAVE",
  }

  DEFAULT_IDLE_SECONDS = 1800

  # The handoff this process got from the server that started it, taken out
  # of the environment once so that no compiler this process starts sees it.
  class_getter handoff : Handoff? = Handoff.take_from_env

  # Whether `crystal build` with *arguments* (after `build`) is a client of
  # the build server.
  def self.client?(arguments : Array(String)) : Bool
    return false unless ENV[ENABLE_VARIABLE]? == "1"
    return false if handoff
    return false if ENV[DIGEST_VARIABLE]?
    arguments.includes?("--incremental") && !arguments.includes?("--no-codegen")
  end

  # The socket of the server for this compiler executable, working directory,
  # argument list and cache directory. A different compiler, or a different
  # build of the same compiler, gets a server of its own.
  def self.socket_path(argv : Array(String)) : String
    executable = ::Process.executable_path || "crystal"
    info = File.info?(executable)
    key = String.build do |io|
      io << executable << '\0'
      io << info.try(&.size) << '\0' << info.try(&.modification_time.to_unix_ns) << '\0'
      io << Dir.current << '\0'
      io << ENV["CRYSTAL_CACHE_DIR"]? << '\0'
      io << ENV["CRYSTAL_PATH"]? << '\0'
      argv.each { |argument| io << argument << '\0' }
    end
    digest = Crystal::Digest::SHA1.hexdigest(key)
    # Unix socket paths are limited to about 100 bytes: keep it in /tmp.
    "/tmp/crystal-infer-#{digest[0, 20]}.sock"
  end

  # The part of a build's environment type inference reads outside macros:
  # `COMPARED_VARIABLES` and the compiler's `CRYSTAL_` variables, without
  # the per-build ones.
  def self.comparable_env(env : Hash(String, String)) : Hash(String, String)
    env.select do |name, _|
      next false if PER_BUILD_VARIABLES.includes?(name)
      COMPARED_VARIABLES.includes?(name) || name.starts_with?("CRYSTAL_")
    end
  end

  # The listening socket and status pipe a fresh compiler process got from
  # the server that started it.
  record Handoff, listening_fd : Int32, status_fd : Int32, socket_path : String do
    def self.take_from_env : Handoff?
      value = ENV.delete(HANDOFF_VARIABLE) || return nil
      listening, status, socket_path = value.split(',', 3)
      Handoff.new(listening.to_i, status.to_i, socket_path)
    end
  end
end
