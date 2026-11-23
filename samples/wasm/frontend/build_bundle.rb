#!/usr/bin/ruby
# Pack Crystal sources into one JSON bundle for the in-browser frontend:
# { "files": { "/mount/relative/path.cr": "source text", ... } }
#
# usage: build_bundle.rb <out.json> [--crystal-path=/a:/b] [--default-args="..."] <mount>=<directory or file> ...
#   Every *.cr file under <directory> lands under <mount>. The std library's
#   compiler and specs are left out: a user program never
#   requires them. A <file> (for example a target profile) lands at <mount>
#   itself. --crystal-path is stored for the page to pass as CRYSTAL_PATH, and
#   --default-args for the page to pass before the file (e.g. a target profile).
require "json"
require "find"

out, *mounts = ARGV
crystal_path = nil
default_args = nil
mounts = mounts.reject do |arg|
  if arg.start_with?("--crystal-path=")
    crystal_path = arg.delete_prefix("--crystal-path=")
  elsif arg.start_with?("--default-args=")
    default_args = arg.delete_prefix("--default-args=").split
  end
end
abort "usage: build_bundle.rb <out.json> <mount>=<dir> ..." if out.nil? || mounts.empty?

SKIPPED_DIRECTORIES = %w[compiler spec .git .build node_modules].freeze

files = {}
mounts.each do |pair|
  mount, directory = pair.split("=", 2)
  directory = File.expand_path(directory)
  if File.file?(directory)
    files[mount] = File.read(directory, encoding: "UTF-8")
    next
  end
  Find.find(directory) do |path|
    if File.directory?(path)
      Find.prune if path != directory && SKIPPED_DIRECTORIES.include?(File.basename(path))
      next
    end
    next unless path.end_with?(".cr")

    relative = path.delete_prefix(directory + "/")
    files[File.join(mount, relative)] = File.read(path, encoding: "UTF-8")
  end
end

bundle = { "files" => files }
bundle["crystal_path"] = crystal_path if crystal_path
bundle["default_args"] = default_args if default_args
File.write(out, JSON.generate(bundle))
bytes = files.values.sum(&:bytesize)
puts "#{files.size} files, #{bytes} bytes of source, #{File.size(out)} bytes of JSON -> #{out}"
