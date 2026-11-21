module Regex::Mica::Regex
  # Unicode data for classes and case folding: the property sets and the
  # simple case folding orbits of one pinned Unicode Character Database
  # version (`Tables::VERSION`), generated into `unicode/tables.cr` by
  # scripts/unicode/generate_tables.rb. The tables are read-only static data
  # in the binary, read in place: no heap, no decoding and no work at
  # program start.
  module Unicode
    # What a property name refers to, following PCRE2's property types.
    enum PropertyKind
      # A two-letter general category such as `Lu`.
      GeneralCategory
      # A one-letter general category group such as `L`.
      GeneralCategoryGroup
      # `L&` or `LC`: `Lu`, `Ll` and `Lt` together.
      LetterAmpersand
      # A script that appears in no Script_Extensions list (script only).
      Script
      # A script that appears in Script_Extensions lists; a bare name means
      # Script_Extensions, `sc:` asks for the Script property alone.
      ScriptExtensions
      # A Bidi_Class value, named `bidi<value>` or `bc:<value>`.
      BidiClass
      # A Boolean property such as `Alphabetic`.
      Boolean
      # `Any`.
      Any
      # `Xan`: letters and numbers.
      Alnum
      # `Xps` and `Xsp`: separators plus horizontal and vertical space.
      Space
      # `Xuc`: characters a universal character name can spell.
      UniversalName
      # `Xwd`: letters, numbers, `Mn` and `Pc`.
      Word
    end

    # The result of `lookup`: which set a property name selects.
    record Property, kind : PropertyKind, set_id : Int32

    # Looks up a property name from `\p{...}`. *loose* is the name as PCRE2
    # normalizes it: negation removed, ASCII letters lower-cased, and
    # spaces, hyphens, underscores and other ASCII white space dropped. It
    # may carry a `sc:`, `scx:`, `script:`, `scriptextensions:`, `bc:` or
    # `bidiclass:` prefix (the first `:` or `=` separates it). Returns nil
    # for an unknown name.
    #
    # ```
    # Mica::Regex::Unicode.lookup("greek").try(&.kind)    # => PropertyKind::ScriptExtensions
    # Mica::Regex::Unicode.lookup("sc:greek").try(&.kind) # => PropertyKind::Script
    # ```
    def self.lookup(loose : String) : Property?
      separator = loose.each_char_with_index { |char, index| break index if char == ':' || char == '=' }
      return lookup_loose(loose) unless separator
      prefix = loose[0, separator]
      value = loose[(separator + 1)..]
      case prefix
      when "bidiclass", "bc"
        entry = lookup_loose("bidi" + value)
        return entry if entry && entry.kind.bidi_class?
        nil
      when "script", "sc"
        script_property(value, script_only: true)
      when "scriptextensions", "scx"
        script_property(value, script_only: false)
      end
    end

    private def self.script_property(value : String, script_only : Bool) : Property?
      entry = property_name_entry(value)
      return nil unless entry
      kind = property_kind(entry)
      set_id = Tables::PROPERTY_NAMES[entry + 3]
      return Property.new(PropertyKind::Script, set_id) if kind.script?
      return nil unless kind.script_extensions?
      script_only ? Property.new(PropertyKind::Script, Tables::PROPERTY_NAMES[entry + 4]) : Property.new(kind, set_id)
    end

    private def self.lookup_loose(loose : String) : Property?
      entry = property_name_entry(loose)
      return nil unless entry
      Property.new(property_kind(entry), Tables::PROPERTY_NAMES[entry + 3])
    end

    # The fields of each `Tables::PROPERTY_NAMES` entry.
    private PROPERTY_NAME_FIELDS = 5

    # Returns the index in `Tables::PROPERTY_NAMES` of the entry for
    # *loose*, or nil: a binary search of the sorted names, which are
    # static data in the binary.
    private def self.property_name_entry(loose : String) : Int32?
      wanted = loose.to_slice
      text = Tables::PROPERTY_NAME_TEXT.to_slice
      entries = Tables::PROPERTY_NAMES
      low = 0
      high = Tables::PROPERTY_NAME_COUNT
      while low < high
        middle = (low + high) // 2
        entry = middle * PROPERTY_NAME_FIELDS
        order = text[entries[entry], entries[entry + 1]] <=> wanted
        return entry if order == 0
        if order < 0
          low = middle + 1
        else
          high = middle
        end
      end
      nil
    end

    private def self.property_kind(entry : Int32) : PropertyKind
      PropertyKind.from_value(Tables::PROPERTY_NAMES[entry + 2])
    end

    # Returns the number of ranges in static set *set_id*.
    def self.range_count(set_id : Int32) : Int32
      Tables::SETS[set_id * 2 + 1]
    end

    # Yields each range of static set *set_id* as `{first, last}`, in
    # order.
    def self.each_range(set_id : Int32, & : Int32, Int32 ->) : Nil
      bounds = decoded_ranges(set_id)
      (bounds.size // 2).times { |index| yield bounds[index * 2], bounds[index * 2 + 1] }
    end

    # Returns the ranges of static set *set_id* as `first, last` pairs: a
    # read-only view of the generated table, which is static data in the
    # binary, so reading a set allocates nothing and decodes nothing.
    def self.decoded_ranges(set_id : Int32) : Slice(Int32)
      Tables::RANGES[Tables::SETS[set_id * 2] * 2, range_count(set_id) * 2]
    end

    # Returns true when *code_point* is in static set *set_id* (a binary
    # search).
    def self.includes?(set_id : Int32, code_point : Int32) : Bool
      bounds = decoded_ranges(set_id)
      low = 0
      high = bounds.size // 2
      while low < high
        middle = (low + high) // 2
        if bounds[middle * 2 + 1] < code_point
          low = middle + 1
        elsif bounds[middle * 2] > code_point
          high = middle
        else
          return true
        end
      end
      false
    end

    # Calls the block with every other member of *code_point*'s simple case
    # folding orbit (at most `Tables::LARGEST_ORBIT - 1` of them).
    def self.each_fold_partner(code_point : Int32, & : Int32 ->) : Nil
      index = fold_index_at_or_after(code_point)
      return if index >= fold_entry_count
      entries = Tables::FOLD_ORBITS
      return unless entries[index * 2] == code_point
      partner = entries[index * 2 + 1]
      steps = 0
      while partner != code_point && steps < Tables::LARGEST_ORBIT
        yield partner
        partner = entries[fold_index_at_or_after(partner) * 2 + 1]
        steps += 1
      end
    end

    # The first code point past ASCII.
    ASCII_END = 0x80

    # Calls the block with every other member of ASCII *code_point*'s
    # simple case folding orbit, as `each_fold_partner` does, and returns
    # true when it has any, without reading the tables: a letter folds
    # with its other case, `k` and `K` with U+212A KELVIN SIGN, `s` and `S`
    # with U+017F LATIN SMALL LETTER LONG S, and no other ASCII code point
    # folds (a spec checks each of the 128 against `FOLD_ORBITS`).
    @[AlwaysInline]
    def self.each_ascii_fold_partner(code_point : Int32, & : Int32 ->) : Bool
      lower = code_point | 0x20
      return false unless 0x61 <= lower <= 0x7A
      yield code_point ^ 0x20
      yield 0x212A if lower == 0x6B
      yield 0x17F if lower == 0x73
      true
    end

    # Calls the block with each code point in *first*..*last* that has fold
    # partners, in order, and returns the number of such code points
    # visited (the work done).
    def self.each_folding_code_point(first : Int32, last : Int32, & : Int32 ->) : Int32
      index = fold_index_at_or_after(first)
      entries = Tables::FOLD_ORBITS
      visited = 0
      while index < fold_entry_count
        code_point = entries[index * 2]
        break if code_point > last
        yield code_point
        visited += 1
        index += 1
      end
      visited
    end

    # Returns the number of code points in *first*..*last* that have fold
    # partners, without visiting them (two binary searches).
    def self.folding_code_point_count(first : Int32, last : Int32) : Int32
      fold_index_at_or_after(last + 1) - fold_index_at_or_after(first)
    end

    private def self.fold_entry_count : Int32
      Tables::FOLD_ORBITS.size // 2
    end

    private def self.fold_index_at_or_after(code_point : Int32) : Int32
      entries = Tables::FOLD_ORBITS
      low = 0
      high = entries.size // 2
      while low < high
        middle = (low + high) // 2
        if entries.unsafe_fetch(middle * 2) < code_point
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end
  end
end

require "./unicode/tables"
