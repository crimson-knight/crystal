module Crystal
  # :nodoc:
  module RegexLiteralSyntax
    # Returns the syntax error in the source of a regex literal, or nil.
    #
    # The parser checks literals with the engine the compiler itself was
    # built with. A compiler built with `-Duse_mica` reads PCRE2's syntax
    # through Mica's parser, which stops at the first construct Mica leaves
    # out (lookaround, backreferences, ...): such a pattern is valid PCRE2, so
    # it is accepted here, and a program built with `-Duse_mica` has it
    # checked again by `MicaRegexLiteral` when the literal is expanded.
    def self.error?(source : String) : String?
      {% if flag?(:use_mica) %}
        begin
          Regex.new(source)
          nil
        rescue Regex::UnsupportedSyntaxError
          nil
        rescue error : ArgumentError
          error.message
        end
      {% else %}
        Regex.error?(source)
      {% end %}
    end
  end
end
