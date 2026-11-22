module YAML::Mica::YAML
  # Raised when input is not well-formed YAML. `detail` is the problem
  # ("did not find expected key"), `position` where it was found (1-based
  # line and column, 0-based byte offset). When the scanner or parser was
  # inside a larger construct, `context` names it ("while parsing a block
  # mapping") and `context_position` says where that construct began.
  #
  # ```
  # begin
  #   Mica::YAML.parse("a: [1, 2", limits: Mica::YAML::ParseLimits::CONFIG_FILE, timeout: nil)
  # rescue error : Mica::YAML::SyntaxError
  #   error.detail  # => "did not find expected ',' or ']'"
  #   error.context # => "while parsing a flow sequence"
  # end
  # ```
  class SyntaxError < Mica::ParseError
    # The construct being read when the problem was found, or nil.
    getter context : String?

    # Where the construct named by `context` began, or nil.
    getter context_position : Core::Position?

    def initialize(detail : String, position : Core::Position, @context : String? = nil,
                   @context_position : Core::Position? = nil)
      super(detail, position)
    end
  end

  # Raised when the input's bytes are not valid UTF-8 (or UTF-16 or UTF-32
  # behind a byte order mark), or hold a character YAML does not allow (a
  # control character other than tab and the line breaks).
  class InvalidCharacterError < Mica::EncodingError
  end

  # Raised when an alias names an anchor the document has not defined.
  class UnknownAnchorError < SyntaxError
  end

  # Raised when a parse would pass one of its `ParseLimits`. `limit` names
  # it: "max_input_bytes", "max_depth", "max_nodes" or
  # "max_alias_expansion". The work budget and the timeout raise
  # `Mica::WorkBudgetExceededError` and `Mica::DeadlineExceededError`.
  class ParseLimitError < Mica::LimitExceededError
    # The name of the limit, for example "max_alias_expansion".
    getter limit : String

    def initialize(detail : String, position : Core::Position, @limit : String)
      super(detail, position)
    end
  end
end
