require "../core"

module YAML::Mica::YAML
  # Raised when `Emitter` is given an event it cannot write: an event out
  # of order ("expected DOCUMENT-START or STREAM-END"), an anchor or tag it
  # cannot express ("anchor value must contain alphanumerical characters
  # only"), a scalar with neither a tag nor an implicit flag, or an anchor,
  # tag or value that is not UTF-8. Apart from the UTF-8 messages, the
  # message is the problem text libyaml 0.2.5 reports for the same event.
  class EmitError < Mica::Error
  end
end
