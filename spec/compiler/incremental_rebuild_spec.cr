require "../spec_helper"

private def build_incrementally(program : String, executable : String, resident_modules : Int32 = 0) : Crystal::Compiler
  compiler = Crystal::Compiler.new
  compiler.incremental = true
  # Two or more threads compile each module on a worker thread with an
  # isolated LLVM context, the path that disposes contexts.
  compiler.n_threads = 2
  # With a limit, IR generation spills modules to disk in parts.
  compiler.resident_modules = resident_modules
  ENV["CRYSTAL_SPEC_COMPILER_FLAGS"]?.try { |flags| compiler.flags.concat(flags.split) }
  compiler.compile(Crystal::Compiler::Source.new(program, File.read(program)), executable)
  compiler
end

private HELPER_SOURCE = "module Helper\n  def self.value\n    ARGV.size + 111\n  end\nend\n"
private USER_SOURCE   = "class User\n  def initialize(@n : Int32)\n  end\n\n  def show\n    puts Helper.value &+ @n\n  end\nend\n"

# Writes a program of three files, each with a module of its own, and
# returns the paths of helper.cr, program.cr and the executable.
private def write_helper_program(directory : String) : {String, String, String}
  Dir.mkdir_p(directory)
  helper = File.join(directory, "helper.cr")
  program = File.join(directory, "program.cr")
  File.write(helper, HELPER_SOURCE)
  File.write(File.join(directory, "user.cr"), USER_SOURCE)
  File.write(program, %(require "./helper"\nrequire "./user"\nUser.new(ARGV.size).show\n))
  {helper, program, File.join(directory, "program")}
end

# Changes one number in helper.cr; the file keeps its size.
private def edit_helper(helper : String, seconds_ahead : Int32 = 5) : Nil
  File.write(helper, HELPER_SOURCE.sub("111", "112"))
  File.touch(helper, Time.utc + seconds_ahead.seconds)
end

private def list_of_cached(program : String, pattern : Regex) : Array(String)
  cache_directory = Crystal::CacheDir.instance.directory_for(program)
  Dir.children(cache_directory).select(&.matches?(pattern)).sort!.map { |child| File.join(cache_directory, child) }
end

# The cached bitcode files of the module of `Helper`, first part first.
private def list_of_helper_bitcode(program : String) : Array(String)
  list_of_cached(program, /\AH-elper\.o0(\.part\d+)?\.bc\z/)
end

private def modification_times(list_of_filenames : Array(String)) : Hash(String, Time)
  list_of_filenames.to_h { |filename| {filename, File.info(filename).modification_time} }
end

describe "Compiler with --incremental" do
  it "rebuilds a module whose bitcode changes while its size stays the same" do
    with_tempfile("same_size_program") do |directory|
      helper, program, executable = write_helper_program(directory)

      build_incrementally(program, executable)
      Process.capture(executable).should eq("111\n")
      list_of_bitcode_before = list_of_helper_bitcode(program)
      list_of_bitcode_before.size.should eq(1)
      bitcode_before = File.read(list_of_bitcode_before.first)
      objects_before = modification_times(list_of_cached(program, /\.o\z/))
      objects_before.size.should be > 2
      # Every object has the record of the bitcode it was built from.
      list_of_cached(program, /\.hash\z/).size.should eq(objects_before.size)

      edit_helper(helper)
      build_incrementally(program, executable)
      Process.capture(executable).should eq("112\n")

      bitcode_after = File.read(list_of_helper_bitcode(program).first)
      bitcode_after.bytesize.should eq(bitcode_before.bytesize)
      bitcode_after.should_not eq(bitcode_before)
      # Only the object of `Helper` was built again.
      objects_after = modification_times(list_of_cached(program, /\.o\z/))
      list_of_rebuilt = objects_after.keys.select { |filename| objects_after[filename] != objects_before[filename] }
      list_of_rebuilt.map { |filename| File.basename(filename) }.should eq(["H-elper.o0.o"])
    end
  end

  it "rebuilds a module spilled in parts whose bitcode changes while its size stays the same" do
    with_tempfile("same_size_spilled_program") do |directory|
      helper, program, executable = write_helper_program(directory)

      build = build_incrementally(program, executable, resident_modules: 1)
      build.last_module_spill.should_not be_nil
      Process.capture(executable).should eq("111\n")
      list_of_bitcode_before = list_of_helper_bitcode(program)
      list_of_sizes_before = list_of_bitcode_before.map { |filename| File.size(filename) }
      list_of_contents_before = list_of_bitcode_before.map { |filename| File.read(filename) }
      objects_before = modification_times(list_of_cached(program, /\.o\z/))
      list_of_cached(program, /\.hash\z/).size.should eq(objects_before.size)

      edit_helper(helper)
      rebuild = build_incrementally(program, executable, resident_modules: 1)
      Process.capture(executable).should eq("112\n")

      list_of_bitcode_after = list_of_helper_bitcode(program)
      list_of_bitcode_after.map { |filename| File.size(filename) }.should eq(list_of_sizes_before)
      list_of_bitcode_after.map { |filename| File.read(filename) }.should_not eq(list_of_contents_before)
      objects_after = modification_times(list_of_cached(program, /\.o\z/))
      list_of_rebuilt = objects_after.keys.select { |filename| objects_after[filename] != objects_before[filename] }
      list_of_rebuilt.map { |filename| File.basename(filename) }.should eq(["H-elper.o0.o"])

      # The parts whose bitcode the cache already had were linked to their
      # cached files instead of written, and no spill file is left.
      module_spill = rebuild.last_module_spill.should_not be_nil
      module_spill.linked_part_count.should be > 0
      module_spill.linked_part_count.should be < module_spill.spill_count
      list_of_cached(program, /\.new\.bc\z/).should be_empty
    end
  end

  it "reuses an object by the hash of its bitcode, without reading the cached bitcode" do
    with_tempfile("hash_only_program") do |directory|
      helper, program, executable = write_helper_program(directory)

      build_incrementally(program, executable)
      objects_before = modification_times(list_of_cached(program, /\.o\z/))
      # A build that compared bitcode files would find every module changed.
      list_of_cached(program, /\.bc\z/).each { |filename| File.write(filename, "not bitcode") }

      File.touch(helper, Time.utc + 5.seconds)
      build_incrementally(program, executable)
      modification_times(list_of_cached(program, /\.o\z/)).should eq(objects_before)
      Process.capture(executable).should eq("111\n")
    end
  end

  it "builds an object again when it is not the one its record was written for" do
    with_tempfile("replaced_object_program") do |directory|
      helper, program, executable = write_helper_program(directory)

      build_incrementally(program, executable)
      helper_object = list_of_cached(program, /\AH-elper\.o0\.o\z/).first
      helper_record = list_of_cached(program, /\AH-elper\.o0\.hash\z/).first
      record_before = Crystal::CachedObjectRecord.read?(helper_record).should_not be_nil
      # Another compiler replaced the object and its bitcode, and knows
      # nothing of the record.
      File.write(helper_object, "not an object")
      File.write(list_of_helper_bitcode(program).first, "not bitcode")
      File.touch(helper_object, Time.utc + 3.seconds)

      File.touch(helper, Time.utc + 5.seconds)
      build_incrementally(program, executable)
      Process.capture(executable).should eq("111\n")
      record_after = Crystal::CachedObjectRecord.read?(helper_record).should_not be_nil
      record_after.module_hash.should eq(record_before.module_hash)
      record_after.written_as.should_not eq(record_before.written_as)
      record_after.describes_objects?([helper_object]).should be_true
    end
  end

  it "rebuilds an edited program and reuses the object files of unchanged modules" do
    with_tempfile("edited_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      # A body the code generator does not inline: only the module of
      # `Helper` changes.
      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 1\n  end\nend\n")
      File.write(program, %(require "./helper"\nputs Helper.value\n))

      build_incrementally(program, executable)
      Process.capture(executable).should eq("1\n")

      File.write(helper, "module Helper\n  def self.value\n    ARGV.size + 999\n  end\nend\n")
      File.touch(helper, Time.utc + 5.seconds)
      rebuild = build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
      rebuild.@last_modules_total.should be > 1

      build_incrementally(program, executable)
      Process.capture(executable).should eq("999\n")
    end
  end

  it "rebuilds a module that inlines a body another file changed" do
    with_tempfile("inlined_body_program") do |directory|
      Dir.mkdir_p(directory)
      helper = File.join(directory, "helper.cr")
      user = File.join(directory, "user.cr")
      program = File.join(directory, "program.cr")
      executable = File.join(directory, "program")
      # `Helper.value` is inlined into `User#show`, in the module of `User`,
      # whose own defs are all in user.cr. `Helper.other` is not inlined, so
      # helper.cr has a module of its own as well.
      helper_source = "module Helper\n  def self.value\n    1\n  end\n\n  def self.other(x)\n    x > 0 ? 10 : 20\n  end\nend\n"
      File.write(helper, helper_source)
      File.write(user, "class User\n  def initialize(@n : Int32)\n  end\n\n  def show\n    puts Helper.value + Helper.other(@n)\n  end\nend\n")
      File.write(program, %(require "./helper"\nrequire "./user"\nUser.new(ARGV.size).show\n))

      build_incrementally(program, executable)
      Process.capture(executable).should eq("21\n")

      File.write(helper, helper_source.sub("    1\n", "    100\n"))
      File.touch(helper, Time.utc + 5.seconds)
      build_incrementally(program, executable)
      Process.capture(executable).should eq("120\n")
    end
  end
end
