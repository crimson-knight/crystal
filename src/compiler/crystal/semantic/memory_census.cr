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
    @cached_typed_defs = [] of Def
    @cached_typed_def_ids = Set(UInt64).new
    @fingerprints = Hash(UInt64, TypedDefFingerprint).new
    @block_call_copies = [] of {Def, Call}
    @main_node : ASTNode?

    # What codegen reads from one typed def: a hash over every node class and
    # node type in its body (and, through its calls, in the uncached typed
    # defs those calls own), the same hash with the def's owner erased, and the
    # bytes of the def's own nodes.
    record TypedDefFingerprint, content : UInt64, content_without_owner : UInt64, bytes : Int64

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
      @main_node = main_node
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
      print_identical_copies(io)
      stats = @program.block_instance_stats
      io.printf("sharing  block instances typed %d, shared %d, reused by their first call %d, diverged %d, late yields %d, block type differs %d, yields depend on block %d\n",
        stats.typed, stats.shared, stats.reused_by_first_call, stats.diverged, stats.late_yields, stats.block_type_differs, stats.yields_depend_on_block)
      stats.unshared_reasons.to_a.sort_by { |entry| -entry[1] }.first(40).each do |reason, count|
        io.printf("unshared %-80s %8d calls\n", reason[0, 80], count)
      end
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

    # Reports how many typed copies are identical in everything codegen
    # reads. Copies owned by a call with a block ("block-call copies") are
    # grouped by content; copies cached in `def_instances` are grouped by
    # content with the owner erased, which shows what treating the receiver as
    # a parameter could share.
    private def print_identical_copies(io : IO) : Nil
      main_node = @main_node || return
      fingerprint_node(main_node, nil)
      # The list grows while it is walked: defs cached by owners the type walk
      # does not reach are appended as calls to them are found.
      index = 0
      while index < @cached_typed_defs.size
        fingerprint(@cached_typed_defs[index])
        index += 1
      end

      block_groups = Hash(UInt64, {Int64, Int64}).new
      block_sources = Hash(String, {Int64, Int64, Set(UInt64)}).new
      block_bytes = 0_i64
      with_params = {0_i64, 0_i64, Set(UInt64).new}
      without_params = {0_i64, 0_i64, Set(UInt64).new}
      @block_call_copies.each do |typed_def, call|
        print_data = fingerprint(typed_def)
        block_bytes += print_data.bytes
        current = block_groups[print_data.content]? || {0_i64, print_data.bytes}
        block_groups[print_data.content] = {current[0] + 1, current[1]}
        key = source_key(typed_def)
        source = block_sources[key]? || {0_i64, 0_i64, Set(UInt64).new}
        source[2] << print_data.content
        block_sources[key] = {source[0] + 1, source[1] + print_data.bytes, source[2]}
        block = call.block
        if block && (block.args.empty? && !block.splat_index)
          without_params[2] << print_data.content
          without_params = {without_params[0] + 1, without_params[1] + print_data.bytes, without_params[2]}
        else
          with_params[2] << print_data.content
          with_params = {with_params[0] + 1, with_params[1] + print_data.bytes, with_params[2]}
        end
      end
      io.printf("identical %-47s %12d copies  %10.1f MB\n", "block-call copies (own nodes)", @block_call_copies.size, block_bytes / 1e6)
      io.printf("identical %-47s %12d copies  %10.1f MB\n", "block-call copies, distinct content", block_groups.size,
        block_groups.sum { |_, value| value[1] } / 1e6)
      io.printf("identical %-47s %12d copies  %10.1f MB  %d distinct\n", "block-call copies, block without parameters", without_params[0], without_params[1] / 1e6, without_params[2].size)
      io.printf("identical %-47s %12d copies  %10.1f MB  %d distinct\n", "block-call copies, block with parameters", with_params[0], with_params[1] / 1e6, with_params[2].size)
      block_sources.to_a.sort_by { |entry| -entry[1][1] }.first(25).each do |name, (count, bytes, distinct)|
        io.printf("identical block  %-40s %12d copies  %10.1f MB  %d distinct\n", name[0, 40], count, bytes / 1e6, distinct.size)
      end

      cached_sources = Hash(String, {Int64, Int64, Set(UInt64), Set(UInt64), Set(UInt64)}).new
      cached_bytes = 0_i64
      erased_groups = Hash(UInt64, Int64).new
      @cached_typed_defs.each do |typed_def|
        print_data = fingerprint(typed_def)
        cached_bytes += print_data.bytes
        erased_groups[print_data.content_without_owner] ||= print_data.bytes
        key = source_key(typed_def)
        source = cached_sources[key]? || {0_i64, 0_i64, Set(UInt64).new, Set(UInt64).new, Set(UInt64).new}
        source[2] << typed_def.owner.object_id
        source[3] << print_data.content
        source[4] << print_data.content_without_owner
        cached_sources[key] = {source[0] + 1, source[1] + print_data.bytes, source[2], source[3], source[4]}
      end
      io.printf("identical %-47s %12d copies  %10.1f MB\n", "cached copies (own nodes)", @cached_typed_defs.size, cached_bytes / 1e6)
      io.printf("identical %-47s %12d copies  %10.1f MB\n", "cached copies, distinct with owner erased", erased_groups.size,
        erased_groups.sum { |_, value| value } / 1e6)
      cached_sources.to_a.sort_by { |entry| -entry[1][1] }.first(25).each do |name, (count, bytes, owners, distinct, erased)|
        io.printf("identical cached %-40s %12d copies  %10.1f MB  %d owners, %d distinct, %d distinct with owner erased\n",
          name[0, 40], count, bytes / 1e6, owners.size, distinct.size, erased.size)
      end
    end

    private def source_key(typed_def : Def) : String
      location = typed_def.location
      location ? "#{typed_def.name} #{File.basename(location.filename.to_s)}:#{location.line_number}" : typed_def.name
    end

    private def fingerprint(typed_def : Def) : TypedDefFingerprint
      if existing = @fingerprints[typed_def.object_id]?
        return existing
      end
      # A def that reaches itself is named by its identity inside its own walk.
      @fingerprints[typed_def.object_id] = TypedDefFingerprint.new(typed_def.object_id, typed_def.object_id, 0_i64)
      result = fingerprint_node(typed_def, typed_def.owner)
      @fingerprints[typed_def.object_id] = result
      result
    end

    private def mix(hash : UInt64, value : UInt64) : UInt64
      (hash ^ value) &* 0x100000001b3_u64 &+ (hash >> 29)
    end

    private def fingerprint_node(root : ASTNode, owner : Type?) : TypedDefFingerprint
      erased = Set(UInt64).new
      if owner
        erased << owner.object_id
        erased << owner.metaclass.object_id unless owner.metaclass?
        erased << owner.instance_type.object_id if owner.metaclass?
        erased << owner.virtual_type.object_id
      end
      content = 0xcbf29ce484222325_u64
      content_without_owner = content
      bytes = 0_i64
      stack = [root] of ASTNode
      collector = CensusChildCollector.new
      while current = stack.pop?
        bytes += gc_bytes(current.as(Void*)) + current.census_owned_bytes(self)
        class_id = current.crystal_type_id.to_u64
        type_id = current.type?.try(&.object_id) || 0_u64
        content = mix(mix(content, class_id), type_id)
        content_without_owner = mix(mix(content_without_owner, class_id), erased.includes?(type_id) ? 1_u64 : type_id)
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
        end
        if current.is_a?(Call)
          current.target_defs.try &.each do |target_def|
            if @cached_typed_def_ids.includes?(target_def.object_id)
              content = mix(content, target_def.object_id)
              # A cached callee is named by its source and argument types, so
              # two receivers that call the same method on themselves agree.
              callee = target_def.name.hash
              target_def.args.each do |arg|
                arg_type_id = arg.type?.try(&.object_id) || 0_u64
                callee = mix(callee, erased.includes?(arg_type_id) ? 1_u64 : arg_type_id)
              end
              callee_owner_id = target_def.owner.object_id
              callee = mix(callee, erased.includes?(callee_owner_id) ? 1_u64 : callee_owner_id)
              content_without_owner = mix(content_without_owner, callee)
            elsif current.block && !target_def.block_arg.try(&.type?)
              # Typed for this call alone: the def yields to the call's block.
              first_visit = !@fingerprints.has_key?(target_def.object_id)
              nested = fingerprint(target_def)
              @block_call_copies << {target_def, current} if first_visit
              content = mix(content, nested.content)
              content_without_owner = mix(content_without_owner, nested.content_without_owner)
            else
              # Cached by an owner the type walk does not reach (a virtual
              # type, a proc or tuple type, a metaclass of a generic instance).
              @cached_typed_def_ids << target_def.object_id
              @cached_typed_defs << target_def
              content = mix(content, target_def.object_id)
              content_without_owner = mix(content_without_owner, target_def.object_id)
            end
          end
        end
      end
      TypedDefFingerprint.new(content, content_without_owner, bytes)
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
            @cached_typed_defs << typed_def
            @cached_typed_def_ids << typed_def.object_id
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
