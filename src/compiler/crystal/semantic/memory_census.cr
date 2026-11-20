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
      gc_bytes(value.as(Void*))
    end

    def owned_bytes(value : SmallNodeList) : Int64
      owned_bytes(value.@tail)
    end

    def owned_bytes(value : Location) : Int64
      return 0_i64 unless @seen_locations.add?(value.object_id)
      filename = value.filename
      if filename.is_a?(VirtualFile) && @virtual_files.add?(filename.object_id)
        add("macro expansion sources (VirtualFile text)", 1, gc_bytes(filename.source.as(Void*)) + gc_bytes(filename.as(Void*)))
      end
      gc_bytes(value.as(Void*))
    end

    def owned_bytes(value) : Int64
      0_i64
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
          current.target_defs.try { |target_defs| @pending_target_defs.concat(target_defs) }
        end
      end
    end

    private def count_node(node : ASTNode) : Nil
      own = gc_bytes(node.as(Void*))
      owned = node.census_owned_bytes(self)
      add(@category, 1, own + owned)
      name = node.class.name
      current = @nodes_by_class[name]? || {0_i64, 0_i64}
      @nodes_by_class[name] = {current[0] + 1, current[1] + own + owned}
    end
  end

  class ASTNode
    # Bytes of the arrays, hashes, strings and locations this node owns (census only).
    def census_owned_bytes(census : MemoryCensus) : Int64
      total = 0_i64
      {% for ivar in @type.instance_vars %}
        total += census.owned_bytes(@{{ivar.id}})
      {% end %}
      total
    end
  end

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
