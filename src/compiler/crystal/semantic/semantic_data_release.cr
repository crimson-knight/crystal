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
    def release_semantic_only_data : Int32
      released = 0
      visited = Set(UInt64).new
      release_semantic_only_data(self, visited) { released += 1 }
      vars.each_value &.release_bindings
      released
    end

    private def release_semantic_only_data(type : Type, visited : Set(UInt64), &on_release : ->) : Nil
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

      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| release_semantic_only_data(instance, visited, &on_release) }
      end
      type.types?.try &.each_value { |nested| release_semantic_only_data(nested, visited, &on_release) }
      release_semantic_only_data(type.metaclass, visited, &on_release) unless type.metaclass?
    end
  end
end
