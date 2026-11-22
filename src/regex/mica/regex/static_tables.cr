module Regex::Mica::Regex
  # :nodoc:
  # One direction's complete DFA (see `Static::DirectionTables`). Entries
  # are state ids of type `T` (`UInt8` or `UInt16`, the narrowest that
  # holds them); the row of state `s` starts at `s << shift`, so the search
  # loop reads a transition with one shift and one add. States are
  # numbered dead first (0 the dead state, 1 the dead state that reports a
  # match), then the other match states up to `special_limit`, then
  # (forward and reverse) the accelerated states up to `accel_limit`, then
  # the rest.
  #
  # `classes` maps each byte to its column. It is the pattern's byte
  # classes, or, in a table built over UTF-8 decoder states (see
  # `Static::DecoderAlphabet`), a map whose columns are shared by classes
  # that no state reads at the same decoder state (a byte between
  # characters, or inside one); the haystack is valid UTF-8, so a state
  # never reads a byte its decoder state cannot have. `edge_symbol` (and
  # the one after it, the final line feed) and `word_offset` (added to a
  # non-ASCII byte's column inside a Unicode word character) are the
  # columns past the classes.
  struct StaticDirection(T)
    getter shift : Int32
    getter relevant_flags : Int32
    getter context_mask : Int32
    getter special_limit : Int32
    getter accel_limit : Int32
    getter table : Slice(T)
    getter starts : Slice(T)
    getter accel_bytes : Slice(Int32)
    getter classes : Slice(UInt8)
    getter edge_symbol : Int32
    getter word_offset : Int32

    def initialize(*, @shift : Int32, @relevant_flags : Int32, @context_mask : Int32, @special_limit : Int32,
                   @accel_limit : Int32, @table : Slice(T), @starts : Slice(T), @accel_bytes : Slice(Int32),
                   @classes : Slice(UInt8), @edge_symbol : Int32, @word_offset : Int32)
    end

    # The index into `starts` for state flags *flags*: the bits of
    # `context_mask` packed down, so the table has one entry per
    # combination the DFA can tell apart.
    @[AlwaysInline]
    def start_index(flags : Int32) : Int32
      mask = @context_mask
      index = 0
      bit = 0
      while mask != 0
        lowest = mask & -mask
        index |= 1 << bit if flags & lowest != 0
        bit += 1
        mask &= mask - 1
      end
      index
    end
  end

  # :nodoc:
  # The NFA the capture pass runs (see `Static::NfaTables`), its state
  # numbers `T`.
  struct StaticProgram(T)
    getter start_state : Int32
    getter kinds : Slice(UInt8)
    getter lows : Slice(UInt8)
    getter highs : Slice(UInt8)
    getter next_states : Slice(T)
    getter alternates : Slice(T)
    getter arguments : Slice(T)
    getter sparse_lows : Slice(UInt8)
    getter sparse_highs : Slice(UInt8)
    getter sparse_targets : Slice(T)
    # See `Static::BuildTheTables#class_targets_of`.
    getter class_count : Int32
    getter class_targets : Slice(T)

    def initialize(*, @start_state : Int32, @kinds : Slice(UInt8), @lows : Slice(UInt8), @highs : Slice(UInt8),
                   @next_states : Slice(T), @alternates : Slice(T), @arguments : Slice(T),
                   @sparse_lows : Slice(UInt8), @sparse_highs : Slice(UInt8), @sparse_targets : Slice(T),
                   @class_count : Int32 = 0, @class_targets : Slice(T) = Slice(T).empty)
    end

    # The program of a pattern without groups: its capture pass never runs.
    def self.empty : self
      new(start_state: 0, kinds: Slice(UInt8).empty, lows: Slice(UInt8).empty, highs: Slice(UInt8).empty,
        next_states: Slice(T).empty, alternates: Slice(T).empty, arguments: Slice(T).empty,
        sparse_lows: Slice(UInt8).empty, sparse_highs: Slice(UInt8).empty, sparse_targets: Slice(T).empty)
    end

    # The number of states.
    def size : Int32
      @kinds.size
    end

    # The target of Sparse state *state* on *byte* (of class
    # `classes[byte]`), or -1: one load from `class_targets` when the
    # program has it, else `sparse_target`.
    @[AlwaysInline]
    def sparse_step(state : Int32, byte : UInt8, classes : Pointer(UInt8)) : Int32
      targets = @class_targets
      return sparse_target(state, byte) if targets.empty?
      target = targets.unsafe_fetch(state * @class_count + classes[byte]).to_i32
      target == size ? -1 : target
    end

    # The target of Sparse state *state* on *byte*, or -1 (binary search
    # over its sorted, disjoint ranges).
    @[AlwaysInline]
    def sparse_target(state : Int32, byte : UInt8) : Int32
      low = @arguments.unsafe_fetch(state).to_i32
      high = low + @alternates.unsafe_fetch(state).to_i32
      while low < high
        middle = (low + high) >> 1
        if @sparse_highs.unsafe_fetch(middle) < byte
          low = middle + 1
        elsif @sparse_lows.unsafe_fetch(middle) > byte
          high = middle
        else
          return @sparse_targets.unsafe_fetch(middle).to_i32
        end
      end
      -1
    end
  end

  # :nodoc:
  # The one-pass DFA a static pattern's capture pass reads first (see
  # `OnePassDFA#captures` and `Static::OnePassTables`).
  struct StaticOnePass
    # The most bytes read between charges.
    CHUNK_BYTES = 4096

    getter class_count : Int32
    getter steps : Slice(Int32)
    getter cells : Slice(Int32)
    getter match_edges : Slice(Int32)
    getter edge_slots : Slice(UInt64)
    getter edge_looks : Slice(UInt32)
    getter ascii_loops : Slice(UInt8)

    def initialize(*, @class_count : Int32, @steps : Slice(Int32), @cells : Slice(Int32), @match_edges : Slice(Int32),
                   @edge_slots : Slice(UInt64), @edge_looks : Slice(UInt32), @ascii_loops : Slice(UInt8))
    end

    # The one-pass DFA of a pattern that has none.
    def self.empty : self
      new(class_count: 1, steps: Slice(Int32).empty, cells: Slice(Int32).empty, match_edges: Slice(Int32).empty,
        edge_slots: Slice(UInt64).empty, edge_looks: Slice(UInt32).empty, ascii_loops: Slice(UInt8).empty)
    end

    # True when the pattern has a one-pass DFA.
    def present? : Bool
      !@steps.empty?
    end

    # Writes the groups of the match *start*...*finish* into the
    # *slot_count* words at *slots*; returns false when no path reads the
    # span (the caller then runs the Pike VM).
    def captures(bytes : Bytes, start : Int32, finish : Int32, search_start : Int32, classes : Pointer(UInt8),
                 slots : Pointer(Int32), slot_count : Int32, meter : StaticMeter) : Bool
      slot_count.times { |index| slots[index] = -1 }
      steps = @steps.to_unsafe
      row = 0
      at = start
      charged = start
      allowed_end = start
      while at < finish
        if at >= allowed_end
          meter.charge(at - charged, at)
          charged = at
          allowed_end = at + meter.readable(Math.min(finish - at, CHUNK_BYTES), at)
        end
        bound = Math.min(finish, allowed_end)
        if @ascii_loops.unsafe_fetch(row // @class_count) != 0
          at = Core::ByteScan.skip_ascii(bytes, at, bound)
          next if at >= bound
        end
        while at < bound
          step = steps[row &+ classes[bytes.unsafe_fetch(at)]]
          break unless step >= 0 && step & 1 == 0
          at &+= 1
          if step >> 2 == row
            while at < bound && steps[row &+ classes[bytes.unsafe_fetch(at)]] == step
              at &+= 1
            end
          end
          row = step >> 2
        end
        next if at >= bound
        cell = row &+ classes[bytes.unsafe_fetch(at)]
        step = steps[cell]
        return false if step < 0
        return false unless take(@cells.unsafe_fetch(cell), bytes, at, search_start, slots)
        row = step >> 2
        at &+= 1
      end
      meter.charge(finish - charged + 1, charged)
      index = @match_edges.unsafe_fetch(row // @class_count)
      return false if index < 0
      take(index, bytes, finish, search_start, slots)
    end

    private def take(edge : Int32, bytes : Bytes, at : Int32, search_start : Int32, slots : Pointer(Int32)) : Bool
      looks = @edge_looks.unsafe_fetch(edge)
      while looks != 0
        kind = Program::LookKind.new(looks.trailing_zeros_count.to_i32)
        return false unless Look.holds?(kind, bytes, at, search_start)
        looks &= looks - 1
      end
      saved = @edge_slots.unsafe_fetch(edge)
      while saved != 0
        slots[saved.trailing_zeros_count] = at
        saved &= saved - 1
      end
      true
    end
  end
end
