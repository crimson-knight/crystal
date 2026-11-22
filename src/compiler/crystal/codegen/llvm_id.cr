require "../types"

module Crystal
  # This class assigns a pair of IDs `{min, max}` to every type in the program.
  #
  # For a regular class or struct (not metaclass), this pair
  # of ids is such that `min` is the minimum ID of its subtypes,
  # and `max` is 1 + the maximum ID of its subtypes. In this way
  # we can quickly know if a type implements another type: its ID
  # must be between {min, max} of such type.
  #
  # For example, ids could be assigned like this:
  #
  # - Foo: {1, 8}
  #   - Bar: {1, 2}
  #     - Baz: {1, 1}
  #   - Qux: {3, 3}
  #   - Gen(T): {5, 7}
  #     - Gen(Int32): {4, 4}
  #     - Gen2(T): {5, 6}
  #       - Gen2(Char): {5, 5}
  #
  # Note that generic instances and generic subtypes are considered
  # as subtypes of a generic type.
  #
  # For metaclasses IDs are assigned sequentially as they are needed,
  # because dispatch on metaclasses is less often.
  #
  # An incremental build passes the ids of the build before it
  # (*type_ids_by_stable_key*, see `StableNumbering`). Then a type that had
  # an id keeps it, and a type that is new gets an id after all the kept
  # ones, so adding a type changes the id of no other type. The ids of a
  # type and its subtypes are then no longer one range: `#id_ranges` gives
  # the ranges they do form, and that is what a subtype check tests.
  class LLVMId
    getter id_to_metaclass : Hash(Int32, Int32)

    # Kept ids are given up, and every type is numbered again, once the
    # largest kept id is more than this many times the number of kept ids
    # (types that went away leave their ids unused).
    STABLE_ID_SPREAD_LIMIT = 2

    # The ids of this build by stable key: what the next build keeps.
    getter type_ids_in_use_by_stable_key = {} of String => Int32

    @type_ids_by_stable_key : Hash(String, Int32)?
    @set_of_ids_in_use = Set(Int32).new
    @stable_key_turns = Hash(String, Int32).new(0)

    def initialize(program, type_ids_by_stable_key : Hash(String, Int32)? = nil)
      @ids = {} of Type => {Int32, Int32}
      @id_to_metaclass = {} of Int32 => Int32
      @next_id = 0
      if type_ids_by_stable_key
        largest_kept_id = type_ids_by_stable_key.each_value.max? || 0
        if largest_kept_id > STABLE_ID_SPREAD_LIMIT * type_ids_by_stable_key.size + 1024
          type_ids_by_stable_key = {} of String => Int32
          largest_kept_id = 0
        end
        @type_ids_by_stable_key = type_ids_by_stable_key
        # New types are numbered after the kept ids.
        @next_id = largest_kept_id
      end
      assign_id(program.object)
      assign_id_to_metaclass(program.object)
    end

    # Whether ids are kept from the build before (see the class comment).
    def stable? : Bool
      !@type_ids_by_stable_key.nil?
    end

    # One more than the largest id given out so far.
    def id_limit : Int32
      @next_id + 1
    end

    # Yields every type that has an id, with its id.
    def each_type_with_id(& : Type, Int32 ->) : Nil
      @ids.each { |type, (_, id)| yield type, id }
    end

    # The sorted ranges (both ends included) that hold the ids of *type* and
    # of all its subtypes, and no id of any other type.
    def id_ranges(type) : Array({Int32, Int32})
      unless stable?
        # Subtypes were numbered right before their supertype: one range.
        min_max = min_max_type_id(type)
        return min_max ? [min_max] : [] of {Int32, Int32}
      end

      list_of_ids = [] of Int32
      collect_subtype_ids(type, list_of_ids)
      list_of_ids.sort!
      list_of_ranges = [] of {Int32, Int32}
      list_of_ids.each do |id|
        last_range = list_of_ranges.last?
        if last_range && id <= last_range[1] + 1
          list_of_ranges[-1] = {last_range[0], id}
        else
          list_of_ranges << {id, id}
        end
      end
      list_of_ranges
    end

    private def collect_subtype_ids(type, list_of_ids : Array(Int32)) : Nil
      return if type.is_a?(MetaclassType)

      list_of_ids << type_id(type)
      subtypes_of(type).each do |subtype|
        collect_subtype_ids(subtype, list_of_ids)
      end
    end

    # The subtypes `#assign_id` numbers before *type*.
    private def subtypes_of(type : NonGenericClassType)
      subclasses_of(type)
    end

    private def subtypes_of(type : GenericClassType)
      subtypes = type.instantiated_types.reject(&.unbound?)
      subtypes.concat(subclasses_of(type))
      subtypes
    end

    private def subtypes_of(type : GenericClassInstanceType)
      type.subclasses
    end

    private def subtypes_of(type)
      [] of Type
    end

    # The name a type keeps its id under from one build to the next.
    def self.stable_key(type : Type) : String
      type.llvm_name
    end

    # The id *type* had in the build before, or a new one.
    private def new_id(type) : Int32
      type_ids_by_stable_key = @type_ids_by_stable_key
      return next_id unless type_ids_by_stable_key

      stable_key = LLVMId.stable_key(type)
      # Two types can print the same (private types of two files): the
      # later one is told apart by its turn.
      turn = (@stable_key_turns[stable_key] += 1)
      stable_key = "#{stable_key}\##{turn}" if turn > 1
      kept_id = type_ids_by_stable_key[stable_key]?
      # A kept id is only good while no other type of this build has it.
      id = kept_id && kept_id > 0 && @set_of_ids_in_use.add?(kept_id) ? kept_id : next_unused_id
      @type_ids_in_use_by_stable_key[stable_key] = id
      id
    end

    private def next_unused_id : Int32
      loop do
        id = next_id
        return id if @set_of_ids_in_use.add?(id)
      end
    end

    def type_id(type : TypeDefType)
      type_id(type.typedef)
    end

    def type_id(type : VirtualType | VirtualMetaclassType)
      raise "BUG: called type_id for #{type} (#{type.class})"
    end

    def type_id(type)
      min_max = @ids[type]?
      if min_max
        min_max[1]
      else
        id = new_id(type)
        put_id type, id, id
        id
      end
    end

    def min_max_type_id(type)
      @ids[type]?
    end

    private def assign_id(type)
      min_max_type_id = min_max_type_id(type)
      if min_max_type_id
        min_max_type_id[1]
      else
        assign_id_impl(type)
      end
    end

    private def assign_id_impl(type : NonGenericClassType)
      assign_id_from_subtypes type, subclasses_of(type)
    end

    private def assign_id_impl(type : MetaclassType)
      # Skip for now
      0
    end

    private def assign_id_impl(type : GenericClassType)
      subtypes = type.instantiated_types.reject(&.unbound?)
      subtypes.concat(subclasses_of(type))
      assign_id_from_subtypes type, subtypes
    end

    private def assign_id_impl(type : PrimitiveType)
      id = new_id(type)
      put_id type, id, id
      id
    end

    private def assign_id_impl(type : GenericClassInstanceType)
      assign_id_from_subtypes type, type.subclasses
    end

    private def assign_id_impl(type : NilType)
      put_id type, 0, 0
      0
    end

    private def assign_id_impl(type)
      raise "BUG: unhandled type in assign id: #{type}"
    end

    private def assign_id_from_subtypes(type, subtypes)
      if subtypes.empty?
        id = new_id(type)
        put_id type, id, id
        id
      else
        min_id = uninitialized Int32
        first = true
        subtypes.each do |subtype|
          sub_id = assign_id(subtype)
          if first && sub_id != 0
            min_id = sub_id
            first = false
          end
        end
        id = new_id(type)
        put_id type, min_id, id
        min_id
      end
    end

    private def assign_id_to_metaclass(type : NonGenericClassType)
      assign_id_to_metaclass(type, type.metaclass)
      type.subclasses.each do |subclass|
        assign_id_to_metaclass(subclass)
      end
    end

    private def assign_id_to_metaclass(type : GenericClassInstanceType | PrimitiveType)
      assign_id_to_metaclass(type, type.metaclass)
      type.subclasses.each do |subclass|
        assign_id_to_metaclass(subclass)
      end
    end

    private def assign_id_to_metaclass(type : GenericClassType)
      assign_id_to_metaclass(type, type.metaclass)
      type.each_instantiated_type do |instance|
        assign_id_to_metaclass(instance) unless instance.unbound?
      end
      type.subclasses.each do |subclass|
        assign_id_to_metaclass(subclass)
      end
    end

    private def assign_id_to_metaclass(type : MetaclassType)
      # Nothing
    end

    private def assign_id_to_metaclass(type)
      raise "BUG: unhandled type in assign id to metaclass: #{type}"
    end

    private def assign_id_to_metaclass(type, metaclass)
      @id_to_metaclass[type_id(type)] = type_id(metaclass)
    end

    private def put_id(type, min, max)
      @ids[type] = {min, max}
    end

    private def next_id
      @next_id += 1
    end

    private def subclasses_of(type)
      type.subclasses.reject(GenericInstanceType)
    end
  end
end
