require "../unix/file"

# :nodoc:
module Crystal::System::File
  protected def system_init(mode : String, blocking : Bool) : Nil
  end

  def self.chmod(path, mode)
    raise NotImplementedError.new "Crystal::System::File.chmod: file permission changes are not available in the WASM sandbox. WASI does not support POSIX file permissions."
  end

  def self.chown(path, uid : Int, gid : Int, follow_symlinks)
    raise NotImplementedError.new "Crystal::System::File.chown: file ownership changes are not available in the WASM sandbox. WASI does not support POSIX file ownership."
  end

  private def system_chown(uid : Int, gid : Int)
    raise NotImplementedError.new "Crystal::System::File#system_chown: file ownership changes are not available in the WASM sandbox. WASI does not support POSIX file ownership."
  end

  def self.realpath(path)
    raise NotImplementedError.new "Crystal::System::File.realpath: realpath is not available in the WASM sandbox. WASI has limited filesystem path resolution."
  end

  def self.utime(atime : ::Time, mtime : ::Time, filename : String) : Nil
    raise NotImplementedError.new "Crystal::System::File.utime: setting file timestamps is not available in the WASM sandbox."
  end

  def self.delete(path : String, *, raise_on_missing : Bool) : Bool
    raise NotImplementedError.new "Crystal::System::File.delete: file deletion is not available in the WASM sandbox. Use WASI-compatible file operations through preopened directories."
  end
end
