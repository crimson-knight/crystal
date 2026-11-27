#!/usr/bin/ruby
# Sub-file require check for `src/big/`.
#
# Every public file in src/big/ (`require "big/big_int"`, `"big/json"`, ...)
# must compile on its own, with a one-line use of what it defines, in every
# build: the default build (the pure-Crystal engine), the `-Duse_gmp` build,
# and a 32-bit target, which always uses GMP. The default and `-Duse_gmp`
# programs are built and run, and their output is compared with the expected
# line; the 32-bit targets are type-checked (`--no-codegen --cross-compile`).
# The internal halves in src/big/gmp/ and src/big/pure/ are loaded only
# through src/big.cr and are not public paths.
#
# usage (from the fork's root): /usr/bin/ruby scripts/big_num/subfile_requires.rb [OUTPUT_DIR]
# Exit status 0 when every program compiles (and prints its expected line);
# the report goes to OUTPUT_DIR/subfile_requires.txt (default
# tmp/big_num/subfile_requires).
require "fileutils"
require "open3"

ROOT = Dir.pwd
OUT = File.expand_path(ARGV[0] || "tmp/big_num/subfile_requires")
abort "run from the fork's root (src/big.cr not found)" unless File.exist?("src/big.cr")
FileUtils.mkdir_p(OUT)

# The compiler binary behind the crystal-alpha wrapper: the wrapper sets its
# own CRYSTAL_PATH, which would hide the fork's src/ from the build.
def compiler
  return ENV["CRYSTAL_COMPILER"] if ENV["CRYSTAL_COMPILER"]
  wrapper = `command -v crystal-alpha`.strip
  wrapper = `command -v crystal`.strip if wrapper.empty?
  abort "no crystal-alpha or crystal on PATH (or set CRYSTAL_COMPILER)" if wrapper.empty?
  text = File.read(wrapper, 4096) rescue ""
  text[/exec "([^"]+)"/, 1] || wrapper
end

# One use of what each public file defines, and the line it prints.
USES = {
  "big_int"      => ['puts BigInt.new(7) * 3', "21"],
  "big_float"    => ['puts BigFloat.new(BigInt.new(7)) * 3', "21.0"],
  "big_rational" => ['puts BigRational.new(1, 3) + 1', "4/3"],
  "big_decimal"  => ['puts BigDecimal.new("1.5") * 2', "3.0"],
  "number"       => ['puts 2 * BigInt.new(3)', "6"],
  "json"         => ['puts BigInt.from_json("12345678901234567890")', "12345678901234567890"],
  "yaml"         => ['puts BigDecimal.from_yaml("1.25")', "1.25"],
  "lib_gmp"      => ['puts sizeof(LibGMP::BitcntT) > 0', "true"],
}

public_files = Dir["src/big/*.cr"].map { |path| File.basename(path, ".cr") }.sort
missing = public_files - USES.keys
abort "no use written for src/big/#{missing.join(", ")}.cr; add one to USES" unless missing.empty?

BUILDS = [
  {name: "default", flags: [], run: true},
  {name: "-Duse_gmp", flags: ["-Duse_gmp"], run: true},
  {name: "arm-linux-gnueabihf", flags: ["--no-codegen", "--cross-compile", "--target", "arm-linux-gnueabihf"], run: false},
  {name: "i686-linux-gnu", flags: ["--no-codegen", "--cross-compile", "--target", "i686-linux-gnu"], run: false},
]

env = {"CRYSTAL_PATH" => "lib:#{ROOT}/src"}
report = ["sub-file require check, #{Time.now.utc}, #{RUBY_PLATFORM}", "compiler: #{compiler}", ""]
failures = 0

BUILDS.each do |build|
  public_files.each do |name|
    use, expected = USES[name]
    source = File.join(OUT, "#{name}.cr")
    File.write(source, %(require "big/#{name}"\n#{use}\n))
    binary = File.join(OUT, "#{name}-#{build[:name].delete("-")}")
    output, status = Open3.capture2e(env, compiler, "build", *build[:flags], "-o", binary, source)
    warnings = output.lines.grep(/warning/i)
    result =
      if !status.success?
        "FAIL (compile): #{output.lines.last(3).join.strip}"
      elsif !warnings.empty?
        "FAIL (warning): #{warnings.first.strip}"
      elsif build[:run]
        printed, run_status = Open3.capture2e(binary)
        printed = printed.strip
        run_status.success? && printed == expected ? "ok (prints #{printed})" : "FAIL (prints #{printed.inspect}, expected #{expected.inspect})"
      else
        "ok (type-checks)"
      end
    failures += 1 if result.start_with?("FAIL")
    report << format("%-20s big/%-13s %s", build[:name], name, result)
  end
end

report << ""
report << "#{BUILDS.size * public_files.size} programs, #{failures} failures"
File.write(File.join(OUT, "subfile_requires.txt"), report.join("\n") + "\n")
puts report
exit(failures == 0 ? 0 : 1)
