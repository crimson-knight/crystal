#!/usr/bin/ruby
# Planted-bug check for the BigNum differential harness (BIGNUM.md 5.2 and
# the G2-harness done-test): proves the harness flags a wrong answer in
# every operation class.
#
# For each operation it runs the differential binary three ways:
#   1. clean:   the GMP-backed double, no bug         -> must report 0 differences
#   2. planted: the double returns a wrong value      -> must report > 0 differences
#   3. injected: the fault injector on the engine     -> must report > 0 differences
#      (only where the engine implements the operation; a stub stays pending,
#      and the injector is then shown on the double instead)
#
# usage: /usr/bin/ruby scripts/big_num/planted_bug_check.rb BINARY OUTPUT_DIR [COUNT]
require "json"
require "open3"
require "fileutils"

binary, output_directory, count = ARGV[0], ARGV[1], (ARGV[2] || "200")
abort "usage: planted_bug_check.rb BINARY OUTPUT_DIR [COUNT]" unless binary && output_directory
FileUtils.mkdir_p(output_directory)

def run_differential(binary, output_directory, label, operation, count, extra)
  json_path = File.join(output_directory, "runs", "#{operation}.#{label}.json")
  FileUtils.mkdir_p(File.dirname(json_path))
  command = [binary, "--seed", "20261127", "--count", count, "--ops", operation, "--json", json_path,
             "--reproducers", File.join(output_directory, "reproducers")] + extra
  _, error_output, _ = Open3.capture3(*command)
  abort "#{command.join(" ")} wrote no summary:\n#{error_output}" unless File.exist?(json_path)
  JSON.parse(File.read(json_path))["operations"].fetch(operation)
end

operations, _ = Open3.capture2(binary, "--list")
rows = operations.split("\n").map do |operation|
  clean = run_differential(binary, output_directory, "clean", operation, count, ["--subject", "double"])
  planted = run_differential(binary, output_directory, "planted", operation, count, ["--subject", "double", "--plant", operation])
  engine = run_differential(binary, output_directory, "engine-injected", operation, count, ["--subject", "engine", "--inject", operation])
  engine_exists = engine["pending"] == 0
  injected = engine_exists ? engine : run_differential(binary, output_directory, "double-injected", operation, count, ["--subject", "double", "--inject", operation])
  row = {
    "operation" => operation,
    "clean_differences" => clean["differences"],
    "planted_differences" => planted["differences"],
    "engine_implements" => engine_exists,
    "injected_on" => engine_exists ? "engine" : "double",
    "injected_differences" => injected["differences"],
    "count" => clean["count"],
  }
  row["passed"] = row["clean_differences"] == 0 && row["planted_differences"] > 0 && row["injected_differences"] > 0
  row
end

File.write(File.join(output_directory, "planted_bug_check.json"), JSON.pretty_generate(rows) + "\n")
File.open(File.join(output_directory, "planted_bug_check.md"), "w") do |io|
  io.puts "| operation | count | clean diffs | planted-bug diffs | injector on | injected diffs | engine implements | flagged |"
  io.puts "|---|---|---|---|---|---|---|---|"
  rows.each do |row|
    io.puts "| #{row["operation"]} | #{row["count"]} | #{row["clean_differences"]} | #{row["planted_differences"]} | #{row["injected_on"]} | #{row["injected_differences"]} | #{row["engine_implements"] ? "yes" : "no (stub)"} | #{row["passed"] ? "yes" : "NO"} |"
  end
end
failed = rows.reject { |row| row["passed"] }
puts "#{rows.size} operation classes; #{rows.count { |row| row["engine_implements"] }} implemented by the engine; #{failed.size} not flagged#{failed.empty? ? "" : ": " + failed.map { |row| row["operation"] }.join(", ")}"
exit(failed.empty? ? 0 : 1)
