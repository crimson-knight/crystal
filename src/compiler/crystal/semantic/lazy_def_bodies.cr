module Crystal
  # Sets aside the bodies of methods that macros wrote until a call needs
  # them.
  #
  # A macro that runs once per type writes the same methods into every one
  # of them (Grant's `column` and `macro inherited` write about 600 methods
  # per model). On a program of 300 Grant models, 138,000 of those methods
  # are never called, and their parsed bodies hold 350 MB through all of
  # type inference, the stage that sets the compiler's memory peak.
  #
  # The text of every macro expansion is kept anyway (in the
  # `MacroSourceStore`, see `VirtualFile`). When the declarations are done
  # and type inference starts, the body of each such method is replaced by a
  # `LazyMacroDefBody` that remembers where the method's text is in its
  # expansion. The first read of `Def#body` parses that text again, with the
  # same locations, and normalizes it, which gives the body the parser and
  # normalizer gave it the first time.
  #
  # Only methods whose whole text is one stretch of their expansion, with
  # no location pragmas in it, and whose location points into that
  # expansion, are set aside. A method whose body macro expressions write
  # (`macro_def?`) is kept, and so is every method while the declarations
  # are processed: they may read and change bodies.
  #
  # `CRYSTAL_LAZY_DEF_BODIES=0` keeps every body. With
  # `CRYSTAL_LAZY_DEF_BODIES_VERIFY=1` each body is parsed again when it is
  # set aside and compared with the one it replaces; a method whose bodies
  # differ is kept and named on standard error.
  class LazyMacroDefBody < DeferredDefBody
    def initialize(@program : Program, @virtual_file : VirtualFile, @byte_offset : Int32, @bytesize : Int32)
    end

    def materialize_into(owner : Def) : Nil
      lazy_def_bodies = @program.lazy_def_bodies
      lazy_def_bodies.materialized += 1
      if LazyDefBodies.trace? && lazy_def_bodies.materialized <= 40
        STDERR.puts "lazy def bodies: making #{owner.name} again from"
        caller.first(14).each { |frame| STDERR.puts "  #{frame}" }
      end
      owner.body = LazyDefBodies.parse_body(@program, owner, @virtual_file, @byte_offset, @bytesize)
    end
  end

  DeferredDefBody.materializer = ->(owner : Def, deferred : DeferredDefBody) do
    deferred.as(LazyMacroDefBody).materialize_into(owner)
    nil
  end

  class LazyDefBodies
    # A method written by a macro, and where its text is in the expansion.
    record Candidate, a_def : Def, virtual_file : VirtualFile, byte_offset : Int32, bytesize : Int32

    def self.enabled_by_env? : Bool
      ENV["CRYSTAL_LAZY_DEF_BODIES"]? != "0"
    end

    def self.trace? : Bool
      ENV["CRYSTAL_LAZY_DEF_BODIES_TRACE"]? == "1"
    end

    def self.verify? : Bool
      ENV["CRYSTAL_LAZY_DEF_BODIES_VERIFY"]? == "1"
    end

    # How many bodies were set aside, and how many of them were made again.
    property deferred = 0
    property materialized = 0
    property verify_mismatches = 0

    # Why the methods macros wrote were not set aside, with how many.
    getter kept_by_reason = Hash(String, Int32).new(0)

    @list_of_candidates = [] of Candidate

    def initialize(@program : Program)
    end

    # Notes the methods in *generated_node*, the parsed and normalized text
    # *source* of a macro expansion whose locations point into
    # *virtual_file*, that can be set aside. *pragma_offsets* are the
    # offsets of the expansion's location pragmas (the parser consumes them).
    def note(generated_node : ASTNode, source : String, virtual_file : VirtualFile, pragma_offsets : Array(Int32)?) : Nil
      list_of_defs = [] of Def
      collect_defs(generated_node, list_of_defs)
      return if list_of_defs.empty?
      unless source.ascii_only?
        @kept_by_reason["expansion text is not ASCII"] += list_of_defs.size
        return
      end

      starts = line_start_offsets(source)
      list_of_defs.each do |a_def|
        if reason = kept_reason(a_def, source, starts, virtual_file, pragma_offsets)
          @kept_by_reason[reason] += 1
        end
      end
    end

    # Notes *a_def* as a candidate, or says why it is kept.
    private def kept_reason(a_def : Def, source : String, starts : Array(Int32), virtual_file : VirtualFile, pragma_offsets : Array(Int32)?) : String?
      return "macro code in the body" if a_def.macro_def?
      return "abstract or empty" if a_def.abstract? || a_def.body_as_held.is_a?(Nop)
      location = a_def.location
      end_location = a_def.end_location
      return "no location" unless location && end_location
      return "location points out of the expansion" unless location.filename.same?(virtual_file) && end_location.filename.same?(virtual_file)

      first_line = location.line_number
      last_line = end_location.line_number
      return "lines out of range" unless 0 < first_line <= last_line <= starts.size

      byte_offset = starts[first_line - 1] + location.column_number - 1
      end_offset = starts[last_line - 1] + end_location.column_number
      return "offsets out of range" unless 0 <= byte_offset < end_offset <= source.bytesize
      return "text does not start with def and end with end" unless source.byte_slice(byte_offset, 4) == "def " && source.byte_slice(end_offset - 3, 3) == "end"
      return "location pragma inside" if pragma_offsets && pragma_offsets.any? { |pragma_offset| byte_offset <= pragma_offset < end_offset }

      @list_of_candidates << Candidate.new(a_def, virtual_file, byte_offset, end_offset - byte_offset)
      nil
    end

    # Sets aside the body of every method noted so far.
    def defer_all : Nil
      verify = LazyDefBodies.verify?
      @list_of_candidates.each do |candidate|
        a_def = candidate.a_def
        next unless deferrable?(a_def.body_as_held)

        if verify && !same_body?(candidate, a_def.body_as_held)
          @verify_mismatches += 1
          STDERR.puts "lazy def bodies: #{a_def.name} (#{a_def.location}) parses to another body; kept"
          next
        end

        a_def.body = LazyMacroDefBody.new(@program, candidate.virtual_file, candidate.byte_offset, candidate.bytesize)
        @deferred += 1
      end
      @list_of_candidates = [] of Candidate
    end

    # Parses the text of *owner* again and returns its normalized body.
    def self.parse_body(program : Program, owner : Def, virtual_file : VirtualFile, byte_offset : Int32, bytesize : Int32)
      location = owner.location || raise "BUG: deferred body of #{owner.name} without a location"
      text = virtual_file.source_slice(byte_offset, bytesize)
      parser = program.new_parser(text)
      parser.filename = virtual_file
      parser.line_number = location.line_number
      parser.column_number = location.column_number
      parser.type_nest = 1
      parsed = parser.parse
      parsed = parsed.expressions.first? if parsed.is_a?(Expressions) && parsed.expressions.size == 1
      unless parsed.is_a?(Def) && parsed.name == owner.name && parsed.args.size == owner.args.size &&
             parsed.location == location && parsed.end_location == owner.end_location
        raise "BUG: deferred body of #{owner.name} (#{location}) parsed to something else"
      end
      normalized = program.normalize(parsed)
      raise "BUG: deferred body of #{owner.name} (#{location}) normalized to something else" unless normalized.is_a?(Def)
      # Freshly parsed, so never set aside.
      normalized.body_as_held
    end

    private def deferrable?(held : ASTNode) : Bool
      !held.is_a?(DeferredDefBody) && !held.is_a?(Primitive) && !held.is_a?(Nop)
    end

    private def same_body?(candidate : Candidate, held : ASTNode) : Bool
      parsed = LazyDefBodies.parse_body(@program, candidate.a_def, candidate.virtual_file, candidate.byte_offset, candidate.bytesize)
      without_fresh_names(parsed.to_s) == without_fresh_names(held.to_s) &&
        parsed.location == held.location && parsed.end_location == held.end_location
    rescue ex
      STDERR.puts "lazy def bodies: #{ex.message}"
      false
    end

    private def without_fresh_names(text : String) : String
      text.gsub(/__temp_\d+/, "__temp").gsub(/__arg\d+/, "__arg")
    end

    # The byte offset where each line of *source* starts.
    private def line_start_offsets(source : String) : Array(Int32)
      starts = [0]
      source.each_byte.with_index do |byte, index|
        starts << index + 1 if byte == 10_u8
      end
      starts
    end

    # Adds to *list_of_defs* the defs at the top of *node*: in expressions,
    # visibility modifiers and the bodies of types it declares, never inside
    # a def.
    private def collect_defs(node : ASTNode, list_of_defs : Array(Def)) : Nil
      case node
      when Def
        list_of_defs << node
      when Expressions
        node.expressions.each { |expression| collect_defs(expression, list_of_defs) }
      when VisibilityModifier
        collect_defs(node.exp, list_of_defs)
      when ClassDef
        collect_defs(node.body, list_of_defs)
      when ModuleDef
        collect_defs(node.body, list_of_defs)
      end
    end
  end

  class Program
    # Whether the bodies of methods macros wrote are set aside until a call
    # needs them (see `LazyDefBodies`). The compiler turns it on for builds;
    # tools and the build server, which read or keep untyped bodies, leave it
    # off.
    property? lazy_def_bodies_enabled = false

    getter(lazy_def_bodies) { LazyDefBodies.new(self) }
  end

  class VirtualFile
    # *bytesize* bytes of the expanded source code, from *byte_offset*.
    def source_slice(byte_offset : Int32, bytesize : Int32) : String
      source_store = @source_store
      stored_source = @stored_source
      if source_store && stored_source
        return source_store.read(MacroSourceStore::Entry.new(stored_source.offset + byte_offset, bytesize))
      end
      (@source || "").byte_slice(byte_offset, bytesize)
    end
  end
end
