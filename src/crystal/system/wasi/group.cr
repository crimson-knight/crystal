module Crystal::System::Group
  def system_name
    raise NotImplementedError.new("Crystal::System::Group#system_name: group information is not available in the WASM sandbox. WASI does not expose host user/group data.")
  end

  def system_id
    raise NotImplementedError.new("Crystal::System::Group#system_id: group information is not available in the WASM sandbox. WASI does not expose host user/group data.")
  end

  def self.from_name?(groupname : String)
    raise NotImplementedError.new("Crystal::System::Group.from_name?: group information is not available in the WASM sandbox. WASI does not expose host user/group data.")
  end

  def self.from_id?(groupid : String)
    raise NotImplementedError.new("Crystal::System::Group.from_id?: group information is not available in the WASM sandbox. WASI does not expose host user/group data.")
  end
end
