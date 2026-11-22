module YAML::Mica::YAML
  # Which YAML a parse accepts.
  #
  # - `YAML12` (the default) follows the YAML 1.2.2 specification.
  # - `LibYAML` reads what libyaml 0.2.5 reads, with the same events,
  #   marks and error messages: YAML 1.1 line breaks (NEL, LS and PS end a
  #   line), libyaml's looser indentation and tab rules, and its limits on
  #   anchor names and flow-context plain scalars. The standard-library
  #   compatibility layer uses it, so an application moving from libyaml
  #   sees no change.
  enum Dialect
    YAML12
    LibYAML
  end
end
