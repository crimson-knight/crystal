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
  # * Each instantiation typed again has the same type as before. With
  #   strict signatures and a declared return type that's guaranteed (the
  #   return type firewall); otherwise the type the new body infers is
  #   compared with the old one, which callers keep seeing meanwhile
  #   (`Def#retyping_type`).
  # * It doesn't start raising where it didn't (callers inside a `rescue`
  #   call it differently). In strict code it always counts as raising.
  #
  # Methods that take a block, `initialize` and macro defs are typed
  # together with their callers, so editing them needs a full compilation.
  # Codegen inlines trivial bodies (a literal, `self`, an instance variable)
  # at call sites: when one is involved, `full_codegen_reason` says so.
  #
  # Anything else raises `Unsupported` (a full compilation is needed). Once
  # `apply` started typing, a failure leaves the program half updated: the
  # caller must compile from scratch then too.
  class IncrementalSemantic
    class Unsupported < Exception
    end

    # Instantiations typed again by the last `apply`.
    getter retyped = [] of Def

    # Why the last `apply` needs a full codegen, if it does: codegen inlines
    # instance variable getters at their call sites, so callers' code depends
    # on such a body.
    getter full_codegen_reason : String?

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
      @full_codegen_reason = nil
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

      # What to put back if the new code doesn't compile.
      undo = [] of {Def, ASTNode, Location?, Location?}
      @consistent = false
      begin
        changed.each do |original, new_def|
          records = @program.instantiation_records.try &.[original]?
          undo << {original, original.body, original.location, original.end_location}
          update_original(original, new_def)
          records.try &.each { |record| retype(original, record) }
        end
        expanding.each do |original|
          @program.instantiation_records.try &.[original]?.try &.each { |record| retype(original, record) }
        end
      rescue ex : CodeError
        # The edit has an error: type the old bodies again so the program is
        # the last good one, and the fix can be applied incrementally too.
        # (A template's error can't be undone: expanding it again reads the
        # new template.)
        @consistent = expanding.empty? && undo(undo)

        # Instance and class variable types are guessed from the assignments
        # in every method: assigning one a new type is an error here, but
        # widens the guessed type in a full compilation, which decides.
        if ex.message.try(&.matches?(/(instance|class) variable '[^']+' of .+ must be /))
          raise Unsupported.new("an edit assigns a variable a new type, which may change its guessed type")
        end
        raise ex
      end
      @consistent = true

      # Find the changed methods by their new locations from now on
      undo.each do |original, _, old_location, _|
        if old_location && (old_filename = old_location.filename).is_a?(String)
          key = {old_filename, old_location.line_number, old_location.column_number}
          @defs_by_location.delete(key) if @defs_by_location[key]?.same?(original)
        end
      end
      undo.each do |original, _, _, _|
        if (location = original.location) && (filename = location.filename).is_a?(String)
          @defs_by_location[{filename, location.line_number, location.column_number}] = original
        end
      end

      contents.each { |filename, source| @sources[filename] = source }
    end

    # Whether the program is the last good one: `apply` finished, or an
    # error in the new code was undone. When not, compile from scratch.
    getter? consistent = true

    private def undo(undo : Array({Def, ASTNode, Location?, Location?})) : Bool
      @retyped.clear
      undo.reverse_each do |original, body, location, end_location|
        original.body = body
        original.location = location
        original.end_location = end_location
        @program.instantiation_records.try &.[original]?.try &.each { |record| retype(original, record) }
      end
      @full_codegen_reason = nil
      true
    rescue Exception
      false
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

    # The contents of *program*'s source files, as `new` takes them. Sources
    # that aren't files (the generated main of `crystal spec`, `eval`) don't
    # change while the program is kept, so they're left out.
    def self.file_sources(program : Program) : Hash(String, String)
      program.requires.each_with_object({} of String => String) do |filename, sources|
        sources[filename] = File.read(filename) if File.file?(filename)
      end
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
      old_defs = collect_defs(old_node)
      new_defs = collect_defs(new_node)

      # Methods may also have been added: the new methods are the old ones in
      # the same order with others in between.
      added = added_def_indexes(old_defs, new_defs)
      unless added && skeleton(old_node) == skeleton(new_node, added)
        raise Unsupported.new("#{filename}: more than method bodies changed")
      end

      normalized_node = @program.normalize(new_node.clone)
      normalized_defs = collect_defs(normalized_node)
      unless new_defs.size == normalized_defs.size
        raise Unsupported.new("#{filename}: methods don't line up")
      end

      changed = [] of {Def, Def}
      old_index = 0
      new_defs.each_with_index do |new_def, index|
        next if added.includes?(index)

        old_def = old_defs[old_index]
        old_index += 1
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

      # After pairing the existing methods by their old locations, which the
      # new ones may take
      added.each { |index| add_def(filename, normalized_node, normalized_defs[index]) }
      changed
    end

    # The indexes in *new_defs* of the methods added to *old_defs*, or `nil`
    # if the old ones aren't all there in the same order.
    private def added_def_indexes(old_defs : Array(Def), new_defs : Array(Def)) : Array(Int32)?
      added = [] of Int32
      old_index = 0
      new_defs.each_with_index do |new_def, index|
        if old_index < old_defs.size && signature(old_defs[old_index]) == signature(new_def)
          old_index += 1
        else
          added << index
        end
      end
      old_index == old_defs.size ? added : nil
    end

    private def signature(a_def : Def) : String
      a_def = a_def.clone
      a_def.body = Nop.new
      a_def.to_s
    end

    # Adds a method new in the file to the program. It changes nothing of the
    # existing code when no method of that name exists along the owner's
    # hierarchy (no override or overload), and nothing looks at the owner's
    # methods: `responds_to?`, macro reflection, `method_missing`. Its
    # instantiations come from the calls new code makes.
    private def add_def(filename : String, node : ASTNode, new_def : Def) : Nil
      location = new_def.location
      name = new_def.name
      chain = DefPath.find(node, new_def) || raise Unsupported.new("#{location}: def #{name} is added somewhere other than a class, struct or module")

      if name.in?("initialize", "finalize", "new", "method_missing") || new_def.abstract? || new_def.macro_def?
        raise Unsupported.new("#{location}: added def #{name} changes how the type is built or checked")
      end
      if @program.responds_to_names.includes?(name)
        raise Unsupported.new("#{location}: added def #{name} is checked with `responds_to?`")
      end

      scope = chain.reduce(@program.as(Type)) do |type, enclosing|
        name_node =
          case enclosing
          when ClassDef  then enclosing.name
          when ModuleDef then enclosing.name
          else                next type
          end
        type.lookup_type?(name_node) || raise Unsupported.new("#{location}: owner of added def #{name} not found")
      end
      owner = new_def.receiver ? scope.metaclass : scope
      hierarchy = type_hierarchy(owner)

      if hierarchy.any? { |type| type.defs.try(&.has_key?(name)) }
        raise Unsupported.new("#{location}: added def #{name} overrides or overloads an existing method")
      end
      if hierarchy.any? { |type| @program.types_with_reflected_methods.includes?(type) || type.instance_type.in?(@program.types_with_reflected_methods) }
        raise Unsupported.new("#{location}: a macro looks at the methods of #{owner}")
      end
      if hierarchy.any? { |type| type.macros.try { |macros| macros.has_key?("method_missing") || macros.has_key?("method_added") } }
        raise Unsupported.new("#{location}: #{owner} has a method_missing or method_added macro")
      end

      # Declare it by reopening the types around it with just this method
      wrapped = chain.reverse.reduce(new_def.clone.as(ASTNode)) do |inner, enclosing|
        case enclosing
        when ClassDef
          enclosing = enclosing.clone
          enclosing.body = inner
          enclosing
        when ModuleDef
          enclosing = enclosing.clone
          enclosing.body = inner
          enclosing
        when VisibilityModifier
          VisibilityModifier.new(enclosing.modifier, inner).at(enclosing)
        else
          inner
        end
      end
      wrapped.accept TopLevelVisitor.new(@program)

      added = owner.defs.try(&.[name]?).try(&.find { |def_with_metadata| def_with_metadata.def.location == location })
      raise Unsupported.new("#{location}: added def #{name} wasn't declared") unless added
      if location
        @defs_by_location[{filename, location.line_number, location.column_number}] = added.def
      end
    end

    # *type* with its ancestors and subtypes, and for a module the types
    # including it (and their subtypes): where a method of that name would
    # take part in lookup.
    private def type_hierarchy(type : Type) : Array(Type)
      types = [type] of Type
      types.concat type.ancestors
      types.concat type.all_subclasses
      if type.module?
        type.including_types.try do |including|
          including_types = including.is_a?(UnionType) ? including.union_types : [including]
          including_types.each do |including_type|
            types << including_type
            types.concat including_type.all_subclasses
          end
        end
      end
      types.uniq
    end

    # The nodes enclosing a def: classes, modules and a visibility modifier.
    # `nil` if anything else encloses it (a macro, a lib...).
    private class DefPath < Visitor
      def self.find(node : ASTNode, target : Def) : Array(ASTNode)?
        visitor = new(target)
        node.accept visitor
        visitor.found
      end

      getter found : Array(ASTNode)?
      @path = [] of ASTNode

      def initialize(@target : Def)
      end

      def visit(node : Def)
        @found = @path.dup if node.same?(@target)
        false
      end

      def visit(node : ClassDef | ModuleDef | VisibilityModifier)
        @path << node
        true
      end

      def end_visit(node : ClassDef | ModuleDef | VisibilityModifier)
        @path.pop
      end

      def visit(node : Expressions | FileNode)
        true
      end

      def visit(node : ASTNode)
        false
      end
    end

    private def parse(filename : String, source : String) : ASTNode
      parser = @program.new_parser(source)
      parser.filename = filename
      parser.parse
    end

    # Everything in *node* but method bodies, and but the methods at
    # *removed* (indexes in the order of `collect_defs`).
    private def skeleton(node : ASTNode, removed : Array(Int32) = [] of Int32) : String
      node = node.clone
      defs = collect_defs(node)
      defs.each { |a_def| a_def.body = Nop.new }
      unless removed.empty?
        node.accept DefRemover.new(removed.map { |index| defs[index] })
      end
      # `to_s` keeps blank lines between nodes from their locations
      node.to_s.gsub(/\n\s*\n+/, "\n")
    end

    # Removes the given defs (and a visibility modifier around them) from
    # the bodies containing them.
    private class DefRemover < Visitor
      def initialize(@defs : Array(Def))
      end

      private def removed?(node : ASTNode) : Bool
        target = node.is_a?(VisibilityModifier) ? node.exp : node
        @defs.any? &.same?(target)
      end

      def visit(node : Expressions)
        node.expressions.reject! { |exp| removed?(exp) }
        true
      end

      def visit(node : ClassDef | ModuleDef)
        node.body = Nop.new if removed?(node.body)
        true
      end

      def visit(node : Def)
        false
      end

      def visit(node : ASTNode)
        true
      end
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
      if original.name.in?("initialize", "finalize") || original.macro_def? || original.block_arity || original.block_arg ||
         @program.defs_typed_with_callers.includes?(original)
        raise Unsupported.new("#{location}: def #{original.name} is typed together with its callers")
      end
    end

    private def update_original(original : Def, new_def : Def) : Nil
      original.body = new_def.body
      original.location = new_def.location
      original.end_location = new_def.end_location

      # The signature is the same, but default values (copied into the
      # expansions for default arguments) may have moved. The arguments
      # themselves stay: the restrictions augmenter may have added to them.
      original.args.zip?(new_def.args) do |arg, new_arg|
        next unless new_arg
        arg.location = new_arg.location
        arg.default_value = new_arg.default_value if new_arg.default_value
      end
    end

    private def retype(original : Def, record : Program::InstantiationRecord) : Nil
      typed_def = record.typed_def
      old_type = typed_def.type?
      old_raises = typed_def.raises?
      firewall = typed_def.return_type_firewall?

      inlined_before = inlined?(typed_def.body, firewall)
      typed_def.retyping_type = old_type unless firewall
      disconnect(typed_def.body)
      typed_def.unbind_from(typed_def.body)

      body =
        if expansion = record.expansion
          original.expand_default_arguments(@program, expansion[0], expansion[1]).body.clone
        else
          original.body.clone
        end
      typed_def.body = body
      typed_def.location = original.location
      typed_def.end_location = original.end_location
      typed_def.vars = nil
      typed_def.closure = false
      typed_def.self_closured = false
      typed_def.bind_to(body)

      args = MetaVars.new
      record.vars.each do |name, type|
        var = MetaVar.new(name, type)
        if name == "self"
          args[name] = var
          next
        end
        if arg = typed_def.args.find { |arg| arg.name == name }
          var.at(arg)
        end
        var.bind_to(var)
        args[name] = var
      end

      visitor = MainVisitor.new(@program, args, typed_def)
      visitor.match_context = record.context
      visitor.untyped_def = original
      visitor.call = record.call
      visitor.scope = record.self_type
      visitor.path_lookup = record.context.defining_type
      begin
        body.accept visitor
        body.accept FixMissingTypes.new(@program)
        @program.cleanup_again(typed_def)
      ensure
        typed_def.retyping_type = nil
      end

      new_type = firewall ? typed_def.type? : typed_def.type_from_body
      unless new_type == old_type
        raise Unsupported.new("#{original.location}: #{typed_def.short_reference} now has type #{new_type}, was #{old_type}")
      end
      if typed_def.raises? && !old_raises
        raise Unsupported.new("#{original.location}: #{typed_def.short_reference} now raises")
      end

      if inlined_before || inlined?(typed_def.body, firewall)
        @full_codegen_reason ||= "#{typed_def.short_reference} has or had a trivial body, inlined at its calls"
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
          key = "#{typed_def.owner}##{typed_def.name}(#{record.vars.join(", ") { |name, type| "#{name}: #{type}" }})"
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
        # node they wrap first; a path to a hoisted literal (`$Regex:0`) has
        # the location of its first occurrence.
        line = node.location.try(&.line_number) unless node.is_a?(Expressions) || node.is_a?(Path)
        @io << node.class.name << ' ' << node.type? << ' ' << line
        if node.is_a?(Call)
          @io << " -> " << node.target_defs.try(&.map { |target| "#{target.owner}##{target.name}" }.join(", "))
        end
        @io << '\n'
        true
      end
    end

    # Whether codegen inlines a def with this body at its call sites (see
    # `CodeGenVisitor#try_inline_call`).
    private def inlined?(body : ASTNode, firewall : Bool) : Bool
      case body
      when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral
        !firewall
      when Var
        body.name == "self" && !firewall
      when InstanceVar
        true
      else
        false
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
