#!/usr/bin/ruby
# Sharded differential runs of Crystal::BigNum::Integer against GMP
# (BIGNUM.md 5.2): one shard per seed, spread over the Mac minis through
# cluster-pool, over Colima (Linux aarch64) on m4-mini-01, or over GitHub's
# ubuntu-24.04 x86-64 runners; then the shard summaries are totaled.
#
# Run from the fork's root. Examples:
#   /usr/bin/ruby scripts/big_num/run_sharded.rb --where minis  --total 10000000 --shards 20 --out tmp/big_num/minis
#   /usr/bin/ruby scripts/big_num/run_sharded.rb --where local  --total 200000   --shards 4  --out tmp/big_num/local
#   /usr/bin/ruby scripts/big_num/run_sharded.rb --where colima --total 10000000 --shards 20 --out tmp/big_num/colima
#   /usr/bin/ruby scripts/big_num/run_sharded.rb --where github --total 10000000 --shards 20 --out tmp/big_num/github
#   /usr/bin/ruby scripts/big_num/run_sharded.rb --total-only --out tmp/big_num/minis
#
# Every shard is resumable: a shard whose summary is already in --out with the
# expected count is skipped, and each cluster-pool job carries the stable key
# bignum-diff-<seed>.
require "json"
require "optparse"
require "fileutils"
require "open3"
require "shellwords"

COLIMA_IMAGE = "crystallang/crystal@sha256:34ac3d5dd5098f85790b800c046f2a6d7fc292193a706d7a3f1acc5f004b94c3"
UBUNTU_GMP = "2:6.3.0+dfsg-2ubuntu6.1"
GMP_DYLIB = "/opt/homebrew/opt/gmp/lib/libgmp.10.dylib"
DEFAULT_BENCH_BRANCH = "bench/g2-harness-diff"

options = {
  where: "local", total: 100_000, shards: 4, first_seed: 1, out: nil, ops: nil, max_bits: 8192,
  subject: "engine", parallel: 8, binary: nil, total_only: false, keep_branch: false, branch: DEFAULT_BENCH_BRANCH,
}
OptionParser.new do |parser|
  parser.banner = "usage: run_sharded.rb [options]"
  parser.on("--where PLACE", "minis, local, colima or github (default local)") { |value| options[:where] = value }
  parser.on("--total N", Integer, "operations in all (default 100000)") { |value| options[:total] = value }
  parser.on("--shards N", Integer, "shards, one seed each (default 4)") { |value| options[:shards] = value }
  parser.on("--first-seed N", Integer, "seed of the first shard; shard k uses first-seed + k (default 1)") { |value| options[:first_seed] = value }
  parser.on("--out DIR", "where shard summaries and the total go") { |value| options[:out] = value }
  parser.on("--ops LIST", "operations filter passed to the binary") { |value| options[:ops] = value }
  parser.on("--max-bits N", Integer, "largest operand (default 8192)") { |value| options[:max_bits] = value }
  parser.on("--subject NAME", "engine (default) or double") { |value| options[:subject] = value }
  parser.on("--parallel N", Integer, "shards dispatched at once to the minis (default 8)") { |value| options[:parallel] = value }
  parser.on("--binary PATH", "a release differential binary already built for macOS arm64") { |value| options[:binary] = value }
  parser.on("--total-only", "only total the summaries already in --out") { options[:total_only] = true }
  parser.on("--branch NAME", "github: the temporary branch (default #{DEFAULT_BENCH_BRANCH})") { |value| options[:branch] = value }
  parser.on("--keep-branch", "github: leave the bench branch (default: delete it after the logs are fetched)") { options[:keep_branch] = true }
end.parse!
abort "--out is required" unless options[:out]
OUT = File.expand_path(options[:out])
ROOT = Dir.pwd
abort "run from the fork's root (no scripts/big_num/differential.cr here)" unless File.exist?(File.join(ROOT, "scripts/big_num/differential.cr"))
FileUtils.mkdir_p(OUT)

count_per_shard = (options[:total].to_f / options[:shards]).ceil
seeds = (0...options[:shards]).map { |index| options[:first_seed] + index }

def shard_done?(seed, count)
  path = File.join(OUT, "shard-#{seed}.json")
  return false unless File.exist?(path)
  JSON.parse(File.read(path))["total_count"] == count
rescue JSON::ParserError
  false
end

def binary_arguments(seed, count, options, json_path, reproducer_directory)
  arguments = ["--subject", options[:subject], "--seed", seed.to_s, "--count", count.to_s,
               "--max-bits", options[:max_bits].to_s, "--json", json_path, "--reproducers", reproducer_directory]
  arguments += ["--ops", options[:ops]] if options[:ops]
  arguments
end

# The compiler binary behind the crystal-alpha wrapper: the wrapper sets its
# own CRYSTAL_PATH, which would hide the fork's src/ from the build.
def compiler
  wrapper = `command -v crystal-alpha`.strip
  abort "crystal-alpha is not on PATH" if wrapper.empty?
  text = File.read(wrapper, 4096) rescue ""
  text[/exec "([^"]+)"/, 1] || wrapper
end

def build_macos_binary(options)
  return File.expand_path(options[:binary]) if options[:binary]
  binary = File.join(OUT, "build", "big_num_differential")
  FileUtils.mkdir_p(File.dirname(binary))
  command = [compiler, "build", "--release", "-Duse_gmp", "scripts/big_num/differential.cr", "-o", binary]
  puts "building: CRYSTAL_PATH=#{ROOT}/src #{command.join(" ")}"
  system({"CRYSTAL_PATH" => File.join(ROOT, "src")}, *command) or abort "build failed"
  binary
end

def run_on_minis(seeds, count, options)
  binary = build_macos_binary(options)
  queue = Queue.new
  seeds.reject { |seed| shard_done?(seed, count) }.each { |seed| queue << seed }
  puts "#{queue.size} shards to run, #{count} operations each"
  workers = Array.new([options[:parallel], queue.size].min) do
    Thread.new do
      until queue.empty?
        seed = (queue.pop(true) rescue break)
        arguments = binary_arguments(seed, count, options, "shard-#{seed}.json", "reproducers-#{seed}")
        shard = "./big_num_differential #{arguments.shelljoin} > shard-#{seed}.log 2>&1; " \
                "echo \"exit $?\" >> shard-#{seed}.log; hostname > shard-#{seed}.host.txt; " \
                "shasum -a 256 #{GMP_DYLIB} >> shard-#{seed}.host.txt; sw_vers -productVersion >> shard-#{seed}.host.txt; " \
                "mkdir -p reproducers-#{seed}; true"
        command = ["cluster-pool", "dispatch", "--on", "m4-mini-01", "--on", "m4-mini-02",
                   "--key", "bignum-diff-#{seed}", "--label", "BigNum differential seed #{seed} (#{count} ops)",
                   "--cores", "1", "--ram", "1", "--storage", "1", "--time", "60m", "--wait", "3h",
                   "--result", "shard-#{seed}.json", "--result", "shard-#{seed}.log",
                   "--result", "shard-#{seed}.host.txt", "--result", "reproducers-#{seed}",
                   "--", "/bin/zsh", "-c", shard]
        # One folder per shard: cluster-pool copies the folder out and the
        # results back, and shards sharing a folder race in rsync.
        stage = File.join(OUT, "stage", "seed-#{seed}")
        FileUtils.mkdir_p(stage)
        FileUtils.cp(binary, File.join(stage, "big_num_differential"))
        output, status = "", nil
        3.times do
          output, status = Open3.capture2e(*command, chdir: stage)
          break if status.success? && File.exist?(File.join(stage, "shard-#{seed}.json"))
          sleep 5
        end
        File.write(File.join(OUT, "dispatch-#{seed}.log"), output)
        %W(shard-#{seed}.json shard-#{seed}.log shard-#{seed}.host.txt).each do |name|
          FileUtils.cp(File.join(stage, name), OUT) if File.exist?(File.join(stage, name))
        end
        reproducers = File.join(stage, "reproducers-#{seed}")
        FileUtils.cp_r(reproducers, OUT) if Dir.exist?(reproducers) && !Dir.empty?(reproducers)
        puts "seed #{seed}: dispatch #{status.success? ? "ok" : "FAILED"} #{output.lines.last&.strip}"
      end
    end
  end
  workers.each(&:join)
end

def run_locally(seeds, count, options)
  binary = build_macos_binary(options)
  seeds.reject { |seed| shard_done?(seed, count) }.each do |seed|
    arguments = binary_arguments(seed, count, options, File.join(OUT, "shard-#{seed}.json"), File.join(OUT, "reproducers-#{seed}"))
    command = ["cluster-pool", "run", "--resume", "--key", "bignum-diff-#{seed}",
               "--label", "BigNum differential seed #{seed} (#{count} ops)",
               "--cores", "1", "--ram", "1", "--storage", "1", "--time", "60m", "--wait", "3h",
               "--", binary] + arguments
    output, _ = Open3.capture2e(*command)
    File.write(File.join(OUT, "shard-#{seed}.log"), output)
    File.write(File.join(OUT, "shard-#{seed}.host.txt"), "#{`hostname`}#{`shasum -a 256 #{GMP_DYLIB}`}#{`sw_vers -productVersion`}")
    puts "seed #{seed}: #{output.lines.grep(/^seed=/).last&.strip}"
  end
end

# The shell a Linux shard host runs: build with the fork's stdlib, then run
# every seed. Takes the source tree at $SRC and writes into $OUT_DIR.
def linux_script(seeds, count, options, compiler_command)
  runs = seeds.map do |seed|
    arguments = binary_arguments(seed, count, options, "$OUT_DIR/shard-#{seed}.json", "$OUT_DIR/reproducers-#{seed}")
    "[ -s $OUT_DIR/shard-#{seed}.json ] || ./big_num_differential #{arguments.map { |argument| argument.start_with?("$") ? argument : argument.shellescape }.join(" ")} 2>&1 | tail -5 | tee $OUT_DIR/shard-#{seed}.log"
  end
  <<~SH
    set -e
    cd "$SRC"
    #{compiler_command} --version | tee $OUT_DIR/compiler.txt
    CRYSTAL_PATH="$SRC/src" #{compiler_command} build --release -Duse_gmp scripts/big_num/differential.cr -o big_num_differential
    { uname -m; dpkg-query -W libgmp10 libgmp-dev; sha256sum $(dpkg -L libgmp10 | grep 'libgmp.so.10.[0-9.]*$'); } | tee $OUT_DIR/host.txt
    set +e
    #{runs.join("\n")}
    true
  SH
end

def source_tarball(stage)
  FileUtils.mkdir_p(stage)
  tarball = File.join(stage, "fork.tar.gz")
  system("tar", "-czf", tarball, "-C", ROOT, "src", "scripts/big_num") or abort "tar failed"
  tarball
end

def run_on_colima(seeds, count, options)
  stage = File.join(OUT, "colima-stage")
  source_tarball(stage)
  pending = seeds.reject { |seed| shard_done?(seed, count) }
  return puts("every shard is done") if pending.empty?
  File.write(File.join(stage, "shards.sh"), linux_script(pending, count, options, "crystal"))
  inner = "apt-get install -y --no-install-recommends libgmp-dev=#{UBUNTU_GMP} >/dev/null && " \
          "mkdir -p /work/src && tar -xzf /stage/fork.tar.gz -C /work/src && SRC=/work/src OUT_DIR=/stage/out sh /stage/shards.sh"
  shard_command = "export PATH=/opt/homebrew/bin:$PATH; mkdir -p out; docker --context colima run --rm -v \"$PWD:/stage\" " \
                  "#{COLIMA_IMAGE} sh -c #{inner.shellescape}"
  command = ["cluster-pool", "dispatch", "--on", "m4-mini-01", "--key", "bignum-diff-colima",
             "--label", "BigNum differential Linux aarch64 (Colima), seeds #{pending.first}..#{pending.last}",
             "--cores", "2", "--ram", "2", "--storage", "2", "--time", "60m", "--wait", "3h",
             "--result", "out", "--", "/bin/zsh", "-c", shard_command]
  output, status = Open3.capture2e(*command, chdir: stage)
  File.write(File.join(OUT, "dispatch-colima.log"), output)
  Dir.glob(File.join(stage, "out", "*")).each { |path| FileUtils.cp_r(path, OUT) }
  puts "colima: #{status.success? ? "ok" : "FAILED"}\n#{output.lines.last(5).join}"
end

def run_on_github(seeds, count, options)
  workflow = File.read(File.join(ROOT, "scripts/big_num/github/bignum-diff-linux-x86_64.yml"))
  arguments = ["--subject", options[:subject], "--max-bits", options[:max_bits].to_s]
  arguments += ["--ops", options[:ops]] if options[:ops]
  workflow = workflow.gsub("__SEEDS__", seeds.join(" ")).gsub("__COUNT__", count.to_s).gsub("__ARGUMENTS__", arguments.shelljoin)
  workflow = workflow.gsub(DEFAULT_BENCH_BRANCH, options[:branch])
  bench_branch = options[:branch]
  worktree = File.join(OUT, "github-worktree")
  FileUtils.rm_rf(worktree)
  system("git", "worktree", "add", "--detach", worktree, "HEAD", exception: true)
  # Uncommitted changes in the fork travel with the run, as they do into the
  # Colima tarball, so a run tests the tree as it is on disk.
  patch = `git diff HEAD`
  unless patch.empty?
    IO.popen(["git", "-C", worktree, "apply"], "w") { |io| io.write(patch) }
    system("git", "-C", worktree, "add", "-A", exception: true)
  end
  FileUtils.mkdir_p(File.join(worktree, ".github/workflows"))
  Dir.glob(File.join(worktree, ".github/workflows/*")).each { |path| FileUtils.rm_f(path) }
  File.write(File.join(worktree, ".github/workflows/bignum-diff.yml"), workflow)
  system("git", "-C", worktree, "add", ".github/workflows", exception: true)
  system("git", "-C", worktree, "commit", "-q", "-m", "bench: BigNum differential on ubuntu-24.04 x86-64", exception: true)
  head = `git -C #{worktree.shellescape} rev-parse HEAD`.strip
  system("git", "-C", worktree, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{bench_branch}", exception: true)
  puts "pushed #{bench_branch} at #{head}; waiting for the run"
  run_id = nil
  60.times do
    run_id = `gh run list --branch #{bench_branch} --commit #{head} --json databaseId --jq '.[0].databaseId'`.strip
    break unless run_id.empty?
    sleep 10
  end
  abort "no workflow run appeared for #{head}" if run_id.to_s.empty?
  system("gh", "run", "watch", run_id, "--exit-status", "--interval", "30")
  system("gh", "run", "view", run_id, "--log", out: File.join(OUT, "github-run-#{run_id}.log"))
  system("gh", "run", "download", run_id, "--dir", File.join(OUT, "github-artifacts"))
  Dir.glob(File.join(OUT, "github-artifacts", "*", "*")).each { |path| FileUtils.cp_r(path, OUT) }
  unless options[:keep_branch]
    system("git", "push", "-q", "origin", "--delete", bench_branch)
  end
  system("git", "worktree", "remove", "--force", worktree)
end

def total(seeds, count)
  summaries = Dir.glob(File.join(OUT, "shard-*.json")).map { |path| JSON.parse(File.read(path)) }
  operations = Hash.new { |hash, key| hash[key] = {"count" => 0, "differences" => 0, "pending" => 0, "oracle_raised" => 0} }
  summaries.each do |summary|
    summary["operations"].each do |name, tally|
      tally.each { |field, value| operations[name][field] += value }
    end
  end
  missing = seeds.reject { |seed| summaries.any? { |summary| summary["seed"] == seed && summary["total_count"] == count } }
  totals = {
    "shards" => summaries.size,
    "seeds" => summaries.map { |summary| summary["seed"] }.sort,
    "missing_seeds" => missing,
    "targets" => summaries.map { |summary| summary["target"] }.uniq,
    "gmp_versions" => summaries.map { |summary| summary["gmp_version"] }.uniq,
    "subject" => summaries.map { |summary| summary["subject"] }.uniq,
    "total_count" => operations.values.sum { |tally| tally["count"] },
    "total_differences" => operations.values.sum { |tally| tally["differences"] },
    "total_pending" => operations.values.sum { |tally| tally["pending"] },
    "hosts" => Dir.glob(File.join(OUT, "*host.txt")).map { |path| File.read(path).strip }.uniq,
    "operations" => operations,
    "list_of_mismatches" => summaries.flat_map { |summary| summary["list_of_mismatches"] }.first(50),
  }
  File.write(File.join(OUT, "total.json"), JSON.pretty_generate(totals) + "\n")
  File.open(File.join(OUT, "total.md"), "w") do |io|
    io.puts "Shards: #{totals["shards"]} (missing: #{missing.empty? ? "none" : missing.join(", ")}); targets: #{totals["targets"].join(", ")}; GMP #{totals["gmp_versions"].join(", ")}"
    io.puts
    io.puts "| operation | count | differences | pending | GMP raised |"
    io.puts "|---|---|---|---|---|"
    operations.each { |name, tally| io.puts "| #{name} | #{tally["count"]} | #{tally["differences"]} | #{tally["pending"]} | #{tally["oracle_raised"]} |" }
    io.puts "| **total** | #{totals["total_count"]} | #{totals["total_differences"]} | #{totals["total_pending"]} | |"
  end
  puts "total: #{totals["total_count"]} operations, #{totals["total_differences"]} differences, #{totals["total_pending"]} pending, #{summaries.size} shards, missing #{missing.inspect}"
  totals
end

unless options[:total_only]
  case options[:where]
  when "minis" then run_on_minis(seeds, count_per_shard, options)
  when "local" then run_locally(seeds, count_per_shard, options)
  when "colima" then run_on_colima(seeds, count_per_shard, options)
  when "github" then run_on_github(seeds, count_per_shard, options)
  else abort "unknown --where #{options[:where]}"
  end
end
totals = total(seeds, count_per_shard)
exit(totals["total_differences"].zero? && totals["missing_seeds"].empty? ? 0 : 1)
