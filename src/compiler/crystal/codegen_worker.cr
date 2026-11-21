require "json"

module Crystal
  # Compiles LLVM bitcode files to object files in a process of its own.
  #
  # The compiler starts several of these (`crystal internal-codegen-worker`)
  # once IR generation is over and every module has been written to its
  # bitcode file. Each worker reads its settings and then one job per line
  # from its input, holds a single module in memory at a time, and answers
  # each job with one line.
  class CodegenWorker
    # The hidden subcommand of the compiler binary that runs a worker.
    COMMAND = "internal-codegen-worker"

    # The code generation settings of the compiler that started the worker.
    struct Settings
      include JSON::Serializable

      getter target_triple : String
      getter mcpu : String?
      getter mattr : String?
      getter optimization_mode : String
      getter code_model : String

      def initialize(@target_triple, @mcpu, @mattr, @optimization_mode, @code_model)
      end

      def self.from_compiler(compiler : Compiler) : self
        new(
          target_triple: compiler.codegen_target.to_s,
          mcpu: compiler.mcpu,
          mattr: compiler.mattr,
          optimization_mode: compiler.optimization_mode.to_s,
          code_model: compiler.mcmodel.to_s,
        )
      end

      # A compiler that optimizes and emits objects exactly as the one these
      # settings were taken from.
      def to_compiler : Compiler
        compiler = Compiler.new
        compiler.codegen_target = Codegen::Target.new(target_triple)
        compiler.mcpu = mcpu
        compiler.mattr = mattr
        compiler.optimization_mode = Compiler::OptimizationMode.parse(optimization_mode)
        compiler.mcmodel = LLVM::CodeModel.parse(code_model)
        compiler
      end
    end

    # One module to compile: where its bitcode is, where its object file
    # goes, and where to print the optimized IR (`--emit llvm-ir` style dump).
    # `name` and `bitcode_bytesize` are for the pool that hands the job out
    # (`CodegenWorkerPool`): what to call the module in a message, and the
    # size its memory estimate comes from.
    struct Job
      include JSON::Serializable

      getter bitcode_filename : String
      getter object_filename : String
      getter llvm_ir_filename : String?
      getter name : String = ""
      getter bitcode_bytesize : Int64 = 0_i64

      def initialize(@bitcode_filename, @object_filename, @llvm_ir_filename = nil,
                     @name = bitcode_filename, @bitcode_bytesize = 0_i64)
      end
    end

    # The answer to a job. `error_message` is set when the job failed.
    struct Outcome
      include JSON::Serializable

      getter error_message : String?

      def initialize(@error_message = nil)
      end
    end

    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
    end

    # Compiles every job read from the input until the input is closed.
    # Stops at the first failed job, after reporting it.
    def perform : Nil
      settings_line = @input.gets
      return unless settings_line

      compiler = Settings.from_json(settings_line).to_compiler

      while job_line = @input.gets
        outcome = compile(compiler, Job.from_json(job_line))
        @output.puts outcome.to_json
        @output.flush
        break if outcome.error_message
      end
    end

    private def compile(compiler : Compiler, job : Job) : Outcome
      compiler.compile_bitcode_file_to_object(job.bitcode_filename, job.object_filename, job.llvm_ir_filename)
      Outcome.new
    rescue ex
      Outcome.new(error_message: "#{job.bitcode_filename}: #{ex.message} (#{ex.class})")
    end
  end
end
