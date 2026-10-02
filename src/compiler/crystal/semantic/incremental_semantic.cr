require "../syntax/ast"
require "../syntax/parser"

module Crystal
  # Applies body-only edits to a program that was already typed, by typing
  # again just the instantiations of the methods whose body changed.
  #
  # This is sound when the rest of the program can't observe the edit:
  #
  # * The file's structure is unchanged: everything but method bodies prints
  #   the same, so the same types, methods, macros and requires exist.
  # * Each changed method is in strict code (`--strict-signatures`) and
  #   declares its return type, so callers see the declared type whatever the
  #   body infers (the return type firewall).
  # * Its instantiations still have the same type after typing again. (They
  #   always count as raising in strict code, so a body that starts raising
  #   doesn't change how callers call them.)
  #
  # Methods that take a block, `initialize` and macro defs are typed
  # together with their callers, so editing them needs a full compilation.
  #
  # Anything else raises `Unsupported` (a full compilation is needed). Once
  # `apply` started typing, a failure leaves the program half updated: the
  # caller must compile from scratch then too.
  class IncrementalSemantic
    class Unsupported < Exception
    end

    # Instantiations typed again by the last `apply`.
    getter retyped = [] of Def

    # *sources* are the contents the program was compiled from, by filename.
    def initialize(@program : Program, @sources : Hash(String, String))
      @defs_by_location = {} of {String, Int32, Int32} => Def
      index_defs(@program)
      @program.file_modules.each_value { |file_module| index_defs(file_module) }
    end

    # Applies the new *contents* of some source files (by filename), and
    # changes to files macros read (*changed_inputs*: templates, a `run`
    # program's data): the methods whose body expanded such a macro are
    # typed again, which expands it again.
    def apply(contents : Hash(String, String), changed_inputs : Enumerable(String) = [] of String) : Nil
      @retyped.clear
      changed = [] of {Def, Def}

      contents.each do |filename, new_source|
        old_source = @sources[filename]? || raise Unsupported.new("#{filename} wasn't part of the program")
        next if old_source == new_source

        changed.concat changed_defs(filename, old_source, new_source)
      end

      expanding = Set(Def).new.compare_by_identity
      changed_inputs.each do |path|
        macro_input_users(path).each { |user| expanding << user }
      end
      changed.each { |original, _| expanding.delete(original) }

      changed.each { |original, _| check_retypeable(original) }
      expanding.each { |original| check_retypeable(original) }

      changed.each do |original, new_def|
        records = @program.instantiation_records.try &.[original]?
        update_original(original, new_def)
        records.try &.each { |record| retype(original, record) }
      end
      expanding.each do |original|
        @program.instantiation_records.try &.[original]?.try &.each { |record| retype(original, record) }
      end

      contents.each { |filename, source| @sources[filename] = source }
    end

    # The source files whose content differs from what the program was last
    # updated with, and the files macros read whose content changed since:
    # what `apply` should be given after changes that weren't watched one
    # by one (see `crystal watch hold`).
    def changed_files : Array(String)
      changed = @sources.compact_map do |filename, source|
        current = File.read(filename) rescue nil
        filename unless current == source
      end
      @program.external_macro_inputs.each do |key, value|
        kind, _, input = key.partition(':')
        next unless kind.in?("read_file", "file_exists", "dir_tree")
        next if @sources.has_key?(input)
        changed << input unless IncrementalCache::ExternalInput.unchanged?({key => value})
      end
      changed.uniq
    end

    # Whether *filename* is one of the program's source files.
    def source?(filename : String) : Bool
      @sources.has_key?(filename)
    end

    # The methods whose body expanded a macro that read *path* (or a
    # directory containing it).
    private def macro_input_users(path : String) : Array(Def)
      path = File.expand_path(path)
      users = [] of Def
      found = false
      @program.external_macro_input_users.each do |key, key_users|
        kind, _, input = key.partition(':')
        next unless kind.in?("read_file", "file_exists", "dir_tree")
        next unless input == path || (kind == "dir_tree" && path.starts_with?(File.join(input, "")))

        found = true
        if key_users.includes?(nil)
          raise Unsupported.new("#{path} is read by a macro outside a method body")
        end
        key_users.each { |user| users << user.not_nil! }
      end
      raise Unsupported.new("#{path} changed, but no macro of the program read it") unless found
      users
    end

    # The files and directories macros of *program* read, for watching. A
    # directory read as a whole comes with its subdirectories and files.
    def self.macro_input_paths(program : Program) : Set(String)
      paths = Set(String).new
      program.external_macro_inputs.each_key do |key|
        kind, _, input = key.partition(':')
        case kind
        when "read_file", "file_exists"
          paths << input
        when "dir_tree"
          paths << input
          Dir.glob(File.join(::Path[input].to_posix.to_s, "**", "*"), match: :dot_files) { |entry| paths << entry }
        end
      end
      paths
    end

    private def index_defs(type : Type) : Nil
      if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
        type.types?.try &.each_value { |inner_type| index_defs(inner_type) }
      end
      index_defs(type.metaclass) if type.metaclass != type

      type.defs.try &.each_value do |defs_with_metadata|
        defs_with_metadata.each do |def_with_metadata|
          a_def = def_with_metadata.def
          if (location = a_def.location) && (filename = location.filename).is_a?(String)
            @defs_by_location[{filename, location.line_number, location.column_number}] = a_def
          end
        end
      end
    end

    # The methods of *filename* whose body or position changed, as the
    # program's def and the newly parsed (and normalized) one.
    private def changed_defs(filename : String, old_source : String, new_source : String) : Array({Def, Def})
      old_node = parse(filename, old_source)
      new_node = parse(filename, new_source)

      unless skeleton(old_node) == skeleton(new_node)
        raise Unsupported.new("#{filename}: more than method bodies changed")
      end

      old_defs = collect_defs(old_node)
      new_defs = collect_defs(new_node)
      normalized_defs = collect_defs(@program.normalize(new_node.clone))
      unless old_defs.size == new_defs.size == normalized_defs.size
        raise Unsupported.new("#{filename}: methods don't line up")
      end

      changed = [] of {Def, Def}
      old_defs.each_with_index do |old_def, index|
        new_def = new_defs[index]
        next if old_def.body.to_s == new_def.body.to_s && same_position?(old_def, new_def)
        next if old_def.abstract?

        location = old_def.location.not_nil!
        original = @defs_by_location[{filename, location.line_number, location.column_number}]?
        raise Unsupported.new("#{location}: def #{old_def.name} not found in the program") unless original

        unless same_body_flags?(old_def, new_def)
          raise Unsupported.new("#{location}: def #{old_def.name} changed how it uses blocks, super or special variables")
        end

        changed << {original, normalized_defs[index]}
      end
      changed
    end

    private def parse(filename : String, source : String) : ASTNode
      parser = @program.new_parser(source)
      parser.filename = filename
      parser.parse
    end

    # Everything in *node* but method bodies.
    private def skeleton(node : ASTNode) : String
      node = node.clone
      collect_defs(node).each { |a_def| a_def.body = Nop.new }
      node.to_s
    end

    private def collect_defs(node : ASTNode) : Array(Def)
      collector = DefCollector.new
      node.accept collector
      collector.defs
    end

    private class DefCollector < Visitor
      getter defs = [] of Def

      def visit(node : Def)
        @defs << node
        false
      end

      def visit(node : ASTNode)
        true
      end
    end

    # A method that only moved (lines were added above it) is typed again
    # too, so that its nodes get their new locations.
    private def same_position?(old_def : Def, new_def : Def) : Bool
      old_def.location.try(&.line_number) == new_def.location.try(&.line_number) &&
        old_def.end_location.try(&.line_number) == new_def.end_location.try(&.line_number)
    end

    # The parser derives these from the body; they change how the method is
    # instantiated and called.
    private def same_body_flags?(old_def : Def, new_def : Def) : Bool
      old_def.block_arity == new_def.block_arity &&
        old_def.uses_block_arg? == new_def.uses_block_arg? &&
        old_def.calls_super? == new_def.calls_super? &&
        old_def.calls_initialize? == new_def.calls_initialize? &&
        old_def.calls_previous_def? == new_def.calls_previous_def? &&
        old_def.assigns_special_var? == new_def.assigns_special_var?
    end

    private def check_retypeable(original : Def) : Nil
      location = original.location
      unless @program.strict_file?(location.try(&.original_filename))
        raise Unsupported.new("#{location}: def #{original.name} isn't strict code (--strict-signatures)")
      end
      raise Unsupported.new("#{location}: def #{original.name} has no return type") unless original.return_type
      if original.name.in?("initialize", "finalize") || original.macro_def? || original.block_arity || original.block_arg
        raise Unsupported.new("#{location}: def #{original.name} is typed together with its callers")
      end
    end

    private def update_original(original : Def, new_def : Def) : Nil
      original.body = new_def.body
      original.location = new_def.location
      original.end_location = new_def.end_location
    end

    private def retype(original : Def, record : Program::InstantiationRecord) : Nil
      typed_def = record.typed_def
      old_type = typed_def.type?
      old_raises = typed_def.raises?

      disconnect(typed_def.body)
      typed_def.unbind_from(typed_def.body)

      body = original.body.clone
      typed_def.body = body
      typed_def.location = original.location
      typed_def.end_location = original.end_location
      typed_def.vars = nil
      typed_def.closure = false
      typed_def.self_closured = false
      typed_def.bind_to(body)

      args = MetaVars.new
      if self_type = record.self_type
        args["self"] = MetaVar.new("self", self_type)
      end
      record.arg_types.each_with_index do |type, index|
        arg = typed_def.args[index]
        var = MetaVar.new(arg.name, type).at(arg)
        var.bind_to(var)
        args[arg.name] = var
      end

      visitor = MainVisitor.new(@program, args, typed_def)
      visitor.match_context = record.context
      visitor.untyped_def = original
      visitor.call = record.call
      visitor.scope = record.self_type
      visitor.path_lookup = record.context.defining_type
      body.accept visitor
      body.accept FixMissingTypes.new(@program)
      @program.cleanup_again(typed_def)

      unless typed_def.type?.same?(old_type)
        raise Unsupported.new("#{original.location}: #{typed_def.short_reference} now has type #{typed_def.type?}, was #{old_type}")
      end
      if typed_def.raises? && !old_raises
        raise Unsupported.new("#{original.location}: #{typed_def.short_reference} now raises")
      end

      @retyped << typed_def
    end

    # Every typed method of the code under *root*: its signature, and its
    # type, location and typed body. Two programs typed from the same sources
    # must agree on these; used to verify incremental results.
    def self.typed_methods(program : Program, root : String) : Hash(String, String)
      methods = {} of String => String
      program.instantiation_records.try &.each_value do |records|
        records.each do |record|
          typed_def = record.typed_def
          next unless (filename = typed_def.location.try(&.filename)).is_a?(String) && filename.starts_with?(root)
          key = "#{typed_def.owner}##{typed_def.name}(#{record.arg_types.join(", ")})"
          methods[key] = describe(typed_def)
        end
      end
      methods
    end

    private def self.describe(typed_def : Def) : String
      description = String.build do |io|
        io << "type: " << typed_def.type? << '\n'
        io << "line: " << typed_def.location.try(&.line_number) << '\n'
        io << typed_def.body << '\n'
        typed_def.body.accept(TypeLister.new(io))
      end
      canonical_names(description)
    end

    # Macros can generate random or counter based names (`buf3f1c...`,
    # `__temp_12`), which differ between any two compilations. Number them
    # in order of appearance instead.
    private def self.canonical_names(text : String) : String
      names = {} of String => String
      text.gsub(/\b__\w+|\b[A-Za-z_]+[0-9a-f]{8,}\b/) do |name|
        names[name] ||= "__name#{names.size}"
      end
    end

    private class TypeLister < Visitor
      def initialize(@io : IO)
      end

      def visit(node : ASTNode)
        # Expressions are often synthesized, with the location of whatever
        # node they wrap first.
        line = node.location.try(&.line_number) unless node.is_a?(Expressions)
        @io << node.class.name << ' ' << node.type? << ' ' << line
        if node.is_a?(Call)
          @io << " -> " << node.target_defs.try(&.map { |target| "#{target.owner}##{target.name}" }.join(", "))
        end
        @io << '\n'
        true
      end
    end

    # Removes the nodes of a body that is being replaced from the type graph,
    # so that what they depended on doesn't keep updating them.
    private def disconnect(node : ASTNode) : Nil
      node.accept Disconnector.new
    end

    private class Disconnector < Visitor
      def visit(node : ASTNode)
        node.dependencies.each &.remove_observer(node)
        true
      end
    end
  end
end
