module Crystal
  # :nodoc:
  module RegexLiteralSyntax
    # Returns the syntax error in the source of a regex literal, or nil.
    #
    # The parser checks literals with the engine the compiler itself was
    # built with. A compiler built on Mica (the default) reads PCRE2's syntax
    # through Mica's parser, which stops at the first construct Mica leaves
    # out (lookaround, backreferences, ...): such a pattern is valid PCRE2, so
    # it is accepted here, and a program that runs on Mica has it
    # checked again by `MicaRegexLiteral` when the literal is expanded.
    def self.error?(source : String) : String?
      {% if Regex::Engine.resolve.name == "Regex::MicaEngine" %}
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
