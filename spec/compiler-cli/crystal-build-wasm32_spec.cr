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

# The heap ceiling of the load-and-dump fixture. A native build of the same
# loop peaks at about 2 MiB; a wasm32 build whose collector misses roots or
# never runs grows to hundreds of MiB.
private WASM32_LOAD_DUMP_PEAK_HEAP_MEBIBYTES = 64

# What linking and running a wasm32 program needs on this machine, or nil
# when all of it is present.
private def missing_wasm32_run_tools : String?
  return "CRYSTAL_SPEC_WASM32_LIBS is not set" unless WASM32_LIBRARY_PATH
  return "wasm-ld is not on PATH" unless Process.find_executable("wasm-ld")
  return "deno is not on PATH" unless Process.find_executable("deno")
end

# What linking a wasm32 module and running Binaryen's post-link step need on
# this machine, or nil when all of it is present.
private def missing_wasm32_link_tools : String?
  return "CRYSTAL_SPEC_WASM32_LIBS is not set" unless WASM32_LIBRARY_PATH
  return "wasm-ld is not on PATH" unless Process.find_executable("wasm-ld")
  return "wasm-opt is not on PATH" unless Process.find_executable("wasm-opt")
end

# The flags of the lean wasm32 release recipe (WASM_GUIDE.md, "Lean release
# builds"): no fibers, no collector, no debug information, `--release`.
private LEAN_RELEASE_FLAGS = %w[--target wasm32-wasi -Dwithout_mt -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib
  -Dfrontend_no_fibers -Dgc_none --no-debug --release]

# The gzipped size (`gzip -9`) the lean release build of
# fixtures/wasm32-lean-release.cr must stay under. It measured 71,308 bytes
# (209,438 bytes before gzip) on 2026-11-24 with LLVM 21.1.8 and Binaryen 126;
# the default `--release` build of the same program, with fibers, Boehm GC
# and debug information, is 182,550 bytes gzipped.
private LEAN_RELEASE_GZIP_CEILING = 78_000

# The runs of four or more printable ASCII characters in the file at *path*,
# as `strings` lists them.
private def printable_strings(path : String) : Array(String)
  File.read(path).scrub.scan(/[ -~]{4,}/).map(&.[0])
end

# The size of the file at *path* compressed with `gzip -9`.
private def gzip_size(path : String) : Int32
  compressed = IO::Memory.new
  Process.run("gzip", ["-9", "-c", path], output: compressed).should be_success
  compressed.size
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
  # In an optimized build, LLVM keeps most pointers in WebAssembly locals,
  # which Boehm's conservative scan cannot see. `wasm-opt --spill-pointers`
  # stores them on the shadow stack, and each fiber needs a shadow stack of
  # its own so another fiber does not write over the spilled pointers of a
  # suspended one. Without both, the collector frees chains the fixture still
  # walks, and the walk finds other objects in their place.
  it "keeps objects referenced only from locals alive across collections, with fibers" do
    if reason = missing_wasm32_run_tools
      pending!("needs a wasm32 toolchain and host: #{reason}")
    end
    pending!("wasm-opt is not on PATH") unless Process.find_executable("wasm-opt")

    with_tempfile("wasm32-gc-locals.wasm") do |program_path|
      build = Process.capture_result(crystal, "build", "--target", "wasm32-wasi",
        "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib", "--release",
        "-o", program_path, fixture_path("wasm32-gc-locals.cr"),
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      run = Process.capture_result("deno", "run", "--allow-read",
        fixture_path("wasi-host-no-args.mjs"), program_path)
      run.output.lines.should eq([
        "main fiber: 60 of 60 chains intact",
        "spawned fibers: 240 of 240 chains intact",
      ])
      run.should(be_success)
    end
  end

  # A browser game's save loop with the collector running on its own: each
  # round loads a world from JSON, allocates a large buffer and dumps the
  # world again. The collector must keep every block it frees in the heap
  # (WASI's emulated munmap cannot return part of it, and the module traps)
  # and see every pointer a round holds in a local, so all rounds read back
  # the world the round before wrote and the heap stays small.
  it "runs a load-and-dump loop with automatic collections, intact and in a small heap" do
    if reason = missing_wasm32_run_tools
      pending!("needs a wasm32 toolchain and host: #{reason}")
    end
    pending!("wasm-opt is not on PATH") unless Process.find_executable("wasm-opt")

    with_tempfile("wasm32-gc-load-dump.wasm") do |program_path|
      build = Process.capture_result(crystal, "build", "--target", "wasm32-wasi",
        "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib", "--release",
        "-o", program_path, fixture_path("wasm32-gc-load-dump.cr"),
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      run = Process.capture_result("deno", "run", "--allow-read",
        fixture_path("wasi-host-no-args.mjs"), program_path)
      run.should(be_success)
      list_of_lines = run.output.lines
      list_of_lines.first?.should eq("60000 of 60000 rounds intact")
      peak_heap_line = list_of_lines[1]? || ""
      peak_heap_mebibytes = peak_heap_line[/\Apeak heap (\d+) MiB\z/, 1]?.try(&.to_i)
      peak_heap_mebibytes.should_not be_nil
      (peak_heap_mebibytes || Int32::MAX).should be < WASM32_LOAD_DUMP_PEAK_HEAP_MEBIBYTES
    end
  end

  it "builds a lean release module with no home paths and under its size ceiling" do
    if reason = missing_wasm32_link_tools
      pending!("needs a wasm32 toolchain: #{reason}")
    end
    pending!("needs gzip on PATH") unless Process.find_executable("gzip")

    with_tempfile("wasm32-lean-release.wasm") do |program_path|
      build = Process.capture_result([crystal, "build", *LEAN_RELEASE_FLAGS, "-o", program_path,
                                      fixture_path("wasm32-lean-release.cr")],
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      home = ENV["HOME"]
      printable_strings(program_path).select(&.includes?(home)).should be_empty
      gzip_size(program_path).should be < LEAN_RELEASE_GZIP_CEILING
    end
  end

  it "keeps home paths out of an unoptimized build with --no-debug" do
    if reason = missing_wasm32_link_tools
      pending!("needs a wasm32 toolchain: #{reason}")
    end

    with_tempfile("wasm32-no-debug.wasm") do |program_path|
      build = Process.capture_result(crystal, "build", "--target", "wasm32-wasi",
        "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib", "--no-debug",
        "-o", program_path, fixture_path("wasm32-lean-release.cr"),
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      home = ENV["HOME"]
      printable_strings(program_path).select(&.includes?(home)).should be_empty
    end
  end

  it "builds a WASI reactor with -Dwithout_main whose exports run after _initialize" do
    if reason = missing_wasm32_run_tools
      pending!("needs a wasm32 toolchain and host: #{reason}")
    end
    pending!("wasm-opt is not on PATH") unless Process.find_executable("wasm-opt")

    with_tempfile("wasm32-reactor.wasm") do |program_path|
      build = Process.capture_result([crystal, "build", *LEAN_RELEASE_FLAGS, "-Dwithout_main", "-Dlean_unreachable",
                                      "-o", program_path, fixture_path("wasm32-reactor.cr")],
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH})
      build.should(be_success)

      run = Process.capture_result("deno", "run", "--allow-read",
        fixture_path("wasi-host-no-args.mjs"), program_path, "reactor_add", "2", "3")
      run.should(be_success)
      run.output.lines.should eq(["exports _start: false", "reactor_add: 105"])
    end
  end

  it "rejects a WASI reactor that keeps fibers" do
    result = Process.capture_result(crystal, "build", "--no-codegen", "--target", "wasm32-wasi",
      "-Dwithout_mt", "-Dwithout_iconv", "-Dwithout_openssl", "-Dwithout_zlib", "-Dwithout_main",
      fixture_path("wasm32-reactor.cr"))
    result.status.success?.should be_false
    result.error.should contain("build it with -Dfrontend_no_fibers")
  end

  it "stops before linking when a wasm32 tool does not have its pinned SHA-256" do
    if reason = missing_wasm32_link_tools
      pending!("needs a wasm32 toolchain: #{reason}")
    end

    with_tempfile("wasm32-pinned.wasm") do |program_path|
      build = Process.capture_result([crystal, "build", *LEAN_RELEASE_FLAGS, "-Dwithout_main", "-o", program_path,
                                      fixture_path("wasm32-reactor.cr")],
        env: {"CRYSTAL_LIBRARY_PATH" => WASM32_LIBRARY_PATH, "CRYSTAL_WASM_OPT_SHA256" => "0" * 64})
      build.status.success?.should be_false
      build.error.should contain("but CRYSTAL_WASM_OPT_SHA256 expects #{"0" * 64}")
      File.exists?(program_path).should be_false
    end
  end
end
