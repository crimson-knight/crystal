require "./reference_double"
{% unless flag?(:g2_harness_without_engine) %}
  require "crystal/big_num"
{% end %}

module G2Harness
  # The types a run can be pointed at: "engine" (`Crystal::BigNum::Integer`)
  # and "double" (`ReferenceDouble`, GMP-backed, for the self-check and the
  # planted-bug check). `-Dg2_harness_without_engine` builds without the engine.
  module Subject
    LIST_OF_NAMES = {% if flag?(:g2_harness_without_engine) %} ["double"] {% else %} ["engine", "double"] {% end %}

    # Expands *body* once per subject type inside a `case` on *name*, with the
    # local `subject_type` bound to that type (pass it to a `forall T` method).
    macro dispatch(name, &body)
      case {{name}}
      when "double"
        subject_type = ::G2Harness::ReferenceDouble
        {{body.body}}
      {% unless flag?(:g2_harness_without_engine) %}
        when "engine"
          subject_type = ::Crystal::BigNum::Integer
          {{body.body}}
      {% end %}
      else
        raise ArgumentError.new("Unknown subject #{{{name}}} (known: #{::G2Harness::Subject::LIST_OF_NAMES.join(", ")})")
      end
    end
  end
end
