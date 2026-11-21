require "../syntax/ast"

module Crystal
  # Reports where semantic analysis keeps its memory.
  #
  # Enabled by setting `CRYSTAL_MEMORY_CENSUS` to a file path (or `-` for
  # standard error) before running the compiler. After `Semantic (main)` the
  # census forces a full collection, then walks every type, every typed def
  # instance, every untyped def, the main program node and every macro
  # expansion source. Each object is counted once, at the size the GC actually
  # allocated for it, plus the arrays, hashes and strings it owns. The report
  # lists categories, the largest node classes, the largest `Program` fields,
  # and the live heap the census could not attribute.
  class MemoryCensus
    @seen = Set(UInt64).new
    @seen_types = Set(UInt64).new
    @seen_strings = Set(UInt64).new
    @seen_locations = Set(UInt64).new
    @nodes_by_class = Hash(String, {Int64, Int64}).new
    @categories = Hash(String, {Int64, Int64}).new
    @program_fields = Hash(String, Int64).new
    @virtual_files = Set(UInt64).new
    @category = "main program"
    @pending_target_defs = [] of Def
    @typed_defs_by_source = Hash(String, {Int64, Int64}).new
    @class_stats = Hash(String, ClassStat).new
    @in_signature = false
    @rare_fields_count = 0_i64
    @rare_fields_bytes = 0_i64
    @signature_nodes = 0_i64
    @signature_bytes = 0_i64
    @location_count = 0_i64
    @location_bytes = 0_i64
    @string_count = 0_i64
    @string_bytes = 0_i64
    @dependency_sizes = Array(Int64).new(5, 0_i64)
    @observer_sizes = Array(Int64).new(5, 0_i64)
    @binding_pairs = Array(Int64).new(9, 0_i64)
    @heap_histogram = Hash(UInt64, Int64).new
    @@class_names : Hash(Int32, String)?

    def initialize(@program : Program)
    end

    def self.enabled? : Bool
      !ENV["CRYSTAL_MEMORY_CENSUS"]?.presence.nil?
    end

    def self.report(program : Program, main_node : ASTNode, stage : String) : Nil
      path = ENV["CRYSTAL_MEMORY_CENSUS"]?.presence || return
      GC.collect
      stats = GC.stats
      live_bytes = (stats.heap_size - stats.free_bytes).to_i64
      census = new(program)
      census.enumerate_heap
      census.run(main_node)
      if path == "-"
        census.print(STDERR, stage, live_bytes, stats.heap_size.to_i64)
      else
        File.open(path, "a") { |file| census.print(file, stage, live_bytes, stats.heap_size.to_i64) }
      end
    end

    def run(main_node : ASTNode) : Nil
      # Types first, so cached typed defs land in their owner's category and
      # only defs reachable solely through a call are counted as block calls.
      walk_type(@program)
      with_category("main program") { walk_node(main_node) }
      # Typed defs instantiated for calls with a block are not cached in
      # `def_instances`; the calling node is their only owner.
      with_category("typed defs (block calls, owned by the call)") do
        while typed_def = @pending_target_defs.pop?
          walk_typed_def(typed_def)
        end
      end
      @program_fields = @program.census_field_bytes(self)
    end

    def print(io : IO, stage : String, live_bytes : Int64, heap_bytes : Int64) : Nil
      total_bytes = @categories.sum { |_, value| value[1] }
      io << "== memory census after " << stage << "\n"
      io.printf("heap     %-48s %12s         %10.1f MB\n", "GC heap size", "", heap_bytes / 1e6)
      io.printf("heap     %-48s %12s         %10.1f MB\n", "live after full collection", "", live_bytes / 1e6)
      io.printf("heap     %-48s %12s         %10.1f MB\n", "attributed by census", "", total_bytes / 1e6)
      io.printf("heap     %-48s %12s         %10.1f MB\n", "not attributed", "", (live_bytes - total_bytes) / 1e6)
      @categories.to_a.sort_by { |entry| -entry[1][1] }.each do |name, (count, bytes)|
        io.printf("category %-48s %12d objects %10.1f MB\n", name, count, bytes / 1e6)
      end
      @nodes_by_class.to_a.sort_by { |entry| -entry[1][1] }.first(20).each do |name, (count, bytes)|
        io.printf("node     %-48s %12d objects %10.1f MB\n", name, count, bytes / 1e6)
      end
      @program_fields.to_a.sort_by { |entry| -entry[1] }.first(12).each do |name, bytes|
        io.printf("program  %-48s %12s         %10.1f MB\n", name, "", bytes / 1e6)
      end
      print_typed_defs_by_source(io)
      print_field_stats(io)
      print_heap_histogram(io)
      io.flush
    end

    # Bytes the GC allocated for *pointer*, or 0 when it is not a GC object.
    def gc_bytes(pointer : Void*) : Int64
      return 0_i64 if pointer.null?
      base = LibGC.base(pointer)
      return 0_i64 if base.null?
      LibGC.size(base).to_i64
    end

    def owned_bytes(value : Array(T)) : Int64 forall T
      total = gc_bytes(value.as(Void*))
      buffer = value.@buffer - value.@offset_to_buffer
      total += gc_bytes(buffer.as(Void*)) if value.@capacity > 0
      total
    end

    def owned_bytes(value : Hash(K, V)) : Int64 forall K, V
      gc_bytes(value.as(Void*)) + gc_bytes(value.@entries.as(Void*)) + gc_bytes(value.@indices.as(Void*))
    end

    def owned_bytes(value : String) : Int64
      return 0_i64 unless @seen_strings.add?(value.object_id)
      bytes = gc_bytes(value.as(Void*))
      @string_count += 1
      @string_bytes += bytes
      bytes
    end

    def owned_bytes(value : SmallNodeList) : Int64
      rest = value.@rest
      rest.is_a?(Array(ASTNode)) ? owned_bytes(rest) : 0_i64
    end

    def owned_bytes(value : Location) : Int64
      return 0_i64 unless @seen_locations.add?(value.object_id)
      filename = value.filename
      if filename.is_a?(VirtualFile) && @virtual_files.add?(filename.object_id)
        add("macro expansion sources (VirtualFile text)", 1, gc_bytes(filename.source.as(Void*)) + gc_bytes(filename.as(Void*)))
      end
      bytes = gc_bytes(value.as(Void*))
      @location_count += 1
      @location_bytes += bytes
      bytes
    end

    def owned_bytes(value : Call::RareFields | Def::RareFields) : Int64
      @rare_fields_count += 1
      bytes = gc_bytes(value.as(Void*)) + value.census_owned_bytes(self)
      @rare_fields_bytes += bytes
      bytes
    end

    def owned_bytes(value) : Int64
      0_i64
    end

    # One instance variable of a node class: its inline size, how many
    # instances hold a non-default value, and the bytes those values own.
    class FieldStat
      getter name : String
      getter inline_bytes : Int32
      getter set_count = 0_i64
      getter owned_bytes = 0_i64

      def initialize(@name : String, @inline_bytes : Int32)
      end

      def record(set : Bool, owned : Int64) : Nil
        @set_count += 1 if set
        @owned_bytes += owned
      end
    end

    # Per-class totals for the field report.
    class ClassStat
      getter instance_bytes : Int32
      getter fields : Array(FieldStat)
      property count = 0_i64

      def initialize(@instance_bytes : Int32, @fields : Array(FieldStat))
      end
    end

    def class_stat(name : String, & : -> ClassStat) : ClassStat
      @class_stats[name] ||= yield
    end

    def field_set?(value : Nil) : Bool
      false
    end

    def field_set?(value : Bool) : Bool
      value
    end

    def field_set?(value : Int) : Bool
      value != 0
    end

    def field_set?(value : Enum) : Bool
      value.value != 0
    end

    def field_set?(value : SmallNodeList) : Bool
      value.size > 0
    end

    def field_set?(value : Array) : Bool
      !value.empty?
    end

    def field_set?(value : Hash) : Bool
      !value.empty?
    end

    def field_set?(value) : Bool
      true
    end

    # Counts how many nodes hold 0, 1, 2 or more dependencies and observers.
    def record_bindings(dependencies : SmallNodeList, observers : SmallNodeList) : Nil
      @dependency_sizes[dependencies.size.clamp(0, 4)] += 1
      @observer_sizes[observers.size.clamp(0, 4)] += 1
      both = dependencies.size.clamp(0, 2) * 3 + observers.size.clamp(0, 2)
      @binding_pairs[both] += 1
    end

    private def print_field_stats(io : IO) : Nil
      io.printf("shared   %-48s %12d objects %10.1f MB\n", "typed def signatures (args, return type)", @signature_nodes, @signature_bytes / 1e6)
      io.printf("shared   %-48s %12d objects %10.1f MB\n", "rare-fields side objects of calls and defs", @rare_fields_count, @rare_fields_bytes / 1e6)
      io.printf("shared   %-48s %12d objects %10.1f MB\n", "Location objects (each counted once)", @location_count, @location_bytes / 1e6)
      io.printf("shared   %-48s %12d objects %10.1f MB\n", "String objects owned by nodes and types", @string_count, @string_bytes / 1e6)
      {"dependencies" => @dependency_sizes, "observers" => @observer_sizes}.each do |name, sizes|
        io.printf("bindings %-14s size 0: %d, 1: %d, 2: %d, 3: %d, 4+: %d\n", name, sizes[0], sizes[1], sizes[2], sizes[3], sizes[4])
      end
      io.printf("bindings (dependencies, observers) clamped to 2: %s\n",
        @binding_pairs.map_with_index { |count, index| "(#{index // 3},#{index % 3})=#{count}" }.join(" "))
      ranked = @class_stats.to_a.sort_by { |entry| -(@nodes_by_class[entry[0]]?.try(&.[1]) || 0_i64) }
      ranked.first(14).each do |name, stat|
        io.printf("fields   %s: %d instances, instance_sizeof %d\n", name, stat.count, stat.instance_bytes)
        stat.fields.each do |field|
          io.printf("field      %-28s %3d bytes inline  set in %10d (%5.1f%%)  owns %9.1f MB\n", field.name, field.inline_bytes,
            field.set_count, stat.count == 0 ? 0.0 : field.set_count * 100.0 / stat.count, field.owned_bytes / 1e6)
        end
      end
    end

    # Every object the last collection marked, grouped by the class its first
    # word names and by its allocated size. Buffers have no class header, so
    # they land under "(no class header)" or, when their first word happens to
    # equal a type id, under that class at an implausible size.
    def enumerate_heap : Nil
      names = MemoryCensus.class_names
      max_id = names.keys.max
      state = {@heap_histogram, max_id}
      box = Box.box(state)
      GC.disable
      LibGC.enumerate_reachable_objects_inner(->(object : Void*, bytes : LibC::SizeT, data : Void*) {
        histogram, limit = Box({Hash(UInt64, Int64), Int32}).unbox(data)
        id = object.as(Int32*).value
        id = -1 if id <= 0 || id > limit
        key = (id.to_u32!.to_u64 << 32) | bytes.to_u32!
        histogram[key] = (histogram[key]? || 0_i64) + 1
        nil
      }, box)
      GC.enable
    end

    private def print_heap_histogram(io : IO) : Nil
      names = MemoryCensus.class_names
      rows = @heap_histogram.map do |key, count|
        id = (key >> 32).to_u32!.to_i32!
        bytes = (key & 0xffff_ffff_u64).to_i64
        name = id == -1 ? "(no class header)" : (names[id]? || "(type id #{id})")
        {name, bytes, count, bytes * count}
      end
      total = rows.sum(&.[3])
      io.printf("heapobj  %-58s %12d objects %10.1f MB\n", "all marked objects", rows.sum(&.[2]), total / 1e6)
      by_class = Hash(String, {Int64, Int64}).new
      rows.each do |name, _, count, total_bytes|
        current = by_class[name]? || {0_i64, 0_i64}
        by_class[name] = {current[0] + count, current[1] + total_bytes}
      end
      by_class.to_a.sort_by { |entry| -entry[1][1] }.first(60).each do |name, (count, class_bytes)|
        io.printf("heapcls  %-58s %12d objects %10.1f MB\n", name[0, 58], count, class_bytes / 1e6)
      end
      rows.sort_by { |row| -row[3] }.first(80).each do |name, bytes, count, total_bytes|
        io.printf("heapobj  %-48s %9d B %12d objects %10.1f MB\n", name[0, 48], bytes, count, total_bytes / 1e6)
      end
    end

    # Names of the concrete reference classes by type id, for the heap histogram.
    def self.class_names : Hash(Int32, String)
      @@class_names ||= begin
        names = Hash(Int32, String).new
        {% for type in Reference.all_subclasses %}
          {% name = type.stringify %}
          {% container = name.starts_with?("Array(") || name.starts_with?("Hash(") || name.starts_with?("Set(") || name.starts_with?("Deque(") %}
          {% known = name.starts_with?("Crystal::") || name == "String" || name == "Array(String)" || name == "Set(String)" || (container && name.includes?("Crystal::")) %}
          {% excluded = ["PrettyPrint", "Crystal::CodeGenVisitor::DIBuilder"] %}
          {% if known && !excluded.any? { |part| name.includes?(part) } && !type.abstract? && !type.private? && !(name =~ /(^|[^A-Za-z0-9_:])\*?[A-Z][0-9]*($|[^A-Za-z0-9_:])/) %}
            names[{{type}}.crystal_instance_type_id] = {{name}}
          {% end %}
        {% end %}
        names
      end
    end

    private def add(category : String, count : Int, bytes : Int) : Nil
      current = @categories[category]? || {0_i64, 0_i64}
      @categories[category] = {current[0] + count, current[1] + bytes}
    end

    # Typed defs grouped by the source def they were instantiated from: how
    # many copies each source def has and what they hold together.
    private def print_typed_defs_by_source(io : IO) : Nil
      groups = @typed_defs_by_source.to_a
      copies = groups.sum { |entry| entry[1][0] }
      bytes = groups.sum { |entry| entry[1][1] }
      repeated = groups.select { |entry| entry[1][0] >= 100 }
      io.printf("source   %-48s %12d copies  %10.1f MB\n", "#{groups.size} source defs, all typed copies", copies, bytes / 1e6)
      io.printf("source   %-48s %12d copies  %10.1f MB\n", "#{repeated.size} source defs with >= 100 copies",
        repeated.sum { |entry| entry[1][0] }, repeated.sum { |entry| entry[1][1] } / 1e6)
      groups.sort_by { |entry| -entry[1][1] }.first(15).each do |name, (count, group_bytes)|
        io.printf("source   %-48s %12d copies  %10.1f MB\n", name[0, 48], count, group_bytes / 1e6)
      end
    end

    private def walk_typed_def(typed_def : Def) : Nil
      return if @seen.includes?(typed_def.object_id)
      before = @categories[@category]?.try(&.[1]) || 0_i64
      # The signature (argument restrictions and defaults, return type) is
      # walked first so the report shows what a typed copy spends outside
      # its body.
      @in_signature = true
      typed_def.args.each { |arg| walk_node(arg) }
      walk_node(typed_def.double_splat)
      walk_node(typed_def.block_arg)
      walk_node(typed_def.return_type)
      @in_signature = false
      walk_node(typed_def)
      after = @categories[@category]?.try(&.[1]) || 0_i64
      location = typed_def.location
      key = location ? "#{typed_def.name} #{File.basename(location.filename.to_s)}:#{location.line_number}" : typed_def.name
      current = @typed_defs_by_source[key]? || {0_i64, 0_i64}
      @typed_defs_by_source[key] = {current[0] + 1, current[1] + after - before}
    end

    private def walk_type(type : Type) : Nil
      return unless @seen_types.add?(type.object_id)
      generic = generic_instance?(type)
      add(generic ? "types (generic instances)" : "types (plain)", 1,
        gc_bytes(type.as(Void*)) + type.census_owned_bytes(self))

      if type.is_a?(DefInstanceContainer)
        if instances = type.@def_instances
          category = generic ? "typed defs (generic instance owners)" : "typed defs (plain owners)"
          instances.each_value do |typed_def|
            with_category(category) { walk_typed_def(typed_def) }
          end
        end
      end

      if type.is_a?(ModuleType)
        type.defs.try &.each_value do |list|
          list.each do |def_with_metadata|
            with_category("untyped defs") { walk_node(def_with_metadata.def) }
          end
        end
        type.macros.try &.each_value do |list|
          list.each { |macro_definition| with_category("macro definitions") { walk_node(macro_definition) } }
        end
      end

      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| walk_type(instance) }
      end

      type.types?.try &.each_value { |nested| walk_type(nested) }
      walk_type(type.metaclass) unless type.metaclass?
    end

    private def generic_instance?(type : Type) : Bool
      return true if type.is_a?(GenericInstanceType)
      type.is_a?(MetaclassType) && type.instance_type.is_a?(GenericInstanceType)
    end

    private def with_category(category : String, &) : Nil
      previous = @category
      @category = category
      yield
      @category = previous
    end

    private def walk_node(node : ASTNode?) : Nil
      return unless node
      stack = [node] of ASTNode
      collector = CensusChildCollector.new
      while current = stack.pop?
        next unless @seen.add?(current.object_id)
        count_node(current)
        collector.children.clear
        current.accept_children(collector)
        stack.concat(collector.children)
        if current.is_a?(ExpandableNode)
          current.expanded.try { |expanded| stack << expanded }
        end
        if current.is_a?(Def)
          current.vars.try &.each_value { |meta_var| stack << meta_var }
        end
        if current.is_a?(Block)
          current.vars.try &.each_value { |meta_var| stack << meta_var }
          current.after_vars.try &.each_value { |meta_var| stack << meta_var }
        end
        if current.is_a?(Call)
          current.expanded.try { |expanded| stack << expanded }
          current.each_target_def { |target_def| @pending_target_defs << target_def }
        end
      end
    end

    private def count_node(node : ASTNode) : Nil
      own = gc_bytes(node.as(Void*))
      owned = node.census_owned_bytes(self)
      add(@category, 1, own + owned)
      if @in_signature
        @signature_nodes += 1
        @signature_bytes += own + owned
      end
      name = node.class.name
      current = @nodes_by_class[name]? || {0_i64, 0_i64}
      @nodes_by_class[name] = {current[0] + 1, current[1] + own + owned}
    end
  end

  class ASTNode
    # Bytes of the arrays, hashes, strings and locations this node owns (census only).
    def census_owned_bytes(census : MemoryCensus) : Int64
      stat = census.class_stat({{@type.name.stringify}}) do
        fields = [] of MemoryCensus::FieldStat
        {% for ivar in @type.instance_vars %}
          fields << MemoryCensus::FieldStat.new({{ivar.name.stringify}}, sizeof(typeof(@{{ivar.id}})))
        {% end %}
        MemoryCensus::ClassStat.new(instance_sizeof(self), fields)
      end
      stat.count += 1
      census.record_bindings(@dependencies, @observers)
      total = 0_i64
      {% for ivar, index in @type.instance_vars %}
        owned = census.owned_bytes(@{{ivar.id}})
        stat.fields[{{index}}].record(census.field_set?(@{{ivar.id}}), owned)
        total += owned
      {% end %}
      total
    end
  end

  {% for node_class in %w(Call Def) %}
    class {{node_class.id}}::RareFields
      # Bytes of the arrays, hashes and strings these fields own (census only).
      def census_owned_bytes(census : MemoryCensus) : Int64
        total = 0_i64
        {% verbatim do %}
          {% for ivar in @type.instance_vars %}
            total += census.owned_bytes(@{{ivar.id}})
          {% end %}
        {% end %}
        total
      end
    end
  {% end %}

  class Type
    # Bytes of the arrays, hashes and strings this type owns (census only).
    def census_owned_bytes(census : MemoryCensus) : Int64
      total = 0_i64
      {% for ivar in @type.instance_vars %}
        total += census.owned_bytes(@{{ivar.id}})
      {% end %}
      total
    end
  end

  class Program
    # Bytes owned directly by each `Program` field that holds a container (census only).
    def census_field_bytes(census : MemoryCensus) : Hash(String, Int64)
      fields = Hash(String, Int64).new
      {% for ivar in @type.instance_vars %}
        fields[{{ivar.name.stringify}}] = census.owned_bytes(@{{ivar.id}})
      {% end %}
      fields
    end
  end

  # Collects the direct children of a node without descending further.
  class CensusChildCollector < Visitor
    getter children = [] of ASTNode

    def visit(node : ASTNode) : Bool
      @children << node
      false
    end
  end
end

lib LibGC
  fun enumerate_reachable_objects_inner = GC_enumerate_reachable_objects_inner(callback : (Void*, LibC::SizeT, Void*) ->, client_data : Void*)
end
