require "./signal"
require "./sys/types"

lib LibC
  POSIX_SPAWN_SETSIGDEF  = 0x04
  POSIX_SPAWN_SETSIGMASK = 0x08

  # Opaque to Crystal: only initialized and passed around by pointer.
  struct PosixSpawnattrT
    __data : StaticArray(UInt64, 42) # 336 bytes
  end

  struct PosixSpawnFileActionsT
    __data : StaticArray(UInt64, 10) # 80 bytes
  end

  fun posix_spawnp(pid : PidT*, file : Char*, file_actions : PosixSpawnFileActionsT*, attrp : PosixSpawnattrT*, argv : Char**, envp : Char**) : Int
  fun posix_spawnattr_init(attr : PosixSpawnattrT*) : Int
  fun posix_spawnattr_destroy(attr : PosixSpawnattrT*) : Int
  fun posix_spawnattr_setflags(attr : PosixSpawnattrT*, flags : Short) : Int
  fun posix_spawnattr_setsigmask(attr : PosixSpawnattrT*, sigmask : SigsetT*) : Int
  fun posix_spawnattr_setsigdefault(attr : PosixSpawnattrT*, sigdefault : SigsetT*) : Int
  fun posix_spawn_file_actions_init(file_actions : PosixSpawnFileActionsT*) : Int
  fun posix_spawn_file_actions_destroy(file_actions : PosixSpawnFileActionsT*) : Int
  fun posix_spawn_file_actions_adddup2(file_actions : PosixSpawnFileActionsT*, fd : Int, newfd : Int) : Int
  fun posix_spawn_file_actions_addclose(file_actions : PosixSpawnFileActionsT*, fd : Int) : Int
end
