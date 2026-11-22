module Regex::Mica::Regex
  # :nodoc:
  # What a program's matches look like when every one is short: the most
  # bytes a match can span, and (when they are few) the bytes a match's
  # last byte can be. `LazyDFA#find_from_each_start` uses both: it runs the
  # DFA anchored at each start, which reads at most `longest` + 1 bytes
  # per start, and it skips every start more than `longest` bytes before
  # the next occurrence of a final byte, as no match can begin there.
  #
  # ```
  # # [a-q][^u-z]{13}x: at most 1 + 13·4 + 1 bytes, always ending in "x".
  # short_match.longest             # => 54
  # short_match.list_of_final_bytes # => [120_u8]
  # ```
  class ShortMatch
    # The longest match that qualifies, in bytes.
    BOUND = 512
    # The most distinct final bytes kept; with more, `list_of_final_bytes`
    # is empty and no start is skipped.
    MAX_FINAL_BYTES = 3

    # The most bytes a match can span.
    getter longest : Int32
    # The bytes every match ends with, or empty when they are more than
    # `MAX_FINAL_BYTES` (or the program can match the empty string).
    getter list_of_final_bytes : Array(UInt8)

    # The fewest bytes a match spans (`StartFilter.shortest_match`).
    getter shortest : Int32
    # True for each byte no state of the program reads, so no match holds
    # it (`u` in `[a-q][^u-z]{80}x`); see `outside?`.
    @outside_bytes : StaticArray(Bool, 256)
    # True when `@outside_bytes` holds any byte and `shortest` is at least
    # `SKIP_SHORTEST`, so `LazyDFA#find_from_each_start` can skip the starts
    # too close before such a byte.
    getter? skips_short_stretches : Bool

    # The fewest bytes a match must span for `skips_short_stretches?`. A
    # start at an outside byte already dies on its first step, so for a
    # match of a byte or two the look-ahead costs more than it skips.
    SKIP_SHORTEST = 4

    def initialize(@longest : Int32, @list_of_final_bytes : Array(UInt8), @shortest : Int32 = 0,
                   @outside_bytes : StaticArray(Bool, 256) = StaticArray(Bool, 256).new(false))
      @skips_short_stretches = @shortest >= SKIP_SHORTEST && @outside_bytes.any?
    end

    # Returns the analysis of *program*, or nil when a match can span more
    # than `BOUND` bytes (or any number, through a loop that reads input).
    def self.analyze(program : Program) : ShortMatch?
      longest = longest_match(program)
      return nil unless longest
      new(longest, final_bytes(program), StartFilter.shortest_match(program), outside_bytes(program))
    end

    # True when no match holds *byte*.
    @[AlwaysInline]
    def outside?(byte : UInt8) : Bool
      @outside_bytes.unsafe_fetch(byte)
    end

    # The bytes no state of *program* reads: every byte, less those of each
    # byte-range state and of each transition of a sparse state. A match is
    # made of the bytes its states read, so it holds none of these. Each
    # range is cleared with one `memset`, so a program of many states costs
    # one call per state.
    def self.outside_bytes(program : Program) : StaticArray(Bool, 256)
      outside = StaticArray(Bool, 256).new(true)
      table = outside.to_unsafe
      program.each_distinct_state do |state, _|
        (table + state.low).clear(state.high.to_i32 - state.low.to_i32 + 1) if state.kind.byte_range?
      end
      program.each_transition_range do |low, high|
        (table + low).clear(high.to_i32 - low.to_i32 + 1)
      end
      outside
    end

    # Returns the most bytes a match of *program* can span, or nil when a
    # loop reads input or the length passes `BOUND`. One depth-first pass:
    # a state's longest path to the match state is known once its
    # successors' are, and a successor still on the stack is a loop.
    def self.longest_match(program : Program) : Int32?
      # UNSEEN, ON_STACK, or the longest path in bytes.
      # Both lists are scratch outside the collector's heap, freed on the
      # way out; the stack grows in the helpers through its pointer.
      longest = OffHeapList(Int32).new(program.state_count, UNSEEN)
      list_of_pending = OffHeapList(Int32).new(16)
      begin
        longest_path(program, longest, pointerof(list_of_pending))
      ensure
        longest.free
        list_of_pending.free
      end
    end

    private def self.longest_path(program : Program, longest : OffHeapList(Int32),
                                  list_of_pending : OffHeapList(Int32)*) : Int32?
      list_of_pending.value << program.start_state
      while index = list_of_pending.value.last?
        if longest[index] == UNSEEN
          longest[index] = ON_STACK
          return nil unless push_successors(program, index, program.state_at(index), longest, list_of_pending)
          next
        end
        list_of_pending.value.pop
        next if longest[index] >= 0
        state = program.state_at(index)
        result = case state.kind
                 when .byte_range?
                   longest[state.next_state] + 1
                 when .save?, .look?
                   longest[state.next_state]
                 when .split?
                   Math.max(longest[state.next_state], longest[state.alternate])
                 when .sparse?
                   most = 0
                   state.alternate.times do |offset|
                     most = Math.max(most, longest[program.transition_at(index, state, offset).target] + 1)
                   end
                   most
                 else
                   0
                 end
        return nil if result > BOUND
        longest[index] = result
      end
      longest[program.start_state]
    end

    private UNSEEN   = -2
    private ON_STACK = -1

    # Pushes the successors of *state* whose longest path is not known yet;
    # false when one is on the stack (a loop).
    private def self.push_successors(program : Program, index : Int32, state : Program::State, longest : OffHeapList(Int32),
                                     list_of_pending : OffHeapList(Int32)*) : Bool
      case state.kind
      when .byte_range?, .save?, .look?
        push_successor(state.next_state, longest, list_of_pending)
      when .split?
        push_successor(state.next_state, longest, list_of_pending) &&
          push_successor(state.alternate, longest, list_of_pending)
      when .sparse?
        (0...state.alternate).all? do |offset|
          push_successor(program.transition_at(index, state, offset).target, longest, list_of_pending)
        end
      else
        true
      end
    end

    private def self.push_successor(successor : Int32, longest : OffHeapList(Int32), list_of_pending : OffHeapList(Int32)*) : Bool
      length = longest[successor]
      return false if length == ON_STACK
      list_of_pending.value << successor if length == UNSEEN
      true
    end

    # Returns the bytes a match of *program* can end with (the byte read
    # just before the match state is reached through steps that read
    # nothing), or an empty list when they are more than `MAX_FINAL_BYTES`
    # or the start state reaches the match state reading nothing.
    def self.final_bytes(program : Program) : Array(UInt8)
      # The states that reach a match state reading nothing, found by
      # walking the steps that read nothing backward from the match states.
      list_of_predecessors = Array(Array(Int32)?).new(program.state_count, nil)
      program.each_state do |state, index|
        case state.kind
        when .split?
          (list_of_predecessors[state.next_state] ||= [] of Int32) << index
          (list_of_predecessors[state.alternate] ||= [] of Int32) << index
        when .save?, .look?
          (list_of_predecessors[state.next_state] ||= [] of Int32) << index
        end
      end
      reaches_match = Array(Bool).new(program.state_count, false)
      list_of_pending = [] of Int32
      program.each_state do |state, index|
        next unless state.kind.match?
        reaches_match[index] = true
        list_of_pending << index
      end
      while index = list_of_pending.pop?
        list_of_predecessors[index].try &.each do |predecessor|
          next if reaches_match[predecessor]
          reaches_match[predecessor] = true
          list_of_pending << predecessor
        end
      end
      none = [] of UInt8
      return none if reaches_match[program.start_state]
      list_of_final_bytes = [] of UInt8
      program.each_state do |state, index|
        if state.kind.byte_range?
          next unless reaches_match[state.next_state]
          return none unless add_final_bytes(list_of_final_bytes, state.low, state.high)
        elsif state.kind.sparse?
          state.alternate.times do |offset|
            transition = program.transition_at(index, state, offset)
            next unless reaches_match[transition.target]
            return none unless add_final_bytes(list_of_final_bytes, transition.low, transition.high)
          end
        end
      end
      list_of_final_bytes
    end

    # Adds *low*..*high* to *list_of_final_bytes*; false when the list
    # would pass `MAX_FINAL_BYTES`.
    private def self.add_final_bytes(list_of_final_bytes : Array(UInt8), low : UInt8, high : UInt8) : Bool
      return false if high.to_i32 - low.to_i32 >= MAX_FINAL_BYTES
      (low..high).each do |byte|
        list_of_final_bytes << byte unless list_of_final_bytes.includes?(byte)
        return false if list_of_final_bytes.size > MAX_FINAL_BYTES
      end
      true
    end
  end
end
