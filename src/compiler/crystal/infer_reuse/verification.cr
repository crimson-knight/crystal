module Crystal::InferReuse
  # The fresh side of `CRYSTAL_INFER_REUSE_VERIFY=1`: the same build, type
  # checked from scratch by a new compiler process (`--no-codegen`, without
  # `--incremental` so it leaves the incremental cache alone), which writes
  # the digest of its typed program to a temporary file.
  module Verification
    def self.fresh_digest(request : BuildRequest) : TypedProgramDigest
      executable = ::Process.executable_path || raise Error.new("can't find the compiler executable")
      digest_file = File.tempname("crystal-infer-verify", ".json")
      argv = request.argv.reject("--incremental") + ["--no-codegen"]
      env = request.env.dup
      env.delete(ENABLE_VARIABLE)
      env[DIGEST_VARIABLE] = digest_file
      output = IO::Memory.new
      status = ::Process.run(executable, argv, env: env, clear_env: true, chdir: request.working_directory,
        output: ::Process::Redirect::Close, error: output)
      unless status.success?
        raise Error.new("the fresh type check for the verification failed (#{status}):\n#{output}")
      end
      TypedProgramDigest.from_json(File.read(digest_file))
    ensure
      File.delete?(digest_file) if digest_file
    end
  end
end
