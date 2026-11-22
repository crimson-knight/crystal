module Regex::Mica::Regex
  # Options for one search, following Crystal's `Regex::MatchOptions`.
  @[Flags]
  enum MatchOptions : UInt32
    # The match must start at the search's start position.
    Anchored
    # The match must end at the end of the haystack.
    EndAnchored
  end
end
