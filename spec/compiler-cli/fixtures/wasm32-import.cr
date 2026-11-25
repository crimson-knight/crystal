# A lib fun the host provides in its own import module.
@[Link(wasm_import_module: "host")]
lib LibHost
  fun host_note(code : Int32) : Void
end

fun note_twice(code : Int32) : Void
  LibHost.host_note(code)
  LibHost.host_note(code)
end
