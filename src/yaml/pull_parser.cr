require "./enums"

# Mica's pure-Crystal parser and emitter (no C library) are the default YAML
# engine; see `doc/yaml_mica.md`. libyaml is selected with the compiler flag
# `-Duse_libyaml`. `-Duse_mica` is accepted and selects the default.
{% if flag?(:use_libyaml) %}
  require "./libyaml/lib_yaml"
  require "./libyaml/pull_parser"
{% else %}
  require "./mica_engine/pull_parser"
{% end %}
