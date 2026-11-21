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
    @nodes_by_class = Hash(String, {Int64, Int64}).new
    @categories = Hash(String, {Int64, Int64}).new
    @program_fields = Hash(String, Int64).new
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
    @class_stats = Hash(String, ClassStat).new
    @in_signature = false
    @rare_fields_count = 0_i64
    @meta_vars_count = 0_i64
    @meta_vars_bytes = 0_i64
    @rare_fields_bytes = 0_i64
    @signature_nodes = 0_i64
    @signature_bytes = 0_i64
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
        census.print_inference_state(STDERR) if inference_report?
        census.print_what_if(STDERR) if what_if?
      else
        File.open(path, "a") do |file|
          census.print(file, stage, live_bytes, stats.heap_size.to_i64)
          census.print_inference_state(file) if inference_report?
          census.print_what_if(file) if what_if?
        end
      end
      exit 0 if what_if?
    end

    # Reports what `OwnerShapeSharing` shares. Runs after the cleanup stage,
    # because codegen reads the typed defs as cleanup leaves them.
    def self.report_owner_shapes(program : Program, main_node : ASTNode) : Nil
      path = ENV["CRYSTAL_MEMORY_CENSUS"]?.presence || return
      census = new(program)
      census.run(main_node)
      output = IO::Memory.new
      output << "== owner shapes after Semantic (cleanup)\n"
      census.print_copies_and_owner_shapes(output)
      if path == "-"
        STDERR << output
      else
        File.open(path, "a") { |file| file << output }
      end
    end

    def print_copies_and_owner_shapes(io : IO) : Nil
      print_identical_copies(io)
      print_owner_shapes(io)
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
      @program.virtual_files.each do |virtual_file|
        add("macro expansion sources (VirtualFile text)", 1, gc_bytes(virtual_file.source.as(Void*)) + gc_bytes(virtual_file.as(Void*)))
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

    def owned_bytes(value : MetaVars) : Int64
      @meta_vars_count += 1
      large = value.@large
      bytes = gc_bytes(value.as(Void*)) + gc_bytes(value.@entries.as(Void*)) + (large ? owned_bytes(large) : 0_i64)
      @meta_vars_bytes += bytes
      bytes
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
      io.printf("shared   %-48s %12d objects %10.1f MB\n", "MetaVars maps owned by defs, blocks and calls", @meta_vars_count, @meta_vars_bytes / 1e6)
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

    # Reports what `OwnerShapeSharing` would share among the cached copies, how
    # the owner enters the bodies of the defs whose copies differ only by
    # owner, and what keeps the rest apart.
    private def print_owner_shapes(io : IO) : Nil
      main_node = @main_node || return
      sharing = OwnerShapeSharing.new(@program)
      sharing.analyze(main_node)
      stats = sharing.stats
      io.printf("shapes   %d typed defs, %d groups, %d share another def's function, %d unshareable, %d pinned, %d rounds, %.1f s\n",
        stats.typed_defs, stats.groups, stats.shared, stats.unshareable, stats.pinned, stats.rounds, stats.seconds)

      all_bytes = 0_i64
      shared_bytes = 0_i64
      shared_copies = 0_i64
      blockers = Hash(String, {Int64, Int64}).new
      sources = Hash(String, OwnerShapeSource).new
      causes = Hash(String, {Int64, Int64}).new
      @cached_typed_defs.each do |typed_def|
        shape = sharing.shape?(typed_def) || next
        print_data = fingerprint(typed_def)
        all_bytes += print_data.bytes
        source = sources[source_key(typed_def)] ||= OwnerShapeSource.new
        source.copies += 1
        source.bytes += print_data.bytes
        source.erased << print_data.content_without_owner
        source.groups << {shape.first, shape.second}
        source.owner_use |= shape.owner_use
        if sharing.representative?(typed_def)
          shared_bytes += print_data.bytes
          shared_copies += 1
          source.shared_copies += 1
          source.shared_bytes += print_data.bytes
        end
        unless sharing.representative?(typed_def)
          base_key = {shape.base_first, shape.base_second}
          if peer = source.first_by_base[base_key]?
            unless peer.same?(shape)
              cause = owner_shape_root_cause(sharing, shape, peer, 0)
              current = causes[cause]? || {0_i64, 0_i64}
              causes[cause] = {current[0] + 1, current[1] + print_data.bytes}
            end
          else
            source.first_by_base[base_key] = shape
          end
        end
        if blocker = shape.blocker
          current = blockers[blocker]? || {0_i64, 0_i64}
          blockers[blocker] = {current[0] + 1, current[1] + print_data.bytes}
          source.blockers[blocker] = (source.blockers[blocker]? || 0) + 1
        end
      end
      io.printf("shapes   %-48s %12d copies  %10.1f MB\n", "cached copies", @cached_typed_defs.size, all_bytes / 1e6)
      io.printf("shapes   %-48s %12d copies  %10.1f MB\n", "cached copies that share another def's function", shared_copies, shared_bytes / 1e6)
      blockers.to_a.sort_by { |entry| -entry[1][1] }.first(40).each do |reason, (count, bytes)|
        io.printf("shapes blocker %-74s %9d copies %9.1f MB\n", reason[0, 74], count, bytes / 1e6)
      end

      # Copies with the same own shape as another copy of their source def that
      # still got their own function, by the def down the call graph that
      # first differs.
      causes.to_a.sort_by { |entry| -entry[1][1] }.first(60).each do |cause, (count, bytes)|
        io.printf("shapes cause %-100s %9d copies %9.1f MB\n", cause[0, 100], count, bytes / 1e6)
      end

      # Where the own shapes of the first two copies of a source def differ.
      if pattern = ENV["CRYSTAL_OWNER_SHAPES_DIFF"]?.presence
        regex = Regex.new(pattern)
        first_copy = Hash(String, Def).new
        described = Set(String).new
        @cached_typed_defs.each do |typed_def|
          key = source_key(typed_def)
          next unless key.matches?(regex)
          next if described.includes?(key)
          shape = sharing.shape?(typed_def) || next
          if earlier = first_copy[key]?
            earlier_shape = sharing.shape?(earlier) || next
            next if earlier.args.size != typed_def.args.size
            next if earlier_shape.base_first == shape.base_first
            described << key
            io.printf("shapes diff %s (%s / %s): %s\n", key, earlier.owner, typed_def.owner, sharing.describe_difference(earlier, typed_def))
          else
            first_copy[key] = typed_def
          end
        end
      end

      # Source defs whose copies differ only by owner: fewer distinct bodies
      # with the owner erased than copies.
      owner_only = sources.to_a.select { |entry| entry[1].erased.size < entry[1].copies }
      owner_only.sort_by! { |entry| -entry[1].bytes }
      io.printf("shapes   %-48s %12d copies  %10.1f MB  %d source defs, %d copies shared (%.1f MB)\n", "defs whose copies differ only by owner",
        owner_only.sum { |entry| entry[1].copies }, owner_only.sum { |entry| entry[1].bytes } / 1e6, owner_only.size,
        owner_only.sum { |entry| entry[1].shared_copies }, owner_only.sum { |entry| entry[1].shared_bytes } / 1e6)
      {owner_only.first(50), owner_only}.each_with_index do |list, index|
        label = index == 0 ? "top 50" : "all"
        OwnerShapeSharing::OwnerUse.each do |use|
          matching = list.select { |entry| entry[1].owner_use.includes?(use) }
          io.printf("shapes use %-7s %-18s %6d source defs %9d copies %9.1f MB, shared %9d copies %9.1f MB\n", label, use.to_s,
            matching.size, matching.sum { |entry| entry[1].copies }, matching.sum { |entry| entry[1].bytes } / 1e6,
            matching.sum { |entry| entry[1].shared_copies }, matching.sum { |entry| entry[1].shared_bytes } / 1e6)
        end
        combos = Hash(String, {Int64, Int64, Int64, Int64, Int64}).new
        list.each do |_, source|
          key = source.owner_use.none? ? "(owner only in types)" : source.owner_use.to_s
          current = combos[key]? || {0_i64, 0_i64, 0_i64, 0_i64, 0_i64}
          combos[key] = {current[0] + 1, current[1] + source.copies, current[2] + source.bytes, current[3] + source.shared_copies, current[4] + source.shared_bytes}
        end
        combos.to_a.sort_by { |entry| -entry[1][2] }.first(30).each do |key, (defs, copies, bytes, shared, shared_size)|
          io.printf("shapes mix %-7s %-80s %5d source defs %8d copies %8.1f MB, shared %8d copies %8.1f MB\n", label, key[0, 80], defs, copies, bytes / 1e6, shared, shared_size / 1e6)
        end
      end
      owner_only.first(50).each do |name, source|
        blocker = source.blockers.to_a.sort_by { |entry| -entry[1] }.first(3).map { |entry| "#{entry[1]}x #{entry[0]}" }.join("; ")
        io.printf("shapes def %-40s %6d copies %7.1f MB  %5d erased, %5d groups, %5d shared  [%s]  %s\n", name[0, 40], source.copies, source.bytes / 1e6,
          source.erased.size, source.groups.size, source.shared_copies, source.owner_use.to_s, blocker[0, 200])
      end
    end

    # Follows the first pair of callees that are in different groups, down to
    # the def whose own shape differs, and names it.
    private def owner_shape_root_cause(sharing : OwnerShapeSharing, shape : OwnerShapeSharing::Shape, peer : OwnerShapeSharing::Shape, depth : Int32) : String
      if shape.base_first != peer.base_first || shape.base_second != peer.base_second || depth > 40
        typed_def = shape.typed_def
        owner = typed_def.owner?
        side = owner && owner.metaclass? ? "class method" : "method"
        return "#{side} #{source_key(typed_def)}: #{shape.blocker || "own shape differs"}"
      end
      shape.callees.each_with_index do |callee, index|
        other = peer.callees[index]? || break
        callee_shape = sharing.shape?(callee) || next
        other_shape = sharing.shape?(other) || next
        next if callee_shape.first == other_shape.first && callee_shape.second == other_shape.second
        return owner_shape_root_cause(sharing, callee_shape, other_shape, depth + 1)
      end
      "unknown"
    end

    # Totals for the typed copies of one source def (see `print_owner_shapes`).
    class OwnerShapeSource
      property copies = 0_i64
      property bytes = 0_i64
      property shared_copies = 0_i64
      property shared_bytes = 0_i64
      property owner_use = OwnerShapeSharing::OwnerUse::None
      getter erased = Set(UInt64).new
      getter groups = Set({UInt64, UInt64}).new
      getter blockers = Hash(String, Int32).new
      getter first_by_base = Hash({UInt64, UInt64}, OwnerShapeSharing::Shape).new
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
          current.each_target_def do |target_def|
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
    # Bytes of the arrays, hashes and strings this node owns (census only).
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
