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

    # With `CRYSTAL_INFER_REUSE_DIGEST_TEXT` set to a directory, the text each
    # digest was made from goes to `<directory>/<pid>.txt`, for comparing two
    # programs by hand when a verification fails.
    @[JSON::Field(ignore: true)]
    @text : IO::Memory? = ENV["CRYSTAL_INFER_REUSE_DIGEST_TEXT"]?.try { IO::Memory.new }

    def initialize(program : Program, node : ASTNode)
      @digests_by_def_name = {} of String => Array(String)
      digest_root(node)
      program.class_var_initializers.each { |initializer| digest_root(initializer.node) }
      visited = Set(UInt64).new
      each_type(program, visited) { |type| digest_type(type) }
      program.file_modules.each_value { |file_module| each_type(file_module, visited) { |type| digest_type(type) } }

      while typed_def = @pending.shift?
        name = TypedProgramDigest.def_name(typed_def)
        @text.try { |io| io << "== " << name << "\n" }
        (@digests_by_def_name[name] ||= [] of String) << digest_of(typed_def.body)
      end
      @digests_by_def_name.each_value &.sort!
      if (text = @text) && (directory = ENV["CRYSTAL_INFER_REUSE_DIGEST_TEXT"]?)
        File.write(File.join(directory, "#{::Process.pid}.txt"), text.to_s)
      end
    end

    # The names of the defs whose digests differ, or that only one of the
    # two programs reaches.
    def differences(other : TypedProgramDigest) : Array(String)
      names = (@digests_by_def_name.keys + other.digests_by_def_name.keys).uniq.sort!
      names.reject { |name| @digests_by_def_name[name]? == other.digests_by_def_name[name]? }
    end

    def self.def_name(typed_def : Def) : String
      # Fresh argument names (`__temp_*`, as in a string interpolation's
      # `String.interpolation` instance) come from a counter of the whole
      # program, so they are numbered in argument order, as bodies number them.
      number_by_fresh_name = {} of String => Int32
      String.build do |io|
        io << typed_def.owner << '#' << typed_def.name << '('
        typed_def.args.join(io, ", ") do |arg, inner_io|
          if arg.name.matches_full?(MethodListExpansion::FRESH_NAME)
            inner_io << "__fresh_" << (number_by_fresh_name[arg.name] ||= number_by_fresh_name.size)
          else
            inner_io << arg.name
          end
          inner_io << " : " << arg.type?
        end
        io << ')'
        if block_arg = typed_def.block_arg
          io << " &" << block_arg.type?
        end
        io << " : " << typed_def.type? << " @ "
        stable_location(typed_def.location, io)
      end
    end

    # A location as two processes that expand the same macros print it: a
    # macro expansion is named by where it was expanded, not by its virtual
    # file's name, which holds a memory address.
    def self.stable_location(location : Location?, io : IO) : Nil
      return unless location
      filename = location.filename
      if filename.is_a?(VirtualFile)
        io << "macro expanded at "
        stable_location(filename.expanded_location, io)
        io << " line " << location.line_number << ":" << location.column_number
      else
        io << filename << ":" << location.line_number << ":" << location.column_number
      end
    end

    private def digest_root(node : ASTNode) : Nil
      @text.try { |io| io << "== <root>\n" }
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
      digester = BodyDigester.new(@text)
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

      # Fresh variable names (`__temp_*`) numbered in the order they appear in
      # the body: the compiler numbers them from a counter of the whole
      # program, so a body typed again by a build server gets other numbers
      # than a fresh type check gives it, for the same code.
      @number_by_fresh_name = {} of String => Int32

      def initialize(@text : IO?)
      end

      def final : String
        @digest.final.hexstring
      end

      def visit(node : ASTNode) : Bool
        # A method or macro definition in the program's source is not code:
        # its typed instances are digested on their own, from the calls that
        # reach them. (A build server adds and removes methods in its types
        # without changing the parsed nodes that declared them.)
        return false if node.is_a?(Def) || node.is_a?(Macro)

        text = String.build do |io|
          io << node.class.name << ' ' << node.type? << ' '
          # An `Expressions` gets a location or not depending on how its file
          # was parsed (an incremental build parses differently); code
          # generation does not use it.
          if !node.is_a?(Expressions) && (location = node.location)
            io << location.line_number << ':' << location.column_number
          end
          io << ' '
          label(node, io)
          io << '\n'
        end
        @digest.update(text.to_slice)
        @text.try { |io| io << text }

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
        when Var, Arg
          io << canonical_name(node.name)
        when InstanceVar, ClassVar, Global
          io << node.name
        when NumberLiteral
          io << node.value << node.kind
        when StringLiteral, CharLiteral, SymbolLiteral, BoolLiteral
          io << node
        when Path
          io << node.names.join("::")
        when ErasedTypeVar
          io << node.owner << '.' << node.name
        end
      end

      private def canonical_name(name : String) : String
        return name unless name.matches_full?(MethodListExpansion::FRESH_NAME)
        "__fresh_#{@number_by_fresh_name[name] ||= @number_by_fresh_name.size}"
      end
    end
  end
end
