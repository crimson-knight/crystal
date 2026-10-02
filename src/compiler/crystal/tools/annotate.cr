require "../syntax/ast"
require "../compiler"

module Crystal
  class Command
    private def annotate
      dry_run = false
      config = create_compiler "tool annotate", no_codegen: true
      if options.delete("--dry-run")
        dry_run = true
      end
      config.compiler.no_codegen = true
      # The tool needs the types the bodies infer, before any are declared.
      config.compiler.strict_signatures = false
      instances = [] of Def
      result = config.compile_configure_program { |program| program.collected_def_instances = instances }

      annotator = ReturnTypeAnnotator.new(result.program, Dir.current, instances)
      annotator.process
      annotator.apply unless dry_run
      annotator.report(STDOUT, dry_run)
    end
  end

  # Infers the return types of the methods in this directory's code (except
  # `lib/`) that don't declare one, and writes them into the source, so the
  # code can be compiled with `--strict-signatures`.
  #
  # A method's type is the type of its instantiations. When they disagree it
  # tries `self` and the owner's type parameters (`T`); a method that still
  # has no single type (a duck-typed helper returning its argument's type), or
  # that is never called, is listed for a human to annotate instead.
  class ReturnTypeAnnotator
    record Edit, def_node : Def, restriction : String
    record Unresolved, def_node : Def, reason : String

    getter edits = [] of Edit
    getter unresolved = [] of Unresolved

    # Methods are matched with their instantiations by location and name: a
    # generated `new` has the location of its `initialize`.
    alias Key = {Location, String}

    @instances = Hash(Key, Array(Def)).new { |hash, key| hash[key] = [] of Def }
    @originals = {} of Key => Def

    def initialize(@program : Program, root : String, def_instances : Array(Def))
      @root = root
      def_instances.each do |typed_def|
        @instances[{typed_def.location.not_nil!, typed_def.name}] << typed_def if target?(typed_def)
      end
    end

    def process : Nil
      collect_type(@program)
      @program.file_modules.each_value { |file_module| collect_type(file_module) }

      @originals.to_a.sort_by! { |(location, _), _| {location.filename.as(String), location.line_number, location.column_number} }.each do |key, original|
        instances = @instances[key]?
        if !instances || instances.empty?
          @unresolved << Unresolved.new(original, original.abstract? ? "abstract" : "never called, so its type is unknown")
          next
        end

        if reason = ambiguous_generic(instances)
          @unresolved << Unresolved.new(original, reason)
        elsif restriction = infer(instances)
          @edits << Edit.new(original, restriction)
        else
          types = instances.compact_map(&.type?).uniq!.join(", ")
          @unresolved << Unresolved.new(original, "returns different types depending on the call: #{types}")
        end
      end
    end

    private def target?(a_def : Def) : Bool
      return false if a_def.return_type
      return false if a_def.name.in?("initialize", "finalize")
      return false if a_def.new?
      return false unless location = a_def.location
      return false unless (filename = location.filename).is_a?(String)

      filename.starts_with?(@root) && !filename.starts_with?(File.join(@root, "lib", ""))
    end

    private def collect_type(type : Type) : Nil
      if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
        type.types?.try &.each_value { |inner_type| collect_type(inner_type) }
      end

      if type.is_a?(GenericType)
        type.each_instantiated_type { |instance| collect_type(instance) }
      end

      collect_type(type.metaclass) if type.metaclass != type

      type.defs.try &.each_value do |defs_with_metadata|
        defs_with_metadata.each do |def_with_metadata|
          a_def = def_with_metadata.def
          @originals[{a_def.location.not_nil!, a_def.name}] = a_def if target?(a_def)
        end
      end
    end

    # In a generic type instantiated only once, a type like `Int32` in
    # `Box(Int32)` could be meant as `Int32` or as `T`: the body decides,
    # which needs a reader.
    private def ambiguous_generic(instances : Array(Def)) : String?
      owners = instances.map(&.owner.instance_type).uniq!
      return nil unless owners.size == 1
      owner = owners.first
      return nil unless owner.is_a?(GenericInstanceType)

      types = instances.compact_map(&.type?).uniq!
      return nil unless types.size == 1
      type = types.first
      return nil if type == owner
      return nil unless involves_type_vars?(type, owner)

      "only used with #{owner}: #{type} could be a concrete type or a type parameter"
    end

    # The restriction for the return type, as source code, or `nil`.
    private def infer(instances : Array(Def)) : String?
      # Typed defs are cached per argument types, so an instantiation can be
      # recorded more than once (e.g. with different blocks).
      instances = instances.uniq { |typed_def| {typed_def.owner, typed_def.type?} }

      candidates = nil
      instances.each do |typed_def|
        type = typed_def.type?
        return nil unless type

        options = restriction_options(typed_def, type)
        candidates = candidates ? (candidates & options) : options
        return nil if candidates.empty?
      end

      candidates.try &.first?
    end

    # The ways to write *type* for *typed_def*, most preferred first.
    private def restriction_options(typed_def : Def, type : Type) : Array(String)
      owner = typed_def.owner
      instance_owner = owner.instance_type
      options = [] of String

      concrete = convert(type, owner)
      generic_owner = instance_owner.is_a?(GenericInstanceType)

      # `self` where the type follows the owner: in a generic type, or in
      # subclasses that inherit the method. A concrete type comes first
      # otherwise, as a body like `Point.new` doesn't return a subclass.
      if (type == instance_owner || type == instance_owner.virtual_type) && generic_owner
        options << "self"
      end

      # In a generic type, write the parts that are type arguments with the
      # parameter name, so other instantiations keep working.
      if generic_owner && (substituted = substitute_type_vars(type, owner, instance_owner.as(GenericInstanceType)))
        options << substituted if substituted != concrete
      end

      # A concrete type in a generic type is fine unless it involves a type
      # argument: `def size : Int32` but not `def first : Int32` in `Box(T)`.
      if concrete && !(generic_owner && involves_type_vars?(type, instance_owner.as(GenericInstanceType)))
        options << concrete
      end

      if (type == instance_owner || type == instance_owner.virtual_type) && !generic_owner
        options << "self"
      end

      options
    end

    private def convert(type : Type, scope : Type) : String?
      node = TypeToRestriction.new(scope.instance_type).convert(type)
      return nil unless node
      return nil if contains_underscore?(node)

      simplify_paths(node, scope)
      prettify(node.to_s)
    end

    private def substitute_type_vars(type : Type, scope : Type, owner : GenericInstanceType) : String?
      node = TypeToRestriction.new(scope.instance_type).convert(type)
      return nil unless node
      return nil if contains_underscore?(node)

      replacements = {} of String => String
      owner.type_vars.each do |name, type_var|
        next unless (var_type = type_var.type?) && !type_var.is_a?(NumberLiteral)
        if converted = TypeToRestriction.new(scope.instance_type).convert(var_type)
          replacements[converted.to_s] = name
        end
      end
      return nil if replacements.empty?

      node = replace_subtrees(node, replacements)
      simplify_paths(node, scope)
      prettify(node.to_s)
    end

    private def replace_subtrees(node : ASTNode, replacements : Hash(String, String)) : ASTNode
      if name = replacements[node.to_s]?
        return Path.new(name)
      end

      case node
      when Generic
        node.type_vars = node.type_vars.map { |type_var| replace_subtrees(type_var, replacements).as(ASTNode) }
        node.named_args.try &.each { |named_arg| named_arg.value = replace_subtrees(named_arg.value, replacements) }
      when Union
        node.types = node.types.map { |union_type| replace_subtrees(union_type, replacements).as(ASTNode) }
      when Metaclass
        node.name = replace_subtrees(node.name, replacements)
      when ProcNotation
        node.inputs = node.inputs.try &.map { |input| replace_subtrees(input, replacements).as(ASTNode) }
        node.output = node.output.try { |output| replace_subtrees(output, replacements) }
      end
      node
    end

    private def involves_type_vars?(type : Type, owner : GenericInstanceType) : Bool
      owner.type_vars.any? do |_, type_var|
        next false if type_var.is_a?(NumberLiteral)
        var_type = type_var.type?
        var_type && (type == var_type || type_mentions?(type, var_type))
      end
    end

    private def type_mentions?(type : Type, needle : Type) : Bool
      return true if type == needle

      case type
      when UnionType
        type.union_types.any? { |union_type| type_mentions?(union_type, needle) }
      when GenericInstanceType
        type.type_vars.any? do |_, type_var|
          (var_type = type_var.type?) ? type_mentions?(var_type, needle) : false
        end
      else
        false
      end
    end

    private def contains_underscore?(node : ASTNode) : Bool
      found = false
      node.accept(UnderscoreFinder.new { found = true })
      found
    end

    private class UnderscoreFinder < Visitor
      def initialize(&@on_found : ->)
      end

      def visit(node : Underscore)
        @on_found.call
        false
      end

      def visit(node : ASTNode)
        true
      end
    end

    # `TypeToRestriction` writes public types fully qualified (`::Int32`).
    # Drop the `::` where the name resolves to the same type from the
    # method's scope anyway.
    private def simplify_paths(node : ASTNode, scope : Type) : Nil
      node.accept(PathSimplifier.new(scope.instance_type))
    end

    private class PathSimplifier < Visitor
      def initialize(@scope : Type)
      end

      # Uses the shortest suffix of the name (`Point` for `App::Point`) that
      # resolves to the same type from the scope.
      def visit(node : Path)
        return false unless node.global?
        return false unless global_type = @scope.program.lookup_type?(Path.new(node.names))

        (node.names.size - 1).downto(0) do |start|
          names = node.names[start..]
          local_type = begin
            @scope.lookup_type?(Path.new(names))
          rescue CodeError
            nil
          end
          if local_type == global_type
            node.names = names
            node.global = false
            break
          end
        end
        false
      end

      def visit(node : ASTNode)
        true
      end
    end

    # `(Foo | ::Nil)` reads better as `Foo?`.
    private def prettify(restriction : String) : String
      restriction = restriction.lchop('(').rchop(')') if restriction.starts_with?('(') && restriction.ends_with?(')') && balanced_inside?(restriction)
      if restriction.ends_with?(" | Nil") && restriction.count('|') == 1
        restriction = "#{restriction.rchop(" | Nil")}?"
      elsif restriction.starts_with?("Nil | ") && restriction.count('|') == 1
        restriction = "#{restriction.lchop("Nil | ")}?"
      end
      restriction
    end

    private def balanced_inside?(text : String) : Bool
      depth = 0
      text.each_char_with_index do |char, index|
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        return false if depth == 0 && index < text.size - 1
      end
      true
    end

    # Writes the edits into the source files.
    def apply : Nil
      @edits.group_by { |edit| edit.def_node.location.not_nil!.filename.as(String) }.each do |filename, edits|
        source = File.read(filename)
        line_offsets = [0]
        source.each_char_with_index { |char, index| line_offsets << index + 1 if char == '\n' }

        insertions = edits.compact_map do |edit|
          location = edit.def_node.location.not_nil!
          start = line_offsets[location.line_number - 1] + location.column_number - 1
          if offset = signature_end(source, start)
            {offset, " : #{edit.restriction}"}
          end
        end

        insertions.sort_by! { |offset, _| -offset }
        insertions.each do |offset, text|
          source = source.insert(offset, text)
        end
        File.write(filename, source)
      end
    end

    # The offset right after the method's name or its closing `)`, where the
    # return type goes. `nil` if the signature can't be found.
    private def signature_end(source : String, start : Int32) : Int32?
      def_index = source.index(/\bdef\s+/, start)
      return nil unless def_index

      index = def_index + 3
      while index < source.size && source[index].whitespace?
        index += 1
      end

      # The name: everything up to `(`, whitespace or `;`. Operator names
      # such as `[]=` or `<=>` contain none of these.
      name_start = index
      while index < source.size && !source[index].in?('(', ' ', '\t', '\n', '\r', ';')
        index += 1
      end
      return nil if index == name_start
      return index unless index < source.size && source[index] == '('

      depth = 0
      quote = nil
      while index < source.size
        char = source[index]
        if quote
          if char == '\\'
            index += 1
          elsif char == quote
            quote = nil
          end
        else
          case char
          when '"', '\''
            quote = char
          when '('
            depth += 1
          when ')'
            depth -= 1
            return index + 1 if depth == 0
          end
        end
        index += 1
      end
      nil
    end

    def report(io : IO, dry_run : Bool) : Nil
      current_dir = Dir.current
      relative = ->(def_node : Def) do
        location = def_node.location.not_nil!
        "#{::Path[location.filename.as(String)].relative_to(current_dir)}:#{location.line_number}"
      end

      if dry_run
        @edits.each do |edit|
          io.puts "#{relative.call(edit.def_node)}: def #{edit.def_node.name} : #{edit.restriction}"
        end
        io.puts
      end

      io.puts "#{dry_run ? "Would annotate" : "Annotated"} #{@edits.size} method#{@edits.size == 1 ? "" : "s"}."
      return if @unresolved.empty?

      io.puts "#{@unresolved.size} method#{@unresolved.size == 1 ? "" : "s"} need a return type by hand:"
      @unresolved.each do |item|
        io.puts "  #{relative.call(item.def_node)}: def #{item.def_node.name} — #{item.reason}"
      end
    end
  end
end
