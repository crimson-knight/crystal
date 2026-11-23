module Crystal::InferReuse
  # `TypeNode#methods` and `#all_methods` for a macro: what *block* gives,
  # recorded for a build server; or, while a build server runs the
  # expansion again, the answer `MethodListReplay` gives.
  def self.methods_for_macro(program : Program, type : Type, kind : String, & : -> ArrayLiteral) : ArrayLiteral
    record = program.infer_reuse_record || return yield
    if replay = record.method_list_replay
      return ArrayLiteral.new(replay.methods(type, kind).map(&.as(ASTNode)))
    end
    result = yield
    list_of_defs = result.elements.compact_map(&.as?(Def))
    record.add_method_list_read(MethodListRead.new(type, kind, list_of_defs, nil, false))
    result
  end

  # `TypeNode#has_method?` for a macro, like `.methods_for_macro`.
  def self.has_method_for_macro(program : Program, type : Type, name : String, & : -> BoolLiteral) : BoolLiteral
    record = program.infer_reuse_record || return yield
    if replay = record.method_list_replay
      return BoolLiteral.new(replay.has_method?(type, name))
    end
    result = yield
    record.add_method_list_read(MethodListRead.new(type, "has_method?", [] of Def, name, result.value))
    result
  end

  # What one macro read of a type's methods returned: `methods` and
  # `all_methods` give the methods themselves, `has_method?` a name and its
  # answer.
  record MethodListRead, type : Type, kind : String, list_of_defs : Array(Def), name : String?, answer : Bool

  # A macro expansion that read lists of methods, with what it produced and
  # how to run it again (`#rerun`). A build server that adds or removes a
  # method runs it again with each read answered as the original build
  # would have answered it with the edit (`MethodListReplay`), and reuses the
  # kept program only when the text it produces is the same.
  class MethodListExpansion
    getter list_of_reads = [] of MethodListRead
    property output : String? = nil
    # Where the expansion happened; a method added after this place in the
    # same file was not declared yet when a top-level expansion ran.
    getter site : Location?
    # Whether the expansion ran during type inference, when every method of
    # the program was declared.
    getter? after_top_level : Bool

    def initialize(@site, @after_top_level, @rerun : MacroRerun)
    end

    def rerun : String
      @rerun.run
    end

    # Fresh variable names a macro writes (`%name`), which differ on each run.
    FRESH_NAME = /__temp_(?:[0-9a-f]{8}_)?\d+/

    # The file the expansion's output was parsed as, once it was parsed.
    property virtual_file : VirtualFile? = nil

    # Compares two outputs of this expansion. Returns the shift that takes
    # the lines of *before* to those of *after* when both are the same
    # program: equal once the fresh variable names of each are numbered in
    # the order they first appear and, when they differ only in lines that
    # hold nothing but whitespace (a macro loop that ran once more over a
    # method it skips), parsed to the same nodes. Returns `nil` otherwise.
    def self.compare(program : Program, before : String, after : String) : Location::LineShift?
      canonical_before = canonical(before)
      canonical_after = canonical(after)
      return Location::LineShift.new([{1, 0}]) if canonical_before == canonical_after

      list_of_before = canonical_before.lines
      list_of_after = canonical_after.lines
      return nil unless list_of_before.reject(&.blank?) == list_of_after.reject(&.blank?)
      parsed_before = parsed(program, canonical_before) || return nil
      parsed_after = parsed(program, canonical_after) || return nil
      return nil unless parsed_before == parsed_after

      list_of_steps = [{1, 0}]
      after_index = 0
      list_of_before.each_with_index do |line, before_index|
        next if line.blank?
        while list_of_after[after_index].blank?
          after_index += 1
        end
        offset = after_index - before_index
        list_of_steps << {before_index + 1, offset} unless list_of_steps.last[1] == offset
        after_index += 1
      end
      Location::LineShift.new(list_of_steps)
    end

    # The nodes *text* parses to, or `nil` when it does not parse on its own.
    # Nodes compare equal without their locations, so blank lines between
    # them do not count.
    private def self.parsed(program : Program, text : String) : ASTNode?
      program.new_parser(text).parse
    rescue CodeError
      nil
    end

    private def self.canonical(text : String) : String
      number_by_name = {} of String => Int32
      text.gsub(FRESH_NAME) { |name| "__fresh_#{number_by_name[name] ||= number_by_name.size}" }
    end
  end

  # How to run one macro expansion again: what `Program#expand_macro` got.
  # It is data rather than a block so that a type-inference snapshot
  # (`InferPersist`) can hold it.
  class MacroRerun
    def initialize(@program : Program, @a_macro : Macro?, @call : Call?, @node : ASTNode?, @scope : Type,
                   @path_lookup : Type?, @free_vars : Hash(String, TypeVar)?, @a_def : Def?)
    end

    # Expands the macro again and returns its text.
    def run : String
      a_macro = @a_macro
      call = @call
      if a_macro && call
        @program.expand_macro(a_macro, call, @scope, @path_lookup, @a_def)[0]
      elsif node = @node
        @program.expand_macro(node, @scope, @path_lookup, @free_vars, @a_def)[0]
      else
        raise Error.new("BUG: a macro rerun with neither a macro nor a node")
      end
    end
  end

  # The macro expansions running now, innermost last, each with its
  # `MethodListExpansion` once it reads a list of methods.
  class MethodListFrames
    record Frame, site : Location?, after_top_level : Bool, rerun : MacroRerun

    @list_of_frames = [] of Frame
    @list_of_expansions = [] of MethodListExpansion?

    def push(site : Location?, after_top_level : Bool, rerun : MacroRerun) : Nil
      @list_of_frames << Frame.new(site, after_top_level, rerun)
      @list_of_expansions << nil
    end

    # Ends the innermost expansion; returns its `MethodListExpansion`, if it
    # read a list of methods.
    def pop(output : String?) : MethodListExpansion?
      @list_of_frames.pop?
      expansion = @list_of_expansions.pop?
      if expansion
        expansion.output = output
        @last_finished = expansion
      end
      expansion
    end

    @last_finished : MethodListExpansion?

    # Gives *virtual_file* to the expansion that just produced *source*, when
    # it read a list of methods.
    def attach(source : String, virtual_file : VirtualFile) : Nil
      expansion = @last_finished || return
      @last_finished = nil
      expansion.virtual_file = virtual_file if expansion.output.same?(source) || expansion.output == source
    end

    # The `MethodListExpansion` of the innermost expansion, made on its first
    # read; `nil` outside any expansion.
    def current : MethodListExpansion?
      frame = @list_of_frames.last? || return nil
      @list_of_expansions[-1] ||= MethodListExpansion.new(frame.site, frame.after_top_level, frame.rerun)
    end
  end

  # Answers the method-list reads of one expansion run again: each read gets
  # what the original build answered, with the methods a build server adds
  # or removes in or out of the lists that contain them.
  class MethodListReplay
    @next_read_index = 0

    def initialize(@list_of_reads : Array(MethodListRead), @list_of_added : Array(Def), @list_of_removed : Array(Def))
    end

    def methods(type : Type, kind : String) : Array(Def)
      edited(next_read(type, kind)).list_of_defs
    end

    # *read* as the original build would have made it with the edit.
    def edited(read : MethodListRead) : MethodListRead
      if read.kind == "has_method?"
        name = read.name
        added = @list_of_added.any? { |added_def| added_def.name == name && MethodListReplay.lists?(read.type, "all_methods", added_def.owner) }
        return added ? MethodListRead.new(read.type, read.kind, read.list_of_defs, name, true) : read
      end
      list_of_defs = read.list_of_defs.reject { |a_def| @list_of_removed.any?(&.same?(a_def)) }
      @list_of_added.each do |added_def|
        list_of_defs << added_def if MethodListReplay.lists?(read.type, read.kind, added_def.owner)
      end
      MethodListRead.new(read.type, read.kind, list_of_defs, read.name, read.answer)
    end

    def has_method?(type : Type, name : String) : Bool
      read = next_read(type, "has_method?")
      raise Refusal.new("a macro asked #{type}.has_method?(#{name}) again with another name") unless read.name == name
      return true if @list_of_added.any? { |added_def| added_def.name == name && MethodListReplay.lists?(type, "all_methods", added_def.owner) }
      if read.answer && @list_of_removed.any? { |removed_def| removed_def.name == name && MethodListReplay.lists?(type, "all_methods", removed_def.owner) }
        raise Refusal.new("a macro asked #{type}.has_method?(#{name}) of a removed method")
      end
      read.answer
    end

    # Whether the methods of *owner* are in a list of *kind* for *type*.
    def self.lists?(type : Type, kind : String, owner : Type) : Bool
      return true if owner.same?(type)
      kind != "methods" && type.ancestors.any?(&.same?(owner))
    end

    private def next_read(type : Type, kind : String) : MethodListRead
      read = @list_of_reads[@next_read_index]? || raise Refusal.new("a macro run again read more lists of methods than before")
      @next_read_index += 1
      unless read.type.same?(type) && read.kind == kind
        raise Refusal.new("a macro run again read the methods of #{type}, it read those of #{read.type} before")
      end
      read
    end
  end
end
