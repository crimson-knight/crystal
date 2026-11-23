module Crystal::InferPersist
  # Writes every object reachable from a `Roots` to a snapshot file.
  #
  # Pass 1 walks the object graph from the roots and marks each object's
  # address (`AddressSet`). Pass 2 numbers the objects by address and writes,
  # in that order: the class number of each object, the text of each string,
  # the fields of each object other than hashes, then the entries of each
  # hash (a hash is filled last when read, after every key it holds is
  # complete, because a key's hash value can depend on its contents).
  #
  # A reference is written as a varint: 0 for `nil`, 1 to the number of
  # externals for an external (`EXTERNAL_NAMES`), and above that the object's
  # number. A union field that can hold a value (a number, a struct) starts
  # with a tag byte. Object ids stored as numbers (`DefInstanceKey`,
  # `Program#unions` and the hashes keyed by object id) are written as
  # references when they are the id of an object in the snapshot, so the
  # loading process gets the new object's id.
  class SnapshotWriter
    # Objects the loading process provides itself, by position.
    EXTERNAL_NAMES = {"compiler", "stdout", "stderr"}

    @addresses = AddressSet.new
    @list_of_unaligned = [] of Void*
    @unaligned_index_by_address = {} of UInt64 => Int32
    @stack = [] of Void*
    @class_index_by_type_id = {} of Int32 => Int32
    @hash_class_indexes = Set(Int32).new
    @dropped_type_ids = Set(Int32).new
    @list_of_class_indexes = [] of Int32
    getter object_count = 0
    # What the snapshot could not hold; the write fails when any is found.
    getter list_of_problems = Set(String).new
    getter string_count = 0

    def initialize(@roots : Roots, @compiler : Compiler)
      InferPersist.persistable_case(:register, 0, nil)
      {% for name in DROPPED %}
        @dropped_type_ids << {{name.id}}.crystal_instance_type_id
      {% end %}
    end

    # Writes the snapshot to *fd* after *header* (see `Snapshot`).
    def write(output : ByteOutput) : Nil
      mark(@roots)
      while pointer = @stack.pop?
        discover_object(pointer)
      end
      @addresses.freeze
      unless @list_of_problems.empty?
        raise Error.new("snapshot: can't persist #{@list_of_problems.join(", ")}")
      end

      each_object { |object| @list_of_class_indexes << class_index(object) }
      @object_count = @list_of_class_indexes.size
      output.write_varint(@object_count.to_u64)
      @list_of_class_indexes.each { |index| output.write_varint(index.to_u64) }

      @output = output
      position = 0
      each_object do |object|
        index = @list_of_class_indexes[position]
        position += 1
        if index == STRING_CLASS
          string = object.as(String)
          @string_count += 1
          output.write_varint(string.bytesize.to_u64)
          output.write_bytes(string.to_slice)
        end
      end
      position = 0
      each_object do |object|
        index = @list_of_class_indexes[position]
        position += 1
        next if index == STRING_CLASS || @hash_class_indexes.includes?(index)
        InferPersist.persistable_case(:write, index, object)
      end
      position = 0
      each_object do |object|
        index = @list_of_class_indexes[position]
        position += 1
        next unless @hash_class_indexes.includes?(index)
        InferPersist.persistable_case(:write, index, object)
      end
      write_ref(@roots)
      output.flush
      unless @list_of_problems.empty?
        raise Error.new("snapshot: can't persist #{@list_of_problems.join(", ")}")
      end
    end

    protected def register_class(type_id : Int32, index : Int32, hash : Bool) : Nil
      @class_index_by_type_id[type_id] = index
      @hash_class_indexes << index if hash
    end

    private def output : ByteOutput
      @output || raise Error.new("BUG: snapshot output not set")
    end

    private def each_object(& : Void* ->) : Nil
      @addresses.each { |address| yield Pointer(Void).new(address) }
      @list_of_unaligned.each { |pointer| yield pointer }
    end

    # The class number of the object at *pointer*, from its type id (the
    # first word of every object); -1 for a class a snapshot can not hold.
    private def class_index(pointer : Void*) : Int32
      type_id = pointer.as(Int32*).value
      return STRING_CLASS if type_id == String.crystal_instance_type_id
      @class_index_by_type_id[type_id]? || -1
    end

    private def external_code(object : Compiler) : Int32?
      1
    end

    private def external_code(object : IO) : Int32?
      if object.same?(STDOUT)
        2
      elsif object.same?(STDERR)
        3
      end
    end

    private def external_code(object) : Int32?
      nil
    end

    # Marks *object* for writing; returns `false` for an external or a
    # dropped object, which the snapshot does not hold.
    private def mark(object) : Bool
      return false if external_code(object)
      return false if @dropped_type_ids.includes?(object.crystal_type_id)
      if class_index(Pointer(Void).new(object.object_id)) < 0
        @list_of_problems << "an object of #{object.class}" unless @list_of_problems.size > 50
        return false
      end
      address = object.object_id
      if AddressSet.aligned?(address)
        return true unless @addresses.add?(address)
      else
        return true if @unaligned_index_by_address.has_key?(address)
        @unaligned_index_by_address[address] = @list_of_unaligned.size
        @list_of_unaligned << Pointer(Void).new(address)
      end
      @stack << Pointer(Void).new(address) unless object.is_a?(String)
      true
    end

    # The number of a marked object (from 0), or `nil`.
    private def number_of(address : UInt64) : Int32?
      if AddressSet.aligned?(address)
        @addresses.rank?(address)
      elsif index = @unaligned_index_by_address[address]?
        @addresses.size + index
      end
    end

    private def discover_object(pointer : Void*) : Nil
      InferPersist.persistable_case(:discover, class_index(pointer), pointer)
    end

    # Pass 1 ------------------------------------------------------------

    private def discover_fields(object : Array) : Nil
      object.each { |element| discover_value(element) }
    end

    private def discover_fields(object : Hash) : Nil
      object.each do |key, value|
        discover_value(key)
        discover_value(value)
      end
    end

    private def discover_fields(object : MetaVars) : Nil
      object.each do |(name, var)|
        mark(name)
        mark(var)
      end
    end

    private def discover_fields(object : StringPool) : Nil
    end

    private def discover_fields(object : VirtualFile) : Nil
      mark(object.macro)
      discover_value(object.expanded_location)
    end

    private def discover_fields(object) : Nil
      discover_ivars(object)
    end

    private def discover_ivars(object : T) : Nil forall T
      {% for ivar in T.instance_vars %}
        discover_value(object.@{{ivar.name}})
      {% end %}
    end

    private def discover_value(value : T) : Nil forall T
      {% if T.union? %}
        case value
        {% for member in T.union_types %}
        when {{member}}
          discover_value(value)
        {% end %}
        end
      {% elsif T == Nil || T == Bool || T == Char || T == Symbol || T < Number || T < Enum %}
        # nothing to reach
      {% elsif T < Reference || T.module? %}
        mark(value)
      {% elsif T < Tuple %}
        {% for index in 0...T.type_vars.size %}
          discover_value(value[{{index}}])
        {% end %}
      {% elsif T < NamedTuple %}
        {% for key in T.keys %}
          discover_value(value[{{key.symbolize}}])
        {% end %}
      {% elsif T < Proc || T.stringify.starts_with?("Pointer(") || T.stringify.starts_with?("LLVM::") || T.stringify.starts_with?("LibLLVM::") || T.stringify.starts_with?("Atomic(") %}
        # an opaque value: checked when written
      {% elsif T < Struct %}
        {% for ivar in T.instance_vars %}
          discover_value(value.@{{ivar.name}})
        {% end %}
      {% else %}
        {% raise "InferPersist: no way to walk #{T}" %}
      {% end %}
    end

    # Pass 2 ------------------------------------------------------------

    private def write_ref(value) : Nil
      unless value
        output.write_byte(0_u8)
        return
      end
      if code = external_code(value)
        output.write_varint(code.to_u64)
        return
      end
      if @dropped_type_ids.includes?(value.crystal_type_id)
        output.write_byte(0_u8)
        return
      end
      number = number_of(value.object_id) || raise Error.new("BUG: snapshot: unmarked #{value.class}")
      output.write_varint((number + EXTERNAL_NAMES.size + 1).to_u64)
    end

    # An object id kept as a number: written as a reference when it is the
    # id of an object in the snapshot, else as 0 and the raw number.
    private def write_object_id(value : UInt64) : Nil
      if number = number_of(value)
        output.write_varint((number + EXTERNAL_NAMES.size + 1).to_u64)
      else
        output.write_byte(0_u8)
        output.write_u64(value)
      end
    end

    private def write_fields(object : Array(T)) : Nil forall T
      output.write_varint(object.size.to_u64)
      object.each { |element| write_field(element, T, {{T == UInt64}}) }
    end

    private def write_fields(object : Hash(K, V)) : Nil forall K, V
      output.write_byte(object.compare_by_identity? ? 1_u8 : 0_u8)
      output.write_varint(object.size.to_u64)
      object.each do |key, value|
        write_field(key, K, true)
        write_field(value, V, false)
      end
    end

    private def write_fields(object : MetaVars) : Nil
      output.write_varint(object.size.to_u64)
      object.each do |(name, var)|
        write_ref(name)
        write_ref(var)
      end
    end

    private def write_fields(object : StringPool) : Nil
    end

    private def write_fields(object : VirtualFile) : Nil
      write_ref(object.macro)
      source = object.source
      output.write_varint(source.bytesize.to_u64)
      output.write_bytes(source.to_slice)
      write_field(object.expanded_location, typeof(object.expanded_location), false)
      output.write_varint(object.file_index.to_u64)
    end

    private def write_fields(object) : Nil
      write_ivars(object)
    end

    private def write_ivars(object : T) : Nil forall T
      {% for ivar in T.instance_vars %}
        write_field(object.@{{ivar.name}}, typeof(object.@{{ivar.name}}), {{ivar.name.ends_with?("object_id")}})
      {% end %}
    end

    # Writes *value*, whose declared type is *type*. *object_id* marks a
    # number that may be an object id (see `#write_object_id`).
    private def write_field(value, type : T.class, object_id : Bool) : Nil forall T
      {% if T.union? && T.union_types.any? { |member| !((member < Reference || member.module?)) && member != Nil } %}
        case value
        when Nil
          output.write_byte(0_u8)
        when Reference
          output.write_byte(1_u8)
          write_ref(value)
        {% for member, index in T.union_types.reject { |member| (member < Reference || member.module?) || member == Nil } %}
        when {{member}}
          output.write_byte({{index + 2}}_u8)
          write_value(value, object_id)
        {% end %}
        end
      {% elsif T == Nil %}
        # nothing
      {% elsif T < Reference || T.union? || T.module? %}
        write_ref(value)
      {% else %}
        write_value(value.as(T), object_id)
      {% end %}
    end

    private def write_value(value : T, object_id : Bool) : Nil forall T
      {% if T == Bool %}
        output.write_byte(value ? 1_u8 : 0_u8)
      {% elsif T == Char %}
        output.write_varint(value.ord.to_u64)
      {% elsif T == Symbol %}
        output.write_svarint(value.unsafe_as(Int32).to_i64)
      {% elsif T < Enum %}
        # The raw bits of its storage: the base type can be any integer type.
        copy = value
        raw = case sizeof(T)
              when 1 then pointerof(copy).as(UInt8*).value.to_u64
              when 2 then pointerof(copy).as(UInt16*).value.to_u64
              when 4 then pointerof(copy).as(UInt32*).value.to_u64
              else        pointerof(copy).as(UInt64*).value
              end
        output.write_varint(raw)
      {% elsif T == Int128 || T == UInt128 %}
        output.write_u64(value.to_u64!)
        output.write_u64((value >> 64).to_u64!)
      {% elsif T == UInt64 %}
        if object_id
          write_object_id(value)
        else
          output.write_varint(value)
        end
      {% elsif T == Int8 || T == Int16 || T == Int32 || T == Int64 %}
        output.write_svarint(value.to_i64)
      {% elsif T == UInt8 || T == UInt16 || T == UInt32 %}
        output.write_varint(value.to_u64)
      {% elsif T == Float64 %}
        output.write_u64(value.unsafe_as(UInt64))
      {% elsif T == Float32 %}
        output.write_varint(value.unsafe_as(UInt32).to_u64)
      {% elsif T < Tuple %}
        {% for index in 0...T.type_vars.size %}
          write_field(value[{{index}}], {{T.type_vars[index]}}, object_id)
        {% end %}
      {% elsif T < NamedTuple %}
        {% for key in T.keys %}
          write_field(value[{{key.symbolize}}], {{T[key]}}, object_id)
        {% end %}
      {% elsif T < Proc || T.stringify.starts_with?("Pointer(") || T.stringify.starts_with?("LLVM::") || T.stringify.starts_with?("LibLLVM::") || T.stringify.starts_with?("Atomic(") %}
        {% if T < Proc %}
          @list_of_problems << "a proc (#{ {{T.stringify}} })" unless @list_of_problems.size > 50
        {% end %}
        # Handles to LLVM or memory: never valid in another process; read as zero.
      {% elsif T < Struct %}
        {% for ivar in T.instance_vars %}
          write_field(value.@{{ivar.name}}, typeof(value.@{{ivar.name}}), {{ivar.name.ends_with?("object_id")}})
        {% end %}
      {% else %}
        {% raise "InferPersist: no way to write #{T}" %}
      {% end %}
    end
  end
end
