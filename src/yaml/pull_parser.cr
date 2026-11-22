require "./enums"

# libyaml is the default YAML engine. Mica's pure-Crystal parser and emitter
# (no C library) are opt-in via compiler flag `-Duse_mica`; see
# `doc/yaml_mica.md`.
{% if flag?(:use_mica) %}
  require "./mica_engine/pull_parser"
{% else %}
  require "./libyaml/lib_yaml"
  require "./libyaml/pull_parser"
{% end %}
