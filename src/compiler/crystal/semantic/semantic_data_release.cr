module Crystal
  class Program
    # Drops the bodies of untyped method and macro definitions once semantic
    # analysis is complete and only codegen remains.
    #
    # Every call is typed against a *clone* of the untyped def
    # (see `Call#prepare_typed_def_with_args`), and codegen only reads typed
    # defs, so the original bodies are dead weight from here on. In a large
    # app they are a sizeable part of the heap (macro-generated methods for
    # 300 Grant models: about 0.9 GB of a 6.7 GB live heap).
    #
    # `External` defs (`fun` declarations, including `fun`s with a Crystal
    # body) are typed in place and code-generated directly, so they are kept.
    #
    # It also drops the type-inference edges of instance, class and global
    # vars and the calls waiting for new subclasses. They reach into every
    # method body, so without this no typed body could be freed during
    # codegen (see `CodeGenVisitor#release_typed_bodies?`).
    #
    # Must only be called when nothing will run semantic analysis on this
    # program again. Returns the number of bodies released.
    #
    # With *main_node* (the program as semantic analysis returned it) it
    # also drops the type-inference edges of every node codegen will read
    # (see `InferenceEdgeReleaser`).
    def release_semantic_only_data(main_node : ASTNode? = nil) : Int32
      released = 0
      visited = Set(UInt64).new
      edge_releaser = main_node && InferenceEdgeReleaser.enabled? ? InferenceEdgeReleaser.new(self) : nil
      release_semantic_only_data(self, visited, edge_releaser) { released += 1 }
      # Private top-level defs live in the module of their file.
      file_modules.each_value do |file_module|
        release_semantic_only_data(file_module, visited, edge_releaser) { released += 1 }
      end
      vars.each_value &.release_bindings
      if edge_releaser && main_node
        edge_releaser.release(main_node)
        class_var_initializers.each do |initializer|
          edge_releaser.release(initializer.node)
          edge_releaser.release(initializer.meta_vars)
        end
        file_modules.each_value do |file_module|
          file_module.vars?.try { |file_vars| edge_releaser.release(file_vars) }
        end
        # The text of every macro expansion: large strings that only an
        # error message would read from here on.
        virtual_files.each &.release_source
        @last_inference_edge_releaser = edge_releaser
      end
      released
    end

    # The releaser the last `#release_semantic_only_data` ran, for its
    # counters.
    getter last_inference_edge_releaser : InferenceEdgeReleaser?

    private def release_semantic_only_data(type : Type, visited : Set(UInt64), edge_releaser : InferenceEdgeReleaser?, &on_release : ->) : Nil
      return unless visited.add?(type.object_id)

      if type.is_a?(ModuleType)
        type.defs.try &.each_value do |list|
          list.each do |def_with_metadata|
            untyped_def = def_with_metadata.def
            next if untyped_def.is_a?(External)
            next if untyped_def.body.is_a?(Primitive) || untyped_def.body.is_a?(Nop)
            untyped_def.body = Nop.new
            on_release.call
          end
        end
        type.macros.try &.each_value do |list|
          list.each do |macro_definition|
            next if macro_definition.body.is_a?(Nop)
            macro_definition.body = Nop.new
            on_release.call
          end
        end
      end

      if type.is_a?(InstanceVarContainer)
        type.@instance_vars.try &.each_value &.release_bindings
      end
      if type.is_a?(ClassVarContainer)
        type.@class_vars.try &.each_value &.release_bindings
      end
      type.release_subclass_observers if type.is_a?(SubclassObservable)

      if edge_releaser
        if type.is_a?(DefInstanceContainer)
          type.@def_instances.try &.each_value { |typed_def| edge_releaser.release(typed_def) }
          # A def typed for calls with a block belongs to those calls from
          # here on: it is freed with the last body that calls it.
          type.release_block_def_instances
        end
        if type.is_a?(InstanceVarInitializerContainer)
          type.instance_vars_initializers.try &.each do |initializer|
            edge_releaser.release(initializer.value)
            edge_releaser.release(initializer.meta_vars)
          end
        end
        if type.is_a?(Const)
          edge_releaser.release(type.value)
          type.fake_def.try { |fake_def| edge_releaser.release(fake_def) }
          type.visitor = nil
        end
      end

      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| release_semantic_only_data(instance, visited, edge_releaser, &on_release) }
      end
      type.types?.try &.each_value { |nested| release_semantic_only_data(nested, visited, edge_releaser, &on_release) }
      release_semantic_only_data(type.metaclass, visited, edge_releaser, &on_release) unless type.metaclass?

      # A virtual type holds typed defs of its own (the ones called on it).
      if virtual_type = type.existing_virtual_type
        release_semantic_only_data(virtual_type, visited, edge_releaser, &on_release)
      end
    end
  end

  # Drops the type-inference edges (dependencies and observers) of the nodes
  # codegen will read, and the visitors that typed them, once semantic
  # analysis is complete.
  #
  # Codegen reads the type of a node, never its edges. The edges tie the
  # program into one web: a call observes the defs it resolved to, a variable
  # observes every value assigned to it, and each call keeps the visitor that
  # typed it, which keeps the variables and filters of its whole method. As
  # long as they exist, the body of a method whose function has been
  # generated stays reachable from the methods that call it and from the
  # methods it calls, so `CodeGenVisitor#release_typed_bodies?` frees almost
  # nothing: measured on a program of 300 Grant models, 3.2 GB of the 3.5 GB
  # that type inference left were still live when IR generation ended
  # (notes/peak-heap.md).
  #
  # Two edges are kept because codegen reads them: a local variable that
  # depends on `Program#nil_var` (`CodeGenVisitor#bound_to_mod_nil?`), and a
  # call to a lib variable, which depends on its `External`.
  #
  # `CRYSTAL_RELEASE_INFERENCE_EDGES=0` turns the releaser off.
  class InferenceEdgeReleaser < Visitor
    # How many nodes and typed defs had their edges dropped.
    getter released_node_count = 0_i64
    getter released_def_count = 0

    @list_of_pending_defs = [] of Def
    @seen_def_ids = Set(UInt64).new
    @nil_var : ASTNode

    def self.enabled? : Bool
      ENV["CRYSTAL_RELEASE_INFERENCE_EDGES"]? != "0"
    end

    def initialize(program : Program)
      @nil_var = program.nil_var
    end

    # Releases *node*, everything below it, and every typed def its calls
    # resolved to.
    def release(node : ASTNode) : Nil
      if node.is_a?(Def)
        enqueue(node)
      else
        node.accept(self)
      end
      # Typed defs are released from a list, not by recursion: a chain of
      # calls can be as long as the program.
      while typed_def = @list_of_pending_defs.pop?
        @released_def_count += 1
        typed_def.accept(self)
      end
    end

    def release(meta_vars : MetaVars) : Nil
      meta_vars.each_value do |meta_var|
        meta_var.release_bindings(@nil_var)
        @released_node_count += 1
      end
    end

    private def enqueue(typed_def : Def) : Nil
      @list_of_pending_defs << typed_def if @seen_def_ids.add?(typed_def.object_id)
    end

    # A node that was replaced (an expanded literal or macro call, a
    # rewritten `is_a?`) is released through its replacement only: that is
    # what codegen reads, and the replacement shares nodes with the original,
    # so walking both would visit a chain of nested expansions once per path.
    def visit(node : ASTNode) : Bool
      node.release_bindings
      @released_node_count += 1
      if node.is_a?(ExpandableNode)
        return release_replacement(node.expanded)
      end
      true
    end

    # Releases *replacement* if there is one. Returns whether the children
    # of the replaced node must be walked.
    private def release_replacement(replacement : ASTNode?) : Bool
      return true unless replacement

      replacement.accept(self)
      false
    end

    def visit(node : Def) : Bool
      node.release_bindings
      @released_node_count += 1
      node.vars.try { |vars| release(vars) }
      # The record of the calls that share this def keeps each call and its
      # block, and with them the bodies those blocks are in.
      node.block_instance = nil
      true
    end

    def visit(node : Call) : Bool
      first_dependency = node.dependencies.first?
      node.release_bindings(first_dependency.is_a?(External) ? first_dependency : nil)
      node.release_inference_state
      @released_node_count += 1
      node.each_target_def { |target_def| enqueue(target_def) }
      release_replacement(node.expanded)
    end

    def visit(node : Block) : Bool
      node.release_bindings
      @released_node_count += 1
      node.vars.try { |vars| release(vars) }
      node.after_vars = nil
      node.binder = nil
      # Codegen reads the block or the proc literal made from it, depending
      # on the def that is called.
      node.fun_literal.try &.accept(self)
      true
    end

    def visit(node : While) : Bool
      node.release_bindings
      @released_node_count += 1
      node.break_vars = nil
      true
    end

    def visit(node : Path) : Bool
      node.release_bindings
      @released_node_count += 1
      release_replacement(node.syntax_replacement)
    end

    def visit(node : IsA) : Bool
      node.release_bindings
      @released_node_count += 1
      release_replacement(node.syntax_replacement)
    end

    def visit(node : Yield) : Bool
      node.release_bindings
      @released_node_count += 1
      release_replacement(node.expanded)
    end

    def visit(node : ProcPointer) : Bool
      node.release_bindings
      @released_node_count += 1
      release_replacement(node.expanded)
    end

    def visit(node : Primitive) : Bool
      node.release_bindings
      @released_node_count += 1
      node.extra.try &.accept(self)
      true
    end
  end
end
