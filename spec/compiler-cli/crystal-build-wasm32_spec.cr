require "./spec_helper"

# Finds a disassembler that reads WebAssembly object files: `llvm-objdump`
# next to the `llvm-config` the compiler was built with, or `wasm-objdump`
# (WABT) on the PATH.
private def wasm_disassembler : String?
  if llvm_config = ENV["LLVM_CONFIG"]?
    bin_dir = Process.capture_result(llvm_config, "--bindir").output.strip
    objdump = File.join(bin_dir, "llvm-objdump")
    return objdump if File::Info.executable?(objdump)
  end

  Process.find_executable("wasm-objdump")
end

# Counts WebAssembly SIMD instructions (`v128.*` and lane-shaped ones such as
# `f32x4.mul`) in a disassembly listing.
private def count_vector_instructions(listing : String) : Int32
  listing.lines.count(&.matches?(/\b(v128|[if](8|16|32|64)x\d+)\./))
end

describe "`crystal build --target wasm32-wasi`" do
  it "accepts --mattr=+simd128 next to the target's own features and emits vector instructions" do
    with_tempfile("wasm32-simd") do |output_path|
      object_path = "#{output_path}.wasm"
      begin
        result = Process.capture_result(crystal, "build", "--prelude=empty", "--cross-compile",
          "--target", "wasm32-wasi", "--release", "--mattr=+simd128",
          "-o", output_path, fixture_path("wasm32-simd.cr"))
        result.should be_success
        result.error.should_not contain("is not a recognized feature")
        File.exists?(object_path).should be_true

        disassembler = wasm_disassembler
        pending! "no llvm-objdump or wasm-objdump to count vector instructions" unless disassembler

        listing = Process.capture_result(disassembler, "-d", object_path)
          .should(be_success)
          .output
        count_vector_instructions(listing).should be > 0
      ensure
        File.delete?(object_path)
      end
    end
  end

  it "keeps a lib fun in the import module its Link annotation names" do
    with_tempfile("wasm32-import") do |output_path|
      ir_path = "#{output_path}.ll"
      begin
        Process.capture_result(crystal, "build", "--prelude=empty", "--cross-compile",
          "--target", "wasm32-wasi", "--emit", "llvm-ir",
          "-o", output_path, fixture_path("wasm32-import.cr"))
          .should(be_success)

        ir = File.read(ir_path)
        ir.should contain(%("wasm-import-module"="host"))
        ir.should contain(%("wasm-import-name"="host_note"))
      ensure
        File.delete?(ir_path)
        File.delete?("#{output_path}.wasm")
      end
    end
  end
end
