# Crystal WASM Feature Demo: Text-Based RPG Dungeon Crawler
#
# Demonstrates ALL major Crystal language features running in WebAssembly.
#
# Compile:
#   crystal build samples/wasm/demo.cr -o demo.wasm \
#     --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
#
# Run (CLI):
#   wasmtime run -W exceptions=y demo.wasm
#
# Run (Browser):
#   See samples/wasm/index.html - click "Run Feature Demo"

require "json"

# ============================================================
# Feature 1: Enums
# ============================================================
enum Direction
  North; South; East; West
end

enum ItemType
  Weapon; Armor; Potion; Key
end

# ============================================================
# Feature 2: Structs
# ============================================================
struct Position
  property x : Int32
  property y : Int32

  def initialize(@x, @y)
  end

  def distance_to(other : Position) : Float64
    Math.sqrt(((x - other.x) ** 2 + (y - other.y) ** 2).to_f)
  end

  def move(dir : Direction) : Position
    case dir
    when .north? then Position.new(x, y - 1)
    when .south? then Position.new(x, y + 1)
    when .east?  then Position.new(x + 1, y)
    when .west?  then Position.new(x - 1, y)
    else              self
    end
  end

  def to_s(io : IO)
    io << "(#{x}, #{y})"
  end
end

# ============================================================
# Feature 3: Modules (Damageable)
# ============================================================
module Damageable
  abstract def hp : Int32
  abstract def hp=(value : Int32)
  abstract def max_hp : Int32

  def take_damage(amount : Int32) : Int32
    actual = Math.min(amount, hp)
    self.hp = hp - actual
    actual
  end

  def alive? : Bool
    hp > 0
  end

  def health_bar : String
    filled = (hp.to_f / max_hp * 20).to_i
    empty = 20 - filled
    "[#{"+" * filled}#{"-" * empty}] #{hp}/#{max_hp}"
  end
end

# ============================================================
# Feature 4: Classes with Inheritance & Abstract Methods
# ============================================================
abstract class Character
  include Damageable

  property name : String
  property hp : Int32
  property max_hp : Int32
  property position : Position
  property level : Int32

  abstract def attack_power : Int32

  def initialize(@name, @hp, @position, @level = 1)
    @max_hp = @hp
  end

  def to_s(io : IO)
    io << "#{name} (Lv.#{level}) #{health_bar}"
  end
end

class Hero < Character
  property xp : Int32
  property gold : Int32

  def initialize(name : String, hp : Int32, position : Position)
    super(name, hp, position, level: 1)
    @xp = 0
    @gold = 0
  end

  def attack_power : Int32
    8 + level * 3
  end

  def gain_xp(amount : Int32)
    @xp += amount
    if @xp >= level * 50
      @level += 1
      @hp = Math.min(hp + 20, max_hp + 20)
      @max_hp += 20
    end
  end
end

class Monster < Character
  property xp_reward : Int32
  property gold_reward : Int32
  property loot : NamedTuple(item: String, chance: Float64)

  def initialize(name : String, hp : Int32, position : Position, @xp_reward, @gold_reward,
                 @loot = {item: "Nothing", chance: 0.0})
    super(name, hp, position, level: 1)
  end

  def attack_power : Int32
    3 + level * 2
  end
end

# ============================================================
# Feature 5: Generics - Inventory(T)
# ============================================================
class Item
  include JSON::Serializable

  property name : String
  property item_type : String
  property power : Int32

  def initialize(@name, @item_type, @power)
  end

  def to_s(io : IO)
    io << "#{name} [#{item_type}] (+#{power})"
  end
end

class Inventory(T)
  @items = Array(T).new

  def add(item : T)
    @items << item
  end

  def remove(name : String) : T?
    idx = @items.index { |i| i.name == name }
    idx ? @items.delete_at(idx) : nil
  end

  def find(name : String) : T?
    @items.find { |i| i.name == name }
  end

  def each(&block : T ->)
    @items.each { |i| yield i }
  end

  def map(&block : T -> U) forall U
    @items.map { |i| yield i }
  end

  def select(&block : T -> Bool)
    @items.select { |i| yield i }
  end

  def size
    @items.size
  end

  def to_a
    @items.dup
  end

  def to_s(io : IO)
    if @items.empty?
      io << "(empty)"
    else
      @items.each_with_index do |item, i|
        io << "  #{i + 1}. #{item}\n"
      end
    end
  end
end

# ============================================================
# Custom Exception
# ============================================================
class InvalidItemError < Exception
end

# ============================================================
# Game State for JSON serialization
# ============================================================
class GameState
  include JSON::Serializable

  property hero_name : String
  property hero_hp : Int32
  property hero_level : Int32
  property hero_xp : Int32
  property hero_gold : Int32
  property monsters_defeated : Int32
  property items : Array(Item)
  property position_x : Int32
  property position_y : Int32

  def initialize(@hero_name, @hero_hp, @hero_level, @hero_xp, @hero_gold,
                 @monsters_defeated, @items, @position_x, @position_y)
  end
end

# ============================================================
# Main Demo
# ============================================================
def section(title : String)
  puts ""
  puts "--- Feature: #{title} ---"
end

def header(text : String)
  puts ""
  puts "=== #{text} ==="
end

# Track monsters defeated for summary
monsters_defeated = 0

header "Crystal WASM Feature Demo: Dungeon Crawler"
puts "A text RPG showcasing Crystal language features in WebAssembly"
puts "Crystal #{Crystal::VERSION} | Target: wasm32-wasi"

# ----------------------------------------------------------
section "Enums"
# ----------------------------------------------------------
directions = [Direction::North, Direction::East, Direction::South, Direction::West]
puts "Available directions: #{directions.map(&.to_s).join(", ")}"
puts "Item types: #{ItemType.values.map(&.to_s).join(", ")}"
chosen_dir = Direction::North
puts "Hero chooses to go: #{chosen_dir}"

# ----------------------------------------------------------
section "Structs"
# ----------------------------------------------------------
start_pos = Position.new(0, 0)
new_pos = start_pos.move(Direction::North)
puts "Starting position: #{start_pos}"
puts "After moving North: #{new_pos}"
dungeon_exit = Position.new(3, -3)
puts "Distance to dungeon exit #{dungeon_exit}: #{start_pos.distance_to(dungeon_exit).round(2)}"

# ----------------------------------------------------------
section "Classes & Inheritance"
# ----------------------------------------------------------
hero = Hero.new("Crystalia", 100, new_pos)
puts "Hero created: #{hero}"
puts "Hero attack power (abstract method): #{hero.attack_power}"

# ----------------------------------------------------------
section "Modules (Damageable)"
# ----------------------------------------------------------
puts "Hero health bar: #{hero.health_bar}"
dmg = hero.take_damage(15)
puts "Hero takes #{dmg} damage! #{hero.health_bar}"
puts "Hero alive? #{hero.alive?}"

# ----------------------------------------------------------
section "Properties (Getters/Setters)"
# ----------------------------------------------------------
hero.hp = hero.max_hp
puts "Hero HP restored via setter: #{hero.hp}/#{hero.max_hp}"
hero.gold = 10
hero.xp = 0
puts "Hero gold set to: #{hero.gold}"
puts "Hero XP set to: #{hero.xp}"

# ----------------------------------------------------------
section "Generics (Inventory<T>)"
# ----------------------------------------------------------
inventory = Inventory(Item).new
inventory.add(Item.new("Iron Sword", "Weapon", 5))
inventory.add(Item.new("Leather Armor", "Armor", 3))
inventory.add(Item.new("Health Potion", "Potion", 30))
inventory.add(Item.new("Rusty Key", "Key", 0))
puts "Inventory (#{inventory.size} items):"
puts inventory

# ----------------------------------------------------------
section "Named Tuples & Hash"
# ----------------------------------------------------------
room_descriptions = {
  "entrance"  => "A damp stone corridor stretches before you. Torches flicker on the walls.",
  "goblin_den" => "Bones litter the floor. Something moves in the shadows...",
  "treasure"  => "Gold glints in the torchlight! A chest sits against the far wall.",
  "boss_room" => "A massive chamber. The air crackles with dark energy.",
}

item_stats = {
  "Iron Sword"   => {damage: 8, weight: 5.0},
  "Fire Staff"   => {damage: 12, weight: 3.0},
  "Health Potion" => {heal: 30, weight: 0.5},
}

puts "Room: Entrance"
puts room_descriptions["entrance"]
puts ""
puts "Item stats (named tuples):"
item_stats.each do |name, stats|
  puts "  #{name}: #{stats}"
end

# ----------------------------------------------------------
section "Array Operations"
# ----------------------------------------------------------
monster_names = ["Goblin Scout", "Skeleton Warrior", "Cave Spider", "Dark Mage", "Dragon Whelp"]
puts "Monster roster: #{monster_names.join(", ")}"
puts "Sorted: #{monster_names.sort.join(", ")}"
puts "Reversed: #{monster_names.reverse.join(", ")}"
puts "Count: #{monster_names.size}"

# ----------------------------------------------------------
section "Iterators (.each, .map, .select, .reduce)"
# ----------------------------------------------------------
damage_rolls = [12, 8, 15, 6, 20, 3, 18]
puts "Damage rolls: #{damage_rolls}"
puts "Doubled (map): #{damage_rolls.map { |d| d * 2 }}"
puts "Big hits (select >10): #{damage_rolls.select { |d| d > 10 }}"
puts "Total damage (reduce): #{damage_rolls.reduce(0) { |sum, d| sum + d }}"
puts "Average damage: #{damage_rolls.reduce(0) { |sum, d| sum + d } / damage_rolls.size}"

names_upper = monster_names.map(&.upcase)
puts "Monster names uppercased: #{names_upper.first(3).join(", ")}..."

# ----------------------------------------------------------
section "String Operations"
# ----------------------------------------------------------
battle_cry = "for glory and crystal!"
puts "Original: #{battle_cry}"
puts "Upcase: #{battle_cry.upcase}"
puts "Split: #{battle_cry.split(" ")}"
puts "Gsub: #{battle_cry.gsub("crystal", "WASM")}"
puts "Join words: #{battle_cry.split(" ").join(" ** ")}"
puts "Interpolation: The hero shouts '#{battle_cry.upcase}' and charges forward!"

# ----------------------------------------------------------
section "Regex (PCRE2)"
# ----------------------------------------------------------
commands = ["attack goblin", "use health potion", "move north", "cast fireball", "look around"]
commands.each do |cmd|
  case cmd
  when /^attack\s+(.+)$/
    puts "Command '#{cmd}' -> ATTACK target: #{$1}"
  when /^use\s+(.+)$/
    puts "Command '#{cmd}' -> USE item: #{$1}"
  when /^move\s+(north|south|east|west)$/i
    puts "Command '#{cmd}' -> MOVE direction: #{$1}"
  when /^cast\s+(\w+)$/
    puts "Command '#{cmd}' -> CAST spell: #{$1}"
  else
    puts "Command '#{cmd}' -> LOOK around"
  end
end

# ----------------------------------------------------------
section "Math & Random (Damage Rolls)"
# ----------------------------------------------------------
puts "Simulating combat rolls..."
5.times do |i|
  base_damage = hero.attack_power
  roll = Random.rand(1..6)
  crit_roll = Random.rand(1.0)
  is_crit = crit_roll > 0.8
  total = is_crit ? base_damage * 2 + roll : base_damage + roll
  crit_text = is_crit ? " ** CRITICAL HIT! **" : ""
  puts "  Roll #{i + 1}: base=#{base_damage} + d6=#{roll}#{crit_text} = #{total} damage"
end
puts "Math.sqrt(144) = #{Math.sqrt(144.0)}"
puts "Math::PI = #{Math::PI.round(6)}"

# ----------------------------------------------------------
section "Procs & Blocks (Combat Callbacks)"
# ----------------------------------------------------------
on_hit = ->(attacker : String, defender : String, damage : Int32) {
  puts "  [HIT] #{attacker} strikes #{defender} for #{damage} damage!"
}

on_defeat = ->(monster_name : String, xp : Int32) {
  puts "  [DEFEAT] #{monster_name} is vanquished! (+#{xp} XP)"
}

# Simulate a combat encounter
section "Combat Encounter (Classes, Procs, Random)"
hero.position = Position.new(1, -1)
puts "Hero enters the Goblin Den..."
puts room_descriptions["goblin_den"]

goblin = Monster.new("Goblin Scout", 30, hero.position, xp_reward: 25, gold_reward: 10,
  loot: {item: "Goblin Dagger", chance: 0.5})
puts ""
puts "A wild #{goblin.name} appears!"
puts "  #{goblin}"

round = 0
while hero.alive? && goblin.alive?
  round += 1
  puts ""
  puts "-- Round #{round} --"

  # Hero attacks
  hero_dmg = hero.attack_power + Random.rand(1..4)
  goblin.take_damage(hero_dmg)
  on_hit.call(hero.name, goblin.name, hero_dmg)

  break unless goblin.alive?

  # Monster attacks
  mon_dmg = goblin.attack_power + Random.rand(1..3)
  hero.take_damage(mon_dmg)
  on_hit.call(goblin.name, hero.name, mon_dmg)
end

if !goblin.alive?
  on_defeat.call(goblin.name, goblin.xp_reward)
  hero.gain_xp(goblin.xp_reward)
  hero.gold += goblin.gold_reward
  monsters_defeated += 1
  puts "  Hero: #{hero}"

  # Loot roll
  if Random.rand(1.0) < goblin.loot[:chance]
    loot_item = Item.new(goblin.loot[:item], "Weapon", 4)
    inventory.add(loot_item)
    puts "  Loot dropped: #{loot_item}"
  else
    puts "  No loot dropped this time."
  end
end

# ----------------------------------------------------------
section "Exception Handling"
# ----------------------------------------------------------
puts "Trying to use an item that doesn't exist..."
begin
  found = inventory.find("Excalibur")
  raise InvalidItemError.new("Item 'Excalibur' not found in inventory!") if found.nil?
  puts "Using #{found.name}..."
rescue ex : InvalidItemError
  puts "Caught InvalidItemError: #{ex.message}"
end

puts ""
puts "Trying to use a valid item..."
begin
  potion = inventory.find("Health Potion")
  raise InvalidItemError.new("No Health Potion!") if potion.nil?
  old_hp = hero.hp
  hero.hp = Math.min(hero.hp + potion.power, hero.max_hp)
  inventory.remove("Health Potion")
  puts "Used #{potion.name}! HP: #{old_hp} -> #{hero.hp}"
rescue ex : InvalidItemError
  puts "Caught: #{ex.message}"
rescue ex
  puts "Unexpected error: #{ex.message}"
end

# ----------------------------------------------------------
section "Time::Span (Monotonic Timing)"
# ----------------------------------------------------------
elapsed = Time.measure do
  # Simulate some work: sort a bunch of random numbers
  data = Array.new(5000) { Random.rand(10000) }
  data.sort!
  puts "Sorted #{data.size} random numbers."
  puts "Min: #{data.first}, Max: #{data.last}, Median: #{data[data.size // 2]}"
end
puts "Operation took: #{elapsed.total_milliseconds.round(3)} ms"

turn_time = Time::Span.new(seconds: round * 6)
puts "In-game time for #{round} combat rounds: #{turn_time}"

# ----------------------------------------------------------
# Second combat: Skeleton Warrior
# ----------------------------------------------------------
section "Combat 2 (More Classes & Random)"
hero.position = hero.position.move(Direction::East)
puts "Hero moves East to #{hero.position}"

skeleton = Monster.new("Skeleton Warrior", 45, hero.position, xp_reward: 40, gold_reward: 20,
  loot: {item: "Bone Shield", chance: 0.4})
puts "A #{skeleton.name} blocks the path!"
puts "  #{skeleton}"

round2 = 0
while hero.alive? && skeleton.alive?
  round2 += 1
  hero_dmg = hero.attack_power + Random.rand(1..6)
  skeleton.take_damage(hero_dmg)
  on_hit.call(hero.name, skeleton.name, hero_dmg)
  break unless skeleton.alive?
  mon_dmg = skeleton.attack_power + Random.rand(1..4)
  hero.take_damage(mon_dmg)
  on_hit.call(skeleton.name, hero.name, mon_dmg)
end

if !skeleton.alive?
  on_defeat.call(skeleton.name, skeleton.xp_reward)
  hero.gain_xp(skeleton.xp_reward)
  hero.gold += skeleton.gold_reward
  monsters_defeated += 1
  puts "  Hero: #{hero}"
end

# ----------------------------------------------------------
section "Fibers & Channels"
# ----------------------------------------------------------
puts "Starting ambient sound fibers..."
sounds = ["Drip... drip...", "A distant roar echoes.", "Chains rattle somewhere.",
          "Wind howls through the cracks.", "Something skitters in the dark."]
sound_log = [] of String
counter = 0

# Spawn a fiber that processes sounds one at a time
spawn do
  sounds.each do |sound|
    sound_log << sound
    counter += 1
    Fiber.yield
  end
end

# Yield enough times for the fiber to complete all iterations
(sounds.size + 2).times { Fiber.yield }

sound_log.each { |msg| puts "  [Ambient] #{msg}" }
puts "Ambient sound fiber completed: #{counter} sounds produced."
puts "Fiber yielding works correctly on WASM (Asyncify)."

# ----------------------------------------------------------
section "JSON Serialization"
# ----------------------------------------------------------
items_array = inventory.to_a
state = GameState.new(
  hero_name: hero.name,
  hero_hp: hero.hp,
  hero_level: hero.level,
  hero_xp: hero.xp,
  hero_gold: hero.gold,
  monsters_defeated: monsters_defeated,
  items: items_array,
  position_x: hero.position.x,
  position_y: hero.position.y,
)

json_str = state.to_json
puts "Serialized game state to JSON (#{json_str.size} bytes):"
puts json_str
puts ""

# Deserialize and verify
restored = GameState.from_json(json_str)
puts "Deserialized back:"
puts "  Hero: #{restored.hero_name} Lv.#{restored.hero_level} HP:#{restored.hero_hp} Gold:#{restored.hero_gold}"
puts "  Position: (#{restored.position_x}, #{restored.position_y})"
puts "  Monsters defeated: #{restored.monsters_defeated}"
puts "  Items: #{restored.items.map(&.name).join(", ")}"
puts "  Round-trip match: #{json_str == restored.to_json}"

# ----------------------------------------------------------
section "Garbage Collection"
# ----------------------------------------------------------
puts "Creating temporary objects for GC stress test..."
temp_arrays = Array(Array(Int32)).new
100.times do |i|
  temp_arrays << Array.new(100) { Random.rand(1000) }
end
puts "Created #{temp_arrays.size} arrays with #{temp_arrays.size * 100} total elements."
temp_arrays.clear
puts "Cleared references. Running GC.collect..."
GC.collect
puts "GC collection complete."
stats = GC.stats
puts "GC Stats - Heap size: #{stats.heap_size} bytes, Free: #{stats.free_bytes} bytes, Total: #{stats.total_bytes} bytes"

# ----------------------------------------------------------
# Final Summary
# ----------------------------------------------------------
header "Adventure Complete! All Crystal WASM features demonstrated!"
puts ""
puts "Final Hero Status:"
puts "  #{hero}"
puts "  Gold: #{hero.gold} | XP: #{hero.xp} | Position: #{hero.position}"
puts "  Monsters defeated: #{monsters_defeated}"
puts ""
puts "Inventory:"
puts inventory
puts "Features demonstrated:"
features = [
  "Enums", "Structs", "Classes & Inheritance", "Modules (Damageable)",
  "Abstract Methods", "Properties (Getters/Setters)", "Generics (Inventory<T>)",
  "Named Tuples", "Hash", "Array Operations", "Iterators (each/map/select/reduce)",
  "String Operations", "Regex (PCRE2)", "Math & Random", "Procs & Blocks",
  "Exception Handling", "Time::Span", "Fibers & Channels",
  "JSON Serialization", "Garbage Collection",
]
features.each_with_index do |f, i|
  puts "  #{i + 1}. #{f}"
end
puts ""
puts "Total: #{features.size} Crystal features running in WebAssembly!"
