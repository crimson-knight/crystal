require "./spec_helper"

# Finds a disassembler that reads WebAssembly object files: `llvm-objdump`
# next to the `llvm-config` the compiler was built with, or `wasm-objdump`
# (WABT) on the PATH.
private def wasm_disassembler : String?
  llvm_config = ENV["LLVM_CONFIG"]?
  if llvm_config && File::Info.executable?(llvm_config)
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

# The folder of wasm32-wasi libraries (wasi-libc, libgc, libpcre2; for example
# lbguilherme/wasm-libs 0.0.3). It has its own variable because the compiler
# adds `CRYSTAL_WASM_LIBS` to the library path of native builds too, which
# would break linking this spec runner.
private WASM32_LIBRARY_PATH = ENV["CRYSTAL_SPEC_WASM32_LIBS"]?

# What linking and running a wasm32 program needs on this machine, or nil
# when all of it is present.
private def missing_wasm32_run_tools : String?
  return "CRYSTAL_SPEC_WASM32_LIBS is not set" unless WASM32_LIBRARY_PATH
  return "wasm-ld is not on PATH" unless Process.find_executable("wasm-ld")
  return "deno is not on PATH" unless Process.find_executable("deno")
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

  # On wasm32 `LibC::SizeT` is `UInt32`, so any standard library code that
  # hands a `SizeT` to `Pointer.new` reaches the deprecated `Pointer.new(Int)`
  # overload and prints a warning in every user program.
  it "builds a program using common std modules with zero warnings" do
    with_tempfile("wasm32-std-sweep") do |output_base|
      # `--cross-compile` writes the object file `<output>.wasm` and prints
      # the link command, so the spec needs no wasm32 libraries or linker.
      result = Process.capture_result(crystal, "build", "--cross-compile", "--target", "wasm32-wasi",
        "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib",
        "--error-on-warnings", "-o", output_base, fixture_path("wasm32-std-sweep.cr"))

      result.should(be_success)
      result.output.should_not contain("Warning")
      result.error.should_not contain("Warning")
      File.exists?("#{output_base}.wasm").should be_true
    end
  end

  # Browser hosts often start a WASI module with zero program arguments. The
  # standard library used to read argv[0] unconditionally at startup, so
  # `_start` raised before the program's top-level code ran.
  it "runs a program whose WASI host passes no program arguments" do
    if reason = missing_wasm32_run_tools
      pending!("needs a wasm32 toolchain and host: #{reason}")
    end

    with_tempfile("wasm32-no-args.wasm") do |program_path|
      build = Process.capture_result(crystal, "build", "--target", "wasm32-wasi",
        "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib",
        "-o", program_path, fixture_path("wasm32-no-args.cr"),
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      run = Process.capture_result("deno", "run", "--allow-read",
        fixture_path("wasi-host-no-args.mjs"), program_path)
      run.should(be_success)
      # `Log` writes to the same stream as the program, so its line comes first.
      run.output.lines.should eq([
        run.output.lines.first,
        "program name: \"\"",
        "arguments: 0",
        "progname: \"\"",
        "top-level code ran",
      ])
      run.output.lines.first.should contain("INFO - logging works")
    end
  end
end
