# PCRE2 is the default regex engine and should always be preferred.
# The legacy PCRE engine is still supported for compatibility reasons, but it is
# opt-in via compiler flag `-Duse_pcre` or env var `USE_PCRE1`.
# The Mica engine (pure Crystal, linear-time searches, no C library) is opt-in
# via compiler flag `-Duse_mica`; see `doc/regex_mica.md`.
{% if flag?(:use_mica) %}
  require "./mica_engine"

  # :nodoc:
  alias Regex::Engine = MicaEngine
{% elsif flag?(:use_pcre) || !(env("USE_PCRE1") || "").empty? %}
  require "./pcre"

  # :nodoc:
  alias Regex::Engine = PCRE
{% else %}
  require "./pcre2"

  # :nodoc:
  alias Regex::Engine = PCRE2
{% end %}
