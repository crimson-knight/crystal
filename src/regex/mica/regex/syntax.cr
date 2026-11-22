module Regex::Mica::Regex
  # Validates and translates patterns without building a matching program.
  #
  # `check` runs the whole compile front half: the dialect parser, class
  # lowering with case folding, the size preflight and the translation to
  # `Hir`, under the given `CompileLimits`. It is what schema loaders, rule
  # packs and the stdlib shim call to reject a pattern when it is loaded
  # rather than when it is first used.
  #
  # ```
  # limits = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
  # Mica::Regex::Syntax.check("[a-z]+@\\w+", dialect: :crystal, compile_limits: limits).capture_count # => 0
  # Mica::Regex::Syntax.error?("a(?=b)", dialect: :crystal, compile_limits: limits).try(&.message)
  # # => "lookahead is outside the Mica::Regex dialect (see docs/regex.md, \"Excluded constructs\") (byte 1)"
  # ```
  module Syntax
    # The default compile work budget: compile work is linear in the
    # pattern (one operation per byte, node, class range, fold visit and
    # sequence), and a class escape such as `\p{L}` (three bytes, about 650
    # ranges) is the densest construct, so the allowance per byte is wide.
    COMPILE_WORK_BUDGET = Core::WorkBudget.new(operations_per_unit: 4_096, base_operations: 1_000_000)

    # What a successful check found.
    record Report,
      # Capturing groups (the highest group number).
      capture_count : Int32,
      # Named groups in definition order.
      list_of_group_names : Array(Ast::GroupName),
      # The preflight's bound on program states.
      state_estimate : Int64,
      # Bytes charged to the allocation ledger.
      compile_bytes : Int64,
      # Work operations charged.
      operations : Int64

    # Checks *pattern* in *dialect*. Returns a `Report`; raises
    # `SyntaxError` (or its `UnsupportedConstructError` subclass) for a
    # pattern the dialect rejects or leaves out, `CompileLimitError` when a
    # limit trips, and `Mica::WorkBudgetExceededError` or
    # `Mica::DeadlineExceededError` from *meter* (by default a meter on
    # `COMPILE_WORK_BUDGET`).
    def self.check(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                   options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Report
      work_meter = meter || Mica::Regex.stack_object(Core::WorkMeter, COMPILE_WORK_BUDGET)
      ledger = Mica::Regex.stack_object(AllocationLedger, compile_limits.max_compile_bytes)
      charge_fixed_objects(ledger, meter)
      parsed, estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      Translator.translate(parsed, dialect, ledger, work_meter)
      Report.new(parsed.capture_count, parsed.list_of_group_names, estimate, ledger.bytes, work_meter.operations)
    ensure
      ledger.try(&.free_owned_blocks)
    end

    # Returns the error `check` would raise for *pattern*, or nil when the
    # pattern is accepted (like stdlib `Regex.error?`, but returning the
    # positioned `Mica::Error`).
    def self.error?(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                    options : CompileOptions = CompileOptions::None) : Mica::Error?
      check(pattern, dialect: dialect, compile_limits: compile_limits, options: options)
      nil
    rescue error : Mica::Error
      error
    end

    # Parses, checks and translates *pattern*, returning its `Hir`.
    def self.translate(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                       options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Hir::Pattern
      work_meter = meter || Mica::Regex.stack_object(Core::WorkMeter, COMPILE_WORK_BUDGET)
      ledger = Mica::Regex.stack_object(AllocationLedger, compile_limits.max_compile_bytes)
      charge_fixed_objects(ledger, meter)
      parsed, _estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      Translator.translate(parsed, dialect, ledger, work_meter)
    ensure
      ledger.try(&.free_owned_blocks)
    end

    # Compiles *pattern* into the `Program` the engines run: the front half,
    # the translation to `Hir`, and the NFA compiler, all charged to one
    # allocation ledger under *compile_limits*. The compiler's work is
    # bounded by the preflight's state estimate, which is added to the
    # meter's units. `Expression.new` is the public way in.
    def self.compile(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                     options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Program
      work_meter = meter || Mica::Regex.stack_object(Core::WorkMeter, COMPILE_WORK_BUDGET)
      ledger = Mica::Regex.stack_object(AllocationLedger, compile_limits.max_compile_bytes)
      charge_fixed_objects(ledger, meter)
      parsed, estimate = front_half(pattern, dialect, compile_limits, options, ledger, work_meter)
      hir = Translator.translate(parsed, dialect, ledger, work_meter)
      work_meter.add_units(estimate)
      Compiler.compile(hir, estimate, compile_limits, ledger, work_meter)
    ensure
      # The program took the blocks it uses; any left were for a compile
      # that stopped early.
      ledger.try(&.free_owned_blocks)
    end

    # Parses *pattern* into its syntax tree (no class lowering or preflight).
    def self.parse(pattern : String | Bytes, *, dialect : Dialect, compile_limits : CompileLimits,
                   options : CompileOptions = CompileOptions::None, meter : Core::WorkMeter? = nil) : Ast::Pattern
      work_meter = meter || Mica::Regex.stack_object(Core::WorkMeter, COMPILE_WORK_BUDGET)
      ledger = Mica::Regex.stack_object(AllocationLedger, compile_limits.max_compile_bytes)
      charge_fixed_objects(ledger, meter)
      parser = Mica::Regex.stack_object(Parser, pattern_bytes(pattern, dialect, work_meter), options, compile_limits, ledger, work_meter)
      parser.parse
    ensure
      ledger.try(&.free_owned_blocks)
    end

    private def self.front_half(pattern : String | Bytes, dialect : Dialect, limits : CompileLimits,
                                options : CompileOptions, ledger : AllocationLedger,
                                meter : Core::WorkMeter) : {Ast::Pattern, Int64}
      parser = Mica::Regex.stack_object(Parser, pattern_bytes(pattern, dialect, meter), options, limits, ledger, meter)
      parsed = parser.parse
      estimate = Preflight.estimate(parsed, dialect, limits, ledger, meter, lower_sets: true)
      meter.enforce_deadline { Core::Position.new(0_i64) }
      {parsed, estimate}
    end

    # The bytes of *pattern* for *dialect*'s parser, once the deadline has
    # been checked.
    private def self.pattern_bytes(pattern : String | Bytes, dialect : Dialect, meter : Core::WorkMeter) : Bytes
      unless dialect.parser_available?
        milestone = dialect.ecma262? ? "R6" : "R7"
        raise ArgumentError.new("The #{dialect} dialect's parser arrives in milestone #{milestone}")
      end
      bytes = pattern.is_a?(String) ? pattern.to_slice : pattern
      meter.enforce_deadline { Core::Position.new(0_i64) }
      bytes
    end

    # Charges *ledger* with the fixed objects every compilation makes
    # (whether in the collector's heap or in the compiling call's stack
    # frame): the ledger, a meter when the caller gave
    # none, the parser with its two lists and three name tables, the
    # parsed pattern and the report.
    private def self.charge_fixed_objects(ledger : AllocationLedger, meter : Core::WorkMeter?) : Nil
      fixed = AllocationLedger.granules(instance_sizeof(AllocationLedger)) +
              AllocationLedger.granules(instance_sizeof(Parser)) +
              AllocationLedger.granules(instance_sizeof(Array(Int32))) * 2 +
              AllocationLedger.granules(instance_sizeof(Hash(String, Int32))) * 3 +
              AllocationLedger.granules(instance_sizeof(Ast::Pattern)) +
              AllocationLedger.granules(sizeof(Report))
      fixed += AllocationLedger.granules(instance_sizeof(Core::WorkMeter)) unless meter
      ledger.charge(fixed, "a compilation", 0)
    end
  end
end
