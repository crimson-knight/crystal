module Regex::Mica::Regex
  # Options that change how a pattern is read and what it matches. They
  # follow PCRE2's option bits one for one (so the stdlib `Regex` shim can
  # map Crystal's `Regex::CompileOptions` directly: Crystal's `MULTILINE`
  # is `Multiline | DotAll` here). UTF-8, Unicode properties for `\d \w \s`
  # and duplicate group names are always on in the Crystal dialect and have
  # no flag.
  #
  # Every option except the anchoring and invalid-UTF ones can also be set
  # inside a pattern with `(?imnrsxU)`, `(?xx)` and `(?a...)`.
  @[Flags]
  enum CompileOptions : UInt32
    # `i`: letters match their simple case folds.
    IgnoreCase
    # `m`: `^` and `$` also match at line starts and ends.
    Multiline
    # `s`: `.` also matches a newline.
    DotAll
    # `x`: white space and `#` comments are ignored outside classes.
    Extended
    # `xx`: like `Extended`, and space and tab are ignored in classes too.
    ExtendedMore
    # The match must start at the search start.
    Anchored
    # `$` matches only at the very end (not before a final newline).
    DollarEndOnly
    # The match must start before the first newline.
    FirstLine
    # The match must end at the end of the subject.
    EndAnchored
    # Invalid UTF-8 in the subject acts as a barrier instead of an error.
    MatchInvalidUtf
    # `U`: quantifiers are lazy by default and `?` makes them greedy.
    Ungreedy
    # `n`: plain parentheses do not capture.
    NoAutoCapture
    # `r`: case folding never pairs an ASCII with a non-ASCII character.
    CaselessRestrict
    # `aD`: `\d` matches ASCII digits only.
    AsciiBackslashD
    # `aS`: `\s` matches ASCII white space only.
    AsciiBackslashS
    # `aW`: `\w` and `\b` use ASCII word characters only.
    AsciiBackslashW
    # `aP`: POSIX classes such as `[:alpha:]` are ASCII only.
    AsciiPosix
    # `aT`: `[:digit:]` and `[:xdigit:]` are ASCII only.
    AsciiDigit

    # The options a pattern may change inline (everything but anchoring and
    # the invalid-UTF mode).
    INLINE = IgnoreCase | Multiline | DotAll | Extended | ExtendedMore | Ungreedy | NoAutoCapture |
      CaselessRestrict | AsciiBackslashD | AsciiBackslashS | AsciiBackslashW | AsciiPosix | AsciiDigit

    # Every ASCII restriction, as `(?a)` sets them.
    ASCII_ALL = AsciiBackslashD | AsciiBackslashS | AsciiBackslashW | AsciiPosix | AsciiDigit
  end
end
