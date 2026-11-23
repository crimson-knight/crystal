module Crystal::StrictTool
  # Decides, from the typed copies of each def, which types to write into its
  # signature, and which defs need `@[Override]`.
  class Planner
    # How many caller types a report line names before it counts the rest.
    TYPES_SHOWN = 4

    # Defs a later definition with the same signature replaced.
    @replaced_defs = Set(Def).new.compare_by_identity

    def initialize(@recorder : StrictToolRecorder, @unions : Bool)
      @recorder.declarations.each do |declaration|
        if replaced = declaration.replaced
          @replaced_defs << replaced
        end
      end
    end

    # Plans the def of *declaration*; *written* is the same def as parsed
    # from its file, before type inference added restrictions of its own.
    def plan(declaration : StrictToolRecorder::Declaration, written : Def) : MethodPlan
      a_def = declaration.a_def
      owner = declaration.owner
      plan = MethodPlan.new(a_def, owner, Planner.describe(owner, a_def))
      plan.replaced = declaration.replaced

      to_write = missing_types(written, a_def)
      return plan if to_write.empty?

      if reason = skip_reason(a_def, owner, declaration.replaced)
        plan.reason = reason
        return plan
      end

      instances = @recorder.instances_of(a_def)
      if instances.empty?
        plan.reason = "never called in this program, so there are no types to read"
        return plan
      end

      scope = scope_of(owner)
      reasons = [] of String
      fill_arg_types(plan, a_def, written, instances, scope, reasons)
      fill_block_type(plan, a_def, instances, scope, reasons) if to_write.includes?(:block)
      fill_return_type(plan, a_def, instances, scope, reasons) if to_write.includes?(:return)

      unless reasons.empty?
        plan.clear_types(reasons.join("; "))
      end
      plan
    end

    # What *written* leaves unwritten: `:args`, `:block`, `:return`.
    private def missing_types(written : Def, a_def : Def) : Array(Symbol)
      missing = [] of Symbol
      missing << :args if written.args.any? { |arg| !arg.name.empty? && arg.restriction.nil? }
      if (block_arg = written.block_arg) && block_arg.restriction.nil? && a_def.uses_block_arg?
        missing << :block
      elsif a_def.block_arity && !a_def.uses_block_arg?
        missing << :block
      end
      missing << :return unless written.return_type || a_def.name == "initialize"
      missing
    end

    # Why the types of *a_def* can't be written from its callers, if so.
    private def skip_reason(a_def : Def, owner : ModuleType, replaced : Def?) : String?
      return "abstract, so it has no body to read types from" if a_def.abstract?
      if a_def.macro_def?
        return "its body reads @type in macro expressions, so it is typed per receiver"
      end
      generic_owner = owner.metaclass? ? owner.instance_type : owner
      if generic_owner.is_a?(GenericType)
        return "a method of the generic type #{generic_owner}: its types depend on the type parameters"
      end
      if free_vars = a_def.free_vars
        return "it has free variables (forall #{free_vars.join(", ")})"
      end
      if (splat_index = a_def.splat_index) && !a_def.args[splat_index].name.empty?
        return "it collects arguments with a splat"
      end
      return "it collects named arguments with a double splat" if a_def.double_splat
      if a_def.block_arity && !a_def.uses_block_arg?
        return "it yields; rewrite it to call a typed block parameter (`&block : A -> B` and `block.call`) by hand"
      end
      if replaced
        return "it redefines the method at #{Planner.place(replaced)}; typing it would turn the two into overloads"
      end
      if @replaced_defs.includes?(a_def)
        return "a later definition replaces it"
      end
      if abstract_def = untyped_abstract_def(a_def, owner)
        return "it implements #{Planner.describe(abstract_def.owner, abstract_def)} at #{Planner.place(abstract_def)}, whose parameters leave their types out"
      end
      nil
    end

    # An abstract def that *a_def* implements and that leaves a parameter
    # type out: an implementation may not narrow it.
    private def untyped_abstract_def(a_def : Def, owner : ModuleType) : Def?
      owner.ancestors.each do |ancestor|
        list = ancestor.defs.try(&.[a_def.name]?) || next
        list.each do |item|
          candidate = item.def
          next unless candidate.abstract? && candidate.args.size == a_def.args.size
          return candidate if candidate.args.any? { |arg| arg.restriction.nil? }
        end
      end
      nil
    end

    private def fill_arg_types(plan : MethodPlan, a_def : Def, written : Def, instances : Array(StrictToolRecorder::Instance), scope : Type, reasons : Array(String)) : Nil
      program = scope.program
      a_def.args.each_with_index do |arg, index|
        next if arg.name.empty? || written.args[index]?.try(&.restriction)
        types = [] of Type
        default_types = [] of Type
        omitted = false
        instances.each do |instance|
          if type = instance.arg_types[index]?
            types << type
            next
          end
          named = instance.named_arg_types.try &.find { |named_arg| named_arg.name == arg.external_name }
          if named
            types << named.type
            next
          end
          omitted = true
          if type = default_type_in_body(instance.typed_def, arg.name)
            default_types << type
          end
        end

        if default_value = arg.default_value
          if literal_type = literal_type(program, default_value)
            default_types << literal_type
          elsif !omitted
            reasons << "the default value of parameter '#{arg.name}' is never used, so its type is not known"
            next
          end
        end

        label = "parameter '#{arg.name}'"
        all_types = types + default_types
        if text = inherited_text(a_def, plan.owner, scope, all_types) { |inherited| inherited.args[index]?.try(&.restriction) }
          plan.arg_texts[index] = text
          next
        end

        # The callers agree; the default value's type joins theirs.
        callers = unique_types(types)
        if callers.size <= 1 && !default_types.empty?
          merged = program.type_merge(unique_types(all_types).map(&.as(Type?)))
          if merged && (text = type_text(merged, scope))
            plan.arg_texts[index] = text
          else
            reasons << "#{label} can't be written in the source"
          end
          next
        end

        case decided = decide(types, scope, label, plan)
        when String
          plan.arg_texts[index] = decided
        when Reason
          reasons << decided.text
        end
      end
    end

    private def fill_block_type(plan : MethodPlan, a_def : Def, instances : Array(StrictToolRecorder::Instance), scope : Type, reasons : Array(String)) : Nil
      types = instances.compact_map(&.block_arg_type)
      if types.size != instances.size
        reasons << "the type of its block parameter is not known"
        return
      end
      unique = unique_types(types)
      if unique.size != 1
        reasons << "its callers pass blocks of different types (#{type_list(unique)})"
        return
      end
      proc_type = unique.first
      unless proc_type.is_a?(ProcInstanceType)
        reasons << "its block parameter is not a proc (#{proc_type})"
        return
      end
      if text = proc_notation_text(proc_type, scope)
        plan.block_text = text
      else
        reasons << "the type of its block parameter, #{proc_type}, can't be written in the source"
      end
    end

    private def fill_return_type(plan : MethodPlan, a_def : Def, instances : Array(StrictToolRecorder::Instance), scope : Type, reasons : Array(String)) : Nil
      program = scope.program
      types = [] of Type
      instances.each do |instance|
        type = instance.typed_def.type?
        unless type
          reasons << "its return type is not known"
          return
        end
        type = program.nil if type.void?
        types << type
      end

      # A copy that never returns fits any declared return type.
      returning = types.reject(&.no_return?)
      types = returning unless returning.empty?

      unique = unique_types(types)
      if unique.size > 1 && !a_def.receiver && instances.all? { |instance| same_type?(instance.typed_def.type?, instance.receiver) }
        plan.return_text = "self"
        return
      end

      if text = inherited_text(a_def, plan.owner, scope, types, nil_fits_all: true, &.return_type)
        plan.return_text = text
        return
      end

      case decided = decide(types, scope, "the return type", plan)
      when String
        plan.return_text = decided
      when Reason
        reasons << decided.text
      end
    end

    # The type an inherited method with the same name and number of
    # parameters declares where *a_def* leaves it out (the node the block
    # picks), written for *scope*, when every type in *types* fits it.
    # Writing the inherited type keeps the method an override.
    private def inherited_text(a_def : Def, owner : ModuleType, scope : Type, types : Array(Type), nil_fits_all = false, & : Def -> ASTNode?) : String?
      return nil if types.empty?
      owner.ancestors.each do |ancestor|
        list = ancestor.defs.try(&.[a_def.name]?) || next
        list.each do |item|
          inherited = item.def
          next unless inherited.args.size == a_def.args.size && inherited.splat_index.nil? && inherited.double_splat.nil?
          next if inherited.free_vars
          restriction = yield(inherited) || next
          declared = begin
            ancestor.instance_type.lookup_type?(restriction, allow_typeof: false)
          rescue CodeError
            nil
          end
          next unless declared
          # A method declared to return Nil returns nil whatever its body gives.
          next unless (nil_fits_all && declared.nil_type?) || types.all? { |type| type.implements?(declared) }
          return type_text(declared, scope)
        end
      end
      nil
    end

    private def same_type?(type : Type?, receiver : Type) : Bool
      return false unless type
      return false if receiver.metaclass?
      type.same?(receiver)
    end

    record Reason, text : String

    # The text to write for *types*, the types the callers pass, or why
    # there is none.
    private def decide(types : Array(Type), scope : Type, label : String, plan : MethodPlan) : String | Reason
      unique = unique_types(types)
      return Reason.new("no caller gives #{label} a type") if unique.empty?
      if unique.size == 1
        text = type_text(unique.first, scope)
        return text || Reason.new("#{label} is #{unique.first}, which can't be written in the source")
      end

      merged = scope.program.type_merge(unique.map(&.as(Type?)))
      merged_text = merged.try { |type| type_text(type, scope) }
      unless merged_text
        return Reason.new("#{label} differs by caller (#{type_list(unique)}) and the union can't be written in the source")
      end
      plan.unions << "#{label}: #{merged_text}"
      return merged_text if @unions
      Reason.new("#{label} differs by caller (#{type_list(unique)}), so it stays typed per caller; --unions writes `#{merged_text}`")
    end

    private def unique_types(types : Array(Type)) : Array(Type)
      types.uniq(&.object_id)
    end

    private def type_list(types : Array(Type)) : String
      names = types.first(TYPES_SHOWN).map(&.to_s)
      rest = types.size - TYPES_SHOWN
      names << "#{rest} more" if rest > 0
      names.join(", ")
    end

    # The type of the default value assigned to *name* at the start of a
    # typed copy that was called without it.
    private def default_type_in_body(typed_def : Def, name : String) : Type?
      body = typed_def.body
      expressions = body.is_a?(Expressions) ? body.expressions : [body]
      expressions.each do |expression|
        assign = expression.is_a?(AssignWithRestriction) ? expression.assign : expression
        break unless assign.is_a?(Assign)
        target = assign.target
        if target.is_a?(Var) && target.name == name
          return assign.value.type?
        end
      end
      nil
    end

    private def literal_type(program : Program, node : ASTNode) : Type?
      case node
      when NilLiteral    then program.nil
      when BoolLiteral   then program.bool
      when NumberLiteral then program.type_from_literal_kind(node.kind)
      when StringLiteral then program.string
      when CharLiteral   then program.char
      when SymbolLiteral then program.symbol
      when MagicConstant
        node.name.in?(Token::Kind::MAGIC_LINE, Token::Kind::MAGIC_END_LINE) ? program.int32 : program.string
      else
        nil
      end
    end

    # The type the paths of a restriction written in a method of *owner* are
    # looked up from.
    private def scope_of(owner : ModuleType) : Type
      owner.metaclass? ? owner.instance_type : owner
    end

    # The restriction text for *type* as written in a method whose paths are
    # looked up from *scope*, or `nil` when it can't be written.
    def type_text(type : Type, scope : Type) : String?
      type = scope.program.nil if type.void?
      if type.is_a?(ProcInstanceType)
        notation = proc_notation_text(type, scope)
        return notation ? "Proc(#{proc_type_args(type, scope)})" : nil
      end
      node = TypeToRestriction.new(scope).convert(type)
      return nil unless node
      RestrictionText.new(scope).render(node)
    end

    private def proc_type_args(type : ProcInstanceType, scope : Type) : String?
      parts = [] of String
      (type.arg_types + [type.return_type]).each { |part| parts << (type_text(part, scope) || return nil) }
      parts.join(", ")
    end

    # `A, B -> C` for a block parameter of *type*.
    def proc_notation_text(type : ProcInstanceType, scope : Type) : String?
      inputs = [] of String
      type.arg_types.each do |input|
        text = type_text(input, scope) || return nil
        inputs << (input.is_a?(UnionType) ? "(#{text})" : text)
      end
      output_type = type.return_type
      output = type_text(output_type, scope) || return nil
      output = "(#{output})" if output_type.is_a?(UnionType) && output.includes?('|')
      inputs.empty? ? "-> #{output}" : "#{inputs.join(", ")} -> #{output}"
    end

    # Marks with `@[Override]` each planned def that overrides or redefines
    # another, comparing signatures as they will be written.
    def mark_overrides(plans : Array(MethodPlan)) : Nil
      planned = Hash(Def, Def).new.compare_by_identity
      plans.each do |plan|
        planned[plan.a_def] = planned_def(plan) if plan.writes_types?
      end
      plans.each do |plan|
        a_def = plan.a_def
        program = plan.owner.program
        next if a_def.annotation(program.override_annotation)
        if plan.replaced
          plan.needs_override = true
          next
        end
        signature = planned[a_def]? || a_def
        plan.needs_override = true if overrides_inherited?(signature, plan.owner, planned)
      end
    end

    # A copy of the def in *plan* with the parameter types the plan writes.
    private def planned_def(plan : MethodPlan) : Def
      copy = plan.a_def.clone
      plan.arg_texts.each do |index, text|
        copy.args[index].restriction = Planner.parse_restriction(text)
      end
      copy
    end

    def self.parse_restriction(text : String) : ASTNode
      parsed = Parser.parse("def __strict_tool(__argument : #{text}); end")
      parsed.as(Def).args.first.restriction.not_nil!
    end

    private def overrides_inherited?(signature : Def, owner : ModuleType, planned : Hash(Def, Def)) : Bool
      item = DefWithMetadata.new(signature)
      owner.ancestors.each do |ancestor|
        # The strict checks look at plain classes and modules only, not at
        # generic instances an owner inherits from; so does this.
        next unless ancestor.is_a?(ModuleType)
        list = ancestor.defs.try(&.[signature.name]?) || next
        list.each do |existing|
          next unless @recorder.declared_def_ids.includes?(existing.def.object_id)
          other_def = planned[existing.def]? || existing.def
          other = DefWithMetadata.new(other_def)
          return true if item.compare_strictness(other, owner, other_owner: ancestor) == 0
        end
      end
      false
    end

    def self.describe(owner : Type, a_def : Def) : String
      if owner.is_a?(Program) || owner.is_a?(FileModule)
        a_def.name
      elsif owner.metaclass?
        "#{owner.instance_type}.#{a_def.name}"
      else
        "#{owner}##{a_def.name}"
      end
    end

    def self.place(a_def : Def) : String
      location = a_def.location
      return "(unknown place)" unless location
      filename = location.original_filename || location.filename.to_s
      "#{::Path[filename].relative_to(Dir.current)}:#{location.line_number}"
    end
  end

  # Writes a restriction node as source text: paths without the leading
  # `::` where the def's scope finds the same type, `T?` for a type or nil.
  struct RestrictionText
    def initialize(@scope : Type)
    end

    def render(node : ASTNode) : String?
      case node
      when Path
        path_text(node)
      when Generic
        name = render(node.name) || return nil
        parts = [] of String
        node.type_vars.each { |type_var| parts << (render(type_var) || return nil) }
        if named_args = node.named_args
          named_args.each do |named_arg|
            value = render(named_arg.value) || return nil
            key = Symbol.needs_quotes_for_named_argument?(named_arg.name) ? named_arg.name.inspect : named_arg.name
            parts << "#{key}: #{value}"
          end
        end
        "#{name}(#{parts.join(", ")})"
      when Union
        parts = [] of String
        node.types.each { |member| parts << (render(member) || return nil) }
        nil_index = parts.index("Nil")
        if parts.size == 2 && nil_index && !parts[1 - nil_index].includes?(' ')
          "#{parts[1 - nil_index]}?"
        else
          if nil_index
            parts.delete_at(nil_index)
            parts << "Nil"
          end
          parts.join(" | ")
        end
      when Metaclass
        inner = render(node.name) || return nil
        inner.includes?(' ') ? "(#{inner}).class" : "#{inner}.class"
      when NumberLiteral
        node.to_s
      else
        nil
      end
    end

    private def path_text(path : Path) : String
      names = path.names.join("::")
      return names unless path.global?
      program = @scope.program
      target = program.lookup_path(path.names)
      local = begin
        @scope.lookup_path(path.names)
      rescue CodeError
        nil
      end
      local.same?(target) ? names : "::#{names}"
    end
  end
end
