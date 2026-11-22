require "./enums"

# See `src/yaml/pull_parser.cr`: Mica by default, libyaml under `-Duse_libyaml`.
{% if flag?(:use_libyaml) %}
  require "./libyaml/lib_yaml"
  require "./libyaml/builder"
{% else %}
  require "./mica_engine/builder"
{% end %}

module YAML
  # Returns the resulting String of writing YAML to the yielded `YAML::Builder`.
  #
  # ```
  # require "yaml"
  #
  # string = YAML.build do |yaml|
  #   yaml.mapping do
  #     yaml.scalar "foo"
  #     yaml.sequence do
  #       yaml.scalar 1
  #       yaml.scalar 2
  #     end
  #   end
  # end
  # string # => "---\nfoo:\n- 1\n- 2\n"
  # ```
  def self.build(&)
    String.build do |str|
      build(str) do |yaml|
        yield yaml
      end
    end
  end

  # Writes YAML into the given `IO`. A `YAML::Builder` is yielded to the block.
  def self.build(io : IO, &) : Nil
    YAML::Builder.build(io) do |yaml|
      yaml.stream do
        yaml.document do
          yield yaml
        end
      end
    end
  end
end
