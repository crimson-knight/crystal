# Built with the lean wasm32 release recipe (see WASM_GUIDE.md, "Lean
# release builds"): a little of everything a small module uses, numbers,
# arrays, hashes, strings and a rescued exception.
struct Particle
  getter position : Float64
  getter velocity : Float64

  def initialize(@position : Float64, @velocity : Float64)
  end

  def step(seconds : Float64) : Particle
    Particle.new(position + velocity * seconds, velocity - 9.81 * seconds)
  end
end

class StepLimitError < Exception
end

def simulate(step_count : Int32) : Particle
  raise StepLimitError.new("too many steps: #{step_count}") if step_count > 1_000

  particle = Particle.new(10.0, 0.0)
  step_count.times { particle = particle.step(1.0 / 60) }
  particle
end

list_of_heights = [1, 30, 60].map { |step_count| simulate(step_count).position.round(3) }
height_by_label = {"start" => list_of_heights.first, "end" => list_of_heights.last}

begin
  simulate(5_000)
rescue error : StepLimitError
  puts "rescued: #{error.message}"
end

puts "heights: #{list_of_heights.join(", ")}"
puts "end height: #{height_by_label["end"]}"
