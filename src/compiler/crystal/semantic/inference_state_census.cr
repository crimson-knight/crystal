require "./memory_census"
require "./main_visitor"

module Crystal
  # The part of the memory census that looks at type-inference state: the
  # `MetaVar`s, the `MainVisitor`s and the edges between them.
  #
  # `CRYSTAL_MEMORY_CENSUS_INFERENCE=1` adds the shape report (how many
  # dependencies and observers each `MetaVar` has, and who they are).
  # `CRYSTAL_MEMORY_CENSUS_WHATIF=1` then drops one kind of inference state at
  # a time, collects, and prints what the heap holds afterwards. That
  # destroys the program, so the compiler exits when the report is written.
  class MemoryCensus
    def self.inference_report? : Bool
      ENV["CRYSTAL_MEMORY_CENSUS_INFERENCE"]? == "1" || what_if?
    end

    def self.what_if? : Bool
      ENV["CRYSTAL_MEMORY_CENSUS_WHATIF"]? == "1"
    end

    # Every marked object whose class header is *type_id*.
    def self.objects_of(type_id : Int32, bytes_at_least : Int32) : Array(Void*)
      count = 0
      count_box = Box.box({pointerof(count), type_id, bytes_at_least})
      GC.disable
      LibGC.enumerate_reachable_objects_inner(->(object : Void*, bytes : LibC::SizeT, data : Void*) {
        counter, wanted, minimum = Box({Pointer(Int32), Int32, Int32}).unbox(data)
        counter.value += 1 if bytes >= minimum && object.as(Int32*).value == wanted
        nil
      }, count_box)
      objects = Array(Void*).new(count + 16)
      fill_box = Box.box({objects, type_id, bytes_at_least})
      LibGC.enumerate_reachable_objects_inner(->(object : Void*, bytes : LibC::SizeT, data : Void*) {
        list, wanted, minimum = Box({Array(Void*), Int32, Int32}).unbox(data)
        if bytes >= minimum && object.as(Int32*).value == wanted && list.size < list.@capacity
          list << object
        end
        nil
      }, fill_box)
      GC.enable
      objects
    end

    # Yields every marked object whose class header is *type_id*, and leaves
    # no pointer to them behind (the collector scans the list conservatively).
    def self.each_object_of(type_id : Int32, bytes_at_least : Int32, & : Void* ->) : Nil
      objects = objects_of(type_id, bytes_at_least)
      objects.each { |object| yield object }
      objects.to_unsafe.clear(objects.size)
      objects.clear
    end

    def self.count_objects_of(type_id : Int32) : Int32
      count = 0
      box = Box.box({pointerof(count), type_id})
      GC.disable
      LibGC.enumerate_reachable_objects_inner(->(object : Void*, bytes : LibC::SizeT, data : Void*) {
        counter, wanted = Box({Pointer(Int32), Int32}).unbox(data)
        counter.value += 1 if bytes >= 16 && object.as(Int32*).value == wanted
        nil
      }, box)
      GC.enable
      count
    end

    def self.marked_bytes : {Int64, Int64}
      totals = {0_i64, 0_i64}
      pointer = pointerof(totals)
      GC.disable
      LibGC.enumerate_reachable_objects_inner(->(object : Void*, bytes : LibC::SizeT, data : Void*) {
        target = data.as(Pointer({Int64, Int64}))
        target.value = {target.value[0] + 1, target.value[1] + bytes.to_i64}
        nil
      }, pointer.as(Void*))
      GC.enable
      totals
    end

    private def bucket(size : Int32) : Int32
      size > 3 ? 3 : size
    end

    # Shapes of the live `MetaVar`s. *walked* are the ones a typed def or a
    # block owns (`Def#vars`, `Block#vars`, `Block#after_vars`); the others
    # are reachable only through inference edges and visitors.
    def print_inference_state(io : IO) : Nil
      meta_var_count = 0
      shapes = Hash({Bool, Int32, Int32}, Int64).new(0_i64)
      dependency_classes = Hash({Bool, String}, Int64).new(0_i64)
      observer_classes = Hash({Bool, String}, Int64).new(0_i64)
      frozen = 0_i64
      typed = 0_i64
      MemoryCensus.each_object_of(MetaVar.crystal_instance_type_id, instance_sizeof(MetaVar)) do |pointer|
        meta_var = pointer.as(MetaVar)
        meta_var_count += 1
        walked = @seen.includes?(meta_var.object_id)
        dependencies = meta_var.dependencies
        observers = meta_var.@observers
        shapes[{walked, bucket(dependencies.size), bucket(observers.size)}] += 1
        frozen += 1 if meta_var.freeze_type
        typed += 1 if meta_var.type?
        if dependencies.size == 1
          dependency_classes[{walked, dependencies.first.class.name}] += 1
        end
        observers.each { |observer| observer_classes[{walked, observer.class.name}] += 1 }
      end
      io.printf("infer    MetaVar objects %d, with a type %d, with a freeze type %d\n", meta_var_count, typed, frozen)
      shapes.to_a.sort_by { |entry| -entry[1] }.each do |(walked, dependencies, observers), count|
        io.printf("infer    MetaVar %-8s dependencies %d%s observers %d%s %12d objects\n",
          walked ? "owned" : "edge", dependencies, dependencies == 3 ? "+" : " ", observers, observers == 3 ? "+" : " ", count)
      end
      dependency_classes.to_a.sort_by { |entry| -entry[1] }.first(24).each do |(walked, name), count|
        io.printf("infer    MetaVar %-8s single dependency is %-32s %12d\n", walked ? "owned" : "edge", name, count)
      end
      observer_classes.to_a.sort_by { |entry| -entry[1] }.first(24).each do |(walked, name), count|
        io.printf("infer    MetaVar %-8s observed by %-40s %12d\n", walked ? "owned" : "edge", name, count)
      end

      stats = @program.inference_release_stats
      io.printf("infer    release: visitors released %d, keeping their vars %d (with %d point vars); point vars spliced out %d, doing more than repeating one node %d, left bound %d; after vars restored %d\n",
        stats.released_visitors, stats.visitors_keeping_vars, stats.point_vars_of_keeping_visitors,
        stats.spliced_point_vars, stats.kept_point_vars, stats.point_vars_left_bound, stats.restored_after_vars)

      visitor_count = 0
      block_visitors = 0_i64
      vars_entries = 0_i64
      vars_bytes = 0_i64
      MemoryCensus.each_object_of(MainVisitor.crystal_instance_type_id, instance_sizeof(MainVisitor)) do |pointer|
        visitor = pointer.as(MainVisitor)
        visitor_count += 1
        block_visitors += 1 if visitor.block
        vars = visitor.vars
        vars_entries += vars.size
        large = vars.@large
        vars_bytes += gc_bytes(vars.as(Void*)) + gc_bytes(vars.@entries.as(Void*)) + (large ? owned_bytes(large) : 0_i64)
      end
      io.printf("infer    MainVisitor objects %d (%d for a block), their vars hold %d entries in %.1f MB\n",
        visitor_count, block_visitors, vars_entries, vars_bytes / 1e6)

      call_count = 0
      with_visitor = 0_i64
      empty_args = 0_i64
      one_arg = 0_i64
      args_bytes = 0_i64
      MemoryCensus.each_object_of(Call.crystal_instance_type_id, instance_sizeof(Call)) do |pointer|
        call = pointer.as(Call)
        call_count += 1
        with_visitor += 1 if call.parent_visitor?
        empty_args += 1 if call.args.empty?
        one_arg += 1 if call.args.size == 1
        args_bytes += owned_bytes(call.args)
      end
      io.printf("infer    Call objects %d, with a parent visitor %d, no arguments %d, one argument %d, argument arrays %.1f MB\n",
        call_count, with_visitor, empty_args, one_arg, args_bytes / 1e6)
      io.flush
    end

    # Drops one kind of inference state at a time and reports the heap after
    # each. The program is unusable afterwards.
    def print_what_if(io : IO) : Nil
      what_if_line(io, "as is")

      MemoryCensus.each_object_of(MainVisitor.crystal_instance_type_id, instance_sizeof(MainVisitor)) do |pointer|
        pointer.as(MainVisitor).census_drop_vars
      end
      what_if_line(io, "visitors drop their vars")

      MemoryCensus.each_object_of(Call.crystal_instance_type_id, instance_sizeof(Call)) do |pointer|
        pointer.as(Call).census_drop_parent_visitor
      end
      what_if_line(io, "calls drop their parent visitor")

      spliced = 0_i64
      MemoryCensus.each_object_of(MetaVar.crystal_instance_type_id, instance_sizeof(MetaVar)) do |pointer|
        meta_var = pointer.as(MetaVar)
        next if @seen.includes?(meta_var.object_id)
        spliced += 1 if meta_var.census_splice_out
      end
      what_if_line(io, "edge MetaVars with one dependency spliced out (#{spliced})")

      spliced = 0_i64
      MemoryCensus.each_object_of(MetaVar.crystal_instance_type_id, instance_sizeof(MetaVar)) do |pointer|
        meta_var = pointer.as(MetaVar)
        next if @seen.includes?(meta_var.object_id)
        next unless meta_var.@observers.empty?
        meta_var.census_unbind
        spliced += 1
      end
      what_if_line(io, "edge MetaVars nobody observes unbound (#{spliced})")
      io.flush
    end

    private def what_if_line(io : IO, label : String) : Nil
      GC.collect
      objects, bytes = MemoryCensus.marked_bytes
      io.printf("whatif   %-64s %12d objects %10.1f MB\n", label, objects, bytes / 1e6)
      {
        {"Crystal::MetaVar", MetaVar.crystal_instance_type_id},
        {"Crystal::MainVisitor", MainVisitor.crystal_instance_type_id},
        {"Crystal::MetaVars", MetaVars.crystal_instance_type_id},
        {"Crystal::Var", Var.crystal_instance_type_id},
        {"Crystal::Call", Call.crystal_instance_type_id},
        {"Crystal::TypeFilteredNode", TypeFilteredNode.crystal_instance_type_id},
      }.each do |(name, type_id)|
        io.printf("whatif     %-62s %12d objects\n", name, MemoryCensus.count_objects_of(type_id))
      end
    end
  end

  class MainVisitor < SemanticVisitor
    def census_drop_vars : Nil
      @vars = MetaVars.new
    end
  end

  class Call
    def census_drop_parent_visitor : Nil
      @parent_visitor = nil
    end
  end

  class ASTNode
    def census_replace_dependency(old : ASTNode, new : ASTNode) : Nil
      kept = SmallNodeList.new
      @dependencies.each { |node| kept.push(node.same?(old) ? new : node) }
      @dependencies = kept
    end

    def census_unbind : Nil
      @dependencies.each &.remove_observer(self)
      @dependencies = SmallNodeList.new
    end

    # Takes this node out of a chain `observers -> self -> dependency`.
    def census_splice_out : Bool
      return false unless @dependencies.size == 1
      return false if freeze_type
      dependency = @dependencies.first
      return false if dependency.same?(self)
      dependency.remove_observer(self)
      @observers.each do |observer|
        observer.census_replace_dependency(self, dependency)
        dependency.add_observer(observer)
      end
      @observers = SmallNodeList.new
      @dependencies = SmallNodeList.new
      true
    end
  end
end
