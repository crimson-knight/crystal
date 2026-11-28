# A wasm32 program in the shape of a browser game's save loop: each round
# loads the world from JSON, changes it, allocates a large buffer and dumps
# the world back to JSON, with the collector running on its own (no
# `GC.collect`, no `GC.disable`).
#
# It guards two wasm32-wasi collector failures:
#
# - The collector returned heap blocks that stayed free for a few
#   collections with munmap, which WASI's emulated mmap cannot do, so the
#   module aborted with an `unreachable` trap after some collections.
# - A collection in the middle of a round freed objects whose only
#   reference sat in a WebAssembly local, and the round then read other
#   bytes in their place (a JSON parse error, a memory fault, or
#   "Duplicate large block deallocation").
#
# Each round checks the world it loaded against the one it dumped, so a
# freed and reused object shows up as a wrong round, not only as a crash.
#
# The round count is the first argument; it defaults to DEFAULT_ROUNDS.

require "json"

DEFAULT_ROUNDS = 60_000
HERO_COUNT     =      8
ITEM_COUNT     =     12

class Hero
  include JSON::Serializable

  getter hero_name : String
  getter list_of_items : Array(String)
  property step_count : Int32

  def initialize(@hero_name : String, @list_of_items : Array(String), @step_count : Int32)
  end
end

class World
  include JSON::Serializable

  getter list_of_heroes : Array(Hero)
  property round_number : Int32
  property journal_entry : String

  def initialize(@list_of_heroes : Array(Hero), @round_number : Int32, @journal_entry : String)
  end

  def self.first : World
    list_of_heroes = (0...HERO_COUNT).map do |hero_index|
      list_of_items = (0...ITEM_COUNT).map { |item_index| "item-#{hero_index}-#{item_index}" * 4 }
      Hero.new("hero-#{hero_index}", list_of_items, 0)
    end
    World.new(list_of_heroes, 0, "")
  end

  def self.journal_entry_for(round_number : Int32) : String
    "round #{round_number} " + "j" * (round_number % 200)
  end

  # Whether this world is the one round *round_number* dumped.
  def written_by_round?(round_number : Int32) : Bool
    return false unless self.round_number == round_number
    return false unless journal_entry == World.journal_entry_for(round_number)
    return false unless list_of_heroes.size == HERO_COUNT
    list_of_heroes.each_with_index.all? do |hero, hero_index|
      hero.hero_name == "hero-#{hero_index}" &&
        hero.step_count == round_number + 1 &&
        hero.list_of_items.size == ITEM_COUNT &&
        hero.list_of_items.each_with_index.all? { |item, item_index| item == "item-#{hero_index}-#{item_index}" * 4 }
    end
  end
end

round_count = ARGV.first?.try(&.to_i) || DEFAULT_ROUNDS
saved_world = World.first.to_json
intact_rounds = 0
peak_heap_bytes = 0_u64

round_count.times do |round_number|
  world = World.from_json(saved_world)
  intact_rounds += 1 if round_number == 0 || world.written_by_round?(round_number - 1)

  world.round_number = round_number
  world.journal_entry = World.journal_entry_for(round_number)
  world.list_of_heroes.each { |hero| hero.step_count += 1 }

  large_buffer = Bytes.new(70_000 + (round_number % 13) * 4096, (round_number % 251).to_u8)
  intact_rounds -= 1 unless large_buffer[large_buffer.size - 1] == (round_number % 251).to_u8

  saved_world = world.to_json
  peak_heap_bytes = {peak_heap_bytes, GC.stats.heap_size}.max
end

puts "#{intact_rounds} of #{round_count} rounds intact"
puts "peak heap #{peak_heap_bytes // (1024 * 1024)} MiB"
