require "json"
require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Crystal
  # Skips LLVM IR generation, in an incremental build, for the modules whose
  # inputs are the same as in the build before.
  #
  # Every function that is generated gets a *key*: a hash of everything its
  # code is made from (see `KeyWalker`), and a *trace*: the requests its
  # generation made to the rest of the program (functions of other modules,
  # definitions in the main module) and the state it found constants and
  # class variables in. Both are kept in the `Manifest` of the cache
  # directory, with the hash of each module's bitcode.
  #
  # In the next build a module whose object file is still the one built from
  # that bitcode starts as a candidate. Each function that code generation
  # asks the module for is compared with the one the manifest has at that
  # position: same name, same key. When it matches, no code is generated:
  # the function is declared and its trace is replayed, so the rest of the
  # program sees the requests it would have seen. When anything differs the
  # module is generated after all, starting with the functions that were
  # matched so far. A module that matched to the end keeps its cached
  # bitcode hash, and with it its object file.
  #
  # Whether an object file is reused is still decided by the hash of the
  # bitcode (`CompilationUnit`). The key only decides whether the bitcode is
  # made again, and it is built so that an input it does not know makes the
  # function unkeyable (generated every time) rather than reused.
  module IrSkip
    FILENAME = "ir_skip_manifest.bin"
    MAGIC    = "CRIRSKP1"

    # A 128-bit hash, as two words.
    record Digest, first : UInt64, second : UInt64 do
      def to_s(io : IO) : Nil
        io << first.to_s(16, precision: 16) << second.to_s(16, precision: 16)
      end
    end

    # Two running hashes of a stream of words and strings. Strings are hashed
    # byte by byte: `String#hash` differs from one process to the next.
    struct Hasher
      getter first : UInt64 = 0xcbf29ce484222325_u64
      getter second : UInt64 = 0x84222325cbf29ce4_u64

      def mix(value : UInt64) : Nil
        first = (@first ^ value) &* 0x9e3779b97f4a7c15_u64
        @first = first ^ (first >> 32)
        second = (@second &+ value &+ 0x632be59bd9b4e019_u64) &* 0xd6e8feb86659fd93_u64
        @second = second ^ (second >> 29)
      end

      def mix(value : Int) : Nil
        mix(value.to_u64!)
      end

      def mix(value : Bool) : Nil
        mix(value ? 1_u64 : 2_u64)
      end

      def mix(value : Nil) : Nil
        mix(3_u64)
      end

      def mix(value : String) : Nil
        digest = Hasher.digest_of(value)
        mix(digest.first)
        mix(digest.second)
      end

      def mix(value : Digest) : Nil
        mix(value.first)
        mix(value.second)
      end

      def digest : Digest
        Digest.new(@first, @second)
      end

      def self.digest_of(value : String) : Digest
        first = 0xcbf29ce484222325_u64
        second = 0x9ae16a3b2f90404f_u64
        value.to_slice.each do |byte|
          first = (first ^ byte) &* 0x100000001b3_u64
          second = (second &+ byte) &* 0xff51afd7ed558ccd_u64
          second ^= second >> 31
        end
        Digest.new(first ^ value.bytesize.to_u64, second)
      end
    end

    # One step of a function's trace.
    enum TraceKind : UInt8
      # Asks for the function of a callee (index into `Walk#list_of_callees`).
      Fun
      # Defines the type id of a type in the main module (a type reference).
      TypeId
      # Defines the subtype check of a type in the main module.
      Match
      # Reads a constant (index into `Walk#list_of_consts`); *detail* is 1 when the
      # constant needed its initialized flag at that moment.
      ConstPointer
      # Reads a class variable (index into `Walk#list_of_class_vars`); *detail* holds the
      # state it was in.
      ClassVarPointer
      Metaclass
      CheckProcIsNotClosure
      ClassNameMap
      CMalloc
      CRealloc
      # Generates the function of a proc literal that captures nothing
      # (index into `Walk#list_of_proc_literals`, *detail* a type reference to the self
      # type, *text* the function's name).
      ProcLiteral
    end

    # A type is referred to by its index in `Walk#list_of_types`, or, for a type the
    # walk did not list, by its LLVM name (*subject_index* is -1 and *text* the name).
    record TraceEntry, kind : TraceKind, subject_index : Int32, detail : Int32 = 0, text : String? = nil

    # What the manifest keeps of one generated function.
    class RecordedFun
      getter name : String
      getter code_key : Digest
      getter line_key : Digest
      # Set when the function was generated to the end: its trace is complete.
      property? replayable : Bool
      getter list_of_trace_entries : Array(TraceEntry)

      def initialize(@name, @code_key, @line_key, @replayable, @list_of_trace_entries)
      end
    end

    # What the manifest keeps of one module (a type's module or one of its
    # segments): its functions in the order they were generated, and the
    # hash of each part of its bitcode.
    class RecordedUnit
      getter name : String
      getter list_of_funs : Array(RecordedFun)
      property list_of_part_hashes : Array(String)
      getter list_of_part_fun_counts : Array(Int32)
      getter instruction_count : Int64

      # Whether some of the module's functions were generated after the
      # moment they were asked for (see `CodeGenVisitor#invalidate_ir_skip_plan`).
      # Its bitcode is a correct build of these functions, but another build
      # of them can order the module's declarations differently.
      getter? late_generated : Bool

      # Set by the compiler: the object file in the cache was built from
      # this bitcode.
      property? object_is_current = false

      def initialize(@name, @list_of_funs, @list_of_part_hashes, @list_of_part_fun_counts,
                     @instruction_count, @late_generated)
      end

      def replayable? : Bool
        @list_of_funs.all?(&.replayable?)
      end
    end

    # The file that carries keys, traces and bitcode hashes from one build
    # to the next. It is binary: a large program has several hundred
    # thousand trace entries, read on every build.
    class Manifest
      getter salt : String
      getter units_by_name = {} of String => RecordedUnit

      def initialize(@salt)
      end

      # The manifest in *cache_dir*, when it was made with *salt* (with any
      # salt when *salt* is `nil`).
      def self.load?(cache_dir : String, salt : String?) : Manifest?
        path = File.join(cache_dir, FILENAME)
        return nil unless File.file?(path)

        io = IO::Memory.new(File.read(path).to_slice, writable: false)
        return nil unless read_string(io) == MAGIC
        recorded_salt = read_string(io)
        return nil unless salt.nil? || recorded_salt == salt

        manifest = new(recorded_salt)
        read_int(io).times do
          unit = read_unit(io)
          manifest.units_by_name[unit.name] = unit
        end
        manifest
      rescue IO::Error | ArgumentError
        # A manifest that cannot be read only costs this build its skips.
        nil
      end

      # Writes the manifest in one rename, so a stopped build leaves the old
      # one or the new one.
      def save(cache_dir : String) : Nil
        path = File.join(cache_dir, FILENAME)
        pending_path = "#{path}.#{Process.pid}.tmp"
        File.open(pending_path, "w") do |file|
          write_string(file, MAGIC)
          write_string(file, @salt)
          write_int(file, @units_by_name.size)
          @units_by_name.each_value { |unit| write_unit(file, unit) }
        end
        File.rename(pending_path, path)
      rescue IO::Error
        pending_path.try { |pending| File.delete?(pending) }
      end

      private def write_unit(io : IO, unit : RecordedUnit) : Nil
        write_string(io, unit.name)
        io.write_byte(unit.late_generated? ? 1_u8 : 0_u8)
        io.write_bytes(unit.instruction_count, IO::ByteFormat::LittleEndian)
        write_int(io, unit.list_of_part_hashes.size)
        unit.list_of_part_hashes.each { |part_hash| write_string(io, part_hash) }
        write_int(io, unit.list_of_part_fun_counts.size)
        unit.list_of_part_fun_counts.each { |count| write_int(io, count) }
        write_int(io, unit.list_of_funs.size)
        unit.list_of_funs.each do |recorded_fun|
          write_string(io, recorded_fun.name)
          {recorded_fun.code_key, recorded_fun.line_key}.each do |digest|
            io.write_bytes(digest.first, IO::ByteFormat::LittleEndian)
            io.write_bytes(digest.second, IO::ByteFormat::LittleEndian)
          end
          io.write_byte(recorded_fun.replayable? ? 1_u8 : 0_u8)
          write_int(io, recorded_fun.list_of_trace_entries.size)
          recorded_fun.list_of_trace_entries.each do |entry|
            io.write_byte(entry.kind.value)
            write_int(io, entry.subject_index)
            write_int(io, entry.detail)
            if text = entry.text
              io.write_byte(1_u8)
              write_string(io, text)
            else
              io.write_byte(0_u8)
            end
          end
        end
      end

      private def self.read_unit(io : IO) : RecordedUnit
        name = read_string(io)
        late_generated = read_byte(io) == 1_u8
        instruction_count = io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
        list_of_part_hashes = Array(String).new(read_int(io)) { read_string(io) }
        list_of_part_fun_counts = Array(Int32).new(read_int(io)) { read_int(io) }
        list_of_funs = Array(RecordedFun).new(read_int(io)) do
          fun_name = read_string(io)
          code_key = read_digest(io)
          line_key = read_digest(io)
          replayable = read_byte(io) == 1_u8
          list_of_trace_entries = Array(TraceEntry).new(read_int(io)) do
            kind = TraceKind.from_value(read_byte(io))
            subject_index = read_int(io)
            detail = read_int(io)
            text = read_byte(io) == 1_u8 ? read_string(io) : nil
            TraceEntry.new(kind, subject_index, detail, text)
          end
          RecordedFun.new(fun_name, code_key, line_key, replayable, list_of_trace_entries)
        end
        RecordedUnit.new(name, list_of_funs, list_of_part_hashes, list_of_part_fun_counts, instruction_count, late_generated)
      end

      private def self.read_digest(io : IO) : Digest
        first = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        Digest.new(first, io.read_bytes(UInt64, IO::ByteFormat::LittleEndian))
      end

      private def self.read_byte(io : IO) : UInt8
        io.read_byte || raise IO::EOFError.new
      end

      private def self.read_int(io : IO) : Int32
        io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      end

      private def self.read_string(io : IO) : String
        bytesize = read_int(io)
        raise ArgumentError.new("negative string size") if bytesize < 0

        io.read_string(bytesize)
      end

      private def write_int(io : IO, value : Int32) : Nil
        io.write_bytes(value, IO::ByteFormat::LittleEndian)
      end

      private def write_string(io : IO, value : String) : Nil
        write_int(io, value.bytesize)
        io << value
      end
    end

    # Why a candidate module was generated after all.
    enum RegenerationReason
      # A function's key differs in what its code is made from.
      Code
      # A function's key differs only in source positions (line, column or
      # file of its nodes: debug info, cast failure messages, `__LINE__`).
      SourcePosition
      # The module got another function, lost one, or got them in another order.
      FunctionList
      # A function's key cannot be computed.
      Unkeyable
      # A trace could not be replayed: something it names is gone, or a
      # constant or class variable was in another state.
      Replay
    end

    # A function a candidate module was asked for and that matched the manifest.
    record AcceptedFun, name : String, typed_def : Def, self_type : Type, recorded : RecordedFun

    # The state of one candidate module during code generation.
    class UnitPlan
      getter recorded : RecordedUnit
      getter list_of_accepted = [] of AcceptedFun
      getter reason : RegenerationReason?
      getter reason_detail : String?

      # How many functions of the module were compared with the manifest.
      property position = 0

      # While the reason is `SourcePosition`: whether every function seen
      # since still has the code key the manifest has at its position.
      property? source_position_only = false

      def initialize(@recorded)
      end

      def invalidated? : Bool
        !@reason.nil?
      end

      def invalidate(@reason : RegenerationReason, @reason_detail : String) : Nil
        @source_position_only = @reason.try(&.source_position?) || false
      end

      def next_recorded_fun : RecordedFun?
        @recorded.list_of_funs[@list_of_accepted.size]?
      end

      # Whether every function of the module matched: nothing is generated.
      def complete? : Bool
        !invalidated? && @list_of_accepted.size == @recorded.list_of_funs.size
      end
    end

    # What `--stats` and the report file tell about a build.
    class Stats
      include JSON::Serializable

      property mode : String = "skip"
      property candidate_units = 0
      property skipped_units = 0
      property generated_units = 0
      property replayed_functions = 0
      property generated_functions = 0
      property late_generated_functions = 0
      property unkeyable_functions = 0
      property unreplayable_functions = 0
      property key_seconds = 0.0
      property replay_seconds = 0.0
      # Candidate modules that were generated, by `RegenerationReason`.
      property regenerated_units_by_reason = {} of String => Int32
      # Of those with reason `SourcePosition`: the ones where nothing but
      # source positions differs in the whole module.
      property units_regenerated_for_source_position_alone = 0
      # Modules that were no candidates, by why not.
      property units_not_candidate_by_cause = {} of String => Int32
      property list_of_regenerated_units = [] of String
      property verified_units = 0
      property units_not_verifiable = 0
      property list_of_verification_failures = [] of String
      property first_unkeyable_causes = {} of String => Int32
      property first_unreplayable_causes = {} of String => Int32

      def initialize
      end

      def count_cause(counts : Hash(String, Int32), cause : String) : Nil
        counts[cause] = (counts[cause]? || 0) + 1 if counts.size < 40 || counts.has_key?(cause)
      end
    end

    # One build's use of the manifest: what the build before left, how it is
    # used, and what this build leaves for the next one.
    class Session
      enum Mode
        # Candidate modules are not generated.
        Skip
        # Every module is generated; a candidate module whose functions all
        # matched must produce the bitcode the manifest has, or the build fails.
        Verify
      end

      getter mode : Mode
      getter salt : String
      getter previous : Manifest?
      getter stats = Stats.new

      # Why the build before left no candidates at all, if so.
      property no_candidates_cause : String?

      def initialize(@mode, @salt, @previous)
        @stats.mode = @mode.to_s.downcase
      end

      def verify? : Bool
        @mode.verify?
      end

      # The manifest's record of the module named *unit_name*, when the
      # module can start as a candidate.
      def candidate?(unit_name : String) : RecordedUnit?
        return nil if unit_name.empty?
        return nil unless previous = @previous

        recorded = previous.units_by_name[unit_name]?
        cause =
          if recorded.nil?
            "not in the manifest"
          elsif recorded.list_of_funs.empty?
            "no functions"
          elsif !recorded.replayable?
            "holds a function whose trace cannot be replayed"
          elsif !recorded.object_is_current?
            "its object file was not built from the recorded bitcode"
          end
        if cause
          @stats.count_cause(@stats.units_not_candidate_by_cause, cause)
          return nil
        end
        @stats.candidate_units += 1
        recorded
      end
    end

    # A stable description of everything code generation reads from a type
    # when it generates code that uses a value of the type: its name, how
    # its values are laid out, and the types that layout embeds.
    #
    # A type that is stored as a pointer is described by its name where it
    # is a member of another type; a type whose values are embedded (a
    # struct, a tuple, a union with value members) is described in full.
    # Type ids are left out: a module other than the main one reads them
    # from globals the main module defines.
    class TypeDescriptors
      UNKNOWN = Digest.new(0_u64, 0_u64)

      @digests = {} of UInt64 => Digest
      @types_by_llvm_name = {} of String => Type?
      @stack = [] of Type

      def initialize(@program : Program)
        {@program.nil, @program.object, @program.string, @program.bool, @program.int32, @program.void, @program.no_return}.each do |type|
          register(type)
        end
      end

      # The type that was described under the LLVM name *llvm_name*, unless
      # two types share that name.
      def type_named?(llvm_name : String) : Type?
        @types_by_llvm_name[llvm_name]?
      end

      private def register(type : Type) : Nil
        llvm_name = type.llvm_name
        if @types_by_llvm_name.has_key?(llvm_name)
          known = @types_by_llvm_name[llvm_name]
          @types_by_llvm_name[llvm_name] = nil unless known.nil? || known.same?(type)
        else
          @types_by_llvm_name[llvm_name] = type
        end
      end

      # The description of *type*, or `UNKNOWN` for a kind of type this
      # class has no description for.
      def digest(type : Type) : Digest
        if cached = @digests[type.object_id]?
          return cached
        end

        digest, _ = describe(type)
        digest
      end

      # Returns the description and the lowest stack position it refers
      # back to (a type that embeds a pointer to itself). Only a description
      # that refers to nothing below itself is the same wherever it is
      # computed from, and only that one is cached.
      private def describe(type : Type) : {Digest, Int32}
        if cached = @digests[type.object_id]?
          return {cached, Int32::MAX}
        end
        if position = @stack.index(&.same?(type))
          hasher = Hasher.new
          hasher.mix("recursive")
          hasher.mix(type.llvm_name)
          return {hasher.digest, position}
        end

        register(type)
        own_position = @stack.size
        @stack << type
        hasher = Hasher.new
        hasher.mix(type.crystal_type_id)
        hasher.mix(type.llvm_name)
        lowest = Int32::MAX
        known = describe_members(type, hasher) do |member, embedded|
          if embedded
            member_digest, member_lowest = describe(member)
            lowest = member_lowest if member_lowest < lowest
            return {UNKNOWN, lowest} if member_digest == UNKNOWN && member_lowest == Int32::MAX
            hasher.mix(member_digest)
          else
            register(member)
            hasher.mix(member.crystal_type_id)
            hasher.mix(member.llvm_name)
          end
        end
        @stack.pop
        digest = known ? hasher.digest : UNKNOWN
        @digests[type.object_id] = digest if lowest >= own_position
        {digest, lowest}
      ensure
        @stack.truncate(0, own_position) if own_position && @stack.size > own_position
      end

      # Whether a value of *type* inside another value is a pointer.
      private def stored_as_pointer?(type : Type) : Bool
        case type
        when NilableType, NilableReferenceUnionType, ReferenceUnionType
          true
        when VirtualType
          !type.struct?
        when NonGenericClassType, GenericClassInstanceType
          return false if type.is_a?(PointerInstanceType) || type.is_a?(ProcInstanceType) ||
                          type.is_a?(TupleInstanceType) || type.is_a?(NamedTupleInstanceType) ||
                          type.is_a?(StaticArrayInstanceType)
          type.class? && !type.struct? && !type.extern?
        else
          false
        end
      end

      # Mixes what is read from *type* itself and yields each type its
      # layout is made of, with whether that type's own layout is part of
      # it. Returns false for a kind of type that is not known here.
      private def describe_members(type : Type, hasher : Hasher, & : Type, Bool ->) : Bool
        yield_member = ->(member : Type) { }
        case type
        when NilType, BoolType, CharType, IntegerType, FloatType, SymbolType, NoReturnType, VoidType, LibType
          # The name says everything.
        when PointerInstanceType
          yield type.element_type, true
        when StaticArrayInstanceType
          yield type.element_type, true
          hasher.mix(type.size.to_s)
        when ProcInstanceType
          type.arg_types.each { |arg_type| yield arg_type, true }
          yield type.return_type, true
        when TupleInstanceType
          type.tuple_types.each { |member| yield member, !stored_as_pointer?(member) }
        when NamedTupleInstanceType
          type.entries.each do |entry|
            hasher.mix(entry.name)
            yield entry.type, !stored_as_pointer?(entry.type)
          end
        when NonGenericClassType, GenericClassInstanceType
          hasher.mix(type.struct?)
          hasher.mix(type.abstract?)
          hasher.mix(type.extern?)
          hasher.mix(type.extern_union?)
          hasher.mix(type.packed?)
          type.all_instance_vars.each do |name, ivar|
            hasher.mix(name)
            ivar_type = ivar.type? || @program.nil_type
            yield ivar_type, !stored_as_pointer?(ivar_type)
          end
          if type.is_a?(GenericClassInstanceType)
            type.type_vars.each_value do |type_var|
              if type_var.is_a?(Var)
                if var_type = type_var.type?
                  yield var_type, false
                end
              else
                hasher.mix(type_var.to_s)
              end
            end
          end
        when EnumType
          yield type.base_type, true
        when MetaclassType, GenericClassInstanceMetaclassType, GenericModuleInstanceMetaclassType, VirtualMetaclassType
          # A metaclass value is a type id.
          yield type.instance_type, false
        when VirtualType
          base_type = type.base_type
          if type.struct?
            # An abstract struct is laid out as the union of its subtypes.
            yield base_type, true
            type.subtypes.each { |subtype| yield subtype, true }
          else
            yield base_type, false
          end
        when UnionType
          type.union_types.each { |member| yield member, !stored_as_pointer?(member) }
        when TypeDefType
          yield type.typedef, true
        when AliasType
          yield type.remove_indirection, true unless type.remove_indirection.same?(type)
        when NonGenericModuleType, GenericModuleInstanceType, GenericClassType
          # A module, or an abstract generic class, used as a type stands
          # for the union of the types that include or inherit it.
          including = type.remove_indirection
          yield including, true unless including.same?(type)
        else
          return false
        end
        true
      end
    end

    # What walking a typed def produced: its key, and the things of the
    # program its code refers to, in the order the walk met them. A trace
    # names these by their position, which is the same in the next build
    # when the key is.
    class Walk
      getter code_key : Digest
      getter line_key : Digest
      getter blocker : String?
      getter list_of_types : Array(Type)
      getter list_of_callees : Array({Def, Type})
      getter list_of_consts : Array(Const)
      getter list_of_class_vars : Array(MetaTypeVar)
      getter list_of_proc_literals : Array(ProcLiteral)

      def initialize(@code_key, @line_key, @blocker, @list_of_types, @list_of_callees, @list_of_consts, @list_of_class_vars, @list_of_proc_literals)
      end

      def keyable? : Bool
        @blocker.nil?
      end
    end

    # The trace being recorded for the function that is generated right now.
    class Frame
      getter walk : Walk
      getter list_of_trace_entries = [] of TraceEntry
      property unreplayable_cause : String?

      # What the next build compares with, in its place among the
      # functions of its module from the moment generation starts.
      property recorded_fun : RecordedFun?

      # The function the build before generated at the same position of a
      # candidate module.
      property previous_fun : RecordedFun?

      @seen = Set({TraceKind, Int32, Int32, String?}).new
      @type_indexes : Hash(UInt64, Int32)?
      @callee_indexes : Hash({UInt64, UInt64}, Int32)?

      def initialize(@walk)
      end

      def add(kind : TraceKind, subject_index : Int32, detail : Int32 = 0, text : String? = nil) : Nil
        return unless @seen.add?({kind, subject_index, detail, text})

        @list_of_trace_entries << TraceEntry.new(kind, subject_index, detail, text)
      end

      def unreplayable(cause : String) : Nil
        @unreplayable_cause ||= cause
      end

      def type_index?(type : Type) : Int32?
        indexes = @type_indexes ||= begin
          built = Hash(UInt64, Int32).new(initial_capacity: @walk.list_of_types.size)
          @walk.list_of_types.each_with_index { |walk_type, index| built[walk_type.object_id] = index }
          built
        end
        indexes[type.object_id]?
      end

      def callee_index?(typed_def : Def, self_type : Type) : Int32?
        indexes = @callee_indexes ||= begin
          built = Hash({UInt64, UInt64}, Int32).new(initial_capacity: @walk.list_of_callees.size)
          @walk.list_of_callees.each_with_index { |(callee, callee_self), index| built[{callee.object_id, callee_self.object_id}] = index }
          built
        end
        indexes[{typed_def.object_id, self_type.object_id}]?
      end
    end

    # Computes the key of a typed def: a hash of everything code generation
    # reads when it generates the def's function.
    #
    # The walk is a whitelist, like `OwnerShapeSharing::ShapeWalker`, which
    # it follows node by node: a node class or a kind of type it does not
    # know makes the def unkeyable, and an unkeyable function is generated
    # in every build. Where code generation inlines another def (a def that
    # yields, a def whose body is a literal, `self` or an instance variable,
    # a primitive, the initializers of an allocated type), that def's body
    # is part of the key. A def that is called is part of it by the name
    # and signature of its function.
    #
    # Source positions go into a second hash (`Walk#line_key`), so that a
    # build can tell a function whose code changed from one that only moved.
    class KeyWalker < Visitor
      LEAVE         = 0x1f83d9abfb41bd6b_u64
      TOKEN_NAME    = 0x082efa98ec4e6c89_u64
      TOKEN_SEEN    = 0x452821e638d01377_u64
      TOKEN_INLINE  = 0xbe5466cf34e90c6c_u64
      TOKEN_SIMPLE  = 0xc0ac29b7c97c50dd_u64
      TOKEN_CALLEE  = 0xd1310ba698dfb5ac_u64
      TOKEN_EXTERN  = 0x3f84d5b5b5470917_u64
      TOKEN_CONST   = 0x2ffd72dbd01adfb7_u64
      TOKEN_PRIMITV = 0xa4093822299f31d0_u64

      # How deep inlined defs may nest before the def counts as unkeyable.
      MAXIMUM_INLINE_DEPTH = 200

      @code = Hasher.new
      @lines = Hasher.new
      @blocker : String?
      @types = [] of Type
      @type_indexes = {} of UInt64 => Int32
      @callees = [] of {Def, Type}
      @callee_indexes = {} of {UInt64, UInt64} => Int32
      @consts = [] of Const
      @class_vars = [] of MetaTypeVar
      @proc_literals = [] of ProcLiteral
      @made_up_names = [] of String
      @inline_depth = 0
      @filename_digests = {} of UInt64 => Digest
      @symbol_digests = {} of {UInt64, UInt64} => Digest

      getter descriptors : TypeDescriptors

      def initialize(@program : Program, @descriptors : TypeDescriptors, @sharing : OwnerShapeSharing?,
                     @keeps_local_names : Bool)
      end

      def walk(mangled_name : String, typed_def : Def, self_type : Type) : Walk
        @code = Hasher.new
        @lines = Hasher.new
        @blocker = nil
        @types = [] of Type
        @type_indexes.clear
        @callees = [] of {Def, Type}
        @callee_indexes.clear
        @consts = [] of Const
        @class_vars = [] of MetaTypeVar
        @proc_literals = [] of ProcLiteral
        @made_up_names.clear
        @inline_depth = 0

        @code.mix(mangled_name)
        mix_type(self_type)
        if typed_def.is_a?(External)
          mix_external(typed_def)
        else
          mix_def(typed_def)
        end

        Walk.new(@code.digest, @lines.digest, @blocker, @types, @callees, @consts, @class_vars, @proc_literals)
      end

      private def block(reason : String) : Nil
        @blocker ||= reason
      end

      private def mix(value) : Nil
        @code.mix(value)
      end

      private def mix_location(location : Location?) : Nil
        unless location
          @lines.mix(0_u64)
          return
        end
        @lines.mix(location.line_number)
        @lines.mix(location.column_number)
        filename = location.filename
        case filename
        when String
          @lines.mix(@filename_digests[filename.object_id] ||= Hasher.digest_of(filename))
        when VirtualFile
          @lines.mix(@filename_digests[filename.object_id] ||= begin
            hasher = Hasher.new
            expanded = location.expanded_location
            if expanded
              hasher.mix(expanded.line_number)
              hasher.mix(expanded.column_number)
              hasher.mix(expanded.filename.as?(String) || "")
            end
            hasher.mix(location.original_filename || "")
            hasher.digest
          end)
        else
          @lines.mix(1_u64)
        end
      end

      private def mix_local_name(name : String?) : Nil
        if !@keeps_local_names && name && (name.starts_with?("__temp_") || name.starts_with?("__arg"))
          index = @made_up_names.index(name)
          unless index
            index = @made_up_names.size
            @made_up_names << name
          end
          mix(TOKEN_NAME)
          mix(index)
        else
          mix(name)
        end
      end

      # Mixes *type* and lists it. A type that was met before in this walk
      # is mixed as its position in the list.
      private def mix_type(type : Type?) : Nil
        unless type
          mix(0_u64)
          return
        end
        if index = @type_indexes[type.object_id]?
          mix(TOKEN_SEEN)
          mix(index)
          return
        end
        @type_indexes[type.object_id] = @types.size
        @types << type
        digest = @descriptors.digest(type)
        block("a type of a kind without a description: #{type.class}") if digest == TypeDescriptors::UNKNOWN
        mix(digest)
      end

      private def enter(node : ASTNode) : Nil
        mix(node.crystal_type_id)
        mix(node.@flags)
        mix_type(node.type?)
        mix_location(node.location)
      end

      def end_visit(node : ASTNode) : Nil
        mix(LEAVE)
      end

      private def mix_def_header(node : Def) : Nil
        mix(node.name)
        mix_type(node.owner?)
        mix(node.args.size)
        node.args.each do |arg|
          mix_local_name(arg.name)
          mix_type(arg.type?)
        end
        mix(node.splat_index || -1)
        if block_arg = node.block_arg
          mix_local_name(block_arg.name)
          mix_type(block_arg.type?)
        end
        mix(node.block_arity || -1)
        mix_type(node.type?)
        mix(node.@flags)
        mix(node.uses_block_arg?)
        mix(node.raises?)
        mix(node.closure?)
        mix(node.self_closured?)
        mix(node.captured_block?)
        mix(node.no_inline?)
        mix(node.always_inline?)
        mix(node.returns_twice?)
        mix(node.naked?)
        mix(node.target_features)
        mix(node.target_cpu)
        node.special_vars.try &.each { |name| mix(name) }
      end

      private def mix_def(node : Def) : Nil
        mix_def_header(node)
        mix_location(node.location)
        mix_vars(node.vars, node)
        body = node.body
        case body
        when Primitive
          mix_primitive(body, node)
        when ReleasedBody
          block("a def whose body was released")
        else
          body.accept(self)
        end
      end

      private def mix_external(node : External) : Nil
        mix(TOKEN_EXTERN)
        mix_def_header(node)
        mix(node.real_name)
        mix(node.varargs?)
        mix(node.thread_local?)
        mix(node.external_var?)
        mix(node.call_convention.try(&.value) || -1)
        mix(node.wasm_import_module)
        # The body of an exported fun (`fun foo : Int32; 1; end`).
        body = node.body
        body.accept(self) unless body.is_a?(Primitive) || body.is_a?(ReleasedBody)
        mix_vars(node.vars, node)
      end

      private def mix_vars(vars : MetaVars?, holder : ASTNode?) : Nil
        return unless vars
        nil_var = @program.nil_var
        vars.each_value do |meta_var|
          mix_local_name(meta_var.name)
          mix(meta_var.@flags)
          mix_type(meta_var.type?)
          mix_location(meta_var.location)
          context = meta_var.context
          mix(context.same?(holder) ? 1_u64 : (context.is_a?(ASTNode) ? context.crystal_type_id.to_u64 : 2_u64))
          mix(meta_var.dependencies.any?(&.same?(nil_var)))
        end
      end

      # The primitive *body* of *holder*, generated in place of a call or as
      # the body of a function of its own.
      private def mix_primitive(body : Primitive, holder : Def) : Nil
        mix(TOKEN_PRIMITV)
        mix(body.name)
        mix_type(body.type?)
        mix(body.extra.try(&.to_s))
        if holder.is_a?(External)
          mix(holder.real_name)
          mix(holder.thread_local?)
        end
        case body.name
        when "symbol_to_s"
          # Reads the symbol table, declared with its length.
          mix(@program.symbols.size)
        when "allocate", "pre_initialize"
          mix_instance_var_initializers(body.type?)
          mix_instance_var_initializers(holder.owner?.try(&.instance_type))
          mix_instance_var_initializers(holder.type?)
        end
      end

      # Allocating a type runs the initializers of its instance variables,
      # generated in place.
      private def mix_instance_var_initializers(type : Type?) : Nil
        return unless type
        type = type.base_type if type.is_a?(VirtualType)
        mix_type(type)
        current = type
        while current
          if current.is_a?(InstanceVarInitializerContainer)
            current.instance_vars_initializers.try &.each do |initializer|
              mix(initializer.name)
              mix_vars(initializer.meta_vars, nil)
              initializer.value.accept(self)
            end
          end
          current = current.is_a?(ClassType) || current.is_a?(GenericClassInstanceType) ? current.superclass : nil
        end
      end

      def visit(node : Nop | NilLiteral | Unreachable | Expressions | If | While | Not | Return | Break | Next | Yield | TupleLiteral | ExceptionHandler | UninitializedVar | Underscore) : Bool
        enter(node)
        true
      end

      def visit(node : Assign | TypeDeclaration) : Bool
        enter(node)
        mix(node.discarded?)
        true
      end

      def visit(node : PointerOf) : Bool
        enter(node)
        exp = node.exp
        if exp.is_a?(Call)
          # The pointer of a lib variable: the call's first dependency.
          external = exp.dependencies.first?
          if external.is_a?(External)
            mix_external(external)
          else
            block("pointerof a call that is no lib variable")
          end
          return false
        end
        true
      end

      def visit(node : BoolLiteral) : Bool
        enter(node)
        mix(node.value)
        false
      end

      def visit(node : NumberLiteral) : Bool
        enter(node)
        mix(node.value)
        mix(node.kind.value)
        false
      end

      def visit(node : CharLiteral) : Bool
        enter(node)
        mix(node.value.ord)
        false
      end

      def visit(node : StringLiteral) : Bool
        enter(node)
        mix(node.value)
        false
      end

      # A symbol is its index in the program's symbol table.
      def visit(node : SymbolLiteral) : Bool
        enter(node)
        mix(node.value)
        mix(@program.symbols.index(node.value) || -1)
        false
      end

      def visit(node : Var) : Bool
        enter(node)
        mix_local_name(node.name)
        false
      end

      def visit(node : Global) : Bool
        enter(node)
        mix(node.name)
        false
      end

      def visit(node : InstanceVar) : Bool
        enter(node)
        mix(node.name)
        false
      end

      def visit(node : ReadInstanceVar) : Bool
        enter(node)
        mix(node.name)
        true
      end

      def visit(node : ClassVar) : Bool
        enter(node)
        mix(node.name)
        class_var = node.var
        mix_type(class_var.owner)
        mix_type(class_var.type?)
        mix(class_var.thread_local?)
        mix(class_var.uninitialized?)
        mix(class_var.initializer.nil?)
        mix(class_var.simple_initializer?)
        @class_vars << class_var unless @class_vars.any?(&.same?(class_var))
        false
      end

      def visit(node : NamedTupleLiteral) : Bool
        enter(node)
        node.entries.each { |entry| mix(entry.key) }
        true
      end

      def visit(node : Rescue) : Bool
        enter(node)
        mix_local_name(node.name)
        true
      end

      def visit(node : Path) : Bool
        enter(node)
        if target_const = node.target_const
          mix(TOKEN_CONST)
          mix(target_const.llvm_name)
          mix_type(target_const.value.type?)
          mix(target_const.compile_time_value.to_s)
          mix(target_const.simple?)
          mix(target_const.pointer_read?)
          @consts << target_const unless @consts.any?(&.same?(target_const))
        elsif replacement = node.syntax_replacement
          replacement.accept(self)
        end
        false
      end

      def visit(node : Generic | Metaclass | ProcNotation | Union | Self) : Bool
        enter(node)
        false
      end

      def visit(node : TypeOf | SizeOf | InstanceSizeOf | AlignOf | InstanceAlignOf | OffsetOf) : Bool
        enter(node)
        collector = CensusChildCollector.new
        node.accept_children(collector)
        collector.children.each { |child| mix_type(child.type?) }
        if node.is_a?(OffsetOf)
          mix(node.offsetof_type.to_s)
          mix(node.offset.to_s)
        end
        false
      end

      # The check is generated for the types that pass it.
      def visit(node : IsA) : Bool
        enter(node)
        mix(node.nil_check?)
        obj_type = node.obj.type?
        const_type = node.const.type?
        mix_type(obj_type)
        mix_type(const_type)
        mix_type(obj_type.filter_by(const_type)) if obj_type && const_type
        node.obj.accept(self)
        false
      end

      def visit(node : RespondsTo) : Bool
        enter(node)
        mix(node.name)
        obj_type = node.obj.type?
        mix_type(obj_type)
        mix_type(obj_type.filter_by_responds_to(node.name)) if obj_type
        node.obj.accept(self)
        false
      end

      def visit(node : Cast | NilableCast) : Bool
        enter(node)
        mix_type(node.obj.type?)
        to_type = node.to.type?
        mix_type(to_type)
        mix_type(to_type.virtual_type) if to_type
        mix(node.upcast?)
        node.obj.accept(self)
        false
      end

      def visit(node : ProcLiteral) : Bool
        enter(node)
        mix(node.force_nil?)
        mix_type(node.force_nil? ? nil : node.return_type)
        @proc_literals << node unless @proc_literals.any?(&.same?(node))
        mix_def(node.def)
        false
      end

      def visit(node : ProcPointer) : Bool
        enter(node)
        node.obj.try &.accept(self)
        call = node.call
        if target_def = call.target_defs.try(&.first?)
          mix_callee(target_def, target_def.owner)
        else
          block("a proc pointer without a target def")
        end
        false
      end

      def visit(node : Block) : Bool
        enter(node)
        mix(node.splat_index || -1)
        mix_type(node.break.type?)
        node.args.each do |arg|
          mix_local_name(arg.name)
          mix_type(arg.type?)
        end
        mix_vars(node.vars, node)
        if fun_literal = node.fun_literal
          fun_literal.accept(self)
        end
        true
      end

      def visit(node : Call) : Bool
        enter(node)
        mix(node.name)
        mix(node.global?)

        # Code generation raises on a call that still has an expansion, so
        # a function it generates never holds one that is reached.
        return false if node.expanded

        mix(node.uses_with_scope?)
        mix_type(node.with_scope)
        mix_type(node.scope?)
        mix_location(node.name_location)

        node.obj.try &.accept(self)
        mix(node.args.size)
        node.args.each &.accept(self)
        node.named_args.try &.each do |named_arg|
          mix(named_arg.name)
          named_arg.value.accept(self)
        end
        node.block_arg.try &.accept(self)
        node.block.try &.accept(self)

        target_defs = node.target_defs
        if target_defs.nil? || target_defs.empty?
          mix(0_u64)
        else
          mix(target_defs.size)
          target_defs.each { |target_def| mix_target(node, target_def) }
        end
        false
      end

      # What the call *node* reads from *target_def*, one of its target defs.
      private def mix_target(node : Call, target_def : Def) : Nil
        owner = node.super? ? node.scope? : target_def.owner?
        unless owner
          block("a call without an owner")
          return
        end
        mix(node.super?)
        mix_type(owner)

        if node.args.size < target_def.args.size
          # Magic constant arguments take their value from the call's place.
          mix_location(node.location)
          mix_location(node.end_location)
          node.args.size.upto(target_def.args.size - 1) do |index|
            default_value = target_def.args[index].default_value
            mix(default_value.is_a?(MagicConstant) ? default_value.name.value : -1)
            if (location = node.location) && default_value.is_a?(MagicConstant)
              @lines.mix(location.original_filename || "")
            end
          end
        end

        block = node.block
        body = target_def.body
        if target_def.is_a?(External)
          mix_external(target_def)
          add_callee(target_def, owner)
        elsif block && !(block.fun_literal && target_def.uses_block_arg?)
          # The def is generated in place, around the block.
          mix(TOKEN_INLINE)
          mix_inlined_def(target_def)
        elsif block.nil? && CodeGenVisitor.inlines_body_at_call?(target_def, body)
          mix(TOKEN_SIMPLE)
          mix_def_header(target_def)
          body.accept(self)
        elsif block.nil? && body.is_a?(Primitive)
          mix_def_header(target_def)
          mix_primitive(body, target_def)
        else
          mix_callee(target_def, owner)
        end
      end

      private def mix_inlined_def(target_def : Def) : Nil
        if @inline_depth >= MAXIMUM_INLINE_DEPTH
          block("defs inlined more than #{MAXIMUM_INLINE_DEPTH} deep")
          return
        end
        @inline_depth += 1
        mix_def(target_def)
        @inline_depth -= 1
      end

      # A def that is called: the name of its function, and what a call
      # reads from its signature.
      private def mix_callee(target_def : Def, owner : Type) : Nil
        mix(TOKEN_CALLEE)
        mix(symbol_digest(target_def, owner))
        mix_def_header(target_def)
        add_callee(target_def, owner)
      end

      private def add_callee(target_def : Def, owner : Type) : Nil
        key = {target_def.object_id, owner.object_id}
        return if @callee_indexes.has_key?(key)

        @callee_indexes[key] = @callees.size
        @callees << {target_def, owner}
      end

      # The hash of the name of the function a call to *target_def* names:
      # the function of the def that stands for it, when it shares one.
      private def symbol_digest(target_def : Def, owner : Type) : Digest
        @symbol_digests[{target_def.object_id, owner.object_id}] ||= begin
          if (sharing = @sharing) && (representative = sharing.representative?(target_def))
            target_def = representative
            owner = representative.owner
          end
          Hasher.digest_of(target_def.mangled_name(@program, owner))
        end
      end

      def visit(node : ExpandableNode) : Bool
        mix(node.crystal_type_id)
        false
      end

      # Any node class the whitelist does not name.
      def visit(node : ASTNode) : Bool
        block("node #{node.class.name.lchop("Crystal::")}")
        false
      end
    end
  end

  class Program
    # Set by the compiler for an incremental build that may skip IR
    # generation (see `IrSkip`).
    property ir_skip : IrSkip::Session?
  end
end
