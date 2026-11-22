require "regex/mica/regex"

module Crystal
  # :nodoc:
  #
  # Checks regex literals of a program built with `-Duse_mica` against the
  # Mica engine's dialect, so a literal Mica cannot run is a compile error
  # instead of an exception the first time the literal is used. See
  # `doc/regex_mica.md`.
  module MicaRegexLiteral
    # Returns why Mica cannot compile *source* with the literal's *options*,
    # or nil.
    def self.error?(source : String, options : Regex::CompileOptions) : String?
      Regex::Mica::Regex::Syntax.check(source, dialect: :crystal,
        compile_limits: Regex::Mica::Regex::CompileLimits::TRUSTED_PATTERN,
        options: mica_options(options))
      nil
    rescue error : Regex::Mica::Regex::UnsupportedConstructError
      "#{error.construct} (at #{error.byte_offset}) is not supported by the Mica regex engine; see doc/regex_mica.md for rewrites"
    rescue error : Regex::Mica::ParseError
      "#{error.detail} at #{error.byte_offset}"
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
