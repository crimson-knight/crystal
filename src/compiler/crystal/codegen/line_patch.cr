require "./ir_skip"

module Crystal
  # Incremental rebuilds after lines move.
  #
  # Lines added to or removed from a source file move the source positions
  # of every function below them. When nothing else about a module changed,
  # its machine code is the same as in the build before and only the line
  # numbers in its debug information differ. Instead of generating and
  # compiling such a module again, an incremental build keeps the module's
  # cached object file and rewrites the line numbers in its DWARF (the line
  # program and the `DW_AT_decl_line` / `DW_AT_call_line` attributes) by
  # the amount each line moved (see `LinePatch::ObjectPatcher`).
  #
  # How lines moved is known per file: the manifest of the build before
  # (`IrSkip::Manifest`) keeps a hash of every line of every source file,
  # and a diff with the files as they are now gives a `LineMap` (old line
  # to new line) for each file that changed. A function qualifies when its
  # code key matches the build before and its source positions, mapped back
  # through those maps, give the line key the build before recorded
  # (`IrSkip::Walk#mapped_line_key`): every position moved with the lines
  # around it, and no column changed. A module qualifies when every one of
  # its functions matched or qualifies. Anything else (a position inside
  # the edited lines, a relative move inside a function, a changed column,
  # an object the patcher does not understand) regenerates the module as
  # before.
  #
  # `CRYSTAL_LINE_PATCH=0` turns this off. `CRYSTAL_LINE_PATCH_VERIFY=1`
  # generates and compiles every patched module as well, and fails the build
  # when the fresh object's debug lines or machine code differ from the
  # patched one (see `LinePatch::Verification`).
  module LinePatch
    # Diffs of larger files or with more edits than this give no map: the
    # lines of such a file count as moved in unknown ways.
    MAXIMUM_EDIT_DISTANCE = 4000

    # The hash of each line of a source file.
    def self.line_hashes(text : String) : Array(UInt64)
      list_of_hashes = [] of UInt64
      text.each_line(chomp: false) do |line|
        list_of_hashes << IrSkip::Hasher.digest_of(line).first
      end
      list_of_hashes
    end

    # How the lines of one file moved: runs of lines that are the same in
    # the old and the new text. A line outside every run was edited, added
    # or removed. Lines count from 1.
    class LineMap
      record Run, old_start : Int32, new_start : Int32, size : Int32

      getter list_of_runs : Array(Run)

      def initialize(@list_of_runs)
      end

      # The new line of old line *line*, or `nil` when that line was edited
      # or removed. Line 0 (no line) stays 0.
      def map?(line : Int32) : Int32?
        return 0 if line == 0
        run = find_run(line) { |candidate| candidate.old_start }
        return nil unless run && line < run.old_start + run.size

        line - run.old_start + run.new_start
      end

      # The old line of new line *line*, or `nil` when that line is new or
      # edited.
      def unmap?(line : Int32) : Int32?
        return 0 if line == 0
        run = find_run(line) { |candidate| candidate.new_start }
        return nil unless run && line < run.new_start + run.size

        line - run.new_start + run.old_start
      end

      # The last run that starts at or before *line* by *start*.
      private def find_run(line : Int32, & : Run -> Int32) : Run?
        index = @list_of_runs.bsearch_index { |run| yield(run) > line }
        index = index ? index - 1 : @list_of_runs.size - 1
        index >= 0 ? @list_of_runs[index] : nil
      end

      # A digest of the map, for the hash of a patched object.
      def digest : IrSkip::Digest
        hasher = IrSkip::Hasher.new
        @list_of_runs.each do |run|
          hasher.mix(run.old_start)
          hasher.mix(run.new_start)
          hasher.mix(run.size)
        end
        hasher.digest
      end

      # The map between *list_of_old* and *list_of_new* line hashes, or `nil`
      # when they differ in more than `MAXIMUM_EDIT_DISTANCE` lines.
      def self.diff(list_of_old : Array(UInt64), list_of_new : Array(UInt64)) : LineMap?
        old_size = list_of_old.size
        new_size = list_of_new.size
        prefix = 0
        while prefix < old_size && prefix < new_size && list_of_old[prefix] == list_of_new[prefix]
          prefix += 1
        end
        suffix = 0
        while suffix < old_size - prefix && suffix < new_size - prefix &&
              list_of_old[old_size - 1 - suffix] == list_of_new[new_size - 1 - suffix]
          suffix += 1
        end

        list_of_pairs = Myers.matches(list_of_old, prefix, old_size - suffix, list_of_new, prefix, new_size - suffix, MAXIMUM_EDIT_DISTANCE)
        return nil unless list_of_pairs

        list_of_runs = [] of Run
        add = ->(old_index : Int32, new_index : Int32) do
          last = list_of_runs.last?
          if last && last.old_start + last.size == old_index + 1 && last.new_start + last.size == new_index + 1
            list_of_runs[-1] = Run.new(last.old_start, last.new_start, last.size + 1)
          else
            list_of_runs << Run.new(old_index + 1, new_index + 1, 1)
          end
        end
        prefix.times { |index| add.call(index, index) }
        list_of_pairs.each { |(old_index, new_index)| add.call(old_index, new_index) }
        suffix.times do |offset|
          add.call(old_size - suffix + offset, new_size - suffix + offset)
        end
        # A text whose last line has no newline: the line after it (where a
        # file's end position can point) moves with it.
        LineMap.new(list_of_runs)
      end
    end

    # Myers' diff (O((N+M)D)), for the matching lines of two ranges.
    module Myers
      # The pairs of indexes of equal lines in a longest common subsequence
      # of `old[old_start...old_end]` and `new[new_start...new_end]`, in
      # order, or `nil` when more than *limit* lines differ.
      def self.matches(list_of_old : Array(UInt64), old_start : Int32, old_end : Int32,
                       list_of_new : Array(UInt64), new_start : Int32, new_end : Int32,
                       limit : Int32) : Array({Int32, Int32})?
        old_count = old_end - old_start
        new_count = new_end - new_start
        return [] of {Int32, Int32} if old_count == 0 || new_count == 0
        maximum_edits = Math.min(old_count + new_count, limit)
        offset = maximum_edits + 1
        # For each diagonal (old index minus new index), the furthest old index
        # reached with the current number of edits.
        furthest_by_diagonal = Array(Int32).new(2 * maximum_edits + 3, 0)
        list_of_snapshots = [] of Array(Int32)
        found = false
        (0..maximum_edits).each do |edit_count|
          list_of_snapshots << furthest_by_diagonal.dup
          diagonal = -edit_count
          while diagonal <= edit_count
            old_index = if diagonal == -edit_count || (diagonal != edit_count && furthest_by_diagonal[offset + diagonal - 1] < furthest_by_diagonal[offset + diagonal + 1])
                          furthest_by_diagonal[offset + diagonal + 1]
                        else
                          furthest_by_diagonal[offset + diagonal - 1] + 1
                        end
            new_index = old_index - diagonal
            while old_index < old_count && new_index < new_count && list_of_old[old_start + old_index] == list_of_new[new_start + new_index]
              old_index += 1
              new_index += 1
            end
            furthest_by_diagonal[offset + diagonal] = old_index
            if old_index >= old_count && new_index >= new_count
              found = true
              break
            end
            diagonal += 2
          end
          break if found
        end
        return nil unless found

        # Walk back through the snapshots for the runs of equal lines.
        list_of_pairs = [] of {Int32, Int32}
        old_index = old_count
        new_index = new_count
        (list_of_snapshots.size - 1).downto(0) do |edit_count|
          snapshot = list_of_snapshots[edit_count]
          diagonal = old_index - new_index
          previous_diagonal = if diagonal == -edit_count || (diagonal != edit_count && snapshot[offset + diagonal - 1] < snapshot[offset + diagonal + 1])
                                diagonal + 1
                              else
                                diagonal - 1
                              end
          previous_old_index = edit_count == 0 ? 0 : snapshot[offset + previous_diagonal]
          previous_new_index = edit_count == 0 ? 0 : previous_old_index - previous_diagonal
          while old_index > previous_old_index && new_index > previous_new_index
            old_index -= 1
            new_index -= 1
            list_of_pairs << {old_start + old_index, new_start + new_index}
          end
          break if edit_count == 0
          old_index = previous_old_index
          new_index = previous_new_index
        end
        list_of_pairs.reverse!
      end
    end

    # The line maps of one build: for each source file that changed since
    # the build before, how its lines moved. A file without a map is the
    # same as before (or was not recorded, which makes every position in it
    # count as unmoved: a moved one then fails to match).
    class Maps
      getter maps_by_filename : Hash(String, LineMap?)

      def initialize(@maps_by_filename = {} of String => LineMap?)
      end

      def empty? : Bool
        @maps_by_filename.empty?
      end

      # Whether *filename* changed.
      def changed?(filename : String) : Bool
        @maps_by_filename.has_key?(filename)
      end

      # The map of a changed *filename*: `nil` for a file whose lines moved
      # in unknown ways.
      def map_of?(filename : String) : LineMap?
        @maps_by_filename[filename]?
      end

      # A digest of every map, for the hash of a patched object.
      def digest : IrSkip::Digest
        hasher = IrSkip::Hasher.new
        @maps_by_filename.keys.sort!.each do |filename|
          hasher.mix(filename)
          if map = @maps_by_filename[filename]
            hasher.mix(map.digest)
          else
            hasher.mix(nil)
          end
        end
        hasher.digest
      end

      # Compares the recorded line hashes of the build before with the source
      # files of this build.
      def self.compute(previous : Hash(String, Array(UInt64)), current : Hash(String, Array(UInt64))) : Maps
        maps_by_filename = {} of String => LineMap?
        previous.each do |filename, list_of_old|
          list_of_new = current[filename]?
          next if list_of_new == list_of_old
          maps_by_filename[filename] = list_of_new ? LineMap.diff(list_of_old, list_of_new) : nil
        end
        Maps.new(maps_by_filename)
      end
    end

    # The line hashes of every source file in *list_of_filenames* that can
    # be read.
    def self.read_source_lines(list_of_filenames : Enumerable(String)) : Hash(String, Array(UInt64))
      lines_by_filename = {} of String => Array(UInt64)
      list_of_filenames.each do |filename|
        next unless File.file?(filename)
        lines_by_filename[filename] = line_hashes(File.read(filename))
      rescue IO::Error
        # A file that cannot be read has no map: its positions must not move.
      end
      lines_by_filename
    end
  end
end
