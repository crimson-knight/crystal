require "./top_level_visitor"

# Strict files, `@[Override]` and the declaration rules of `@[TypeOnce]`.
#
# A file is strict when its first line is `# crystal: strict`, when it
# requires `strict`, or when a file at or above its directory requires
# `strict/project`. Strict and ordinary files live in one program.
#
# In a strict file:
#
# * a `def` with the same name and argument types as an earlier definition in
#   the same type, or as a method the type inherits, is marked `@[Override]`;
#   an unmarked one is an error naming both. Every method follows the rule,
#   `initialize`, `to_s`, `==` and implementations of an `abstract def`
#   included. A `def` with the same name and different argument types is a
#   new overload and needs no mark;
# * a `def` that writes out the type of every parameter (the block parameter
#   included: `&block : String -> String`, or a proc type named through an
#   `alias`) and its return type, and that can be typed once, is typed once,
#   as if marked `@[TypeOnce]` (see `type_once.cr`);
# * every other `def` compiles with today's typing, one copy per caller, and
#   gets a warning that names the method and what to write.
#
# `@[Override]` on a def that replaces and overrides nothing is an error in
# every file.
#
# A def a macro generated is not written in the file that calls the macro, so
# the strict rules leave it alone; `@[Override]` and `@[TypeOnce]` on it are
# checked as on any def.
#
# The checks run once every declaration of the program is read
# (`StrictDefChecker`), so a method counts as inherited wherever in the
# source its definition is.
module Crystal
  class Program
    # Files that required `strict`.
    getter strict_files = Set(String).new

    # Directories of the files that required `strict/project`.
    getter strict_directories = Set(String).new

    # Whether each source file starts with the strict marker.
    @strict_marker_by_file = Hash(String, Bool).new

    STRICT_MARKER = "# crystal: strict"

    def strict_file?(location : Location?) : Bool
      filename = location.try(&.filename)
      return false unless filename.is_a?(String)
      return true if strict_files.includes?(filename)
      return true if strict_directories.any? { |directory| filename.starts_with?(directory) }
      marker = @strict_marker_by_file[filename]?
      if marker.nil?
        override = source_overrides.try(&.[filename]?)
        marker = @strict_marker_by_file[filename] = override ? Program.strict_marker_text?(override) : Program.strict_marker?(filename)
      end
      marker
    end

    # Does the file at *filename* start with the line `# crystal: strict`?
    def self.strict_marker?(filename : String) : Bool
      return false unless File.file?(filename)
      File.open(filename) do |file|
        first_line = file.gets(limit: 64)
        !first_line.nil? && first_line.rstrip == STRICT_MARKER
      end
    rescue IO::Error
      false
    end

    # Does *text* start with the line `# crystal: strict`?
    def self.strict_marker_text?(text : String) : Bool
      first_line = text.each_line.first?
      !first_line.nil? && first_line.rstrip == STRICT_MARKER
    end

    # Notes a `require` of one of the strict-mode files.
    def record_strict_require(required : String, requiring_file : String?) : Nil
      return unless requiring_file
      case required
      when "strict"
        strict_files << requiring_file
      when "strict/project"
        strict_directories << File.join(File.dirname(requiring_file), "")
      end
    end

    # A def waiting for `StrictDefChecker`: *a_def* was added to *owner*,
    # where it replaced *replaced* (a def with the same name and argument
    # types).
    record DeclaredDef, a_def : Def, owner : ModuleType, replaced : Def?

    # The defs `StrictDefChecker` looks at: those written in a strict file
    # and those marked `@[Override]` or `@[TypeOnce]`.
    getter declared_defs_to_check = [] of DeclaredDef

    # Notes *a_def*, just added to *owner*, for `StrictDefChecker`.
    def record_declared_def(a_def : Def, owner : ModuleType, replaced : Def?) : Nil
      return unless a_def.type_once? || a_def.annotation(override_annotation) || strict_file?(a_def.location)
      declared_defs_to_check << DeclaredDef.new(a_def, owner, replaced)
    end
  end

  # Applies the rules of `@[TypeOnce]`, `@[Override]` and strict files to the
  # defs `Program#record_declared_def` noted, once every declaration is read.
  class StrictDefChecker
    def initialize(@program : Program)
    end

    def run : Nil
      declared_defs = @program.declared_defs_to_check
      declared_defs.each do |declared|
        a_def = declared.a_def
        strict = @program.strict_file?(a_def.location)
        if a_def.type_once?
          check_type_once_def(a_def, declared.owner)
        elsif strict
          check_strict_def(a_def, declared.owner)
        end
        check_override(declared, strict)
      end
      declared_defs.clear
    end

    # `@[TypeOnce]`: the def must be one that can be typed once.
    private def check_type_once_def(node : Def, owner : ModuleType) : Nil
      description = "@[TypeOnce] method '#{node.name}'"
      node.raise "#{description} can't be abstract" if node.abstract?
      node.raise "#{description} can't be 'initialize': an object is built for its own class" if node.name == "initialize"
      if node.macro_def?
        node.raise "#{description} can't have macro expressions in its body: they read the concrete receiver through @type"
      end
      if free_vars = node.free_vars
        node.raise "#{description} can't have free variables (forall #{free_vars.join(", ")}): each binding is a separate typed copy"
      end
      if collecting_splat(node) || node.double_splat
        node.raise "#{description} can't have a splat parameter: each number of arguments is a separate typed copy"
      end
      if yields?(node)
        node.raise "#{description} can't yield: a method that yields is typed into each caller. Capture the block with a typed parameter and call it (&block : Int32 -> String)"
      end
      node.args.each do |arg|
        next if arg.name.empty? || arg.restriction
        arg.raise "#{description} needs a type restriction on parameter '#{arg.name}'"
      end
      if (block_arg = node.block_arg) && !block_type_state(node, owner).complete?
        block_arg.raise "#{description} needs the block's input and output types (&#{block_arg.name} : Int32 -> String)"
      end
      unless node.return_type
        node.raise "#{description} needs a return type: callers get the declared type, not one inferred per caller"
      end
    end

    # A def written in a strict file is typed once when its signature states
    # every type and it can be. Otherwise it is typed as in an ordinary file
    # and gets a warning that names what to write.
    private def check_strict_def(node : Def, owner : ModuleType) : Nil
      typed_once_candidate = StrictDefChecker.typed_once_candidate?(node)
      to_write = strict_def_gaps(node, owner, typed_once_candidate)
      if to_write.empty?
        node.type_once = typed_once_candidate
      else
        message = StrictDefChecker.warning_message(method_description(owner, node), to_write, typed_once_candidate)
        @program.warnings.add_warning(node, message)
      end
    end

    # An abstract def has no body and `initialize` builds an object of its own
    # class: neither is ever typed once, so a strict file asks only for their
    # types.
    def self.typed_once_candidate?(node : Def) : Bool
      !node.abstract? && node.name != "initialize"
    end

    # The text of the warning for a def of a strict file; *to_write* lists
    # what its author has left to write.
    def self.warning_message(method : String, to_write : Array(String), typed_once_candidate : Bool) : String
      String.build do |io|
        io << "strict file: method '" << method << "' "
        if typed_once_candidate
          io << "is typed for each caller, as in an ordinary file. To have it typed once, write "
        else
          io << "leaves types unstated. Write "
        end
        to_write.join(io, "; ")
      end
    end

    # What the author of *node* has left to write, in the words of the
    # warning.
    private def strict_def_gaps(node : Def, owner : ModuleType, typed_once_candidate : Bool) : Array(String)
      to_write = [] of String
      splat = collecting_splat(node)

      node.args.each do |arg|
        next if arg.name.empty? || arg.restriction || arg.same?(splat)
        to_write << "the type of parameter '#{arg.name}' (for example `#{arg.name} : String`)"
      end
      if splat
        if typed_once_candidate
          to_write << "a typed collection parameter in place of the splat '*#{splat.name}' (for example `#{splat.name} : Array(String)`)"
        elsif !splat.restriction
          to_write << "the type of parameter '#{splat.name}' (for example `*#{splat.name} : String`)"
        end
      end
      if double_splat = node.double_splat
        if typed_once_candidate
          to_write << "named parameters with their types in place of the double splat '**#{double_splat.name}' (for example `#{double_splat.name} : String`)"
        elsif !double_splat.restriction
          to_write << "the type of parameter '#{double_splat.name}' (for example `**#{double_splat.name} : String`)"
        end
      end

      if typed_once_candidate && yields?(node)
        to_write << "a typed block parameter that the method calls in place of `yield` (for example `&block : String -> String` and `block.call(value)`)"
      elsif block_arg = node.block_arg
        named = !block_arg.name.empty?
        block_name = named ? "block parameter '#{block_arg.name}'" : "the block parameter"
        example = "for example `&#{block_arg.name} : String -> String`"
        case block_type_state(node, owner)
        in .untyped?
          to_write << "the type of #{block_name} (#{example})"
        in .without_output?
          to_write << "the return type of #{block_name} (#{example})" if typed_once_candidate
        in .not_a_proc?
          to_write << "a proc type for #{block_name} (#{example})"
        in .complete?
        end
      end

      if typed_once_candidate
        if free_vars = node.free_vars
          to_write << "the types the method accepts in place of the free variables (forall #{free_vars.join(", ")})"
        end
        if node.macro_def?
          to_write << "the body without macro expressions that read `@type`, the concrete receiver: let a macro write the whole method, or call a method for the value"
        end
      end

      unless node.return_type || node.name == "initialize"
        to_write << "the return type (for example `def #{node.name}(...) : String`)"
      end
      to_write
    end

    # How much of its type the block parameter of a def states.
    private enum BlockTypeState
      Untyped
      WithoutOutput
      NotAProc
      Complete
    end

    private def block_type_state(node : Def, owner : ModuleType) : BlockTypeState
      restriction = node.block_arg.try(&.restriction)
      return BlockTypeState::Untyped unless restriction
      if restriction.is_a?(ProcNotation)
        return restriction.output ? BlockTypeState::Complete : BlockTypeState::WithoutOutput
      end
      # A proc type named through an `alias`, or written `Proc(String, String)`.
      instance_type = owner.instance_type
      declared = begin
        instance_type.lookup_type?(restriction, self_type: instance_type, allow_typeof: false)
      rescue Crystal::CodeError
        nil
      end
      return BlockTypeState::NotAProc unless declared
      declared.remove_alias.is_a?(ProcInstanceType) ? BlockTypeState::Complete : BlockTypeState::NotAProc
    end

    # The splat parameter of *node* when it collects arguments (`*names`, as
    # opposed to the bare `*` that only separates named parameters).
    private def collecting_splat(node : Def) : Arg?
      splat_index = node.splat_index || return nil
      splat = node.args[splat_index]
      splat.name.empty? ? nil : splat
    end

    # Whether *node* passes values to a block that is inlined into each
    # caller: it takes a block and never refers to it as a value.
    private def yields?(node : Def) : Bool
      return false unless node.block_arity
      !(node.block_arg && node.uses_block_arg?)
    end

    # `@[Override]` is required in a strict file on a def that has the name
    # and argument types of an earlier definition in the same type or of an
    # inherited method. In every file it is an error on a def that replaces
    # and overrides nothing.
    private def check_override(declared : Program::DeclaredDef, strict : Bool) : Nil
      node = declared.a_def
      owner = declared.owner
      replaced = declared.replaced

      if node.annotation(@program.override_annotation)
        return if replaced || inherits_def_named?(owner, node.name)
        node.raise "'#{node.name}' is marked @[Override], but #{owner} has no earlier definition of it and inherits no method with that name"
      end
      return unless strict

      if replaced
        node.raise "#{method_description(owner, node)} is already defined#{definition_location(replaced)}. Mark this definition @[Override] to replace it"
      end
      if overridden = inherited_def_with_same_signature(node, owner)
        node.raise "#{method_description(owner, node)} overrides #{method_description(overridden.owner, overridden)}#{definition_location(overridden)}. Mark this definition @[Override]"
      end
    end

    private def method_description(owner : Type, a_def : Def) : String
      if owner.is_a?(Program)
        a_def.name
      elsif owner.metaclass?
        "#{owner.instance_type}.#{a_def.name}"
      else
        "#{owner}##{a_def.name}"
      end
    end

    private def definition_location(a_def : Def) : String
      location = a_def.location
      location ? " at #{location.original_filename}:#{location.line_number}" : ""
    end

    private def inherits_def_named?(owner : ModuleType, name : String) : Bool
      owner.ancestors.any? do |ancestor|
        ancestor = ancestor.generic_type if ancestor.is_a?(GenericInstanceType)
        ancestor.is_a?(ModuleType) && ancestor.defs.try(&.has_key?(name))
      end
    end

    private def inherited_def_with_same_signature(node : Def, owner : ModuleType) : Def?
      item = DefWithMetadata.new(node)
      owner.ancestors.each do |ancestor|
        # A generic instance (`Box(Int32)`) keeps its defs in its generic type.
        ancestor = ancestor.generic_type if ancestor.is_a?(GenericInstanceType)
        next unless ancestor.is_a?(ModuleType)
        list = ancestor.defs.try(&.[node.name]?) || next
        list.each do |existing|
          return existing.def if item.compare_strictness(existing, owner, other_owner: ancestor) == 0
        end
      end
      nil
    end
  end
end
