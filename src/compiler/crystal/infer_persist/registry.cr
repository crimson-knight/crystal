module Crystal::InferPersist
  # The classes a snapshot holds, found at compile time from the instance
  # variables of the roots (`Roots`, every `ASTNode` and every `Type`), and
  # a `case` over them.
  #
  # Each class gets a number, its place in a list both the writer and the
  # reader compute in the same compiler build (the header refuses a file from
  # another build). Structs, tuples and primitives are written inline and get
  # no number. The walk stops at *opaque* types, which a snapshot never
  # holds by value: procs, pointers, IO, LLVM handles, fibers and the
  # compiler's code generation state. A reference to one of them is written
  # as an external (the loading process's own compiler, standard output and
  # error), as `nil` when its class is listed in `DROPPED` (state the loading
  # process makes again), or refused.
  #
  # *kind* is one of:
  #
  # * `register`: fills `@class_index_by_type_id`.
  # * `discover`: `discover_fields(object.as(T))`.
  # * `write`: `write_fields(object.as(T))`.
  # * `allocate`: makes an empty object of class number *index*.
  # * `fill`: `fill_fields(object.as(T))` for class number *index*.
  #
  # A virtual type (an instance variable typed with a class that has
  # subclasses, such as `Call#parent_visitor` in a compiler with the
  # interpreter, whose `MultidispatchMainVisitor` inherits `MainVisitor`) is
  # neither a class nor a struct to a macro and prints as the class itself:
  # the walk takes the class.
  macro persistable_case(kind, index, object)
    {% roots = [Crystal::InferPersist::Roots] %}
    {% for sub in Crystal::ASTNode.all_subclasses %}{% roots << sub %}{% end %}
    {% for sub in Crystal::Type.all_subclasses %}{% roots << sub %}{% end %}
    {% list = [] of TypeNode %}
    {% seen = {} of String => Bool %}
    {% pending = roots %}
    {% for round in (0..40) %}
      {% next_pending = [] of TypeNode %}
      {% for t in pending %}
        {% name = t.stringify %}
        {% if !t.union? && !t.class? && t < Reference %}
          {% t = parse_type(name).resolve %}
        {% end %}
        {% opaque = name.starts_with?("Proc(") || name.starts_with?("Pointer(") || name.starts_with?("LLVM::") ||
                    name.starts_with?("LibLLVM::") || name.starts_with?("Fiber") || name.starts_with?("Channel") ||
                    name.starts_with?("Sync::") || name.starts_with?("Atomic(") || name.starts_with?("Thread") ||
                    name.starts_with?("Log::") || name.starts_with?("Mutex") || name == "IO" || name.starts_with?("IO::") ||
                    name == "File" || name.starts_with?("File::") || name == "Crystal::Compiler" ||
                    name.starts_with?("Crystal::Compiler::") && !name.starts_with?("Crystal::Compiler::OptimizationMode") ||
                    Crystal::InferPersist::DROPPED.includes?(name) ||
                    name.starts_with?("Crystal::IrSkip::") || name.starts_with?("Crystal::DispatchPrune::") ||
                    name.starts_with?("Crystal::CodegenWorker") || name.starts_with?("Crystal::CodeGenVisitor") ||
                    name.starts_with?("Crystal::LinePatch::") || name.starts_with?("Crystal::DependencyPrinter") ||
                    name == "Crystal::CrystalLLVMBuilder" || name == "Crystal::ModuleSpill" ||
                    name.starts_with?("Exception") ||
                    t.ancestors.any? { |ancestor| ancestor.stringify == "IO" || ancestor.stringify == "Exception" } %}
        {% unless seen[name] || opaque || t.union? %}
          {% seen[name] = true %}
          {% if t.class? && !t.abstract? && !(t.type_vars.any? { |var| !var.is_a?(TypeNode) }) && name != "String" %}
            {% list << t %}
          {% end %}
          {% if name.starts_with?("Array(") || name.starts_with?("Hash(") || name.starts_with?("Set(") ||
                  name.starts_with?("Tuple(") || name.starts_with?("NamedTuple(") %}
            {% for var in t.type_vars %}
              {% if var.is_a?(TypeNode) %}
                {% for member in var.union_types %}
                  {% next_pending << member %}
                  {% for sub in member.all_subclasses %}{% next_pending << sub %}{% end %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
          {% unless name.starts_with?("Array(") || name.starts_with?("Hash(") || name == "StringPool" || name == "Crystal::MetaVars" %}
            {% for ivar in t.instance_vars %}
              {% for member in ivar.type.union_types %}
                {% next_pending << member %}
                {% for sub in member.all_subclasses %}{% next_pending << sub %}{% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        {% if t.union? %}
          {% for member in t.union_types %}{% next_pending << member %}{% end %}
        {% end %}
      {% end %}
      {% pending = next_pending %}
    {% end %}
    {% raise "InferPersist: the class closure did not finish in 40 rounds" unless pending.empty? %}

    {% if kind == :register && env("CRYSTAL_INFER_PERSIST_PRINT_CLASSES") %}
      {% for t in list %}{% puts t.stringify %}{% end %}
    {% end %}
    {% if kind == :register %}
      {% for t, i in list %}
        register_class({{t}}.crystal_instance_type_id, {{i + 1}}, {{t.stringify.starts_with?("Hash(")}})
      {% end %}
    {% elsif kind == :count %}
      {{list.size}}
    {% else %}
      case {{index}}
      {% for t, i in list %}
        when {{i + 1}}
          {% if kind == :discover %}
            discover_fields({{object}}.as({{t}}))
          {% elsif kind == :write %}
            write_fields({{object}}.as({{t}}))
          {% elsif kind == :fill %}
            fill_fields({{object}}.as({{t}}))
          {% elsif kind == :allocate %}
            {% if t.stringify.starts_with?("Array(") || t.stringify.starts_with?("Hash(") || t.stringify == "StringPool" || t.stringify == "Crystal::MetaVars" %}
              {{t}}.new.as(Void*)
            {% else %}
              {{t}}.allocate.as(Void*)
            {% end %}
          {% end %}
      {% end %}
      else
        raise Error.new("snapshot: unknown class number #{ {{index}} }")
      end
    {% end %}
  end
end
