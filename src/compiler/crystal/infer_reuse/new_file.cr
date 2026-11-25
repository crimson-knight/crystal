module Crystal::InferReuse
  # A source file that a glob `require` of the kept build (`require
  # "./models/**"`) finds now and did not find before.
  #
  # The kept program can take it in, and keep everything it typed, when the
  # file only declares new types that nothing in the kept program can tell
  # apart from their absence:
  #
  # * the file holds non-generic, non-abstract classes and structs with a
  #   top-level name the program does not have, each directly below
  #   `Reference` or `Struct`, with no annotations;
  # * their bodies hold methods (no macro methods), instance variable
  #   declarations without a value and the accessor macros of the standard
  #   library (`getter`, `property` and their kin);
  # * no macro of the kept build listed the subclasses, includers or
  #   constants of the program or of an ancestor of a new type, or asked
  #   for one of their constants, and no ancestor has a hook (`inherited`,
  #   `method_added`);
  # * after re-typing, no typed method of the program holds a value whose
  #   type is the virtual type of an ancestor of a new type (a new struct in
  #   an `Array(Struct)` would reach dispatches typed without it).
  #
  # The new types are declared by the passes of the top-level phase, run on
  # the new file alone; their methods are typed when an edited method body
  # calls them, as any method is. A new file of any other kind types the
  # whole program again.
  class NewFile
    # The accessor macros a new type may call in its body.
    ACCESSOR_MACRO_NAMES = {
      "getter", "getter?", "getter!", "property", "property?", "property!", "setter",
      "class_getter", "class_getter?", "class_property", "class_property?", "class_setter",
      "def_equals", "def_hash", "def_equals_and_hash",
    }

    getter filename : String
    getter text : String
    getter list_of_type_names = [] of String

    @node : ASTNode

    def initialize(@filename : String, @text : String, @node : ASTNode)
    end

    # Parses the file named *filename* and checks it declares only what the
    # kept program can take in. Raises `Refusal` otherwise.
    def self.parse(program : Program, filename : String) : NewFile
      text = begin
        File.read(filename)
      rescue ex : IO::Error
        raise Refusal.new("can't read new file #{filename}: #{ex.message}")
      end
      parser = program.new_parser(text)
      parser.filename = filename
      node = begin
        parser.parse
      rescue ex : CodeError
        raise Refusal.new("new file #{filename} does not parse: #{ex.message}")
      end
      new_file = new(filename, text, node)
      new_file.check_shape(program)
      new_file
    end

    protected def check_shape(program : Program) : Nil
      list_of_statements = @node.is_a?(Expressions) ? @node.as(Expressions).expressions : [@node]
      list_of_statements.each do |statement|
        case statement
        when Nop
          next
        when ClassDef
          check_class_def(program, statement)
        else
          refuse("holds a #{statement.class_desc} at the top level")
        end
      end
      refuse("declares no type") if @list_of_type_names.empty?
    end

    private def check_class_def(program : Program, class_def : ClassDef) : Nil
      path = class_def.name
      name = path.names.first
      refuse("declares #{path}, which is not a top-level name") if path.names.size != 1
      refuse("declares #{name} twice") if @list_of_type_names.includes?(name)
      refuse("declares #{name}, which the program has") if program.types.has_key?(name)
      refuse("declares #{name} with type parameters") if class_def.type_vars
      refuse("declares #{name} with a superclass") if class_def.superclass
      refuse("declares #{name} as abstract") if class_def.abstract?
      @list_of_type_names << name

      list_of_members = class_def.body.is_a?(Expressions) ? class_def.body.as(Expressions).expressions : [class_def.body]
      list_of_members.each do |member|
        case member
        when Nop
          next
        when Def
          refuse("defines #{name}##{member.name} with a receiver other than self") if (receiver = member.receiver) && !(receiver.is_a?(Var) && receiver.name == "self")
          refuse("defines #{name}##{member.name} as a macro method") if member.macro_def?
        when TypeDeclaration
          refuse("declares #{member.var} in #{name}, which is not an instance variable") unless member.var.is_a?(InstanceVar)
          refuse("gives #{member.var} of #{name} a value") if member.value
        when Call
          unless member.obj.nil? && member.block.nil? && member.block_arg.nil? && ACCESSOR_MACRO_NAMES.includes?(member.name)
            refuse("calls #{member.name} in the body of #{name}")
          end
        else
          refuse("holds a #{member.class_desc} in the body of #{name}")
        end
      end
    end

    # The types a new type gets its methods and hooks from.
    def self.list_of_ancestors(program : Program, is_struct : Bool) : Array(Type)
      if is_struct
        [program.struct, program.value, program.object] of Type
      else
        [program.reference, program.object] of Type
      end
    end

    # Refuses when a macro of the kept build read a list the new types
    # would be in, or an ancestor runs a hook for a new type.
    def check_reads(program : Program, record : SourceRecord) : Nil
      list_of_watched = [program] of Type
      each_class_def do |class_def|
        list_of_watched.concat(NewFile.list_of_ancestors(program, class_def.struct?))
      end
      list_of_watched.uniq!
      list_of_watched.each do |watched|
        if record.type_list_read_type_by_id.has_key?(watched.object_id) ||
           record.type_list_read_type_by_id.has_key?(watched.metaclass.object_id)
          refuse("adds to the subclasses or constants of #{watched}, which a macro listed")
        end
        {watched, watched.metaclass}.each do |hook_owner|
          if hook_owner.as?(ModuleType).try(&.hooks).try(&.any?)
            refuse("declares a type that a hook of #{watched} would see")
          end
        end
      end
    end

    private def each_class_def(& : ClassDef ->) : Nil
      list_of_statements = @node.is_a?(Expressions) ? @node.as(Expressions).expressions : [@node]
      list_of_statements.each do |statement|
        yield statement if statement.is_a?(ClassDef)
      end
    end

    # Declares the new types and their methods in *program*, as the
    # top-level phase would have. Returns the types.
    def declare(program : Program) : Array(Type)
      node = program.normalize(@node)
      visitor = TopLevelVisitor.new(program)
      node.accept visitor
      program.define_new_methods(visitor.new_expansions)
      TypeDeclarationProcessor.new(program).process(node, finished_hooks: false)
      unless program.has_flag?("no_restrictions_augmenter")
        node.accept RestrictionsAugmenter.new(program, visitor.new_expansions)
      end
      @list_of_type_names.map do |name|
        (program.types[name]? || refuse("declares #{name}, which the top-level phase did not make")).as(Type)
      end
    end

    private def refuse(why : String) : NoReturn
      raise Refusal.new("new file #{@filename} #{why}")
    end
  end
end
