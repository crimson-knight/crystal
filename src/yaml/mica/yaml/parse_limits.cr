module YAML::Mica::YAML
  # Upper bounds on one parse: the input it may read, how deep collections
  # may nest, how many nodes a document may hold, how far aliases may
  # expand, and the work it may do. Every parse in `Mica::YAML` takes them
  # as a required `limits:` argument (there is no default): use a preset
  # (`CONFIG_FILE`, `UNTRUSTED`, `TRUSTED_FILE`) or `ParseLimits.custom`.
  #
  # Every limit is checked before the memory it guards is used: the parser
  # raises `ParseLimitError` naming the limit when the next byte, level,
  # node or alias would pass it.
  #
  # The work allowance follows `Core::WorkBudget`: one unit per input byte,
  # and
  #
  #     allowance = min(base_work + work_per_unit * units, work_ceiling)
  #
  # Scanning charges one operation per byte read plus one per token moved
  # in the token queue, and composing charges one per node and per alias,
  # so only input built to make the scanner re-queue tokens approaches it.
  #
  # ```
  # limits = Mica::YAML::ParseLimits.custom(max_depth: 32)
  # limits.max_input_bytes # => 1_048_576 (from CONFIG_FILE)
  # ```
  struct ParseLimits
    # The largest input a parse can address (offsets are 32-bit).
    MAX_INPUT_BYTES = Int32::MAX.to_i64

    # Bytes of input, all documents of a stream together.
    getter max_input_bytes : Int64
    # Nested sequences and mappings, block and flow.
    getter max_depth : Int32
    # Nodes (scalars, sequences, mappings and aliases) per document, as the
    # node API counts them.
    getter max_nodes : Int64
    # Nodes per document once every alias is replaced by a copy of what it
    # points to (the "billion laughs" bound). The node API never makes
    # those copies; it counts what they would cost and stops here.
    getter max_alias_expansion : Int64
    # Work operations allowed per input byte.
    getter work_per_unit : Int64
    # Work operations allowed regardless of size.
    getter base_work : Int64
    # An absolute cap on work operations, or nil for none.
    getter work_ceiling : Int64?

    def initialize(@max_input_bytes : Int64, @max_depth : Int32, @max_nodes : Int64,
                   @max_alias_expansion : Int64, @work_per_unit : Int64, @base_work : Int64,
                   @work_ceiling : Int64? = nil)
      unless 0 <= @max_input_bytes <= MAX_INPUT_BYTES
        raise ArgumentError.new("max_input_bytes must be between 0 and #{MAX_INPUT_BYTES}")
      end
      raise ArgumentError.new("max_depth must be positive") if @max_depth < 1
      raise ArgumentError.new("max_nodes must be positive") if @max_nodes < 1
      raise ArgumentError.new("max_alias_expansion must be positive") if @max_alias_expansion < 1
      check_not_negative("work_per_unit", @work_per_unit)
      check_not_negative("base_work", @base_work)
      if ceiling = @work_ceiling
        check_not_negative("work_ceiling", ceiling)
      end
    end

    # Returns limits that start from `CONFIG_FILE` and change only the
    # values given.
    def self.custom(*, max_input_bytes : Int64 = CONFIG_FILE.max_input_bytes,
                    max_depth : Int32 = CONFIG_FILE.max_depth,
                    max_nodes : Int64 = CONFIG_FILE.max_nodes,
                    max_alias_expansion : Int64 = CONFIG_FILE.max_alias_expansion,
                    work_per_unit : Int64 = CONFIG_FILE.work_per_unit,
                    base_work : Int64 = CONFIG_FILE.base_work,
                    work_ceiling : Int64? = CONFIG_FILE.work_ceiling) : self
      new(max_input_bytes, max_depth, max_nodes, max_alias_expansion, work_per_unit, base_work, work_ceiling)
    end

    # Returns the work budget these limits allow, with an optional
    # wall-clock *timeout*.
    def work_budget(timeout : Time::Span?) : Core::WorkBudget
      Core::WorkBudget.new(operations_per_unit: @work_per_unit, base_operations: @base_work,
        max_operations: @work_ceiling, timeout: timeout)
    end

    private def check_not_negative(name : String, value : Int64) : Nil
      raise ArgumentError.new("#{name} must not be negative") if value < 0
    end

    # For configuration an application ships or an operator writes
    # (`config/environments/*.yml`, `shard.yml`, CI and deployment files):
    # 1 MiB of input, 128 levels, a million nodes, a million nodes after
    # alias expansion.
    CONFIG_FILE = new(
      max_input_bytes: 1_048_576_i64,
      max_depth: 128,
      max_nodes: 1_000_000_i64,
      max_alias_expansion: 1_000_000_i64,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )

    # For YAML from a sender the program does not control (a request body,
    # an upload): 1 MiB of input, 64 levels, 100,000 nodes, 100,000 nodes
    # after alias expansion.
    UNTRUSTED = new(
      max_input_bytes: 1_048_576_i64,
      max_depth: 64,
      max_nodes: 100_000_i64,
      max_alias_expansion: 100_000_i64,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )

    # For large files the program built itself (data dumps, fixtures,
    # lockfiles of big projects): 256 MiB of input, 1,024 levels.
    TRUSTED_FILE = new(
      max_input_bytes: 268_435_456_i64,
      max_depth: 1_024,
      max_nodes: 100_000_000_i64,
      max_alias_expansion: 100_000_000_i64,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )

    # What libyaml allows: any input up to 2 GiB, any depth memory can
    # hold, no work cap. The standard-library compatibility layer uses
    # these and applies its own nesting and alias checks on top.
    LIBYAML = new(
      max_input_bytes: MAX_INPUT_BYTES,
      max_depth: Int32::MAX,
      max_nodes: Int64::MAX,
      max_alias_expansion: Int64::MAX,
      work_per_unit: Int64::MAX,
      base_work: Int64::MAX,
    )
  end
end
