require "./warnings"

# Writes that land on a copy of a struct and are lost.
#
# A struct is a value: a method that returns one returns a copy. Setting a
# field of that copy changes a temporary that nothing reads afterwards:
#
#     array_of_points[0].x = 1   # Array#[] returns a copy of the Point
#     pointer[3].x = 1           # Pointer#[] returns a copy too
#     pointer.value.x += 1       # `a.b += c` copies `a` to a temporary first
#     make_point.x = 1           # any method that returns a struct
#
# A setter call keeps its write when the receiver is a place the program
# reads again: a local variable, `self`, an instance or class variable,
# `pointer.value` (the codegen hands the setter the pointer itself), or an
# instance variable getter (always inlined) on such a place or on an object
# of a reference type.
#
# The check runs after type inference, from `CleanupTransformer`. The write is
# a warning in every file and an error in a strict file (`# crystal: strict`).
module Crystal
  class Program
    @struct_copy_writes_detected = Set(String).new

    # Reports *node* when it is a setter call (`x.field = value`, or the setter
    # an `x.field op= value` expands to) whose write lands on a copy of a struct.
    def check_write_to_struct_copy(node : Call) : Nil
      return unless StructCopyWrite.setter_name?(node.name)
      receiver = node.obj
      return unless receiver

      receiver_type = receiver.type?
      return unless receiver_type && StructCopyWrite.struct_value?(receiver_type)

      target_defs = node.target_defs
      return unless target_defs
      return unless target_defs.any? { |target_def| StructCopyWrite.writes_own_field?(target_def) }

      op_assign = node.op_assign_source
      if op_assign
        source = op_assign.target.as?(Call).try(&.obj)
        return unless source
      else
        return if StructCopyWrite.writable_place?(receiver)
        source = receiver
      end

      location = op_assign.try(&.location) || node.location
      return unless location
      strict = strict_file?(location)
      return unless strict || @warnings.level.all?

      message = StructCopyWrite.message(node, op_assign, source, receiver_type)
      if strict
        (op_assign || node).raise "strict file: #{message}"
      end

      key = "#{location} #{node.name}"
      return unless @struct_copy_writes_detected.add?(key)
      @warnings.add_warning(op_assign || node, message)
    end
  end

  module StructCopyWrite
    # Is *name* the name of a setter (`x=`), as opposed to `[]=` or an
    # operator such as `==`?
    def self.setter_name?(name : String) : Bool
      return false unless name.ends_with?('=') && name.size > 1
      first = name[0]
      return false unless first.ascii_letter? || first == '_'
      name[0...-1].each_char.all? { |char| char.ascii_alphanumeric? || char == '_' }
    end

    # Is a value of *type* a struct copied on assignment and return?
    def self.struct_value?(type : Type) : Bool
      type = type.remove_typedef
      return false if type.is_a?(UnionType) || type.is_a?(TupleInstanceType) || type.is_a?(NamedTupleInstanceType)
      type.passed_by_value?
    end

    # Does *target_def* store into a field of its receiver?
    def self.writes_own_field?(target_def : Def) : Bool
      return false if target_def.is_a?(External)
      body = target_def.body
      return body.name == "struct_or_union_set" if body.is_a?(Primitive)
      finder = OwnFieldWriteFinder.new
      body.accept finder
      finder.found?
    end

    # Does a write to a field of *node* reach a value the program reads again?
    def self.writable_place?(node : ASTNode) : Bool
      case node
      when Var, InstanceVar, ClassVar, Global
        true
      when ReadInstanceVar
        receiver_type = node.obj.type?
        !(receiver_type && struct_value?(receiver_type)) || writable_place?(node.obj)
      when Expressions
        expressions = node.expressions
        expressions.size == 1 && writable_place?(expressions.first)
      when Call
        writable_call_result?(node)
      else
        false
      end
    end

    # Does *call* give its caller the place it reads from, instead of a copy?
    # This mirrors `CodeGenVisitor#try_inline_call` and the `pointer_get`
    # primitive.
    private def self.writable_call_result?(call : Call) : Bool
      target_defs = call.target_defs
      # Untyped, or a dispatch among several methods: not judged.
      return true unless target_defs && target_defs.size == 1

      target_def = target_defs.first
      return false if target_def.is_a?(External)

      case body = target_def.body
      when Primitive
        body.name == "pointer_get"
      when InstanceVar
        receiver_is_writable?(call)
      when Var
        body.name == "self" && receiver_is_writable?(call)
      else
        false
      end
    end

    # The receiver of an inlined getter: `self` when there is none, a place,
    # or an object of a reference type (its fields live on the heap).
    private def self.receiver_is_writable?(call : Call) : Bool
      receiver = call.obj
      return true unless receiver
      receiver_type = receiver.type?
      return true unless receiver_type && struct_value?(receiver_type)
      writable_place?(receiver)
    end

    def self.message(node : Call, op_assign : OpAssign?, source : ASTNode, source_type : Type) : String
      field = node.name.rchop
      written = (op_assign || node).to_s
      source_text = source.to_s
      String.build do |io|
        io << "`" << written << "` sets field '" << field << "' of a copy of `" << source_text
        io << "` (a " << source_type << " struct), so the write is lost"
        if op_assign
          io << ": `" << op_assign.target << " " << op_assign.op << "=` copies `" << source_text << "` to a temporary first"
        end
        io << ".\n\nCopy it to a local, change the local and write it back:\n\n"
        io << "    copy = " << source_text << "\n"
        if op_assign
          io << "    copy." << field << " " << op_assign.op << "= " << op_assign.value << "\n"
        else
          io << "    copy." << field << " = " << node.args.first? << "\n"
        end
        io << "    " << source_text << " = copy\n"

        if pointer_field_form = pointer_field_form(node, op_assign, source, field)
          io << "\nor write through the pointer in place:\n\n    " << pointer_field_form << "\n"
        end
      end
    end

    # The in-place form for a struct read through a pointer: `(p + i).value.f = v`
    # for `p[i]`, and `p.value.f = p.value.f + v` for `p.value.f += v`.
    private def self.pointer_field_form(node : Call, op_assign : OpAssign?, source : ASTNode, field : String) : String?
      return unless source.is_a?(Call)
      pointer = source.obj
      return unless pointer && pointer.type?.try(&.remove_typedef).is_a?(PointerInstanceType)

      place =
        case source.name
        when "value"
          return unless source.args.empty?
          "#{pointer}.value"
        when "[]"
          return unless source.args.size == 1
          "(#{pointer} + #{source.args.first}).value"
        else
          return
        end

      if op_assign
        case op_assign.op
        when "||", "&&"
          "#{place}.#{field} #{op_assign.op} (#{place}.#{field} = #{op_assign.value})"
        else
          "#{place}.#{field} = #{place}.#{field} #{op_assign.op} #{op_assign.value}"
        end
      else
        "#{place}.#{field} = #{node.args.first?}"
      end
    end

    # Finds an assignment to an instance variable of `self`.
    class OwnFieldWriteFinder < Visitor
      getter? found = false

      def visit(node : Assign)
        @found = true if node.target.is_a?(InstanceVar)
        !@found
      end

      def visit(node : MultiAssign)
        @found = true if node.targets.any?(InstanceVar)
        !@found
      end

      def visit(node : ASTNode)
        !@found
      end
    end
  end
end
