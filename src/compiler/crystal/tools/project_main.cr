module Crystal
  # The main file of the shard in *dir*, for commands given no file: the
  # `main` of the first target in its `shard.yml`, otherwise `src/<name>.cr`
  # for the shard's name. Returns `nil` when there's none.
  #
  # `shard.yml` is read line by line instead of with a YAML parser, which
  # would make the compiler depend on libyaml; it only needs the `name` and
  # the targets' `main` entries, which are plain scalars.
  def self.project_main_file(dir : String = Dir.current) : String?
    shard_yml = File.join(dir, "shard.yml")
    return nil unless File.file?(shard_yml)

    name = nil
    in_targets = false
    File.each_line(shard_yml) do |line|
      next if line.strip.empty? || line.lstrip.starts_with?('#')

      indented = line.starts_with?(' ') || line.starts_with?('\t')
      unless indented
        in_targets = line.starts_with?("targets:")
        if match = line.match(/\Aname:\s*(.+?)\s*\z/)
          name = yaml_scalar(match[1])
        end
        next
      end

      if in_targets && (match = line.match(/\A\s+main:\s*(.+?)\s*\z/))
        main = File.join(dir, yaml_scalar(match[1]))
        return Crystal.relative_filename(main) if File.file?(main)
      end
    end

    if name
      main = File.join(dir, "src", "#{name}.cr")
      return Crystal.relative_filename(main) if File.file?(main)
    end

    nil
  end

  private def self.yaml_scalar(value : String) : String
    value = value.split(" #", 2).first.strip
    if value.size >= 2 && value[0] == value[-1] && value[0].in?('"', '\'')
      value = value[1...-1]
    end
    value
  end
end
