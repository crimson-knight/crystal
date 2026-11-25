require "regex/mica/regex"

module Crystal
  # :nodoc:
  #
  # Checks regex literals of a program that runs `Regex` on Mica (the default
  # engine; see `Program#uses_mica_regex_engine?`) against Mica's dialect, so
  # a literal Mica cannot run is a compile error
  # instead of an exception the first time the literal is used. See
  # `doc/regex_mica.md`.
  module MicaRegexLiteral
    # A source file inside a shards install directory: *shard_name* is the
    # directory under `lib/`, and *path* starts at that `lib/`.
    record ShardFile, shard_name : String, path : String

    # Returns why Mica cannot compile *source* with the literal's *options*,
    # or nil. When *filename* (the literal's file) lives in a shard, the
    # message names the shard and how to upgrade it.
    def self.error?(source : String, options : Regex::CompileOptions, filename : String? = nil) : String?
      Regex::Mica::Regex::Syntax.check(source, dialect: :crystal,
        compile_limits: Regex::Mica::Regex::CompileLimits::TRUSTED_PATTERN,
        options: mica_options(options))
      nil
    rescue error : Regex::Mica::Regex::UnsupportedConstructError
      unsupported = "#{error.construct} (at #{error.byte_offset}) is not supported."
      if shard_file = shard_file?(filename)
        "#{unsupported} #{shard_advice(shard_file)}"
      else
        "#{unsupported} Build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites."
      end
    rescue error : Regex::Mica::ParseError
      detail = "#{error.detail} at #{error.byte_offset}"
      if shard_file = shard_file?(filename)
        "#{detail}. #{shard_advice(shard_file)}"
      else
        detail
      end
    end

    # Returns the shard that *filename* belongs to, or nil for the app's own
    # code. A shard's files sit under a `lib/<shard>/` segment; when the path
    # has several (a shard vendored inside another), the innermost one wins.
    def self.shard_file?(filename : String?) : ShardFile?
      return unless filename

      parts = ::Path.new(filename).parts
      last_possible_lib = parts.size - 3
      return if last_possible_lib < 0

      lib_index = parts.rindex(last_possible_lib) { |part| part == "lib" }
      return unless lib_index

      ShardFile.new(parts[lib_index + 1], parts[lib_index..].join('/'))
    end

    private def self.shard_advice(shard_file : ShardFile) : String
      shard_name = shard_file.shard_name
      "The pattern is in the shard '#{shard_name}' (#{shard_file.path}). " \
      "Upgrade #{shard_name} to a release built for Mica (update its pin in shard.yml, then run shards update #{shard_name}), " \
      "or build with -Duse_pcre2 to run this pattern on PCRE2. See doc/regex_mica.md for rewrites."
    end

    private def self.mica_options(options : Regex::CompileOptions) : Regex::Mica::Regex::CompileOptions
      flags = Regex::Mica::Regex::CompileOptions::None
      flags |= Regex::Mica::Regex::CompileOptions::IgnoreCase if options.ignore_case?
      if options.multiline?
        flags |= Regex::Mica::Regex::CompileOptions::Multiline | Regex::Mica::Regex::CompileOptions::DotAll
      end
      flags |= Regex::Mica::Regex::CompileOptions::Extended if options.extended?
      flags
    end
  end
end
