# One type with many functions that call each other, so a build with a small
# `--module-segment-instructions` compiles it as several object files.
class Ledger
  PREFIX = "step"
  @@steps_taken = 0

  def self.steps_taken : Int32
    @@steps_taken
  end

  def initialize
    @notes = {} of String => Int32
  end

  {% for index in 1..30 %}
    def step{{index}}(value : Int32) : Int32
      @@steps_taken += 1
      @notes["#{PREFIX}{{index}}"] = value
      {% if index < 30 %}
        step{{index + 1}}(value + {{index}})
      {% else %}
        value
      {% end %}
    end
  {% end %}

  def descend(depth : Int32) : Int32
    depth == 0 ? total : ascend(depth - 1) + 1
  end

  def total : Int32
    @notes.values.sum
  end

  def ascend(depth : Int32) : Int32
    depth == 0 ? step29(2) : descend(depth - 1) + 1
  end
end

ledger = Ledger.new
puts ledger.step1(1)
puts ledger.total
puts ledger.descend(5)
puts Ledger.steps_taken
