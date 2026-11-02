#! /usr/bin/env crystal
#
# Compiles the standard library's ECR helper (`ecr/process.cr`, the macro run
# program behind `ECR.embed` and `ECR.def_to_s`) with an installed compiler and
# stores it as a macro run seed next to the standard library:
#
#   <stdlib>/../macro_run_seed/ecr-process.cr/
#
# The compiler uses the seed instead of compiling the helper into an empty
# cache, as long as the seed was built by the same compiler executable from
# unchanged files (see `Crystal::Program#seeded_macro_run`). Run it after the
# compiler and its standard library are in their final place:
#
#   crystal run scripts/seed_macro_run.cr -- COMPILER STDLIB_SRC_DIR
#
# `make macro_run_seed` does this for a source checkout (`bin/crystal`, `src`).

require "file_utils"

MACRO_RUN_PROGRAMS = {"ecr/process.cr"}

class MacroRunSeedError < Exception
end

unless ARGV.size == 2
  abort "Usage: crystal run scripts/seed_macro_run.cr -- COMPILER STDLIB_SRC_DIR"
end

# A compiler given as a relative path keeps working from the temporary directory.
compiler = ARGV[0].includes?('/') ? File.expand_path(ARGV[0]) : ARGV[0]
stdlib_dir = File.expand_path(ARGV[1])
seed_root = File.join(File.dirname(stdlib_dir), "macro_run_seed")
work_dir = File.join(Dir.tempdir, "crystal-macro-run-seed-#{Random::Secure.hex(8)}")
cache_dir = File.join(work_dir, "cache")

begin
  Dir.mkdir_p(cache_dir)
  template_path = File.join(work_dir, "seed.ecr")
  source_path = File.join(work_dir, "seed.cr")
  File.write(template_path, "<%= 1 %>\n")
  File.write(source_path, "require \"ecr\"\nputs ECR.render(#{template_path.inspect})\n")

  # A type-checking build runs every macro, so it compiles the helper into
  # the empty cache with the compiler's default settings. CRYSTAL_MACRO_RUN_SEED
  # makes the compiler ignore an existing seed and record what a seed needs.
  status = Process.run(compiler, ["build", "--no-codegen", source_path],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir, "CRYSTAL_PATH" => "lib:#{stdlib_dir}", "CRYSTAL_MACRO_RUN_SEED" => "write"},
    chdir: work_dir, output: :inherit, error: :inherit)
  raise MacroRunSeedError.new("#{compiler} could not compile the seed program (#{status})") unless status.success?

  MACRO_RUN_PROGRAMS.each do |program|
    seed_name = program.gsub('/', '-')
    cache_entry = Dir.children(cache_dir)
      .map { |name| File.join(cache_dir, name) }
      .find { |dir| dir.ends_with?("-#{seed_name}") && File.exists?(File.join(dir, "macro_run")) }
    raise MacroRunSeedError.new("the compiler left no cached macro run for #{program} in #{cache_dir}") unless cache_entry

    # Build the new seed beside the old one, then swap the directories, so a
    # build never sees a partly written seed.
    seed_dir = File.join(seed_root, seed_name)
    staged_dir = File.join(seed_root, ".#{seed_name}.#{Random::Secure.hex(4)}")
    Dir.mkdir_p(staged_dir)
    {"macro_run", "recorded_requires", "requires", "compiler", "source_digests"}.each do |file|
      source_file = File.join(cache_entry, file)
      raise MacroRunSeedError.new("#{source_file} is missing; is #{compiler} a compiler that writes macro run seeds?") unless File.exists?(source_file)
      FileUtils.cp(source_file, File.join(staged_dir, file))
    end
    File.chmod(File.join(staged_dir, "macro_run"), 0o755)

    retired_dir = "#{staged_dir}.old"
    File.rename(seed_dir, retired_dir) if Dir.exists?(seed_dir)
    File.rename(staged_dir, seed_dir)
    FileUtils.rm_rf(retired_dir)
    puts "Seeded #{program} in #{seed_dir}"
  end
rescue error : MacroRunSeedError
  abort error.message
ensure
  FileUtils.rm_rf(work_dir)
end
