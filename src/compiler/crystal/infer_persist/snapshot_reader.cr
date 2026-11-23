module Crystal::InferPersist
  # Reads what `SnapshotWriter` wrote and returns the `Roots`.
  #
  # Every object is allocated first, from the class table, so that a field
  # can refer to an object whose own fields come later. Strings come with
  # their text before that. Fields are then filled in file order: every
  # object other than a hash, then every hash.
  class SnapshotReader
    # Every object by number, in memory from `malloc`: it is needed only
    # while the snapshot is read, and a collector heap keeps the pages it
    # grew to (8 bytes per object, about 400 MB for Grant300). Collection is
    # off while it is in use (see `Session#read_snapshot`), so the objects it
    # alone points at stay.
    @objects = Pointer(Void*).null
    @object_count = 0
    @class_index_by_type_id = {} of Int32 => Int32
    @hash_class_indexes = Set(Int32).new
    # Whether class number *n* is a hash, by number.
    @hash_class = Slice(Bool).empty

    def initialize(@input : ByteInput, @list_of_externals : Array(Void*))
      InferPersist.persistable_case(:register, 0, nil)
      @hash_class = Slice(Bool).new((@hash_class_indexes.max? || 0) + 1) { |index| @hash_class_indexes.includes?(index) }
    end

    # The number of objects the last `#read` made.
    getter object_count : Int32

    def read : Roots
      count = @input.read_varint.to_i32
      @object_count = count
      class_indexes = Pointer(Int32).new(LibC.malloc(count.to_u64 * 4).address)
      @objects = Pointer(Void*).new(LibC.malloc(count.to_u64 * 8).address)
      raise Error.new("snapshot: out of memory for #{count} objects") if class_indexes.null? || @objects.null?
      begin
        count.times { |position| class_indexes[position] = @input.read_varint.to_i32 }
        # The strings section holds the text of every string, in object order.
        count.times do |position|
          if class_indexes[position] == STRING_CLASS
            bytesize = @input.read_varint.to_i32
            @objects[position] = @input.read_string(bytesize).as(Void*)
          end
        end
        count.times do |position|
          index = class_indexes[position]
          @objects[position] = allocate_object(index) unless index == STRING_CLASS
        end

        count.times do |position|
          index = class_indexes[position]
          next if index == STRING_CLASS || hash_class?(index)
          fill_object(index, @objects[position])
        end
        count.times do |position|
          index = class_indexes[position]
          next unless hash_class?(index)
          fill_object(index, @objects[position])
        end
        read_ref.as(Roots)
      ensure
        LibC.free(class_indexes.as(Void*))
        LibC.free(@objects.as(Void*))
        @objects = Pointer(Void*).null
      end
    end

    private def hash_class?(index : Int32) : Bool
      index < @hash_class.size && @hash_class.unsafe_fetch(index)
    end

    protected def register_class(type_id : Int32, index : Int32, hash : Bool) : Nil
      @class_index_by_type_id[type_id] = index
      @hash_class_indexes << index if hash
    end

    private def allocate_object(index : Int32) : Void*
      InferPersist.persistable_case(:allocate, index, nil)
    end

    private def fill_object(index : Int32, object : Void*) : Nil
      InferPersist.persistable_case(:fill, index, object)
    end

    # The object a reference names, or a null pointer for `nil`.
    private def read_ref : Void*
      code = @input.read_varint
      return Pointer(Void).null if code == 0
      if code <= @list_of_externals.size
        return @list_of_externals[code - 1]
      end
      @objects[object_number(code)]
    end

    # The object a reference names, as *type*. A pointer can be cast to
    # classes but not to a module, so a module in *type* stands for the
    # classes that include it.
    private def read_ref_as(type : T.class) : T forall T
      {% begin %}
        {% classes = [] of TypeNode %}
        {% for member in T.union_types %}
          {% if member.module? %}
            {% for includer in member.includers %}
              {% if includer.class? %}
                {% classes << includer %}
                {% for sub in includer.all_subclasses %}{% classes << sub %}{% end %}
              {% end %}
            {% end %}
          {% else %}
            {% classes << member %}
          {% end %}
        {% end %}
        read_ref.as(::Union({{classes.uniq.splat}})).as(T)
      {% end %}
    end

    private def object_number(code : UInt64) : Int32
      number = code - @list_of_externals.size - 1
      raise Error.new("snapshot: reference to object #{number} of #{@object_count}") unless number < @object_count.to_u64
      number.to_i32
    end

    private def read_object_id : UInt64
      code = @input.read_varint
      return @input.read_u64 if code == 0
      if code <= @list_of_externals.size
        return @list_of_externals[code - 1].address
      end
      @objects[object_number(code)].address
    end

    private def fill_fields(object : Array(T)) : Nil forall T
      size = @input.read_varint.to_i32
      object.clear
      size.times { object << read_field(T, {{T == UInt64}}) }
    end

    private def fill_fields(object : Hash(K, V)) : Nil forall K, V
      object.compare_by_identity if @input.read_byte == 1
      size = @input.read_varint.to_i32
      size.times do
        key = read_field(K, true)
        value = read_field(V, false)
        object[key] = value
      end
    end

    private def fill_fields(object : MetaVars) : Nil
      size = @input.read_varint.to_i32
      size.times do
        name = read_ref.as(String)
        var = read_ref.as(MetaVar)
        object[name] = var
      end
    end

    private def fill_fields(object : StringPool) : Nil
    end

    private def fill_fields(object : VirtualFile) : Nil
      pointerof(object.@macro).value = read_ref.as(Macro)
      bytesize = @input.read_varint.to_i32
      pointerof(object.@source).value = @input.read_string(bytesize)
      pointerof(object.@stored_source).value = nil
      pointerof(object.@source_store).value = nil
      pointerof(object.@expanded_location).value = read_field(Location?, false)
      pointerof(object.@file_index).value = @input.read_varint.to_u32
    end

    private def fill_fields(object) : Nil
      fill_ivars(object)
    end

    private def fill_ivars(object : T) : Nil forall T
      {% for ivar in T.instance_vars %}
        pointerof(object.@{{ivar.name}}).value = read_field(typeof(object.@{{ivar.name}}), {{ivar.name.ends_with?("object_id")}})
      {% end %}
    end

    private def read_field(type : T.class, object_id : Bool) : T forall T
      {% if T.union? && T.union_types.any? { |member| !((member < Reference || member.module?)) && member != Nil } %}
        case @input.read_byte
        when 0
          {% if T.nilable? %}
            nil
          {% else %}
            raise Error.new("snapshot: nil in a field of #{T}")
          {% end %}
        when 1
          {% if T.union_types.any? { |member| (member < Reference || member.module?) } %}
            read_ref_as(::Union({{T.union_types.select { |member| (member < Reference || member.module?) }.splat}}))
          {% else %}
            raise Error.new("snapshot: a reference in a field of #{T}")
          {% end %}
        {% for member, index in T.union_types.reject { |member| (member < Reference || member.module?) || member == Nil } %}
        when {{index + 2}}
          read_value({{member}}, object_id).as(T)
        {% end %}
        else
          raise Error.new("snapshot: bad tag in a field of #{T}")
        end
      {% elsif T == Nil %}
        nil
      {% elsif T < Reference || T.union? || T.module? %}
        read_ref_as(T)
      {% else %}
        read_value(T, object_id)
      {% end %}
    end

    private def read_value(type : T.class, object_id : Bool) : T forall T
      {% if T == Bool %}
        @input.read_byte == 1
      {% elsif T == Char %}
        @input.read_varint.to_i32!.unsafe_chr
      {% elsif T == Symbol %}
        @input.read_svarint.to_i32!.unsafe_as(Symbol)
      {% elsif T < Enum %}
        # The raw bits of the enum's storage (see `SnapshotWriter#write_value`).
        raw = @input.read_varint
        value = uninitialized T
        case sizeof(T)
        when 1 then pointerof(value).as(UInt8*).value = raw.to_u8!
        when 2 then pointerof(value).as(UInt16*).value = raw.to_u16!
        when 4 then pointerof(value).as(UInt32*).value = raw.to_u32!
        else        pointerof(value).as(UInt64*).value = raw
        end
        value
      {% elsif T == Int128 || T == UInt128 %}
        low = @input.read_u64
        high = @input.read_u64
        T.new!(high) << 64 | T.new!(low)
      {% elsif T == UInt64 %}
        object_id ? read_object_id : @input.read_varint
      {% elsif T == Int8 || T == Int16 || T == Int32 || T == Int64 %}
        T.new!(@input.read_svarint)
      {% elsif T == UInt8 || T == UInt16 || T == UInt32 %}
        T.new!(@input.read_varint)
      {% elsif T == Float64 %}
        @input.read_u64.unsafe_as(Float64)
      {% elsif T == Float32 %}
        @input.read_varint.to_u32!.unsafe_as(Float32)
      {% elsif T < Tuple %}
        {
          {% for index in 0...T.type_vars.size %}
            read_field({{T.type_vars[index]}}, object_id),
          {% end %}
        }
      {% elsif T < NamedTuple %}
        {
          {% for key in T.keys %}
            {{key.stringify}}: read_field({{T[key]}}, object_id),
          {% end %}
        }
      {% elsif T < Proc || T.stringify.starts_with?("Pointer(") || T.stringify.starts_with?("LLVM::") || T.stringify.starts_with?("LibLLVM::") || T.stringify.starts_with?("Atomic(") %}
        value = uninitialized T
        Intrinsics.memset(pointerof(value).as(Void*), 0_u8, sizeof(T), false)
        value
      {% elsif T < Struct %}
        value = uninitialized T
        {% for ivar in T.instance_vars %}
          pointerof(value.@{{ivar.name}}).value = read_field(typeof(value.@{{ivar.name}}), {{ivar.name.ends_with?("object_id")}})
        {% end %}
        value
      {% else %}
        {% raise "InferPersist: no way to read #{T}" %}
      {% end %}
    end
  end
end
