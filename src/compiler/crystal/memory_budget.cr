module Crystal
  # A limit on the memory one compilation should use, from
  # `--memory-budget SIZE` or the `CRYSTAL_MEMORY_BUDGET` environment
  # variable, for a build that runs in a container or runner with a fixed
  # amount of memory.
  #
  # The compiler's memory peaks during type inference and IR generation
  # (Grant300: 4.65 GB and 5.4 GB with the defaults, notes/peak-4gb.md). A
  # budget changes what the defaults trade for speed:
  #
  # * The garbage collector lets its heap grow as usual while the heap is
  #   small, and collects four times as often once the heap passes
  #   `HEAP_SHARE_PERCENT` of the budget, so the heap stays closer to the
  #   live data (more collection time, a smaller heap).
  # * IR generation collects four times as often for the whole stage: it
  #   allocates mostly short-lived objects, and every collection lets it
  #   reuse memory instead of mapping free blocks again.
  # * At most `RESIDENT_IR_SHARE` of the budget of LLVM IR stays in memory
  #   during IR generation.
  # * The object file workers share the budget less what the compiler
  #   process itself holds in that stage.
  #
  # A budget is a ceiling: it never raises a setting given explicitly on
  # the command line.
  struct MemoryBudget
    # The heap size, as a share of the budget, from which the collector
    # collects more often.
    HEAP_SHARE_PERCENT = 70

    # The free-space divisor (see `GCTuning`) once the heap has passed its
    # share of the budget, and during IR generation.
    TIGHT_FREE_SPACE_DIVISOR = 40_u64

    # The share of the budget, in parts, that LLVM IR in memory may take
    # during IR generation, and the bounds of that amount in megabytes.
    RESIDENT_IR_SHARE      = 32
    MINIMUM_RESIDENT_IR_MB = 64

    # What the compiler process holds while the object file workers run.
    OBJECT_STAGE_RESERVE_BYTES = 256_i64 * 1024 * 1024

    getter bytes : Int64

    def initialize(@bytes : Int64)
    end

    # Reads a size such as `4G`, `4096M`, `512m` or `4096` (megabytes).
    def self.parse(text : String) : MemoryBudget
      match = text.strip.match(/\A(\d+(?:\.\d+)?)\s*([kKmMgG]?)[bB]?\z/) || raise Error.new("Invalid memory budget: #{text} (for example 4G or 4096M)")
      amount = match[1].to_f64
      scale = case match[2].downcase
              when "k" then 1024_i64
              when "g" then 1024_i64 ** 3
              else          1024_i64 ** 2
              end
      bytes = (amount * scale).to_i64
      raise Error.new("Invalid memory budget: #{text} (at least 256M)") if bytes < 256_i64 * 1024 * 1024
      new(bytes)
    end

    def megabytes : Int64
      @bytes // (1024 * 1024)
    end

    # The heap size from which the collector collects more often.
    def tight_heap_bytes : Int64
      @bytes * HEAP_SHARE_PERCENT // 100
    end

    def resident_ir_megabytes : Int32
      (megabytes // RESIDENT_IR_SHARE).clamp(MINIMUM_RESIDENT_IR_MB.to_i64, Compiler::DEFAULT_RESIDENT_IR_MEGABYTES.to_i64).to_i32
    end

    def object_stage_bytes : Int64
      {@bytes - OBJECT_STAGE_RESERVE_BYTES, @bytes // 2}.max
    end

    # Lowers the settings of *compiler* that are above what this budget
    # allows, and tells the collector about the budget.
    def apply(compiler : Compiler) : Nil
      compiler.memory_budget = self
      if compiler.resident_ir_megabytes <= 0 || compiler.resident_ir_megabytes > resident_ir_megabytes
        compiler.resident_ir_megabytes = resident_ir_megabytes
      end
      worker_bytes = compiler.codegen_worker_memory_budget_bytes
      if worker_bytes.nil? || worker_bytes > object_stage_bytes
        compiler.codegen_worker_memory_budget_bytes = object_stage_bytes
      end
      GCTuning.tighten_above(tight_heap_bytes, TIGHT_FREE_SPACE_DIVISOR)
    end
  end
end
