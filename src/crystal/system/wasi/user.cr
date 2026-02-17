module Crystal::System::User
  def system_username
    raise NotImplementedError.new("Crystal::System::User#system_username: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def system_id
    raise NotImplementedError.new("Crystal::System::User#system_id: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def system_group_id
    raise NotImplementedError.new("Crystal::System::User#system_group_id: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def system_name
    raise NotImplementedError.new("Crystal::System::User#system_name: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def system_home_directory
    raise NotImplementedError.new("Crystal::System::User#system_home_directory: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def system_shell
    raise NotImplementedError.new("Crystal::System::User#system_shell: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def self.from_username?(username : String)
    raise NotImplementedError.new("Crystal::System::User.from_username?: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end

  def self.from_id?(id : String)
    raise NotImplementedError.new("Crystal::System::User.from_id?: user information is not available in the WASM sandbox. WASI does not expose host user data.")
  end
end
