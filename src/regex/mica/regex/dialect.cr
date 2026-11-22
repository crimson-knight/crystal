module Regex::Mica::Regex
  # The pattern languages Mica::Regex reads. Each dialect has its own syntax
  # and its own rules for classes and case folding, but all lower to the
  # same `Hir`.
  #
  # - `Crystal`: the PCRE2 subset Crystal programs use, with Crystal's
  #   options (`UTF | UCP | DUPNAMES` always on). Parsed since R1.
  # - `Ecma262`: ECMAScript `u`-mode patterns for JSON Schema `pattern`.
  #   Its folding and class rules are lowered since R1; its parser arrives
  #   in R6.
  # - `Xsd`: XML Schema Part 2 Appendix F patterns for CDDL `.regexp`. Its
  #   parser arrives in R7.
  enum Dialect
    Crystal
    Ecma262
    Xsd

    # Returns true when this dialect has a parser in this release.
    def parser_available? : Bool
      crystal?
    end
  end
end
