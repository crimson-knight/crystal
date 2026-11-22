module Regex::Mica::Regex
  # :nodoc:
  # Up to `StartFilter::MAX_REQUIRED_BYTES` ASCII bytes every match of a
  # program contains, rarest first, held in one word: the bytes in its low
  # three bytes, in order, and their count above them. A program keeps
  # them in an atomic field, so finding them asks the collector for
  # nothing.
  #
  # ```
  # bytes = Mica::Regex::RequiredBytes::NONE.with('y'.ord.to_u8)
  # bytes.size # => 1
  # bytes[0]   # => 121
  # ```
  struct RequiredBytes
    include Indexable(UInt8)

    # No required byte.
    NONE = new(0_u64)
    # The word an atomic field holds before the bytes are found (its
    # count is one no set of bytes has).
    NOT_FOUND = UInt64::MAX

    getter packed : UInt64

    def initialize(@packed : UInt64)
    end

    def size : Int32
      (@packed >> 24).to_i32
    end

    @[AlwaysInline]
    def unsafe_fetch(index : Int) : UInt8
      (@packed >> (index * 8)).to_u8!
    end

    # These bytes followed by *byte*; they hold fewer than
    # `StartFilter::MAX_REQUIRED_BYTES`.
    def with(byte : UInt8) : RequiredBytes
      count = size
      RequiredBytes.new((@packed & 0x00FF_FFFF_u64) | (byte.to_u64 << (count * 8)) | ((count + 1).to_u64 << 24))
    end
  end

  # What a match of a `Program` needs before any engine runs: the fewest
  # bytes it can span, and the bytes it can start with. `Expression` reads
  # it to answer a search over a short haystack that cannot match without
  # taking a lease or starting an engine (see "Short searches" in
  # docs/regex.md).
  #
  # It also holds up to `MAX_REQUIRED_BYTES` ASCII bytes every match
  # contains (`:` in `.*:(\d+)`, `y` and `x` in `(x+x+)+y`).
  #
  # All are read from the NFA, with every assertion taken as passing, so
  # they over-approximate the matches: a haystack the filter rejects has no
  # match, and one it accepts may or may not.
  #
  # ```
  # filter = Mica::Regex::Expression.new("\\d+px", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  #   .program.plan.start_filter
  # filter.minimum_bytes                        # => 3
  # filter.rejects?("12px".to_slice, 0, false)  # => false
  # filter.rejects?("ab px".to_slice, 0, false) # => true
  # ```
  class StartFilter
    # The fewest bytes a match spans (0 when it can be empty).
    getter minimum_bytes : Int32
    # ASCII bytes every match contains, rarest first (at most
    # `MAX_REQUIRED_BYTES`).
    getter list_of_required_bytes : RequiredBytes = RequiredBytes::NONE
    # One bit per byte value that can start a non-empty match.
    @start_bytes = StaticArray(UInt64, 4).new(0_u64)
    # The same bits one byte per value, for scans that test every byte
    # (`starts?`): one load and no shift.
    # Cleared with one `memset` in `initialize` (`StaticArray.new(false)`
    # writes it a byte at a time, on every program's first search).
    @start_table : StaticArray(Bool, 256)
    # One bit per byte value a match can have second, when every match
    # spans at least two bytes; all set otherwise (see `second?`).
    @second_bytes = StaticArray(UInt64, 4).new(UInt64::MAX)
    # True once `prepare_second_bytes` filled `@second_bytes`.
    @second_ready = Atomic(Bool).new(false)

    # The most single-byte states `required_byte` considers.
    MAX_REQUIRED_CANDIDATES = 8
    # The most required bytes kept.
    MAX_REQUIRED_BYTES = 3

    # The one byte every match starts with, or -1.
    @single_start = -1

    def initialize(program : Program)
      @start_table = uninitialized StaticArray(Bool, 256)
      pointerof(@start_table).clear
      @minimum_bytes = StartFilter.shortest_match(program)
      return unless @minimum_bytes > 0
      collect_start_bytes(program)
      @list_of_required_bytes = program.list_of_required_bytes
      count = @start_bytes.sum(&.popcount)
      @single_start = @start_table.index(true) || -1 if count == 1
    end

    # True when no match can start in *haystack* at *from* (or, unless
    # *anchored*, after it): fewer than `minimum_bytes` bytes remain, or no
    # byte where a match could start is one a match starts with. Reads at
    # most the bytes from *from* on.
    def rejects?(haystack : Bytes, from : Int32, anchored : Bool) : Bool
      last = haystack.size - @minimum_bytes
      return true if from > last
      return false if @minimum_bytes == 0
      last = from if anchored
      return true if next_start(haystack, from, last) < 0
      return !holds_required_words?(haystack, from) if haystack.size - from <= SHORT_SCAN_BYTES
      @list_of_required_bytes.any? { |byte| !StartFilter.holds_byte?(haystack, from, byte) }
    end

    # The longest span from *from* `holds_required_words?` reads in place
    # of a `memchr` per required byte.
    SHORT_SCAN_BYTES = 64

    # True when *haystack* from *from* (at most `SHORT_SCAN_BYTES` bytes
    # on) holds every required byte. A span of eight bytes or more is read
    # a word at a time, the last word where the span ends (overlapping the
    # one before), and a word holds a byte when the word XOR the byte in
    # every lane has a zero lane (`(v - 0x01..) & ~v & 0x80..`, exact for
    # "some lane is zero"). Over a one-line haystack this costs a few
    # cycles per required byte, where a `memchr` call per byte costs more
    # than the scan. Reads no byte before *from*.
    private def holds_required_words?(haystack : Bytes, from : Int32) : Bool
      remaining = haystack.size - from
      pointer = haystack.to_unsafe + from
      @list_of_required_bytes.each do |byte|
        if remaining < 8
          return false unless (0...remaining).any? { |index| pointer[index] == byte }
          next
        end
        lanes = 0x0101010101010101_u64 &* byte
        found = StartFilter.zero_lanes((pointer + remaining - 8).as(UInt64*).value ^ lanes)
        index = 0
        while index + 8 < remaining
          found |= StartFilter.zero_lanes((pointer + index).as(UInt64*).value ^ lanes)
          index += 8
        end
        return false if found == 0
      end
      true
    end

    # The high bit of each lane of *word* that is zero, and possibly of
    # lanes above one (nonzero exactly when some lane is zero).
    @[AlwaysInline]
    protected def self.zero_lanes(word : UInt64) : UInt64
      (word &- 0x0101010101010101_u64) & ~word & 0x8080808080808080_u64
    end

    # True when *haystack* holds *byte* at *from* or after (`memchr`).
    @[AlwaysInline]
    protected def self.holds_byte?(haystack : Bytes, from : Int32, byte : UInt8) : Bool
      return false if from >= haystack.size
      !LibC.memchr(haystack.to_unsafe + from, byte.to_i32, haystack.size - from).null?
    end

    # The most bytes `rejects?` reads from *from* in a haystack of
    # *haystack_size* bytes: the start scan, then one scan per required
    # byte. A caller with a work allowance checks it before the scans run.
    def scan_work(haystack_size : Int32, from : Int32) : Int32
      remaining = Math.max(haystack_size - from, 0)
      remaining * (1 + @list_of_required_bytes.size)
    end

    # The first position from *from* through *last* where a match may
    # start (the byte there is one a match starts with, and at least
    # `minimum_bytes` bytes remain), or -1. Uses `memchr` when matches
    # start with one byte.
    def next_start(haystack : Bytes, from : Int32, last : Int32 = Int32::MAX) : Int32
      last = Math.min(last, haystack.size - @minimum_bytes)
      return -1 if from > last
      return from if @minimum_bytes == 0
      # One position (an anchored search): one load, no call.
      return starts?(haystack[from]) ? from : -1 if from == last
      if @single_start >= 0
        found = LibC.memchr(haystack.to_unsafe + from, @single_start, last + 1 - from)
        return found.null? ? -1 : (found.as(UInt8*) - haystack.to_unsafe).to_i32
      end
      (from..last).each { |index| return index if starts?(haystack.unsafe_fetch(index)) }
      -1
    end

    # The rarest ASCII bytes (by `Prefilter.rank`, at most
    # `MAX_REQUIRED_BYTES`) that every path from the start state to the
    # match state reads in a state (or a sparse transition) that reads
    # only that byte. The `MAX_REQUIRED_CANDIDATES` rarest such bytes are
    # tried together: one pass marks, for each state, the candidates some
    # path from the start avoids on the way there, and a candidate the
    # match state cannot be reached without is required. A state is queued
    # again only when it gains a mark, so the pass is O(m) (each state and
    # transition read at most once per candidate, and in practice about
    # once).
    #
    # With *meter* (a first search, see
    # `Program#required_bytes_for_first_search`), the analysis charges one
    # operation for each state and transition it reads, and for each run a
    # state read looks at, at haystack byte *at*, before it reads them.
    def self.required_bytes(program : Program, meter : SearchMeter? = nil, at : Int32 = 0) : RequiredBytes
      seen = StaticArray(Bool, 128).new(false)
      # The candidates in the order the states hold them, kept sorted by
      # rank as they arrive (ties in arrival order), on the stack: there
      # are at most 128, and a program's first search pays for every
      # allocation made here.
      candidates = uninitialized StaticArray(UInt8, 128)
      ranks = uninitialized StaticArray(Int32, 128)
      candidate_count = 0
      program.each_distinct_state do |state, _|
        meter.charge(1, at) if meter
        next unless state.kind.byte_range? && state.low == state.high && state.low < 0x80
        next if seen[state.low]
        seen[state.low] = true
        rank = Prefilter.rank(state.low)
        place = candidate_count
        while place > 0 && ranks[place - 1] > rank
          candidates[place] = candidates[place - 1]
          ranks[place] = ranks[place - 1]
          place -= 1
        end
        candidates[place] = state.low
        ranks[place] = rank
        candidate_count += 1
      end
      list_of_required = RequiredBytes::NONE
      return list_of_required if candidate_count == 0
      list_of_candidates = candidates.to_slice[0, Math.min(candidate_count, MAX_REQUIRED_CANDIDATES)]
      avoided = avoided_on_the_way_to_a_match(program, list_of_candidates, meter, at)
      list_of_candidates.each_with_index do |byte, index|
        next if avoided.bit(index) == 1
        list_of_required = list_of_required.with(byte)
        break if list_of_required.size == MAX_REQUIRED_BYTES
      end
      list_of_required
    end

    # The candidates (bit i for `list_of_candidates[i]`) that some path from
    # the start state to a match state avoids: no state on it reads only
    # that byte.
    private def self.avoided_on_the_way_to_a_match(program : Program, list_of_candidates : Slice(UInt8),
                                                   meter : SearchMeter?, at : Int32) : UInt8
      blocking = StaticArray(UInt8, 128).new(0_u8)
      list_of_candidates.each_with_index { |byte, index| blocking[byte] = 1_u8 << index }
      # The marks and the states to visit are scratch outside the
      # collector's heap, freed when the pass ends or the meter stops it.
      marks = OffHeap.pointer(UInt8, program.state_count)
      marks.clear(program.state_count)
      list_of_pending = OffHeapList(Int32).new(INITIAL_PENDING_STATES)
      at_match = 0_u8
      begin
        list_of_pending << program.start_state
        marks[program.start_state] = ((1 << list_of_candidates.size) - 1).to_u8
        while index = list_of_pending.pop?
          here = marks[index]
          state = if meter
                    meter.charge(1, at)
                    program.state_at(index, meter, at)
                  else
                    program.state_at(index)
                  end
          case state.kind
          when .match?
            at_match |= here
          when .split?
            mark_avoided(state.next_state, here)
            mark_avoided(state.alternate, here)
          when .save?, .look?
            mark_avoided(state.next_state, here)
          when .byte_range?
            mark_avoided(state.next_state, here & ~blocked_by(blocking, state.low, state.high))
          when .sparse?
            if state.low != 0
              mark_avoided(state.next_state, past_shared_class(program, index, state, here, blocking, meter, at))
              next
            end
            state.alternate.times do |offset|
              meter.charge(1, at) if meter
              transition = program.transition_at(index, state, offset)
              mark_avoided(transition.target, here & ~blocked_by(blocking, transition.low, transition.high))
            end
          end
        end
      ensure
        OffHeap.free(marks)
        list_of_pending.free
      end
      at_match
    end

    # The states `avoided_on_the_way_to_a_match` first has room to queue.
    private INITIAL_PENDING_STATES = 32

    # Adds *bits* to *target*'s marks, queuing it when it gained one (in
    # `avoided_on_the_way_to_a_match`, whose scratch it names).
    private macro mark_avoided(target, bits)
      %target = {{target}}
      %merged = marks[%target] | {{bits}}
      unless %merged == marks[%target]
        marks[%target] = %merged
        list_of_pending << %target
      end
    end

    # The candidates of *here* still avoided once the class that *state*
    # (number *index*, a `Sparse` state reading a shared table) belongs to
    # has been read, without walking the class's states.
    #
    # Such a state is part of a large class's automaton (`ClassMemo`):
    # every path from it reads the rest of one UTF-8 sequence and leaves
    # to the state's `next_state`, the same for every state of the copy.
    # A transition that stays in the class starts a sequence of two bytes
    # or more, none of them ASCII, so that path blocks no candidate and
    # the exit keeps all of *here*; `\w` has some 350 states and 1,400
    # transitions behind its entry, which the walk would read to learn
    # the same. Otherwise every transition leaves the class at once, each
    # blocking the candidate it alone reads.
    private def self.past_shared_class(program : Program, index : Int32, state : Program::State, here : UInt8,
                                       blocking : StaticArray(UInt8, 128), meter : SearchMeter?, at : Int32) : UInt8
      avoided = 0_u8
      state.alternate.times do |offset|
        meter.charge(1, at) if meter
        transition = program.transition_at(index, state, offset)
        # A shared table's exit resolves to `next_state`; the states of
        # the copy are numbered apart from it.
        return here unless transition.target == state.next_state
        avoided |= here & ~blocked_by(blocking, transition.low, transition.high)
      end
      avoided
    end

    # The candidate bits a step reading *low*..*high* blocks: the
    # candidate's own bit when it reads that one byte only.
    @[AlwaysInline]
    private def self.blocked_by(blocking : StaticArray(UInt8, 128), low : UInt8, high : UInt8) : UInt8
      low == high && low < 0x80 ? blocking[low] : 0_u8
    end

    # True when *byte* can follow the first byte of a match (every byte
    # when a match can be shorter than two bytes). A candidate scan checks
    # it with `starts?`, so a position whose next byte no match can have
    # second is not tried (`([a-z\d])([A-Z])` over lowercase text).
    @[AlwaysInline]
    def second?(byte : UInt8) : Bool
      @second_bytes.unsafe_fetch(byte >> 6) & (1_u64 << (byte & 63)) != 0
    end

    # Fills the bits `second?` reads, once: only candidate searches read
    # it, so a program that never takes one never pays for the walk. Two
    # threads may both fill it; each writes the same bytes, and a byte a
    # reader sees before the write is still true, which only tries one
    # candidate more.
    def prepare_second_bytes(program : Program) : Nil
      return if @second_ready.get(:acquire)
      collect_second_bytes(program) if @minimum_bytes >= 2
      @second_ready.set(true, :release)
    end

    # True when a non-empty match can start with *byte*.
    @[AlwaysInline]
    def starts?(byte : UInt8) : Bool
      @start_table.unsafe_fetch(byte)
    end

    # The fewest bytes on any path from the start state to the match state:
    # a 0-1 breadth-first search, byte states weighing one and every other
    # state nothing. O(m) for m states (and their sparse transitions).
    def self.shortest_match(program : Program) : Int32
      # Scratch outside the collector's heap, for this call alone.
      distance = OffHeapList(Int32).new(program.state_count, Int32::MAX)
      deque = Deque(Int32).new
      distance[program.start_state] = 0
      deque << program.start_state
      while index = deque.shift?
        here = distance[index]
        state = program.state_at(index)
        case state.kind
        when .match?
          return here
        when .split?
          relax(distance, deque, state.next_state, here, false)
          relax(distance, deque, state.alternate, here, false)
        when .save?, .look?
          relax(distance, deque, state.next_state, here, false)
        when .byte_range?
          relax(distance, deque, state.next_state, here + 1, true)
        when .sparse?
          # A large class that holds a one-byte character is left in one
          # byte, and no path through its other states is shorter (see
          # `past_shared_class`), so they are not read.
          if state.low != 0 && leaves_shared_class_in_one_byte?(program, index, state)
            relax(distance, deque, state.next_state, here + 1, true)
            next
          end
          state.alternate.times do |offset|
            relax(distance, deque, program.transition_at(index, state, offset).target, here + 1, true)
          end
        end
      end
      Int32::MAX
    ensure
      distance.try(&.free)
    end

    # True when a transition of *state* (number *index*, a `Sparse` state
    # reading a shared table) leaves its class. At a class's entry the
    # one-byte characters are the lowest ranges, so the first transition
    # answers for a class that holds any.
    private def self.leaves_shared_class_in_one_byte?(program : Program, index : Int32, state : Program::State) : Bool
      state.alternate.times do |offset|
        return true if program.transition_at(index, state, offset).target == state.next_state
      end
      false
    end

    # Lowers *target*'s distance to *candidate* when that is shorter, at the
    # front of *deque* for a free step and at the back for a byte.
    private def self.relax(distance : OffHeapList(Int32), deque : Deque(Int32), target : Int32, candidate : Int32,
                           byte : Bool) : Nil
      return unless candidate < distance[target]
      distance[target] = candidate
      byte ? deque.push(target) : deque.unshift(target)
    end

    # Marks every byte a transition reachable from the start state without
    # reading a byte can read first.
    private def collect_start_bytes(program : Program) : Nil
      visited = Set(Int32).new
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .split?
          list_of_pending << state.next_state << state.alternate
        when .save?, .look?
          list_of_pending << state.next_state
        when .byte_range?
          mark(state.low, state.high)
        when .sparse?
          state.alternate.times do |offset|
            transition = program.transition_at(index, state, offset)
            mark(transition.low, transition.high)
          end
        end
      end
    end

    # Fills `@second_bytes` with the bytes any transition reachable after
    # exactly one byte from the start state (assertions taken as passing)
    # can read: the second byte of every match of two bytes or more.
    private def collect_second_bytes(program : Program) : Nil
      list_of_after_first = [] of Int32
      each_reading_state(program, [program.start_state]) do |index, state|
        if state.kind.byte_range?
          list_of_after_first << state.next_state
        else
          state.alternate.times { |offset| list_of_after_first << program.transition_at(index, state, offset).target }
        end
      end
      second = StaticArray(UInt64, 4).new(0_u64)
      each_reading_state(program, list_of_after_first) do |index, state|
        if state.kind.byte_range?
          (state.low..state.high).each { |byte| second[byte >> 6] |= 1_u64 << (byte & 63) }
        else
          state.alternate.times do |offset|
            transition = program.transition_at(index, state, offset)
            (transition.low..transition.high).each { |byte| second[byte >> 6] |= 1_u64 << (byte & 63) }
          end
        end
      end
      @second_bytes = second
    end

    # Yields each state that reads a byte (`ByteRange` or `Sparse`) reachable
    # from *list_of_pending* without reading one.
    private def each_reading_state(program : Program, list_of_pending : Array(Int32), & : Int32, Program::State ->) : Nil
      visited = Set(Int32).new
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .split?
          list_of_pending << state.next_state << state.alternate
        when .save?, .look?
          list_of_pending << state.next_state
        when .byte_range?, .sparse?
          yield index, state
        end
      end
    end

    private def mark(low : UInt8, high : UInt8) : Nil
      (low..high).each do |byte|
        @start_bytes[byte >> 6] |= 1_u64 << (byte & 63)
        @start_table[byte] = true
      end
    end
  end
end
