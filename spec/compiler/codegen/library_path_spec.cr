require "spec"
require "compiler/requires"
require "../../support/env"
require "../../support/tempfile"

private def program_for(triple : String) : Crystal::Program
  program = Crystal::Program.new
  program.codegen_target = Crystal::Codegen::Target.new(triple)
  program
end

describe Crystal::CrystalLibraryPath do
  # `CRYSTAL_WASM_LIBS` holds wasm32 archives (libgc.a, libc.a, ...). On the
  # shared library path a native link would pick them up and fail.
  it "leaves CRYSTAL_WASM_LIBS out of the library path every target shares" do
    with_tempfile("wasm32-libs") do |wasm_libs|
      Dir.mkdir_p(wasm_libs)
      with_env("CRYSTAL_WASM_LIBS": wasm_libs) do
        Crystal::CrystalLibraryPath.default_paths.should_not contain(wasm_libs)
      end
    end
  end

  it "leaves the WASI SDK sysroot out of the library path every target shares" do
    with_tempfile("wasi-sdk") do |wasi_sdk|
      sysroot_lib = File.join(wasi_sdk, "share", "wasi-sysroot", "lib", "wasm32-wasi")
      Dir.mkdir_p(sysroot_lib)
      with_env("WASI_SDK_PATH": wasi_sdk) do
        Crystal::CrystalLibraryPath.default_paths.should_not contain(sysroot_lib)
      end
    end
  end

  it "adds CRYSTAL_WASM_LIBS to wasm32 link flags only" do
    with_tempfile("wasm32-libs") do |wasm_libs|
      Dir.mkdir_p(wasm_libs)
      with_env("CRYSTAL_WASM_LIBS": wasm_libs) do
        program_for("wasm32-unknown-wasi").lib_flags.should contain("-L#{wasm_libs}")
        program_for("aarch64-apple-darwin").lib_flags.should_not contain(wasm_libs)
        program_for("x86_64-linux-gnu").lib_flags.should_not contain(wasm_libs)
      end
    end
  end
end
