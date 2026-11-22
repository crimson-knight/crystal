# Mica is the default regex engine: written in Crystal, linear-time searches,
# no C library to link; see `doc/regex_mica.md`.
# PCRE2 is selected with the compiler flag `-Duse_pcre2`.
# The legacy PCRE engine is still supported for compatibility reasons, with the
# compiler flag `-Duse_pcre` or the env var `USE_PCRE1`.
# `-Duse_mica` is accepted and selects the default.
#
# `Crystal::Program#uses_mica_regex_engine?` makes the same choice in the
# compiler; change both together.
{% if flag?(:use_pcre2) %}
  require "./pcre2"

  # :nodoc:
  alias Regex::Engine = PCRE2
{% elsif flag?(:use_pcre) || !(env("USE_PCRE1") || "").empty? %}
  require "./pcre"

  # :nodoc:
  alias Regex::Engine = PCRE
{% else %}
  require "./mica_engine"

  # :nodoc:
  alias Regex::Engine = MicaEngine
{% end %}
