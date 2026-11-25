require "./call"

# One typed copy for every receiver of a method whose body never consults its
# receiver.
#
# A call is typed against a copy of its method keyed on the receiver type and
# the argument types, so a method inherited by 300 models, or included in 300
# generic instances, is typed 300 times even when its body does the same
# thing for each of them:
#
# ```
# module Grant::Query::Executor::Shared
#   def log_query_with_timing(sql : String, args : Array(Grant::Columns::Type), duration : Time::Span, row_count : Int32?, model_name : String?)
#     Grant::Logs::SQL.debug { "Query executed (#{duration.total_milliseconds}ms) - #{sql} [#{model_name}]" }
#   end
# end
# ```
#
# When the body names nothing that depends on the receiver, the copy typed
# for one receiver is the copy every other receiver would get: the same
# nodes, the same types and the same call targets. Such a call then reuses
# the copy typed first. A body is *receiver free* when:
#
# * it does not name `self`, an instance variable or a class variable, and
#   holds no macro code (`{{ }}`, `{% %}`), `yield`, proc literal or proc
#   pointer, `super` or `previous_def`;
# * every call without a receiver resolves to no method of the receiver (so
#   the lookup falls through to the top level for every receiver alike), and
#   no call that could be a macro is made (a call to a protected method is
#   checked again for each receiver that reuses the copy, once type inference
#   ends);
# * the method takes no block, no splat and no default argument at the call,
#   and has no free variables.
#
# Two receivers share a copy only when the method was found in the same
# defining type (paths in the body resolve from there), the arguments have
# the same types, the declared return type resolves to the same type for
# both, and the receivers have the same representation in generated code (a
# class instance pointer, a class value passed as a type id, or a class
# value not passed at all): the shared function never reads its `self`
# argument, so any receiver of that representation can be passed as it is.
#
# A call that dispatches (a union receiver, or a module type), a `super` or
# `previous_def`, or a call inside a `with ... yield` block keeps the copy
# typed for its own receiver. So does every call when the build keeps typed
# state between builds (incremental builds and the build server key reuse
# on the owner of each copy).
#
# `CRYSTAL_SHARE_RECEIVER_FREE=0` turns sharing off. `verify` types every
# copy as before and compares each one that would have been shared with the
# shared copy once type inference ends (nodes, types, call targets, variables,
# return type), printing any difference; `stats` prints the counters.
module Crystal
  module ReceiverFreeSharing
    enum Mode
      Off
      On
      Verify
    end

    class_getter mode : Mode do
      case ENV["CRYSTAL_SHARE_RECEIVER_FREE"]?
      when "0"      then Mode::Off
      when "verify" then Mode::Verify
      else               Mode::On
      end
    end

    class_getter? print_stats : Bool = ENV["CRYSTAL_SHARE_RECEIVER_FREE"]?.in?("stats", "verify")

    # How a receiver is passed to the generated function. Receivers of one
    # kind are interchangeable for a function that never reads `self`.
    enum ReceiverKind : UInt8
      # A class instance or a virtual class type: an object pointer.
      Object
      # A class value passed as a type id (a generic instance's metaclass).
      ClassValue
      # A virtual metaclass: a type id, and proc literals treat it as
      # closured `self`.
      VirtualClassValue
      # A non-generic metaclass: not passed at all.
      StaticClass
    end

    def self.receiver_kind(type : Type) : ReceiverKind?
      case type
      when VirtualType
        type.struct? ? nil : ReceiverKind::Object
      when VirtualMetaclassType
        ReceiverKind::VirtualClassValue
      when MetaclassType
        ReceiverKind::StaticClass
      when GenericClassInstanceMetaclassType
        ReceiverKind::ClassValue
      when NonGenericClassType, GenericClassInstanceType
        return nil if type.struct? || type.module? || type.is_a?(NilType)
        ReceiverKind::Object
      else
        nil
      end
    end

    # What one source def's body consults, scanned once per def.
    class Scan
      getter? receiver_free : Bool
      getter list_of_receiverless_names : Array(String)

      # Why the body is not receiver free, for the probe.
      getter refusal : String?

      def initialize(@receiver_free : Bool, @list_of_receiverless_names : Array(String), @refusal : String? = nil)
      end
    end

    # Reads an untyped body and records whether it is receiver free.
    class Scanner < Visitor
      getter? receiver_free = true
      getter list_of_receiverless_names = [] of String
      getter refusal : String?

      def initialize(@macro_names : Set(String))
      end

      def refuse(reason : String) : Nil
        @refusal ||= reason
        @receiver_free = false
      end

      def visit(node : ASTNode) : Bool
        @receiver_free
      end

      def visit(node : Var) : Bool
        refuse("self") if node.name == "self"
        false
      end

      def visit(node : InstanceVar | ClassVar | Self | Yield | ProcLiteral | ProcPointer | Primitive | Out | Def | Macro |
                       MacroExpression | MacroIf | MacroFor | MacroLiteral | MacroVerbatim | MacroVar) : Bool
        refuse(node.class.name.lchop("Crystal::"))
        false
      end

      def visit(node : Call) : Bool
        return false unless @receiver_free

        name = node.name
        if node.super? || node.previous_def?
          refuse("super or previous_def")
          return false
        end

        obj = node.obj
        if obj.nil?
          # A global call (`::foo`) only looks at the top level.
          unless node.global?
            if @macro_names.includes?(name)
              refuse("macro name #{name}")
              return false
            end
            @list_of_receiverless_names << name unless @list_of_receiverless_names.includes?(name)
          end
        else
          # A macro called on a type expands in the receiver's scope.
          if (obj.is_a?(Path) || obj.is_a?(Generic)) && @macro_names.includes?(name)
            refuse("macro name #{name}")
            return false
          end
        end
        true
      end
    end

    # A shared copy: the def it was typed from, where that def was found, how
    # the receiver is passed, and the argument types.
    record Key,
      def_object_id : UInt64,
      defining_type_object_id : UInt64,
      receiver_kind : ReceiverKind,
      arg_types : Array(Type)

    # A copy typed for its own receiver that verify mode compares with the
    # shared one.
    record VerifyPair, own_copy : Def, shared_copy : Def, receiver : Type
  end

  class Def
    # `true` for a typed copy that calls with other receivers reuse (see
    # `ReceiverFreeSharing`): its owner is one of several receivers.
    property? receiver_free = false
  end

  class Program
    @receiver_free_scans = {} of UInt64 => ReceiverFreeSharing::Scan
    @receiver_free_macro_names : Set(String)?
    @receiver_free_method_missing : Bool?

    # The shared copies, by what they were typed for.
    getter receiver_free_copies = {} of ReceiverFreeSharing::Key => Def

    # Copies compared in verify mode.
    getter list_of_receiver_free_verify_pairs = [] of ReceiverFreeSharing::VerifyPair

    # `CRYSTAL_SHARE_RECEIVER_FREE_PROBE=<file>`: for every source def, its
    # typed copies and why they were not shared.
    getter receiver_free_probe : Hash(UInt64, {Def, Int32, String})? do
      ENV["CRYSTAL_SHARE_RECEIVER_FREE_PROBE"]?.presence ? Hash(UInt64, {Def, Int32, String}).new : nil
    end

    def note_receiver_free_probe(source_def : Def, reason : String) : Nil
      probe = receiver_free_probe || return
      entry = probe[source_def.object_id]?
      probe[source_def.object_id] = {source_def, (entry.try(&.[1]) || 0) + 1, entry.try(&.[2]) || reason}
    end

    property receiver_free_shared_calls = 0_i64
    property receiver_free_registered = 0_i64

    # Whether this program shares receiver-free copies.
    def share_receiver_free_copies? : Bool
      return false if ReceiverFreeSharing.mode.off?
      return false if infer_reuse_record || compiler.try(&.incremental?)
      true
    end

    def receiver_free_scan(a_def : Def) : ReceiverFreeSharing::Scan
      @receiver_free_scans[a_def.object_id] ||= begin
        if receiver_free_candidate?(a_def)
          scanner = ReceiverFreeSharing::Scanner.new(receiver_free_macro_names)
          a_def.body.accept scanner
          a_def.return_type.try { |return_type| scanner.visit_return_type(return_type) }
          ReceiverFreeSharing::Scan.new(scanner.receiver_free?, scanner.list_of_receiverless_names, scanner.refusal)
        else
          ReceiverFreeSharing::Scan.new(false, [] of String, "kind of method")
        end
      end
    end

    private def receiver_free_candidate?(a_def : Def) : Bool
      return false if a_def.is_a?(External)
      return false if a_def.type_once? || a_def.macro_def? || a_def.abstract? || a_def.new?
      return false if a_def.name == "initialize"
      return false if a_def.block_arity || a_def.block_arg || a_def.uses_block_arg?
      return false if a_def.splat_index || a_def.double_splat || a_def.free_vars
      return false if a_def.calls_super? || a_def.calls_previous_def? || a_def.calls_initialize?
      body = a_def.body
      return false if body.is_a?(Primitive) || body.is_a?(ReleasedBody)
      true
    end

    # Whether any type of the program defines `method_missing`.
    def receiver_free_method_missing? : Bool
      @receiver_free_method_missing ||= receiver_free_macro_names.includes?("method_missing")
    end

    private def receiver_free_macro_names : Set(String)
      @receiver_free_macro_names ||= begin
        names = Set(String).new
        visited = Set(UInt64).new
        collect_receiver_free_names(self, visited) do |type|
          type.macros.try &.each_key { |name| names << name }
          type.metaclass.macros.try &.each_key { |name| names << name } unless type.metaclass?
        end
        file_modules.each_value { |file_module| file_module.macros.try &.each_key { |name| names << name } }
        names
      end
    end

    # Every receiver that reused a shared copy, with that copy.
    getter receiver_free_reuses = {} of {UInt64, UInt64} => {Type, Def}

    def note_receiver_free_reuse(receiver : Type, shared_copy : Def) : Nil
      @receiver_free_reuses[{receiver.object_id, shared_copy.object_id}] ||= {receiver, shared_copy}
    end

    # Raises, as a copy typed for the receiver would have, when a receiver
    # that reused a shared copy has no access to a protected method the
    # copy calls (access depends on the caller's type).
    def check_receiver_free_protected_access : Nil
      protected_calls = {} of UInt64 => Array(Call)
      @receiver_free_reuses.each_value do |(receiver, shared_copy)|
        calls = protected_calls[shared_copy.object_id] ||= ReceiverFreeSharing::ProtectedCalls.new.tap { |finder| shared_copy.body.accept(finder) }.list_of_calls
        calls.each do |call|
          call.target_defs.try &.each do |target|
            next unless target.visibility.protected?
            owner_type = (target.original_owner? || target.owner).instance_type
            next if receiver.instance_type.has_protected_access_to?(owner_type)
            call.raise "protected method '#{target.name}' called for #{target.original_owner? || target.owner}"
          end
        end
      end
    end

    private def collect_receiver_free_names(type : Type, visited : Set(UInt64), &block : Type ->) : Nil
      return unless visited.add?(type.object_id)
      block.call(type)
      type.types?.try &.each_value { |nested| collect_receiver_free_names(nested, visited, &block) }
    end

    # Compares, in verify mode, every copy that would have been shared with
    # the shared copy, and prints the counters. Runs once type inference has
    # ended, when every type is final.
    def report_receiver_free_sharing : Nil
      check_receiver_free_protected_access
      if (probe = receiver_free_probe) && (path = ENV["CRYSTAL_SHARE_RECEIVER_FREE_PROBE"]?.presence)
        File.open(path, "w") do |file|
          probe.values.sort_by! { |entry| -entry[1] }.each do |entry|
            a_def = entry[0]
            location = a_def.location
            file.puts "#{entry[1]}\t#{a_def.owner?}#{a_def.receiver ? "." : "#"}#{a_def.name}\t#{location.try(&.original_filename)}:#{location.try(&.line_number)}\t#{entry[2]}"
          end
        end
      end
      if ReceiverFreeSharing.mode.verify?
        differ = 0
        @list_of_receiver_free_verify_pairs.each do |pair|
          if difference = ReceiverFreeSharing::Comparison.new(pair.own_copy, pair.shared_copy).first_difference
            differ += 1
            if differ <= 20
              STDERR.puts "receiver-free verify: #{pair.own_copy.owner}##{pair.own_copy.name} (#{pair.own_copy.location}) differs from the copy of #{pair.shared_copy.owner}: #{difference}"
            end
          end
        end
        STDERR.puts "receiver-free verify: #{@list_of_receiver_free_verify_pairs.size} copies compared, #{differ} differ, #{@receiver_free_registered} shared copies"
      elsif ReceiverFreeSharing.print_stats?
        STDERR.puts "receiver-free sharing: #{@receiver_free_registered} shared copies, #{@receiver_free_shared_calls} calls reused one"
      end
    end
  end

  class ReceiverFreeSharing::Scanner
    # The declared return type is resolved again for each receiver (see
    # `Call#receiver_free_copy`); only `self` in it is refused here.
    def visit_return_type(node : ASTNode) : Nil
      refuse("self in the return type") if node.is_a?(Self) || (node.is_a?(Path) && node.names == ["self"])
      node.accept(self) if node.is_a?(Generic) || node.is_a?(Union) || node.is_a?(Metaclass) || node.is_a?(ProcNotation)
    end
  end

  # Finds the calls of a typed body that reach a protected method.
  class ReceiverFreeSharing::ProtectedCalls < Visitor
    getter list_of_calls = [] of Call

    def visit(node : ASTNode) : Bool
      if node.is_a?(ExpandableNode) && (expanded = node.expanded)
        expanded.accept(self)
      end
      true
    end

    def visit(node : Call) : Bool
      @list_of_calls << node if node.target_defs.try &.any?(&.visibility.protected?)
      if expanded = node.expanded
        expanded.accept(self)
        return false
      end
      true
    end
  end

  # Compares a copy typed for its own receiver with the shared copy, node by
  # node, in verify mode.
  class ReceiverFreeSharing::Comparison
    def initialize(@own_copy : Def, @shared_copy : Def)
    end

    # A description of the first difference, or `nil` when the copies agree.
    def first_difference : String?
      own_type = @own_copy.type?
      shared_type = @shared_copy.type?
      return "return type #{own_type} against #{shared_type}" unless own_type.same?(shared_type)
      return "declared return type" unless @own_copy.freeze_type.same?(@shared_copy.freeze_type)
      return "raises" unless @own_copy.raises? == @shared_copy.raises?
      return "closure" unless @own_copy.closure? == @shared_copy.closure? && @own_copy.self_closured? == @shared_copy.self_closured?
      return "special variables" unless @own_copy.special_vars == @shared_copy.special_vars

      if difference = vars_difference(@own_copy.vars, @shared_copy.vars)
        return difference
      end

      own_nodes = Fingerprint.new.tap { |fingerprint| @own_copy.body.accept(fingerprint) }.list_of_entries
      shared_nodes = Fingerprint.new.tap { |fingerprint| @shared_copy.body.accept(fingerprint) }.list_of_entries
      return "#{own_nodes.size} nodes against #{shared_nodes.size}" unless own_nodes.size == shared_nodes.size
      own_nodes.each_with_index do |entry, index|
        other = shared_nodes[index]
        return "node #{index}: #{entry} against #{other}" unless entry == other
      end
      nil
    end

    # Compiler-made variables (`__temp_N`, `__argN`) are numbered by the
    # program as a whole, so two copies name them differently: they are
    # compared by their types alone.
    def self.made_by_compiler?(name : String) : Bool
      name.starts_with?("__temp_") || name.starts_with?("__arg")
    end

    private def vars_difference(own_vars : MetaVars?, shared_vars : MetaVars?) : String?
      own_names = own_vars.try(&.keys.reject("self")) || [] of String
      shared_names = shared_vars.try(&.keys.reject("self")) || [] of String
      own_made, own_names = own_names.partition { |name| Comparison.made_by_compiler?(name) }
      shared_made, shared_names = shared_names.partition { |name| Comparison.made_by_compiler?(name) }
      own_made_types = own_made.map { |name| own_vars.not_nil![name].type?.try(&.object_id) || 0_u64 }.sort
      shared_made_types = shared_made.map { |name| shared_vars.not_nil![name].type?.try(&.object_id) || 0_u64 }.sort
      return "compiler-made variables" unless own_made_types == shared_made_types
      return "variables #{own_names} against #{shared_names}" unless own_names.sort == shared_names.sort
      own_names.each do |name|
        own_var = own_vars.not_nil![name]
        shared_var = shared_vars.not_nil![name]
        return "variable #{name}: #{own_var.type?} against #{shared_var.type?}" unless own_var.type?.same?(shared_var.type?)
        return "variable #{name} closured" unless own_var.closured? == shared_var.closured?
      end
      nil
    end

    # The node classes, types and call targets of a body, in order,
    # including what typing expanded a node into.
    private class Fingerprint < Visitor
      getter list_of_entries = [] of String

      def visit(node : ASTNode) : Bool
        @list_of_entries << "#{node.class.name}:#{node.type?.try(&.object_id)}"
        if node.is_a?(ExpandableNode) && (expanded = node.expanded)
          expanded.accept(self)
        end
        true
      end

      def visit(node : Call) : Bool
        entry = String.build do |io|
          io << "Call " << node.name << ':' << node.type?.try(&.object_id)
          node.target_defs.try &.each do |target|
            io << " -> " << target.owner?.try(&.object_id) << '#' << target.name << '(' << target.args.map(&.type?.try(&.object_id)).join(',') << "):" << target.type?.try(&.object_id)
          end
        end
        @list_of_entries << entry
        if expanded = node.expanded
          expanded.accept(self)
          return false
        end
        true
      end

      def visit(node : Var) : Bool
        name = Comparison.made_by_compiler?(node.name) ? "(made by the compiler)" : node.name
        @list_of_entries << "Var #{name}:#{node.type?.try(&.object_id)}"
        true
      end
    end
  end

  class Call
    # The receiver-free key for this call's *match*, or `nil` when the call
    # types its own copy (see `ReceiverFreeSharing`).
    private def receiver_free_key(match : Match, self_type : Type?) : ReceiverFreeSharing::Key?
      key = receiver_free_key_or_refusal(match, self_type)
      key.is_a?(ReceiverFreeSharing::Key) ? key : nil
    end

    # The key, or why this call types its own copy.
    protected def receiver_free_key_or_refusal(match : Match, self_type : Type?) : ReceiverFreeSharing::Key | String
      return "off" unless program.share_receiver_free_copies?
      return "super, previous_def, self type or with scope" if self_type || super? || previous_def? || with_scope

      a_def = match.def
      return "default, splat or named arguments" unless match.arg_types.size == a_def.args.size && match.named_arg_types.nil?
      scan = program.receiver_free_scan(a_def)
      return scan.refusal || "body" unless scan.receiver_free?

      context = match.context
      return "free variables" if context.def_free_vars || context.self_restriction_type
      if bound_free_vars = context.bound_free_vars
        return "free variables" unless bound_free_vars.empty?
      end

      receiver = context.instantiated_type
      if call_obj = obj
        call_receiver = call_obj.type?.try(&.remove_indirection)
        return "receiver differs from the call's" unless call_receiver && call_receiver.same?(receiver)
      end
      kind = ReceiverFreeSharing.receiver_kind(receiver)
      return "receiver kind" unless kind

      unless scan.list_of_receiverless_names.empty?
        # A call without a receiver looks at the receiver first: it must find
        # nothing there, for this receiver as for the one typed first.
        return "receiverless call on a virtual receiver" if receiver.is_a?(VirtualType) || receiver.is_a?(VirtualMetaclassType)
        return "receiverless call on an abstract receiver" if receiver.class? && receiver.abstract?
        if program.receiver_free_method_missing?
          return "method_missing" if receiver.instance_type.lookup_method_missing
          return "method_missing" unless receiver.instance_type.subclasses.empty?
        end
        scan.list_of_receiverless_names.each do |name|
          return "receiverless call #{name} finds a method of the receiver" unless receiver.lookup_defs(name).empty?
        end
      end

      ReceiverFreeSharing::Key.new(a_def.object_id, context.defining_type.object_id, kind, match.arg_types)
    end

    # The shared copy this call can reuse, or `nil`.
    private def receiver_free_copy(key : ReceiverFreeSharing::Key, match : Match) : Def?
      shared = program.receiver_free_copies[key]?
      return nil unless shared

      if return_type = match.def.return_type
        declared = begin
          lookup_node_type(match.context, return_type)
        rescue CodeError
          return nil
        end
        declared = program.nil if declared.void?
        return nil unless declared.same?(shared.freeze_type)
      end
      shared
    end
  end
end
