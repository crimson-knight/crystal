require "./mica/regex"

# :nodoc:
#
# The `Regex` engine behind `-Duse_mica`: Mica's pure-Crystal engine, whose
# searches run in time linear in the haystack under a work allowance, and
# which links no C regex library. See `doc/regex_mica.md`.
module Regex::MicaEngine
  # The PCRE2 release whose syntax Mica's Crystal dialect reads.
  PCRE2_DIALECT_VERSION = {10, 49}

  # Compile limits for every pattern: Crystal programs compile patterns they
  # wrote, so the trusted preset applies (64 KiB of pattern, a million
  # program states).
  COMPILE_LIMITS = Regex::Mica::Regex::CompileLimits::TRUSTED_PATTERN

  # Search limits for every match: the allowance grows with the haystack and
  # the program, up to 10^9 operations per call. Running out raises
  # `Regex::Error`, as PCRE2's match limit does.
  SEARCH_LIMITS = Regex::Mica::Regex::SearchLimits::TRUSTED_INPUT

  @expression : Regex::Mica::Regex::Expression

  def self.version : String
    "Mica #{Regex::Mica::VERSION} (PCRE2 #{PCRE2_DIALECT_VERSION.join('.')} dialect)"
  end

  # Mica reads patterns as PCRE2 10.49 does, so feature checks written
  # against PCRE2 versions see that version.
  def self.version_number : {Int32, Int32}
    PCRE2_DIALECT_VERSION
  end

  # :nodoc:
  def initialize(*, _source @source : String, _options @options)
    # PCRE2 leaves invalid UTF-8 in a pattern compiled with NO_UTF_CHECK
    # undefined; Mica reads each invalid byte as U+FFFD.
    source = source.scrub if options.no_utf_check?
    @expression = MicaEngine.compile(source, MicaEngine.compile_options(options)) do |error|
      raise error
    end
  end

  protected def self.compile(source : String, options : Regex::Mica::Regex::CompileOptions, & : ArgumentError -> _) : Regex::Mica::Regex::Expression
    Regex::Mica::Regex::Expression.new(source, options, compile_limits: COMPILE_LIMITS)
  rescue error : Regex::Mica::Regex::UnsupportedConstructError
    yield Regex::UnsupportedSyntaxError.new(error.construct, error.byte_offset.to_i32)
  rescue error : Regex::Mica::EncodingError
    yield ArgumentError.new("UTF-8 error: #{error.detail} at #{error.byte_offset}")
  rescue error : Regex::Mica::ParseError
    if source.valid_encoding?
      yield ArgumentError.new("#{error.detail} at #{error.byte_offset}")
    else
      yield ArgumentError.new("UTF-8 error: #{error.detail} at #{error.byte_offset}")
    end
  end

  protected def self.compile_options(options : Regex::CompileOptions) : Regex::Mica::Regex::CompileOptions
    flags = Regex::Mica::Regex::CompileOptions::None
    Regex::CompileOptions.each do |option|
      next unless options.includes?(option)
      flags |= case option
               when .ignore_case?    then Regex::Mica::Regex::CompileOptions::IgnoreCase
               when .multiline?      then Regex::Mica::Regex::CompileOptions::Multiline | Regex::Mica::Regex::CompileOptions::DotAll
               when .multiline_only? then Regex::Mica::Regex::CompileOptions::Multiline
               when .dotall?         then Regex::Mica::Regex::CompileOptions::DotAll
               when .extended?       then Regex::Mica::Regex::CompileOptions::Extended
               when .anchored?       then Regex::Mica::Regex::CompileOptions::Anchored
               when .dollar_endonly? then Regex::Mica::Regex::CompileOptions::DollarEndOnly
               when .firstline?      then Regex::Mica::Regex::CompileOptions::FirstLine
               when .endanchored?    then Regex::Mica::Regex::CompileOptions::EndAnchored
               when .utf_8?, .dupnames?, .ucp?
                 # Mica always reads patterns as UTF-8 with Unicode
                 # properties and duplicate names allowed.
                 Regex::Mica::Regex::CompileOptions::None
               when .no_utf_check?
                 # Mica validates every haystack as it reads it; skipping the
                 # check is not offered.
                 Regex::Mica::Regex::CompileOptions::None
               when .match_invalid_utf?
                 raise ArgumentError.new("Regex option MATCH_INVALID_UTF is not supported by the Mica engine")
               else
                 raise "Unreachable"
               end
      options &= ~option
    end
    unless options.none?
      raise ArgumentError.new("Unknown Regex::Option value: #{options}")
    end
    flags
  end

  def self.supports_compile_flag?(options)
    !options.match_invalid_utf?
  end

  private def mica_match_options(options : Regex::Options) : Regex::Mica::Regex::MatchOptions
    flags = Regex::Mica::Regex::MatchOptions::None
    Regex::Options.each do |option|
      next unless options.includes?(option)
      flags |= case option
               when .anchored?     then Regex::Mica::Regex::MatchOptions::Anchored
               when .endanchored?  then Regex::Mica::Regex::MatchOptions::EndAnchored
               when .no_utf_check? then Regex::Mica::Regex::MatchOptions::None
               else
                 raise ArgumentError.new("Invalid regex option #{option} for `match`")
               end
      options &= ~option
    end
    unless options.none?
      raise ArgumentError.new("Unknown Regex::Option value: #{options}")
    end
    flags
  end

  private def mica_match_options(options : Regex::MatchOptions) : Regex::Mica::Regex::MatchOptions
    flags = Regex::Mica::Regex::MatchOptions::None
    Regex::MatchOptions.each do |option|
      next unless options.includes?(option)
      flags |= case option
               when .anchored?     then Regex::Mica::Regex::MatchOptions::Anchored
               when .endanchored?  then Regex::Mica::Regex::MatchOptions::EndAnchored
               when .no_jit?       then Regex::Mica::Regex::MatchOptions::None
               when .no_utf_check? then Regex::Mica::Regex::MatchOptions::None
               else
                 raise "Unreachable"
               end
      options &= ~option
    end
    unless options.none?
      raise ArgumentError.new("Unknown Regex::MatchOption value: #{options}")
    end
    flags
  end

  def self.supports_match_flag?(options)
    true
  end

  protected def self.error_impl(source)
    compile(source, Regex::Mica::Regex::CompileOptions::None) { |error| return error.message }
    nil
  end

  private def name_table_impl
    @expression.name_table
  end

  # Yields each named group's number and name in PCRE2 name-table order
  # (sorted by name, duplicates of a name in pattern order).
  def each_named_capture_group(& : Int32, String ->) : Nil
    @expression.list_of_name_entries.each do |entry|
      yield entry.capture_index, entry.group_name
    end
  end

  private def capture_count_impl
    @expression.capture_count
  end

  private def match_impl(str, byte_index, options)
    MicaEngine.check_byte_index(str, byte_index)
    mica_options = mica_match_options(options)
    ovector = MicaEngine.run_search do
      if skip_utf_check?(options) && !str.valid_encoding?
        MicaEngine.each_valid_run(str, byte_index) do |haystack, start, shift|
          if offsets = find_offsets(haystack, start, mica_options)
            break MicaEngine.shift_offsets(offsets, capture_count_impl &+ 1, shift)
          end
        end
      else
        find_offsets(str, byte_index, mica_options)
      end
    end
    return unless ovector

    ::Regex::MatchData.new(self, str, byte_index, ovector, capture_count_impl)
  end

  private def matches_impl(str, byte_index, options)
    MicaEngine.check_byte_index(str, byte_index)
    mica_options = mica_match_options(options)
    found = MicaEngine.run_search do
      if skip_utf_check?(options) && !str.valid_encoding?
        MicaEngine.each_valid_run(str, byte_index) do |haystack, start|
          break true if @expression.matches_at_byte_index?(haystack, start, mica_options, limits: SEARCH_LIMITS)
        end
      else
        @expression.matches_at_byte_index?(str, byte_index, mica_options, limits: SEARCH_LIMITS)
      end
    end
    found || false
  end

  # Searches *haystack* from *byte_index* and returns the offsets of every
  # group as PCRE2's ovector holds them (begin and end pairs, -1 for a group
  # that did not take part), or nil.
  private def find_offsets(haystack : String, byte_index : Int32, options : Regex::Mica::Regex::MatchOptions) : Int32*?
    @expression.search_groups(haystack, byte_index, options, limits: SEARCH_LIMITS) do |groups|
      offsets = Pointer(Int32).malloc(groups.size &* 2)
      groups.size.times do |group|
        if groups.matched?(group)
          offsets[group &* 2] = groups.byte_begin(group)
          offsets[group &* 2 &+ 1] = groups.byte_end(group)
        else
          offsets[group &* 2] = -1
          offsets[group &* 2 &+ 1] = -1
        end
      end
      offsets
    end
  end

  private def skip_utf_check?(options) : Bool
    @options.no_utf_check? || options.no_utf_check?
  end

  # PCRE2 refuses a start offset inside a character with this message.
  protected def self.check_byte_index(str : String, byte_index : Int32) : Nil
    if 0 < byte_index < str.bytesize && str.to_unsafe[byte_index] & 0xC0 == 0x80
      raise ArgumentError.new("Regex match error: bad offset into UTF string")
    end
  end

  # PCRE2 leaves a search of invalid UTF-8 under NO_UTF_CHECK undefined.
  # Mica validates every haystack, so such a search runs over each run of
  # valid UTF-8 at or after *byte_index* in turn, and invalid bytes never
  # match. Yields each run as its own haystack, the byte index to start
  # from in it, and the shift that maps its offsets back to *str*. A run
  # after invalid bytes starts with one U+0001 of context, so `^`, `\A`
  # and `\b` see a non-word character before it, as they would see the
  # invalid byte; `$` and `\z` can still match at the end of a run.
  protected def self.each_valid_run(str : String, byte_index : Int32, & : String, Int32, Int32 ->) : Nil
    reader = Char::Reader.new(str)
    while true
      run_begin = reader.pos
      while reader.has_next? && reader.error.nil?
        reader.next_char
      end
      run_end = reader.pos
      if run_end >= byte_index
        context = run_begin == 0 ? "" : "\u0001"
        haystack = context + str.byte_slice(run_begin, run_end &- run_begin)
        shift = run_begin &- context.bytesize
        yield haystack, Math.max(byte_index, run_begin) &- shift, shift
      end
      break unless reader.has_next?
      while reader.has_next? && reader.error
        reader.next_char
      end
    end
  end

  protected def self.shift_offsets(offsets : Int32*, group_count : Int32, shift : Int32) : Int32*
    (group_count &* 2).times do |index|
      offsets[index] &+= shift unless offsets[index] < 0
    end
    offsets
  end

  # Runs one search and turns Mica's errors into the ones `Regex` documents:
  # invalid UTF-8 in the haystack is an `ArgumentError`, as with PCRE2, and
  # a search that runs out of its work allowance is a `Regex::Error`, as
  # PCRE2's match limit is.
  protected def self.run_search(&)
    yield
  rescue error : Regex::Mica::EncodingError
    raise ArgumentError.new("Regex match error: UTF-8 error: #{error.detail} at #{error.byte_offset}")
  rescue error : Regex::Mica::LimitExceededError
    raise Regex::Error.new("Regex match error: #{error.message}")
  end

  module MatchData
    # :nodoc:
    def initialize(@regex : Regex, @string : String, @pos : Int32, @ovector : Int32*, @group_size : Int32)
    end

    private def byte_range(n, &)
      n += size if n < 0
      byte_begin = @ovector[n &* 2]
      byte_end = @ovector[n &* 2 &+ 1]
      if byte_begin < 0 || byte_end < 0
        yield n
      else
        Range.new(byte_begin, byte_end, exclusive: true)
      end
    end

    # Resolves a duplicate name as Crystal's PCRE2 binding does.
    private def fetch_impl(group_name : String, &)
      selected_range = nil
      exists = false
      @regex.each_named_capture_group do |number, name|
        next unless name == group_name
        exists = true
        range = byte_range(number) { nil }
        if (range && selected_range && range.begin > selected_range.begin) || !selected_range
          selected_range = range
        end
      end

      if selected_range
        @string.byte_slice(selected_range.begin, selected_range.end - selected_range.begin)
      else
        yield exists
      end
    end
  end
end

class Regex
  # Raised by `Regex.new` under the Mica engine (`-Duse_mica`) for a pattern
  # that is valid PCRE2 but uses a construct Mica leaves out (backreferences,
  # lookaround, atomic groups, recursion, conditionals, `\K`, verbs). It is an
  # `ArgumentError`, like every other pattern `Regex.new` cannot compile.
  class UnsupportedSyntaxError < ArgumentError
    # The construct, for example `"lookahead"`.
    getter construct : String

    # The byte offset in the pattern where the construct starts.
    getter byte_offset : Int32

    def initialize(@construct : String, @byte_offset : Int32)
      super("#{@construct} is not supported by the Mica regex engine at #{@byte_offset} (see doc/regex_mica.md)")
    end
  end
end
