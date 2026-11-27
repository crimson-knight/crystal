#!/usr/bin/ruby
# x86-64 inline-asm flags check for the BigNum engine.
#
# LLVM on x86 treats EFLAGS as clobbered by an inline asm block only when the
# block lists "flags" (it ignores "cc" there, and Crystal adds no default
# clobbers the way clang and rustc do). A block that leaves "flags" out lets
# LLVM keep a comparison's flags live across it: `cmpq; divq; cmovae`.
#
# This script builds x86-64 assembly (`--emit asm`, cross-compiled, release
# and debug) of the bench and the differential, finds every inline asm block
# of the engine's kernels (#APP ... #NO_APP holding divq, mulx, adcx or adox),
# and reports any instruction after a block that reads the flags before any
# instruction writes them. It exits 0 when it found the kernel blocks and no
# such reader; the report goes to OUTPUT_DIR/x86_flags_scan.txt (default
# tmp/big_num/x86_flags_scan).
#
# usage (from the fork's root): /usr/bin/ruby scripts/big_num/x86_flags_scan.rb [OUTPUT_DIR]
require "fileutils"
require "open3"

OUTPUT_DIRECTORY = File.expand_path(ARGV[0] || "tmp/big_num/x86_flags_scan")
abort "run from the fork's root (src/crystal/big_num not found)" unless Dir.exist?("src/crystal/big_num")
FileUtils.mkdir_p(OUTPUT_DIRECTORY)

# The compiler binary behind the crystal-alpha wrapper (see subfile_requires.rb).
def compiler
  return ENV["CRYSTAL_COMPILER"] if ENV["CRYSTAL_COMPILER"]
  wrapper = `command -v crystal-alpha`.strip
  wrapper = `command -v crystal`.strip if wrapper.empty?
  abort "no crystal-alpha or crystal on PATH (or set CRYSTAL_COMPILER)" if wrapper.empty?
  text = File.read(wrapper, 4096) rescue ""
  text[/exec "([^"]+)"/, 1] || wrapper
end

KERNEL_BLOCK = /\b(divq|mulx[a-z]*|adcx[a-z]*|adox[a-z]*)\b/
FLAGS_READER = /\A(j(?!mp)[a-z]+|cmov[a-z]+|set[a-z]+|adc[a-z]?|adcx[a-z]?|adox[a-z]?|sbb[a-z]?|rc[lr][a-z]?|pushf[a-z]?|lahf)\z/
FLAGS_WRITER = /\A(add|sub|cmp|test|and|or|xor|inc|dec|neg|sh[lr]|sa[lr]|imul|mul|bt|bsf|bsr|lzcnt|tzcnt|popcnt|ro[lr]|sahf|popf)[a-z]?\z/
LEAVES_FUNCTION = /\A(call|ret|jmp)[a-z]?\z/

PROGRAMS = {
  "bench" => "scripts/big_num/bench.cr",
  "differential" => "scripts/big_num/differential.cr",
}
BUILDS = {"release" => ["--release"], "debug" => []}

# Returns the number of kernel asm blocks in *assembly_path* and the list of
# flags readers found after one of them before any flags writer.
def scan_assembly(assembly_path)
  list_of_lines = File.readlines(assembly_path, encoding: "BINARY").map(&:strip)
  count_of_kernel_blocks = 0
  list_of_findings = []
  function_name = nil
  index = 0
  while index < list_of_lines.size
    line = list_of_lines[index]
    label = line.sub(/#.*/, "").strip
    function_name = label.chomp(":") if label =~ /\A[^\s.#]\S*:\z/
    if line.start_with?("#APP")
      block_end = index + 1
      block_text = []
      while block_end < list_of_lines.size && !list_of_lines[block_end].start_with?("#NO_APP")
        block_text << list_of_lines[block_end]
        block_end += 1
      end
      if block_text.join(" ") =~ KERNEL_BLOCK
        count_of_kernel_blocks += 1
        following = block_end + 1
        while following < list_of_lines.size
          instruction = list_of_lines[following].sub(/#.*/, "").strip
          break if list_of_lines[following].start_with?("#APP")
          if instruction.empty? || instruction.start_with?(".") || instruction =~ /\A[.\w$]+:\z/
            following += 1
            next
          end
          mnemonic = instruction.split(/\s+/).first
          if mnemonic =~ FLAGS_READER
            list_of_findings << "#{function_name}: '#{instruction}' reads flags #{following - block_end} lines after the asm block at line #{index + 1}"
            break
          end
          break if mnemonic =~ FLAGS_WRITER || mnemonic =~ LEAVES_FUNCTION
          following += 1
        end
      end
      index = block_end
    end
    index += 1
  end
  [count_of_kernel_blocks, list_of_findings]
end

report = []
all_clean = true
PROGRAMS.each do |program_name, entry|
  BUILDS.each do |build_name, build_flags|
    output_base = File.join(OUTPUT_DIRECTORY, "#{program_name}-#{build_name}")
    command = [compiler, "build", *build_flags, "-Duse_gmp", "--cross-compile", "--target", "x86_64-unknown-linux-gnu",
               "--emit", "asm", "-o", output_base, entry]
    environment = {"CRYSTAL_PATH" => "lib:#{Dir.pwd}/src"}
    compiler_output, status = Open3.capture2e(environment, *command)
    list_of_assembly_files = Dir["#{output_base}*.s"]
    if !status.success? || list_of_assembly_files.empty?
      report << "#{program_name} #{build_name}: build FAILED (#{list_of_assembly_files.size} .s files)\n#{compiler_output}"
      all_clean = false
      next
    end
    blocks, findings = list_of_assembly_files.map { |path| scan_assembly(path) }.transpose
    count_of_blocks = blocks.sum
    list_of_findings = findings.flatten
    all_clean = false if count_of_blocks == 0 || !list_of_findings.empty?
    report << "#{program_name} #{build_name}: #{count_of_blocks} kernel asm blocks, #{list_of_findings.size} with flags read after the block"
    list_of_findings.first(10).each { |finding| report << "  #{finding}" }
  end
end
report << (all_clean ? "x86 flags scan: clean" : "x86 flags scan: FAILED")
File.write(File.join(OUTPUT_DIRECTORY, "x86_flags_scan.txt"), report.join("\n") + "\n")
puts report
exit(all_clean ? 0 : 1)
