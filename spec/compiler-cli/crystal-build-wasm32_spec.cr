require "./spec_helper"

describe "`crystal build --target wasm32-wasi`" do
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
end
