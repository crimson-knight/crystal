module Crystal::InferReuse
  # A digest of every typed def code generation can reach: from the main
  # program, class variable initializers, instance variable initializers and
  # constant values, following each call to the defs it resolved to.
  #
  # Each typed def is named by its owner, name, argument types, block type,
  # return type and location, and digested over its typed body: every node's
  # class, type, location and name or value, and the names of the defs each
  # call resolved to. Two programs typed from the same source give the same
  # digests; a typed def that a reused build typed differently, or one that
  # only one of the two programs reaches, shows up as a difference.
  class TypedProgramDigest
    include JSON::Serializable

    getter digests_by_def_name : Hash(String, Array(String))

    @[JSON::Field(ignore: true)]
    @pending = Deque(Def).new

    @[JSON::Field(ignore: true)]
    @seen = Set(Def).new.compare_by_identity

    def initialize(program : Program, node : ASTNode)
      @digests_by_def_name = {} of String => Array(String)
      digest_root(node)
      program.class_var_initializers.each { |initializer| digest_root(initializer.node) }
      visited = Set(UInt64).new
      each_type(program, visited) { |type| digest_type(type) }
      program.file_modules.each_value { |file_module| each_type(file_module, visited) { |type| digest_type(type) } }

      while typed_def = @pending.shift?
        name = TypedProgramDigest.def_name(typed_def)
        (@digests_by_def_name[name] ||= [] of String) << digest_of(typed_def.body)
      end
      @digests_by_def_name.each_value &.sort!
    end

    # The names of the defs whose digests differ, or that only one of the
    # two programs reaches.
    def differences(other : TypedProgramDigest) : Array(String)
      names = (@digests_by_def_name.keys + other.digests_by_def_name.keys).uniq.sort!
      names.reject { |name| @digests_by_def_name[name]? == other.digests_by_def_name[name]? }
    end

    def self.def_name(typed_def : Def) : String
      String.build do |io|
        io << typed_def.owner << '#' << typed_def.name << '('
        typed_def.args.join(io, ", ") { |arg, inner_io| inner_io << arg.name << " : " << arg.type? }
        io << ')'
        if block_arg = typed_def.block_arg
          io << " &" << block_arg.type?
        end
        io << " : " << typed_def.type? << " @ " << typed_def.location
      end
    end

    private def digest_root(node : ASTNode) : Nil
      (@digests_by_def_name["<root>"] ||= [] of String) << digest_of(node)
    end

    private def digest_type(type : Type) : Nil
      if type.is_a?(InstanceVarInitializerContainer)
        type.instance_vars_initializers.try &.each do |initializer|
          (@digests_by_def_name["<ivar #{type}.#{initializer.name}>"] ||= [] of String) << digest_of(initializer.value)
        end
      end
      if type.is_a?(Const) && (value = type.value) && value.type?
        (@digests_by_def_name["<const #{type}>"] ||= [] of String) << digest_of(value)
      end
    end

    private def each_type(type : Type, visited : Set(UInt64), &block : Type ->) : Nil
      return unless visited.add?(type.object_id)

      block.call(type)
      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| each_type(instance, visited, &block) }
      end
      type.types?.try &.each_value { |nested| each_type(nested, visited, &block) }
      each_type(type.metaclass, visited, &block) unless type.metaclass?
    end

    private def digest_of(node : ASTNode) : String
      digester = BodyDigester.new
      node.accept digester
      digester.list_of_target_defs.each do |target_def|
        @pending << target_def if @seen.add?(target_def)
      end
      digester.final
    end

    # Feeds every node of a typed body into a SHA-1 digest.
    class BodyDigester < Visitor
      getter list_of_target_defs = [] of Def

      @digest = Crystal::Digest::SHA1.new

      def final : String
        @digest.final.hexstring
      end

      def visit(node : ASTNode) : Bool
        text = String.build do |io|
          io << node.class.name << ' ' << node.type? << ' '
          if location = node.location
            io << location.line_number << ':' << location.column_number
          end
          io << ' '
          label(node, io)
          io << '\n'
        end
        @digest.update(text.to_slice)

        if node.is_a?(Call)
          node.each_target_def do |target_def|
            @digest.update(TypedProgramDigest.def_name(target_def).to_slice)
            @list_of_target_defs << target_def
          end
        end
        if node.responds_to?(:expanded) && (expanded = node.expanded)
          expanded.accept self if expanded.is_a?(ASTNode)
        end
        true
      end

      private def label(node : ASTNode, io : IO) : Nil
        case node
        when Call
          io << node.name
        when Var, InstanceVar, ClassVar, Global, Arg
          io << node.name
        when NumberLiteral
          io << node.value << node.kind
        when StringLiteral, CharLiteral, SymbolLiteral, BoolLiteral
          io << node
        when Path
          io << node.names.join("::")
        end
      end
    end
  end
end
