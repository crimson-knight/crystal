require "../syntax/ast"
require "../syntax/parser"

# The bodies of the methods macros write, out of memory until a call needs
# them.
#
# Macros write most of the methods of a large program (Grant writes dozens
# for every model and every column), and most of those are never called: in
# a 300-model Amber app, 131,718 methods written by macros, holding 313 MB
# of untyped syntax tree, are still untyped when type inference ends. Their
# text is already kept, in the macro source store, for error messages.
#
# While a macro expansion is parsed, the parser records where each method in
# it starts (the position in the text and the lexer's location state). Once
# the top-level stages have read every body (they look for instance variable
# assignments and the like), type inference starts by letting the bodies of
# those methods go. A body that is read again (a call types the method, a
# macro reads `def.body`) is parsed again from the same text, starting at
# the same position with the same location state and the location pragmas
# that follow, and normalized as it was the first time: the same nodes at
# the same locations. Only the names the compiler makes up for its own
# variables (`__temp_12`) differ, and those are local to the body.
#
# A body is let go only when it is still the one the parser made: a def
# whose body was replaced (a primitive, a `new` filled in, a method from
# `method_missing`) loses its source, and a def with a parameter the
# normalizer renamed (tuple unpacking) is kept.
#
# `CRYSTAL_LAZY_DEF_BODIES=0` keeps every body. `verify` parses every body
# again before letting it go, compares the result (nodes, names, values and
# locations) with the body in memory, and keeps any that differ, printing
# them. Off for documentation, incremental builds and the build server.
module Crystal
  class Program
    class_getter lazy_def_bodies_mode : String = ENV["CRYSTAL_LAZY_DEF_BODIES"]? || "1"

    # `true` or `false` overrides `CRYSTAL_LAZY_DEF_BODIES` for this program,
    # or (the class property) for every program that sets nothing.
    property lazy_def_bodies_setting : Bool?
    class_property lazy_def_bodies_default_setting : Bool?

    # Whether macro-written method bodies are let go during type inference:
    # for a compiler build (not for the interpreter or a tool that has no
    # compiler), or with `CRYSTAL_LAZY_DEF_BODIES=verify` for any program,
    # which the spec suites use.
    def lazy_def_bodies? : Bool
      setting = @lazy_def_bodies_setting
      setting = Program.lazy_def_bodies_default_setting if setting.nil?
      return false if setting == false || (setting.nil? && Program.lazy_def_bodies_mode == "0")
      return false if wants_doc? || infer_reuse_record
      if compiler = self.compiler
        !compiler.incremental?
      else
        setting == true || Program.lazy_def_bodies_mode == "verify"
      end
    end

    property lazy_def_bodies_dropped = 0
    property lazy_def_bodies_parsed_again = 0
    property lazy_def_bodies_differ = 0

    # Lets go of the bodies that can be parsed again. Called when type
    # inference starts.
    def drop_lazy_def_bodies : Nil
      return unless lazy_def_bodies?

      verify = Program.lazy_def_bodies_mode == "verify"
      visited = Set(UInt64).new
      drop_lazy_def_bodies(self, visited, verify)
      file_modules.each_value { |file_module| drop_lazy_def_bodies(file_module, visited, verify) }
      if (verify && @lazy_def_bodies_differ > 0) || ENV["CRYSTAL_LAZY_DEF_BODIES_STATS"]? == "1"
        STDERR.puts "lazy def bodies: #{@lazy_def_bodies_dropped} let go#{verify ? ", #{@lazy_def_bodies_differ} kept because they differ when parsed again" : ""}"
      end
    end

    private def drop_lazy_def_bodies(type : Type, visited : Set(UInt64), verify : Bool) : Nil
      return unless visited.add?(type.object_id)

      if type.is_a?(ModuleType)
        type.defs.try &.each_value do |list|
          list.each do |def_with_metadata|
            drop_lazy_def_body(def_with_metadata.def, verify)
          end
        end
      end

      type.types?.try &.each_value { |nested| drop_lazy_def_bodies(nested, visited, verify) }
      drop_lazy_def_bodies(type.metaclass, visited, verify) unless type.metaclass?
    end

    private def drop_lazy_def_body(a_def : Def, verify : Bool) : Nil
      source = a_def.lazy_body
      return unless source.is_a?(LazyMacroDefBodies::Source)
      return if a_def.lazy_body?

      if verify
        parsed_again = source.body_for(a_def)
        if difference = LazyMacroDefBodies.first_difference(a_def.body, parsed_again)
          @lazy_def_bodies_differ += 1
          STDERR.puts "lazy def bodies: #{a_def.name} (#{a_def.location}) differs when parsed again: #{difference}" if @lazy_def_bodies_differ <= 20
          a_def.lazy_body = nil
          return
        end
      end

      a_def.drop_body(source)
      @lazy_def_bodies_dropped += 1
    end
  end

  # Records where the defs of one macro expansion start, and parses their
  # bodies again on demand.
  class LazyMacroDefBodies < Parser::DefBodyRecorder
    # Where one def starts in the expansion's text.
    class Source < LazyDefBody
      def initialize(@expansion : LazyMacroDefBodies, @start : Lexer::LocationState)
      end

      def body_for(a_def : Def) : ASTNode
        @expansion.parse_body(a_def, @start)
      end
    end

    # The location pragmas of the expansion, by position, in order.
    @list_of_pragmas : Array({Int32, Array(Lexer::LocPragma)})
    @list_of_recorded = [] of {Def, Lexer::LocationState}

    # *normalize* is the normalization the expansion went through.
    def initialize(@program : Program, @virtual_file : VirtualFile, pragmas : Hash(Int32, Array(Lexer::LocPragma))?,
                   @inside_type : Bool, @normalize : ASTNode -> ASTNode)
      @list_of_pragmas = pragmas.try(&.to_a) || [] of {Int32, Array(Lexer::LocPragma)}
    end

    def record(a_def : Def, start : Lexer::LocationState) : Nil
      @list_of_recorded << {a_def, start}
    end

    # Gives each def that was parsed (and normalized) its source. A def
    # whose parameters the normalizer renamed is left without one.
    def attach_sources : Nil
      @list_of_recorded.each do |(a_def, start)|
        next if a_def.args.any?(&.name.starts_with?("__"))
        a_def.lazy_body = Source.new(self, start)
      end
      @list_of_recorded = [] of {Def, Lexer::LocationState}
    end

    # Parses the body of *a_def* again from *start*.
    def parse_body(a_def : Def, start : Lexer::LocationState) : ASTNode
      @program.lazy_def_bodies_parsed_again += 1
      parser = @program.new_parser(@virtual_file.source)
      parser.filename = @virtual_file
      pragmas = Hash(Int32, Array(Lexer::LocPragma)).new
      @list_of_pragmas.each do |(position, list)|
        pragmas[position] = list if position > start.pos
      end
      parser.macro_expansion_pragmas = pragmas
      parser.type_nest = 1 if @inside_type
      parser.wants_doc = false
      parser.restore_location_state(start)
      parser.next_token
      parsed = parser.parse_def
      normalized = @normalize.call(parsed)
      unless normalized.is_a?(Def) && normalized.name == a_def.name
        raise "BUG: parsing the body of #{a_def.name} (#{a_def.location}) again gave #{normalized.class_desc} #{normalized.is_a?(Def) ? normalized.name : ""}"
      end
      normalized.body
    end

    # A description of the first difference between two bodies, or `nil`.
    def self.first_difference(body : ASTNode, other : ASTNode) : String?
      first = Fingerprint.new.tap { |fingerprint| body.accept(fingerprint) }.list_of_entries
      second = Fingerprint.new.tap { |fingerprint| other.accept(fingerprint) }.list_of_entries
      first.each_with_index do |entry, index|
        other_entry = second[index]?
        return "node #{index}: #{entry} against #{other_entry || "nothing"}" unless entry == other_entry
      end
      return "#{first.size} nodes against #{second.size}" unless first.size == second.size
      nil
    end

    # Each node's class, text and locations, with compiler-made names
    # numbered by first appearance.
    private class Fingerprint < Visitor
      getter list_of_entries = [] of String
      @made_names = {} of String => Int32

      def visit(node : ASTNode) : Bool
        text = case node
               when Var, Arg, InstanceVar, ClassVar, Global then node.name
               when Call                                    then "#{node.name} #{node.args.size} #{node.named_args.try(&.map(&.name))} #{node.global?}"
               when Def                                     then node.name
               when Path                                    then "#{node.names.join("::")} #{node.global?}"
               when StringLiteral, SymbolLiteral, NumberLiteral, CharLiteral, BoolLiteral
                 node.to_s
               else
                 ""
               end
        text = text.gsub(/__(temp|arg)\w*/) { |name| "made#{@made_names[name] ||= @made_names.size}" }
        @list_of_entries << "#{node.class.name} #{node.location} #{node.end_location} #{text}"
        true
      end
    end
  end
end
