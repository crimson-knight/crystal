require "../spec_helper"
require "./spec_helper"

# A strict file is public Crystal: one comment, two annotations and one
# `require`. These examples build the same strict sources with this compiler
# and with the public compiler installed as `crystal`, which gets the two
# annotations from the `strict` shard in `compat/strict`.

private STRICT_SHARD_PARENT = File.expand_path("../../compat", __DIR__)

private def public_crystal_environment(crystal_path : String? = nil) : Hash(String, String)
  environment = {} of String => String
  {"PATH", "HOME", "TMPDIR"}.each do |name|
    if value = ENV[name]?
      environment[name] = value
    end
  end
  environment["CRYSTAL_PATH"] = crystal_path if crystal_path
  environment
end

# Builds and runs *source* with the public compiler at *crystal* and returns
# what the program printed.
private def output_with_public_crystal(crystal : String, source : String, executable : String) : String
  default_path = IO::Memory.new
  Process.run(crystal, ["env", "CRYSTAL_PATH"], env: public_crystal_environment, clear_env: true, output: default_path).success?.should be_true
  crystal_path = "#{STRICT_SHARD_PARENT}:#{default_path.to_s.strip}"

  build_error = IO::Memory.new
  status = Process.run(crystal, ["build", source, "-o", executable], env: public_crystal_environment(crystal_path), clear_env: true, output: build_error, error: build_error)
  fail "the public compiler rejected #{source}:\n#{build_error}" unless status.success?
  Process.capture(executable)
end

# Builds and runs *source* with this compiler and returns what the program
# printed and the warnings of the build.
private def output_with_this_compiler(source : String, executable : String) : {String, Array(String)}
  compiler = create_spec_compiler
  compiler.flags.concat(%w[without_interpreter without_libxml2 without_openssl without_zlib])
  compiler.compile(Crystal::Compiler::Source.new(source, File.read(source)), executable)
  {Process.capture(executable), compiler.warnings.infos}
end

describe "Strict files on the public compiler" do
  it "builds a strict file with both compilers, with the same output and no warning" do
    crystal = Process.find_executable("crystal")
    pending! "no public compiler installed as `crystal`" unless crystal

    source = compiler_datapath("strict_files", "sample.cr")
    with_temp_executable("strict_sample_public") do |public_executable|
      with_temp_executable("strict_sample") do |executable|
        output, warnings = output_with_this_compiler(source, executable)
        warnings.should be_empty
        output.should eq(<<-OUTPUT)
          square shape with area 9
          square shape with area 9square shape with area 9
          A
          square shape with area 9
          shape with area 12
          shape with area 12shape with area 12
          A
          shape with area 12

          OUTPUT
        output_with_public_crystal(crystal, source, public_executable).should eq(output)
      end
    end
  end

  it "builds a strict file that leaves types out with both compilers; this one warns" do
    crystal = Process.find_executable("crystal")
    pending! "no public compiler installed as `crystal`" unless crystal

    source = compiler_datapath("strict_files", "loose.cr")
    with_temp_executable("strict_loose_public") do |public_executable|
      with_temp_executable("strict_loose") do |executable|
        output, warnings = output_with_this_compiler(source, executable)
        warnings.size.should eq(2)
        warnings[0].should contain("strict file: method 'Greeter#greet' is typed for each caller, as in an ordinary file. To have it typed once, write the type of parameter 'name' (for example `name : String`); the return type (for example `def greet(...) : String`)")
        warnings[1].should contain("strict file: method 'Greeter#with_block' is typed for each caller, as in an ordinary file. To have it typed once, write the type of block parameter 'block' (for example `&block : String -> String`); the return type (for example `def with_block(...) : String`)")
        output.should eq("hello Ada\ncalled\n")
        output_with_public_crystal(crystal, source, public_executable).should eq(output)
      end
    end
  end
end
