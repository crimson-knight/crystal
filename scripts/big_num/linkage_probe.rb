#!/usr/bin/ruby
# Linkage probe for the pure-Crystal BigInt (BIGNUM.md 5.4).
#
# Builds scripts/big_num/linkage_probe.cr (requires "big", uses BigInt only)
# twice from the fork's src/: the default build must link no GMP (no libgmp
# in `otool -L`/`ldd`, no __gmp symbol in `nm`), and the -Duse_gmp control
# build must link GMP, so the check can still fail.
#
# usage (from the fork's root): /usr/bin/ruby scripts/big_num/linkage_probe.rb [OUTPUT_DIR]
# Exit status 0 when both builds behave as expected; the report goes to
# OUTPUT_DIR/linkage.txt (default tmp/big_num/linkage).
require "fileutils"
require "open3"

ROOT = Dir.pwd
OUT = File.expand_path(ARGV[0] || "tmp/big_num/linkage")
SOURCE = "scripts/big_num/linkage_probe.cr"
abort "run from the fork's root (#{SOURCE} not found)" unless File.exist?(SOURCE)
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

def run(*command)
  output, status = Open3.capture2e(*command)
  [output, status.success?]
end

def linkage_of(binary)
  macos = RUBY_PLATFORM.include?("darwin")
  libraries, = run(macos ? "otool" : "ldd", *(macos ? ["-L", binary] : [binary]))
  undefined, = run("nm", "-u", binary)
  every_symbol, = run("nm", binary)
  {
    "gmp libraries"         => libraries.lines.drop(macos ? 1 : 0).grep(/libgmp|mpir/i).map(&:strip),
    "undefined __gmp names" => undefined.lines.grep(/__gmp/).map(&:strip),
    "all __gmp names"       => every_symbol.lines.grep(/__gmp/).map(&:strip),
  }
end

report = []
report << "linkage probe, #{Time.now.utc}, #{RUBY_PLATFORM}"
report << "fork commit: #{`git -C #{ROOT} rev-parse HEAD`.strip}"
version, = run(compiler, "--version")
report << "compiler: #{compiler} (#{version.lines.first&.strip})"
results = {}

[["default", [], false], ["use_gmp", ["-Duse_gmp"], true]].each do |label, flags, expect_gmp|
  binary = File.join(OUT, "linkage_probe_#{label}")
  command = [compiler, "build", *flags, SOURCE, "-o", binary]
  output, built = Open3.capture2e({"CRYSTAL_PATH" => "lib:#{File.join(ROOT, "src")}"}, *command)
  report << "" << "== #{label}: #{command.join(" ")}"
  unless built
    report << "BUILD FAILED" << output
    results[label] = false
    next
  end
  report << "compiler output: #{output.strip.empty? ? "(none)" : output.strip}"
  found = linkage_of(binary)
  found.each do |name, lines|
    report << "#{name}: #{lines.size}"
    lines.first(5).each { |line| report << "  #{line}" }
  end
  links_gmp = found.values.any? { |lines| !lines.empty? }
  results[label] = (links_gmp == expect_gmp)
  report << "expected #{expect_gmp ? "GMP linked" : "no GMP"}: #{results[label] ? "PASS" : "FAIL"}"
end

passed = results.values.all? && results.size == 2
report << "" << "result: #{passed ? "PASS" : "FAIL"}"
File.write(File.join(OUT, "linkage.txt"), report.join("\n") + "\n")
puts report
exit(passed ? 0 : 1)
