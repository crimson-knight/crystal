require "./codegen"

class Crystal::CodeGenVisitor
  # Top-level code in parts of its own.
  #
  # The program's top-level code is one function, `__crystal_main`, in the
  # main module, with every block it passes inlined. In an Amber app of 300
  # resources `config/routes.cr` alone makes it 294,000 lines of IR (every
  # route of every `routes` block), which `-O3` compiles in 70 to 100 s,
  # serially, in every clean build and after every edit of the routes.
  #
  # With one module per type, a long block body or file body of top-level
  # code goes to functions of their own, each in a module of its own (a
  # *part*), called in order from where the code was. A part is a run of
  # whole statements, so the code of a statement is the code it had in the
  # main function. Where one part ends is decided by the statements
  # themselves (`Plan`): one statement more or less moves the end of one
  # part, not of every part after it, and a part's name comes from its
  # first statement. An edit of one route then changes one part, the parts
  # whose lines moved get their objects' lines patched like the main
  # module's (`LinePatch::MainModule`), and a clean build compiles the parts
  # in parallel.
  #
  # A part receives the variables of the enclosing scope it uses: by
  # pointer, or by value for the ones the code generator holds as values
  # (`self` and the receiver of `with ... yield`). A variable declared in
  # the scope that only one part uses is that part's own. Statements that
  # cannot leave the function they are in stay where they are: control
  # flow out of the scope (`return`, `break`, `next`, `yield`), constant,
  # class variable and global assignments (those are defined by the main
  # module), type and file bodies, and closures.
  #
  # Only in builds with one module per type, for targets whose top-level
  # code needs nothing of the main function's (no Windows, no WebAssembly).
  # `CRYSTAL_MAIN_PARTS=0` turns parts off; `CRYSTAL_MAIN_PART_NODES` sets
  # the size of a part in AST nodes, for measuring.
  module MainParts
    # The module (and function) names of parts start with this.
    NAME_PREFIX = "~main~"

    # The usual size of a part, in AST nodes of its statements.
    DEFAULT_PART_NODE_COUNT = 4_000

    # A body this many times the size of a part or larger is split.
    SPLIT_FACTOR = 2

    # A run of statements smaller than the size of a part divided by this
    # stays in the function it is in.
    MINIMUM_PART_DIVISOR = 8

    # The smallest size of a part `CRYSTAL_MAIN_PART_NODES` can set.
    SMALLEST_PART_NODE_COUNT = 50

    # A part ends after a statement with this probability per node of the
    # statement out of `PART_NODE_COUNT` (see `Plan`). Out of this many.
    BOUNDARY_SCALE = 1 << 20

    # A part is never larger than this many times the usual size, unless
    # one statement is.
    MAXIMUM_FACTOR = 4

    # Nodes of a statement that make up the key of its part's name.
    HEAD_NODE_LIMIT = 64

    def self.part_module_name?(name : String) : Bool
      name.starts_with?(NAME_PREFIX)
    end

    def self.enabled? : Bool
      ENV["CRYSTAL_MAIN_PARTS"]? != "0"
    end

    def self.part_node_count : Int32
      ENV["CRYSTAL_MAIN_PART_NODES"]?.try(&.to_i?).try(&.clamp(SMALLEST_PART_NODE_COUNT..)) || DEFAULT_PART_NODE_COUNT
    end

    # What one statement holds: its size, the variables it names outside
    # the procs it creates, and why it must stay where it is, if it must.
    class Scan < Visitor
      getter node_count = 0
      getter var_names = Set(String).new
      getter blocker : String?
      @proc_depth = 0

      def visit(node : ASTNode) : Bool
        @node_count += 1
        true
      end

      def visit(node : Var) : Bool
        @node_count += 1
        @var_names << node.name if @proc_depth == 0
        true
      end

      def visit(node : Return | Break | Next | Yield) : Bool
        @node_count += 1
        block "#{node.class.name.downcase}" if @proc_depth == 0
        true
      end

      def visit(node : Assign) : Bool
        @node_count += 1
        block "assigns #{node.target}" if node.target.is_a?(Path | ClassVar | Global)
        true
      end

      def visit(node : OpAssign) : Bool
        @node_count += 1
        block "assigns #{node.target}" if node.target.is_a?(Path | ClassVar | Global)
        true
      end

      def visit(node : TypeDeclaration) : Bool
        @node_count += 1
        block "declares #{node.var}" if node.var.is_a?(ClassVar | Global)
        true
      end

      def visit(node : ClassDef | ModuleDef | EnumDef | LibDef | FunDef | FileNode | Primitive) : Bool
        block "#{node.class.name.downcase}"
        false
      end

      def visit(node : Def) : Bool
        block "def with hooks" if node.hook_expansions
        false
      end

      def visit(node : ProcLiteral) : Bool
        @node_count += 1
        block "closure" if node.def.closure?
        @proc_depth += 1
        true
      end

      def end_visit(node : ProcLiteral) : Nil
        @proc_depth -= 1
      end

      def visit(node : Block) : Bool
        @node_count += 1
        if fun_literal = node.fun_literal
          block "closure" if fun_literal.as?(ProcLiteral).try(&.def.closure?)
          @proc_depth += 1
        end
        true
      end

      def end_visit(node : Block) : Nil
        @proc_depth -= 1 if node.fun_literal
      end

      private def block(reason : String) : Nil
        @blocker ||= reason
      end
    end

    # The key of a statement's part name and of where parts end: the first
    # nodes of the statement, without the bodies of the blocks and procs it
    # passes (an edit inside a block leaves the name of the part that holds
    # the call as it was), without positions, and with made-up variable
    # names (`__temp_12`) in order of appearance.
    class Head < Visitor
      @hasher = IrSkip::Hasher.new
      @count = 0
      @made_up_names = [] of String

      def digest : IrSkip::Digest
        @hasher.digest
      end

      def visit(node : ASTNode) : Bool
        return false if @count >= HEAD_NODE_LIMIT
        @count += 1
        @hasher.mix(node.class.name)
        case node
        when Var
          mix_name(node.name)
        when Call
          @hasher.mix(node.name)
        when StringLiteral, SymbolLiteral, NumberLiteral, CharLiteral
          @hasher.mix(node.to_s)
        when Path
          @hasher.mix(node.names.join("::"))
        when Block, ProcLiteral
          return false
        end
        true
      end

      private def mix_name(name : String) : Nil
        if name.starts_with?("__temp_") || name.starts_with?("__arg")
          index = @made_up_names.index(name) || (@made_up_names << name; @made_up_names.size - 1)
          @hasher.mix("~#{index}")
        else
          @hasher.mix(name)
        end
      end
    end

    # One run of statements: in a part of its own, or left where it is.
    class Group
      getter list_of_indexes = [] of Int32
      getter var_names = Set(String).new
      property node_count = 0
      property? outlined = false
      getter head : IrSkip::Digest

      def initialize(@head)
      end
    end

    # How a body is cut into parts. A part ends after a statement with a
    # probability that grows with the statement's size, decided by the
    # statement's `Head`: the same statements end the same parts, whatever
    # comes before them.
    class Plan
      getter list_of_groups = [] of Group

      def self.build?(statements : Array(ASTNode), part_node_count : Int32) : Plan?
        return nil if statements.size < 2

        list_of_scans = statements.map do |statement|
          scan = Scan.new
          statement.accept scan
          scan
        end
        total = list_of_scans.sum(&.node_count)
        return nil if total < part_node_count * SPLIT_FACTOR

        plan = new
        current = nil.as(Group?)
        last_index = statements.size - 1
        statements.each_with_index do |statement, index|
          scan = list_of_scans[index]
          # The last statement may give the body's value: it stays.
          outlinable = index != last_index && scan.blocker.nil?
          head = Head.new.tap { |visitor| statement.accept visitor }.digest
          if !outlinable || scan.node_count >= part_node_count
            plan.close(current, part_node_count)
            current = nil
          end
          group = current ||= Group.new(head)
          group.list_of_indexes << index
          group.var_names.concat(scan.var_names)
          group.node_count += scan.node_count
          group.outlined = outlinable
          if !outlinable || ends_part?(head, scan.node_count, group.node_count, part_node_count)
            plan.close(group, part_node_count)
            current = nil
          end
        end
        plan.close(current, part_node_count)
        if ENV["CRYSTAL_MAIN_PARTS_DEBUG"]?
          list_of_texts = plan.list_of_groups.map { |group| "#{group.outlined? ? "P" : "i"}#{group.list_of_indexes.size}/#{group.node_count}" }
          list_of_blockers = list_of_scans.compact_map(&.blocker).uniq
          STDERR.puts "main parts plan: #{statements.size} statements, #{total} nodes: #{list_of_texts.join(" ")} #{list_of_blockers}"
        end
        plan.list_of_groups.any?(&.outlined?) ? plan : nil
      end

      private def self.ends_part?(head : IrSkip::Digest, statement_node_count : Int32, group_node_count : Int32, part_node_count : Int32) : Bool
        return true if group_node_count >= part_node_count * MAXIMUM_FACTOR
        threshold = BOUNDARY_SCALE.to_u64 * statement_node_count // part_node_count
        head.first % BOUNDARY_SCALE < threshold
      end

      def close(group : Group?, part_node_count : Int32) : Nil
        return unless group
        group.outlined = false if group.outlined? && group.node_count < part_node_count // MINIMUM_PART_DIVISOR
        @list_of_groups << group
      end
    end
  end

  # The functions of the parts made so far (by address), and how many parts
  # have each name key.
  @main_part_fun_addresses = Set(UInt64).new
  @main_part_name_counts = Hash(String, Int32).new(0)
  getter main_part_count = 0

  # Accepts *body*, the body of the scope *owner* (a block or a file) whose
  # variables are *scope_vars*, in parts when it is top-level code that is
  # large enough (see `MainParts`).
  private def accept_scope_body(body : ASTNode, scope_vars : MetaVars?, owner, list_of_arg_names : Array(String)) : Nil
    if body.is_a?(Expressions) && main_parts_apply?
      if plan = MainParts::Plan.build?(body.expressions, MainParts.part_node_count)
        accept_in_parts(body, plan, scope_vars, owner, list_of_arg_names)
        return
      end
    end
    accept body
  end

  private def main_parts_apply? : Bool
    return false if @single_module || !MainParts.enabled?
    return false if @program.has_flag?("windows") || @program.has_flag?("wasm32")

    fun_address = context.fun.to_unsafe.address
    context.fun == @main || @main_part_fun_addresses.includes?(fun_address)
  end

  private def accept_in_parts(body : Expressions, plan : MainParts::Plan, scope_vars : MetaVars?, owner, list_of_arg_names : Array(String)) : Nil
    statements = body.expressions
    locals_by_group = local_vars_by_group(plan, scope_vars, owner, list_of_arg_names)

    old_needs_value = @needs_value
    last_index = statements.size - 1
    plan.list_of_groups.each_with_index do |group, group_index|
      break if @builder.end
      if group.outlined? && codegen_main_part(statements, group, locals_by_group[group_index]? || ([] of MetaVar))
        next
      end
      group.list_of_indexes.each do |index|
        @needs_value = old_needs_value && index == last_index
        accept statements[index]
      end
    end
    @needs_value = old_needs_value
  end

  # The variables declared in the scope that only one part names, by the
  # index of that part's group.
  private def local_vars_by_group(plan : MainParts::Plan, scope_vars : MetaVars?, owner, list_of_arg_names : Array(String)) : Hash(Int32, Array(MetaVar))
    locals_by_group = {} of Int32 => Array(MetaVar)
    return locals_by_group unless scope_vars

    group_index_by_name = {} of String => Int32
    shared_names = Set(String).new
    plan.list_of_groups.each_with_index do |group, group_index|
      group.var_names.each do |name|
        if !group.outlined?
          shared_names << name
        elsif (seen = group_index_by_name[name]?) && seen != group_index
          shared_names << name
        else
          group_index_by_name[name] = group_index
        end
      end
    end

    group_index_by_name.each do |name, group_index|
      next if shared_names.includes?(name) || list_of_arg_names.includes?(name)
      var = scope_vars[name]?
      next unless var && var.belongs_to?(owner) && !var.closured? && !var.special_var?
      (locals_by_group[group_index] ||= [] of MetaVar) << var
    end
    locals_by_group
  end

  # The kind of LLVM value a variable of the enclosing scope is passed to a
  # part as, or `nil` when it cannot be.
  private def main_part_param_type(var : LLVMVar, llvm_context : LLVM::Context) : LLVM::Type?
    value_type = var.pointer.type
    case value_type.kind
    when .pointer?
      llvm_context.pointer
    when .integer?
      llvm_context.int(value_type.int_width)
    else
      nil
    end
  end

  # Generates the statements of *group* as a part, and calls it. Returns
  # false, generating nothing, when a variable cannot be passed.
  private def codegen_main_part(statements : Array(ASTNode), group : MainParts::Group, locals : Array(MetaVar)) : Bool
    local_names = locals.map(&.name).to_set
    list_of_passed = [] of {String, LLVMVar}
    list_of_void_names = [] of String
    names = group.var_names.select { |name| context.vars.has_key?(name) && !local_names.includes?(name) }
    names << "self" if context.vars.has_key?("self")
    names << "%scope" if context.vars.has_key?("%scope")
    names.uniq!.sort!
    names.each do |name|
      var = context.vars[name]
      if var.type.void?
        list_of_void_names << name
      elsif main_part_param_type(var, llvm_context)
        list_of_passed << {name, var}
      else
        return false
      end
    end

    key = group.head.to_s
    turn = (@main_part_name_counts[key] += 1)
    name = turn == 1 ? "#{MainParts::NAME_PREFIX}#{key}" : "#{MainParts::NAME_PREFIX}#{key}~#{turn}"
    first_statement = statements[group.list_of_indexes.first]
    location = first_statement.location

    llvm_mod, llvm_typer = new_module_and_typer(name)
    module_info = ModuleInfo.new(name, llvm_mod, llvm_typer)
    module_info.builder = new_builder(module_info)
    module_info.pin_count = 1
    @modules[name] = module_info
    @main_part_count += 1

    ended = false
    part_vars = context.vars
    in_module(module_info) do
      with_cloned_context do
        context.return_phi = nil
        context.break_phi = nil
        context.next_phi = nil
        context.while_block = nil
        context.reset_closure

        list_of_param_types = list_of_passed.map { |(_, var)| main_part_param_type(var, llvm_context).not_nil! }
        fun_type = LLVM::Type.function(list_of_param_types, llvm_context.void)
        typed_fun = add_typed_fun(module_info, name, fun_type)
        func = typed_fun.func
        @main_part_fun_addresses << func.to_unsafe.address
        context.fun = func
        context.fun_type = fun_type
        {% if LibLLVM::IS_LT_150 %}
          func.add_attribute LLVM::Attribute::UWTable
        {% else %}
          func.add_attribute LLVM::Attribute::UWTable, value: @program.has_flag?("aarch64") ? LLVM::UWTableKind::Sync : LLVM::UWTableKind::Async
        {% end %}
        if @frame_pointers.always?
          func.add_attribute "frame-pointer", value: "all"
        elsif @program.has_flag?("darwin") || @program.has_flag?("solaris")
          func.add_target_dependent_attribute "frame-pointer", "all"
        elsif @frame_pointers.non_leaf?
          func.add_attribute "frame-pointer", value: "non-leaf"
        end

        unless @debug.none?
          emit_fun_debug_metadata(func, name, location.try(&.expanded_location), is_optimized: !@debug.variables?)
        end
        new_entry_block
        set_current_debug_location first_statement if @debug.line_numbers?

        context.vars = LLVMVars.new
        list_of_passed.each_with_index do |(var_name, var), index|
          context.vars[var_name] = LLVMVar.new(func.params[index], var.type, var.already_loaded, debug_variable_created: true)
        end
        list_of_void_names.each do |var_name|
          context.vars[var_name] = LLVMVar.new(llvm_nil, @program.void)
        end
        unless locals.empty?
          local_vars = MetaVars.new
          locals.each { |var| local_vars[var.name] = var }
          alloca_non_closured_vars local_vars, locals.first.context
          locals.each do |var|
            next unless bound_to_mod_nil?(var)
            next unless local_var = context.vars[var.name]?
            assign local_var.pointer, local_var.type, @program.nil, llvm_nil
          end
        end

        @needs_value = false
        group.list_of_indexes.each do |index|
          break if @builder.end
          accept statements[index]
        end
        ended = @builder.end
        ret unless ended
        br_from_alloca_to_entry
      end
    end

    set_current_debug_location first_statement if @debug.line_numbers?
    parent_fun_type = LLVM::Type.function(list_of_passed.map { |(_, var)| main_part_param_type(var, llvm_context).not_nil! }, llvm_context.void)
    callee = typed_fun?(@module_info, name) || add_typed_fun(@module_info, name, parent_fun_type)
    args = list_of_passed.map { |(_, var)| var.pointer }
    if rescue_block = @rescue_block
      invoke_out_block = new_block "invoke_out"
      invoke callee, args, invoke_out_block, rescue_block
      position_at_end invoke_out_block
    else
      call callee, args
    end
    unreachable if ended
    @last = llvm_nil
    true
  end
end
