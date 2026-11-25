# A wasm32 program with fibers and the collector that keeps its only
# reference to live objects in locals while it allocates and forces
# collections. In an optimized build those locals are WebAssembly locals,
# which the conservative collector sees only when `wasm-opt --spill-pointers`
# has stored them on the shadow stack. When it cannot see them, it frees the
# chains below while they are in use, and the walk afterwards finds other
# values in their place.
#
# The main fiber checks chains across collections, and spawned fibers check
# chains across a switch to another fiber that collects.

CHAIN_LENGTH = 40
ROUNDS       = 60
FIBER_COUNT  =  4

class ChainLink
  getter seeded_value : Int32
  getter seeded_label : String
  getter next_link : ChainLink?

  def initialize(@seeded_value : Int32, @seeded_label : String, @next_link : ChainLink?)
  end
end

# Builds a chain of CHAIN_LENGTH links whose values and labels come from *seed*.
@[NoInline]
def build_chain(seed : Int32) : ChainLink
  head = ChainLink.new(seed &* 1000, "#{seed}-0", nil)
  (1...CHAIN_LENGTH).each do |index|
    head = ChainLink.new(seed &* 1000 &+ index, "#{seed}-#{index}", head)
  end
  head
end

# Fills the heap with objects the size of the chain's, so memory the
# collector frees is handed out again, and then forces a collection.
@[NoInline]
def churn(seed : Int32) : Nil
  list_of_decoys = Array(ChainLink).new
  (CHAIN_LENGTH * 4).times do |index|
    list_of_decoys << ChainLink.new(-index, "decoy-#{seed}-#{index}", nil)
  end
  GC.collect
  (CHAIN_LENGTH * 4).times do |index|
    ChainLink.new(-index, "decoy-#{seed}-#{index}", nil)
  end
end

# Whether *head* still holds the chain `build_chain(seed)` built.
@[NoInline]
def chain_intact?(head : ChainLink, seed : Int32) : Bool
  link = head
  (CHAIN_LENGTH - 1).downto(0) do |index|
    return false unless link
    return false unless link.seeded_value == seed &* 1000 &+ index
    return false unless link.seeded_label == "#{seed}-#{index}"
    link = link.next_link
  end
  link.nil?
end

main_failures = 0
ROUNDS.times do |round|
  chain = build_chain(round)
  churn(round)
  main_failures += 1 unless chain_intact?(chain, round)
end

fiber_failures = 0
fibers_done = 0
FIBER_COUNT.times do |fiber_index|
  spawn do
    ROUNDS.times do |round|
      seed = 10_000 &* (fiber_index + 1) &+ round
      chain = build_chain(seed)
      Fiber.yield
      churn(seed)
      fiber_failures += 1 unless chain_intact?(chain, seed)
    end
    fibers_done += 1
  end
end
until fibers_done == FIBER_COUNT
  Fiber.yield
end

puts "main fiber: #{ROUNDS - main_failures} of #{ROUNDS} chains intact"
puts "spawned fibers: #{ROUNDS * FIBER_COUNT - fiber_failures} of #{ROUNDS * FIBER_COUNT} chains intact"
exit(main_failures + fiber_failures == 0 ? 0 : 1)
