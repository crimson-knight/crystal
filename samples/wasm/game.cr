# Crystal Caverns - Interactive WASM Adventure Game
# Demonstrates Crystal features as an interactive WebAssembly module.
# Compile: crystal build samples/wasm/game.cr -o samples/wasm/game.wasm \
#   --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl
# API: game_init, game_command, game_get_output, game_alloc,
#      game_get_room, game_get_hp, game_get_max_hp, game_get_status

# Memory management for WASM output buffer
OUTPUT_BUFFER_SIZE = 65536
OUTPUT_BUFFER     = Pointer(UInt8).malloc(OUTPUT_BUFFER_SIZE)
OUTPUT_LENGTH     = Pointer(Int32).malloc(1)

def write_output(text : String)
  bytes = text.to_slice
  len = Math.min(bytes.size, OUTPUT_BUFFER_SIZE - 1) # Feature 10: Math
  bytes.copy_to(OUTPUT_BUFFER, len)
  OUTPUT_BUFFER[len] = 0_u8
  OUTPUT_LENGTH.value = len
end

# Feature 1: Enums - Direction and GameStatus
enum Direction
  North; South; East; West
end

enum GameStatus
  Playing; Won; Dead
end

# Feature 2: Structs - Position
struct Position
  property x : Int32, y : Int32
  def initialize(@x, @y); end
end
# Feature 11: Named Tuples - Monster stat definitions
MONSTER_STATS = {
  goblin:   {name: "Goblin Scavenger", hp: 28, attack: 5, xp: 15},
  skeleton: {name: "Skeleton Knight", hp: 55, attack: 9, xp: 40},
}
# Feature 3: Classes - Monster, Room, Hero
class Monster
  property name : String, hp : Int32, max_hp : Int32
  property attack : Int32, xp_reward : Int32

  def initialize(@name, @hp, @attack, @xp_reward)
    @max_hp = @hp
  end

  def alive? : Bool
    @hp > 0
  end
end

class Room
  property id : Int32, name : String, description : String
  property exits : Hash(Direction, Int32) # Feature 4: Hash - room connections
  property monster : Monster?, item : String?, riddle_solved : Bool

  def initialize(@id, @name, @description, @exits = {} of Direction => Int32,
                 @monster = nil, @item = nil)
    @riddle_solved = false
  end
end

class Hero
  property hp : Int32, max_hp : Int32, attack : Int32, defense : Int32
  property inventory : Array(String) # Feature 5: Array - inventory
  property room_id : Int32

  def initialize
    @hp, @max_hp, @attack, @defense = 50, 50, 6, 1
    @inventory = [] of String
    @room_id = 1
  end

  def alive? : Bool
    @hp > 0
  end

  def has?(item : String) : Bool
    @inventory.includes?(item)
  end
end
# Game Engine
class Game
  property hero : Hero, rooms : Hash(Int32, Room)
  property status : GameStatus, output : IO::Memory

  def initialize
    @hero = Hero.new
    @status = GameStatus::Playing
    @output = IO::Memory.new
    @rooms = build_rooms
  end

  private def build_rooms : Hash(Int32, Room)
    r = {} of Int32 => Room
    r[1] = Room.new(1, "Entrance Hall",
      "Flickering torches cast dancing shadows across damp stone walls. The air smells\n" \
      "of moss and ancient dust. A grand archway leads north, a heavy oak door east.",
      {Direction::North => 3, Direction::East => 2})
    r[2] = Room.new(2, "Armory",
      "Rusted weapons line the walls -- broken spears, dented shields. But something\n" \
      "gleams on a weapon rack: a crystal-edged sword, still sharp after centuries.",
      {Direction::West => 1}, item: "Crystal Sword")
    r[3] = Room.new(3, "Dark Corridor",
      "The corridor stretches ahead, swallowed by shadow. Your footsteps echo off\n" \
      "unseen walls. A foul stench drifts ahead. You hear a guttural snarl...",
      {Direction::South => 1, Direction::North => 5, Direction::East => 4},
      monster: Monster.new(MONSTER_STATS[:goblin][:name], MONSTER_STATS[:goblin][:hp],
        MONSTER_STATS[:goblin][:attack], MONSTER_STATS[:goblin][:xp]))
    r[4] = Room.new(4, "Library",
      "Towering bookshelves sag under moldering tomes. A spectral lantern casts pale\n" \
      "blue light. A dusty crimson vial sits on a pedestal beside a wall inscription.",
      {Direction::West => 3}, item: "Health Potion")
    r[5] = Room.new(5, "Throne Room",
      "A cavernous hall of black marble. A crumbling throne sits atop a dais. Before it\n" \
      "stands a towering figure of bone and rusted armor -- the Skeleton Knight, its\n" \
      "hollow eyes blazing with cold fire.",
      {Direction::South => 3, Direction::East => 6},
      monster: Monster.new(MONSTER_STATS[:skeleton][:name], MONSTER_STATS[:skeleton][:hp],
        MONSTER_STATS[:skeleton][:attack], MONSTER_STATS[:skeleton][:xp]))
    r[6] = Room.new(6, "Treasury",
      "Mountains of gold coins and glittering gems fill the chamber! Ancient Crystal\n" \
      "artifacts pulse with inner light. The legendary treasure of the Crystal Caverns!",
      {Direction::West => 5})
    r
  end

  def current_room : Room
    @rooms[@hero.room_id]
  end

  # Feature 6: String operations - command parsing and output formatting
  def process(input : String) : String
    @output = IO::Memory.new
    cmd = input.strip.downcase

    if @status != GameStatus::Playing
      @output << "[STATUS] The adventure is over. Call game_init() to restart.\n"
      return @output.to_s
    end

    # Feature 7: Regex - command matching (PCRE2)
    case cmd
    when "help"             then do_help
    when "look", "l"        then do_look
    when /^(north|n)$/      then do_move(Direction::North)
    when /^(south|s)$/      then do_move(Direction::South)
    when /^(east|e)$/       then do_move(Direction::East)
    when /^(west|w)$/       then do_move(Direction::West)
    when "attack", "a"      then do_attack
    when /^take\s+(.+)$/    then do_take($1)
    when "use potion"       then do_use_potion
    when "inventory", "i"   then do_inventory
    when "stats"            then do_stats
    when "riddle"           then do_riddle
    else
      # Feature 9: Exception handling - invalid commands
      begin
        raise "Unknown command: '#{cmd}'"
      rescue ex
        @output << "[ERROR] #{ex.message}. Type 'help' for commands.\n"
      end
    end
    @output.to_s
  end

  private def do_help
    @output << "[STATUS] Commands: look(l), north/south/east/west(n/s/e/w), attack(a),\n"
    @output << "  take <item>, use potion, inventory(i), stats, riddle, help\n"
  end

  private def do_look
    room = current_room
    @output << "== #{room.name} ==\n#{room.description}\n"
    if (m = room.monster) && m.alive?
      @output << "[COMBAT] A #{m.name} blocks your path! (HP: #{m.hp}/#{m.max_hp})\n"
    elsif (m = room.monster) && !m.alive?
      @output << "The remains of a #{m.name} lie on the ground.\n"
    end
    @output << "[ITEM] You see: #{room.item}\n" if room.item
    @output << "Exits: #{room.exits.keys.map(&.to_s.downcase).join(", ")}\n"
  end

  private def do_move(dir : Direction)
    room = current_room
    if (m = room.monster) && m.alive?
      @output << "[COMBAT] The #{m.name} blocks your escape! You must fight!\n"
      return
    end
    if next_id = room.exits[dir]?
      @hero.room_id = next_id
      @output << "You head #{dir.to_s.downcase}...\n\n"
      do_look
      check_win
    else
      @output << "[ERROR] You can't go #{dir.to_s.downcase} from here.\n"
    end
  end

  # Feature 8: Random - combat damage rolls
  # Feature 10: Math - damage calculations
  private def do_attack
    monster = current_room.monster
    if monster.nil? || !monster.alive?
      @output << "[ERROR] There is nothing to attack here.\n"
      return
    end
    # Hero attacks
    base = @hero.attack + (@hero.has?("Crystal Sword") ? 5 : 0)
    roll = Random.rand(1..6)
    crit = Random.rand(1.0) > 0.85
    damage = crit ? (base + roll) * 2 : base + roll
    monster.hp = Math.max(0, monster.hp - damage)
    if crit
      @output << "[COMBAT] *** CRITICAL HIT! *** You slash for #{damage} damage!\n"
    else
      @output << "[COMBAT] You strike the #{monster.name} for #{damage} damage.\n"
    end
    unless monster.alive?
      @output << "[COMBAT] The #{monster.name} collapses! (+#{monster.xp_reward} XP)\n"
      if monster.name == MONSTER_STATS[:skeleton][:name]
        @output << "[ITEM] The Skeleton Knight drops a Bone Key!\n"
        @hero.inventory << "Bone Key" unless @hero.has?("Bone Key")
      end
      return
    end
    # Monster counterattack
    m_damage = Math.max(1, monster.attack + Random.rand(1..4) - @hero.defense)
    @hero.hp = Math.max(0, @hero.hp - m_damage)
    @output << "[COMBAT] The #{monster.name} retaliates for #{m_damage} damage! "
    @output << "(HP: #{@hero.hp}/#{@hero.max_hp})\n"
    unless @hero.alive?
      @status = GameStatus::Dead
      @output << "\n[STATUS] You have fallen in the Crystal Caverns. Your adventure ends here.\n"
    end
  end

  private def do_take(item_name : String)
    room = current_room
    if room_item = room.item
      unless room_item.downcase == item_name.downcase
        @output << "[ERROR] You don't see '#{item_name}' here.\n"
        return
      end
      if room.id == 4 && !room.riddle_solved
        @output << "[ERROR] An inscription reads: 'Answer my riddle to claim the potion.'\n"
        @output << "[STATUS] Type 'riddle' to attempt it.\n"
        return
      end
      @hero.inventory << room_item
      room.item = nil
      @output << "[ITEM] You take the #{room_item}.\n"
    else
      @output << "[ERROR] There is nothing to take here.\n"
    end
  end

  private def do_use_potion
    unless @hero.has?("Health Potion")
      return @output << "[ERROR] You don't have a Health Potion.\n"
    end
    @hero.inventory.delete("Health Potion")
    healed = Math.min(30, @hero.max_hp - @hero.hp)
    @hero.hp = Math.min(@hero.hp + 30, @hero.max_hp)
    @output << "[ITEM] You drink the Health Potion and recover #{healed} HP! (HP: #{@hero.hp}/#{@hero.max_hp})\n"
  end

  private def do_inventory
    return @output << "[STATUS] Your pack is empty.\n" if @hero.inventory.empty?
    @output << "[STATUS] Inventory:\n"
    @hero.inventory.each_with_index { |item, i| @output << "  #{i + 1}. #{item}\n" }
  end

  private def do_stats
    sword = @hero.has?("Crystal Sword") ? " (+5 Crystal Sword)" : ""
    @output << "[STATUS] Hero -- HP: #{@hero.hp}/#{@hero.max_hp} | Atk: #{@hero.attack}#{sword} | Def: #{@hero.defense} | Room: #{current_room.name}\n"
  end

  private def do_riddle
    room = current_room
    unless room.id == 4
      @output << "[ERROR] There is no riddle here.\n"
      return
    end
    if room.riddle_solved
      @output << "[STATUS] You already solved the riddle.\n"
      return
    end
    room.riddle_solved = true
    @output << "[STATUS] The inscription reads:\n" \
               "  'I am compiled, never interpreted. I sparkle and I am strong.\n" \
               "   What language am I?'\n\n" \
               "You whisper: \"Crystal.\"\n\n" \
               "The pedestal glows! The potion is now free to take.\n"
  end

  private def check_win
    return unless @hero.room_id == 6
    @status = GameStatus::Won
    @output << "\n[STATUS] *** VICTORY! ***\n" \
               "[STATUS] You claimed the treasure of the Crystal Caverns!\n" \
               "[STATUS] Congratulations, brave adventurer!\n"
  end
end

GAME = Pointer(Game).malloc(1) # Global game instance for WASM lifetime

# Exported WASM functions (Crystal `fun` = WASM export)

fun game_init : Int32 # Initialize game state, returns 0 on success
  GAME.value = Game.new
  write_output(GAME.value.process("look"))
  0
end

fun game_command(input_ptr : UInt8*, input_len : Int32) : Int32 # Process command, returns output length
  write_output(GAME.value.process(String.new(input_ptr, input_len)))
  OUTPUT_LENGTH.value
end

fun game_get_output : UInt8*          # Pointer to output buffer
  OUTPUT_BUFFER
end

fun game_alloc(size : Int32) : UInt8* # Allocate WASM memory for JS input
  Pointer(UInt8).malloc(size)
end

fun game_get_room : Int32    # Current room ID for JS rendering
  GAME.value.hero.room_id
end

fun game_get_hp : Int32      # Hero HP for JS health bar
  GAME.value.hero.hp
end

fun game_get_max_hp : Int32  # Hero max HP
  GAME.value.hero.max_hp
end

fun game_get_status : Int32  # Game status: 1=won, -1=dead, 0=playing
  case GAME.value.status
  when .won?  then 1
  when .dead? then -1
  else             0
  end
end
