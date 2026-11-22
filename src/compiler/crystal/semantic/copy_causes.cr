require "./memory_census"

module Crystal
  # What one instantiation was keyed on: the source def and the receiver,
  # argument, named-argument and block types `Call#instantiate` looked the
  # typed copy up with. Recorded only while `CRYSTAL_COPY_CAUSES=1` is set, for
  # the memory census (see `MemoryCensus#print_copy_causes`).
  class InstantiationRecord
    getter source_def : Def
    getter receiver : Type
    getter arg_types : Array(Type)
    getter named_args : Array(NamedArgumentType)?
    getter block_type : Type?
    getter? owned_by_call : Bool

    def initialize(@source_def : Def, @receiver : Type, @arg_types : Array(Type),
                   @named_args : Array(NamedArgumentType)?, @block_type : Type?, @owned_by_call : Bool)
    end
  end

  class Program
    # Typed def object id => what it was instantiated for. `nil` unless
    # `CRYSTAL_COPY_CAUSES=1`.
    getter instantiation_records : Hash(UInt64, InstantiationRecord)? do
      ENV["CRYSTAL_COPY_CAUSES"]? == "1" ? Hash(UInt64, InstantiationRecord).new : nil
    end

    # How many typed copies `@[TypeOnce]` avoided (calls that reused the copy
    # typed against the declared types) and how many it typed.
    property type_once_typed = 0
    property type_once_reused = 0
  end

  class MemoryCensus
    # Why a source def has more than one typed copy. A def's copies are keyed
    # on several things at once (receiver, each argument, the block); every
    # one of them that varies is a *dimension*, and each dimension has a
    # cause.
    private class CopyDimension
      getter name : String
      getter values : Array(UInt64)
      # Cause of this dimension for each copy (copies of one def can differ:
      # an unrestricted argument holds a union in one copy and a class in the
      # next).
      getter causes : Array(String)

      def initialize(@name : String, size : Int32)
        @values = Array(UInt64).new(size, 0_u64)
        @causes = Array(String).new(size, "")
      end
    end

    private class CauseTotal
      property copies = 0.0
      property bytes = 0.0
      # Copies this cause alone would remove (its dimension collapsed, every
      # other dimension kept).
      property alone_copies = 0_i64
      property alone_bytes = 0.0
      getter families = Hash(String, {Float64, Float64, Int32, String}).new
    end

    CAUSE_FIRST_COPY = "0 first copy of each source def"

    # Groups every typed copy by the source def it was typed from and reports
    # why each copy beyond the first exists.
    def print_copy_causes(io : IO) : Nil
      records = @program.instantiation_records || return
      # Make sure the block-call copies are listed.
      @main_node.try { |main_node| fingerprint_node(main_node, nil) }
      index = 0
      while index < @cached_typed_defs.size
        fingerprint(@cached_typed_defs[index])
        index += 1
      end

      families = Hash(String, Array({InstantiationRecord, Int64})).new
      unrecorded = {0_i64, 0_i64}
      # Copies owned by instances of each generic type, and how many instances.
      generic_owners = Hash(String, {Int64, Int64, Set(UInt64)}).new
      all_copies = 0_i64
      all_bytes = 0_i64
      each_typed_copy do |typed_def|
        bytes = fingerprint(typed_def).bytes
        all_copies += 1
        all_bytes += bytes
        if record = records[typed_def.object_id]?
          (families[family_key(record.source_def)] ||= [] of {InstantiationRecord, Int64}) << {record, bytes}
          instance = record.receiver.instance_type
          instance = instance.base_type if instance.is_a?(VirtualType)
          if instance.is_a?(GenericInstanceType)
            name = instance.generic_type.to_s
            current = generic_owners[name]? || {0_i64, 0_i64, Set(UInt64).new}
            current[2] << instance.object_id
            generic_owners[name] = {current[0] + 1, current[1] + bytes, current[2]}
          end
        else
          unrecorded = {unrecorded[0] + 1, unrecorded[1] + bytes}
        end
      end

      totals = Hash(String, CauseTotal).new { |hash, key| hash[key] = CauseTotal.new }
      families.each do |key, copies|
        attribute_family(key, copies, totals)
      end

      io << "== copy causes after Semantic (main)\n"
      io.printf("causes   %-78s %9d copies %9.1f MB  %d source defs\n", "all typed copies", all_copies, all_bytes / 1e6, families.size)
      io.printf("causes   %-78s %9d copies %9.1f MB\n", "g typed without a call (lib funs, hooks)", unrecorded[0], unrecorded[1] / 1e6)
      ranked = totals.to_a.sort_by { |entry| -entry[1].bytes }
      ranked.each do |cause, total|
        io.printf("cause    %-66s %9d copies %9.1f MB  %6d source defs | alone: %9d copies %9.1f MB\n", cause[0, 66], total.copies.round.to_i64,
          total.bytes / 1e6, total.families.size, total.alone_copies, total.alone_bytes / 1e6)
      end
      ranked.each do |cause, total|
        next if cause == CAUSE_FIRST_COPY
        total.families.to_a.sort_by { |entry| -entry[1][1] }.first(20).each do |family, (copies, bytes, family_copies, detail)|
          io.printf("causedef %-66s | %-52s %8d copies %8.1f MB  of %6d  %s\n", cause[0, 66], family[0, 52], copies.round.to_i64, bytes / 1e6, family_copies, detail)
        end
      end
      generic_owners.to_a.sort_by { |entry| -entry[1][1] }.first(25).each do |name, (copies, bytes, instances)|
        io.printf("generic  %-66s %9d copies %9.1f MB  %6d instances\n", name[0, 66], copies, bytes / 1e6, instances.size)
      end
      io.printf("typeonce typed %d, reused %d, generic methods kept per instance %d\n", @program.type_once_typed, @program.type_once_reused, @program.generic_type_once_kept)
      io.flush
    end

    private def each_typed_copy(& : Def ->) : Nil
      @cached_typed_defs.each { |typed_def| yield typed_def }
      @block_call_copies.each { |(typed_def, _)| yield typed_def }
    end

    # Names a source def so that the defs a macro generates in every type, and
    # the clones virtual lookup makes of a macro def, land in one family.
    private def family_key(source_def : Def) : String
      location = source_def.location
      return source_def.name unless location
      filename = location.filename
      if filename.is_a?(VirtualFile)
        macro_location = filename.macro.location
        origin = macro_location ? "#{File.basename(macro_location.filename.to_s)}:#{macro_location.line_number}" : "?"
        "#{source_def.name} <macro #{filename.macro.name} #{origin} +#{location.line_number}>"
      else
        "#{source_def.name} #{File.basename(filename.to_s)}:#{location.line_number}"
      end
    end

    private def attribute_family(key : String, copies : Array({InstantiationRecord, Int64}), totals : Hash(String, CauseTotal)) : Nil
      size = copies.size
      family_bytes = copies.sum { |entry| entry[1] }.to_f
      bytes_per_copy = family_bytes / size
      dimensions = copy_dimensions(copies)

      first = totals[CAUSE_FIRST_COPY]
      first.copies += 1
      first.bytes += bytes_per_copy
      first.families[key] = {1.0, bytes_per_copy, size, ""}
      return if size == 1

      detail = dimensions.compact_map { |dimension|
        distinct = dimension.values.uniq.size
        distinct > 1 ? "#{dimension.name}=#{distinct}" : nil
      }.join(" ")

      # What each dimension would remove alone.
      full = distinct_rows(dimensions, size, nil)
      dimensions.each do |dimension|
        saved = full - distinct_rows(dimensions, size, dimension)
        next if saved == 0
        share_by_cause(dimension, saved.to_f) do |cause, share|
          total = totals[cause]
          total.alone_copies += share.round.to_i64
          total.alone_bytes += share * bytes_per_copy
        end
      end

      # Exclusive attribution: collapse the dimension that removes the most
      # copies, credit it, and repeat on what is left. When no single
      # dimension removes a copy (two of them move together, for example the
      # receiver and an argument of type `Array(self)`), the first varying
      # dimension is credited.
      remaining = dimensions.select { |dimension| dimension.values.uniq.size > 1 }
      current = distinct_rows(remaining, size, nil)
      # Copies with equal keys (a call typed again) count as their key's cause.
      duplicates = size - current
      until remaining.empty?
        best = remaining.max_by { |dimension| current - distinct_rows(remaining, size, dimension) }
        saved = current - distinct_rows(remaining, size, best)
        if saved == 0
          best = remaining.first
          note = remaining.size > 1 ? " (moves with: #{remaining[1..].map(&.name).join(", ")})" : ""
          saved = current - 1
          remaining.clear
        else
          note = ""
          remaining.delete(best)
        end
        current -= saved
        share_by_cause(best, saved.to_f) do |cause, share|
          total = totals[cause]
          total.copies += share
          total.bytes += share * bytes_per_copy
          existing = total.families[key]? || {0.0, 0.0, size, detail + note}
          total.families[key] = {existing[0] + share, existing[1] + share * bytes_per_copy, size, existing[3]}
        end
      end
      if duplicates > 0
        cause = "g same key typed again"
        total = totals[cause]
        total.copies += duplicates
        total.bytes += duplicates * bytes_per_copy
        total.families[key] = {duplicates.to_f, duplicates * bytes_per_copy, size, detail}
      end
    end

    # Splits *amount* over the causes of *dimension* in proportion to how
    # many copies carry each cause.
    private def share_by_cause(dimension : CopyDimension, amount : Float64, & : String, Float64 ->) : Nil
      dimension.causes.tally.each do |cause, count|
        yield cause, amount * count / dimension.causes.size
      end
    end

    private def distinct_rows(dimensions : Array(CopyDimension), size : Int32, without : CopyDimension?) : Int32
      rows = Set(UInt64).new
      size.times do |index|
        row = 0xcbf29ce484222325_u64
        dimensions.each do |dimension|
          next if dimension.same?(without)
          row = mix(row, dimension.values[index])
        end
        rows << row
      end
      rows.size
    end

    private def copy_dimensions(copies : Array({InstantiationRecord, Int64})) : Array(CopyDimension)
      size = copies.size
      receiver = CopyDimension.new("receiver", size)
      arity = CopyDimension.new("arity", size)
      named = CopyDimension.new("named", size)
      block = CopyDimension.new("block", size)
      # Virtual lookup clones a def whose body reads `@type` into every
      # subclass, so a subclass reached both directly and through its base
      # type holds two copies with equal keys.
      source = CopyDimension.new("source", size)
      max_args = copies.max_of { |entry| entry[0].arg_types.size }
      args = Array(CopyDimension).new(max_args) { |index| CopyDimension.new("arg#{index}", size) }

      copies.each_with_index do |(record, _), index|
        source_def = record.source_def
        receiver.values[index] = record.receiver.object_id
        source.values[index] = source_def.macro_def? ? source_def.object_id : 0_u64
        source.causes[index] = "a self: @type-reading def cloned again for dispatch through the base"
        receiver.causes[index] = receiver_cause(source_def, record.receiver)
        arity.values[index] = record.arg_types.size.to_u64
        arity.causes[index] = "g number of arguments (defaults, splats)"
        record.arg_types.each_with_index do |arg_type, arg_index|
          args[arg_index].values[index] = arg_type.object_id
          args[arg_index].causes[index] = argument_cause(source_def, arg_index, arg_type)
        end
        (record.arg_types.size...max_args).each do |arg_index|
          args[arg_index].causes[index] = "g number of arguments (defaults, splats)"
        end
        if named_args = record.named_args
          value = 0xcbf29ce484222325_u64
          named_args.each { |named_arg| value = mix(mix(value, named_arg.name.hash), named_arg.type.object_id) }
          named.values[index] = value
        end
        named.causes[index] = "b named arguments"
        if record.owned_by_call?
          # One copy per block type: block-call copies with equal blocks were
          # already shared.
          block.values[index] = index.to_u64 + 1
          block.causes[index] = "e block: yielding def, per block type"
        else
          block.values[index] = record.block_type.try(&.object_id) || 0_u64
          block.causes[index] = "e block: captured block, per return type"
        end
      end
      [receiver] + args + [arity, named, block, source]
    end

    private def receiver_cause(source_def : Def, receiver : Type) : String
      side = receiver.metaclass? ? "class method" : "method"
      location = source_def.location
      instance = receiver.instance_type
      instance = instance.base_type if instance.is_a?(VirtualType)
      defined_in = source_def.owner.instance_type
      generated = location && location.filename.is_a?(VirtualFile)
      if instance == defined_in || (instance.is_a?(GenericInstanceType) && instance.generic_type == defined_in)
        if generated && !instance.is_a?(GenericInstanceType)
          return "f macro-generated #{side}, one per type"
        elsif instance.is_a?(GenericInstanceType)
          return "d generic instance: #{side} of a generic type"
        else
          return "g virtual and concrete self of one type"
        end
      end
      kind = defined_in.module? ? "a module" : "a base class"
      generic = instance.is_a?(GenericInstanceType) ? " (generic receiver)" : ""
      if source_def.macro_def?
        "a self: @type-reading #{side} from #{kind}#{generic}"
      else
        "a self: #{side} from #{kind}#{generic}"
      end
    end

    private def argument_cause(source_def : Def, index : Int32, arg_type : Type) : String
      splat_index = source_def.splat_index
      return "g number of arguments (defaults, splats)" if splat_index && index >= splat_index
      arg = source_def.args[index]? || return "g number of arguments (defaults, splats)"
      restriction = arg.restriction
      value = arg_type.is_a?(UnionType) ? ", union value" : ""
      return "b unrestricted argument#{value}" unless restriction
      case restriction
      when Self
        return "a argument restricted to self"
      when Union
        return "c union restriction"
      when Metaclass
        return "a argument restricted to a metaclass (Base.class)"
      when Generic, ProcNotation
        return "d argument restricted to a generic or proc type#{value}"
      when Path
        if restriction.names.size == 1 && source_def.free_vars.try(&.includes?(restriction.names.first))
          return "d argument restricted to a free variable#{value}"
        end
      end
      resolved = begin
        source_def.owner.lookup_type?(restriction)
      rescue Crystal::CodeError
        nil
      end
      case resolved
      when Nil
        "d argument restricted to a type parameter#{value}"
      when UnionType
        "c union restriction"
      when GenericType
        "d argument restricted to a generic or proc type#{value}"
      else
        if resolved.module?
          "a argument restricted to a module#{value}"
        elsif resolved.abstract? || !resolved.leaf?
          "a argument restricted to a base or abstract type#{value}"
        else
          "g argument restricted to one concrete type"
        end
      end
    end
  end
end
