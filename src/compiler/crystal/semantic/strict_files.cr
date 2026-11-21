require "./top_level_visitor"

# Strict files.
#
# A file is strict when its first line is `# crystal: strict`, when it
# requires `strict`, or when a file at or above its directory requires
# `strict/project`. Strict and ordinary files live in one program.
#
# In a strict file:
#
# * every hand-written `def` declares the type of each parameter and its
#   return type (`initialize` needs no return type);
# * every `def` that qualifies is typed once, as if marked `@[TypeOnce]`
#   (see `type_once.cr`); one that yields, collects a splat, has free
#   variables or macro expressions is typed per caller as in an ordinary file;
# * a `def` that replaces an earlier definition with the same signature in
#   the same type, or overrides an inherited method with the same signature,
#   is marked `@[Override]`; an unmarked one is an error naming both.
#
# `@[Override]` on a def that replaces and overrides nothing is an error in
# every file.
#
# Not checked: defs a macro generated (their author can't mark them), and for
# overrides `initialize` and a def that implements an `abstract def`.
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
        marker = @strict_marker_by_file[filename] = Program.strict_marker?(filename)
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
  end

  class TopLevelVisitor
    # Checks the signature a strict file asks of *node* and marks it to be
    # typed once when it qualifies.
    private def check_strict_def(node : Def) : Nil
      node.args.each do |arg|
        next if arg.name.empty? || arg.restriction
        arg.raise "strict file: method '#{node.name}' needs a type restriction on parameter '#{arg.name}'"
      end
      if (double_splat = node.double_splat) && !double_splat.restriction
        double_splat.raise "strict file: method '#{node.name}' needs a type restriction on parameter '#{double_splat.name}'"
      end
      unless node.return_type || node.name == "initialize"
        node.raise "strict file: method '#{node.name}' needs a return type"
      end
      node.type_once = true if strict_def_typed_once?(node)
    end

    private def strict_def_typed_once?(node : Def) : Bool
      return false if node.abstract? || node.name == "initialize" || node.macro_def? || node.free_vars || node.double_splat
      splat_index = node.splat_index
      return false if splat_index && !node.args[splat_index].name.empty?
      if block_arg = node.block_arg
        restriction = block_arg.restriction
        return false unless restriction.is_a?(ProcNotation) && restriction.output
      elsif node.block_arity
        return false
      end
      true
    end

    # Checks `@[Override]` on *node*, just added to *target_type*, where it
    # replaced *replaced* (a def with the same signature in the same type).
    private def check_override(node : Def, target_type : ModuleType, replaced : Def?) : Nil
      marked = !node.annotation(@program.override_annotation).nil?
      strict = @program.strict_file?(node.location)
      return unless marked || strict
      return if node.name == "initialize"

      if marked
        return if replaced || inherits_def_named?(target_type, node.name)
        node.raise "'#{node.name}' is marked @[Override], but #{target_type} has no earlier definition of it and inherits no method with that name"
      end

      if replaced
        node.raise "#{override_description(target_type, node)} is already defined#{override_location(replaced)}. Mark this definition @[Override] to replace it"
      end

      if overridden = inherited_def_with_same_signature(node, target_type)
        return if overridden.abstract?
        node.raise "#{override_description(target_type, node)} overrides #{override_description(overridden.owner, overridden)}#{override_location(overridden)}. Mark this definition @[Override]"
      end
    end

    private def override_description(owner : Type, a_def : Def) : String
      owner.metaclass? ? "#{owner.instance_type}.#{a_def.name}" : "#{owner}##{a_def.name}"
    end

    private def override_location(a_def : Def) : String
      location = a_def.location
      location ? " at #{location.original_filename}:#{location.line_number}" : ""
    end

    private def inherits_def_named?(target_type : ModuleType, name : String) : Bool
      target_type.ancestors.any? do |ancestor|
        ancestor.is_a?(ModuleType) && ancestor.defs.try(&.has_key?(name))
      end
    end

    private def inherited_def_with_same_signature(node : Def, target_type : ModuleType) : Def?
      item = DefWithMetadata.new(node)
      target_type.ancestors.each do |ancestor|
        next unless ancestor.is_a?(ModuleType)
        list = ancestor.defs.try(&.[node.name]?) || next
        list.each do |existing|
          return existing.def if item.compare_strictness(existing, target_type, other_owner: ancestor) == 0
        end
      end
      nil
    end
  end
end
