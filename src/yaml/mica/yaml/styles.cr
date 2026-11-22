module YAML::Mica::YAML
  # How a scalar is written: `Any` lets the emitter choose, and a parser
  # reports the style it read.
  enum ScalarStyle
    Any
    Plain
    SingleQuoted
    DoubleQuoted
    Literal
    Folded

    # Returns true for the single-quoted and double-quoted styles.
    def quoted? : Bool
      single_quoted? || double_quoted?
    end
  end

  # How a sequence is written: block (`- item`) or flow (`[item]`).
  enum SequenceStyle
    Any
    Block
    Flow
  end

  # How a mapping is written: block (`key: value`) or flow (`{key: value}`).
  enum MappingStyle
    Any
    Block
    Flow
  end
end
