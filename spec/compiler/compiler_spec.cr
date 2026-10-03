require "../spec_helper"
require "./spec_helper"

describe "Compiler" do
  it "has a valid version" do
    SemanticVersion.parse(Crystal::Config.version)
  end

  it "compiles a file" do
    with_temp_executable "compiler_spec_output" do |path|
      Crystal::Command.run ["build"].concat(program_flags_options).concat([compiler_datapath("compiler_sample"), "-o", path])

      File.exists?(path).should be_true

      Process.capture(path).should eq("Hello!")
    end
  end

  it "runs subcommand in preference to a filename " do
    Dir.cd compiler_datapath do
      with_temp_executable "compiler_spec_output" do |path|
        Crystal::Command.run ["build"].concat(program_flags_options).concat(["compiler_sample", "-o", path])

        File.exists?(path).should be_true

        Process.capture(path).should eq("Hello!")
      end
    end
  end

  it "invalidates an incremental build when the effective CPU and features change" do
    with_tempfile "cpu_cache_source.cr", "cpu_cache_output" do |source_path, output_path|
      File.write(source_path, "puts 42\n")
      source = Crystal::Compiler::Source.new(source_path, File.read(source_path))

      portable_compiler = Crystal::Compiler.new
      portable_compiler.incremental = true
      portable_compiler.compile(source, output_path)

      cache_dir = Crystal::CacheDir.instance.directory_for([source])
      cache_path = File.join(cache_dir, Crystal::IncrementalCache::CACHE_FILENAME)
      portable_options = Crystal::IncrementalCacheData.from_json(File.read(cache_path)).codegen_options || raise "Missing portable codegen options"

      native_compiler = Crystal::Compiler.new
      native_compiler.incremental = true
      native_compiler.mcpu = "native"
      native_compiler.compile(source, output_path)

      native_options = Crystal::IncrementalCacheData.from_json(File.read(cache_path)).codegen_options || raise "Missing native codegen options"
      native_options.should_not eq(portable_options)
      native_options.should contain(LLVM.host_cpu_name)
      native_options.should contain(LLVM.host_cpu_features)

      overridden_compiler = Crystal::Compiler.new
      overridden_compiler.incremental = true
      overridden_compiler.mcpu = "native"
      overridden_compiler.mattr = "-aes"
      overridden_compiler.compile(source, output_path)

      overridden_options = Crystal::IncrementalCacheData.from_json(File.read(cache_path)).codegen_options || raise "Missing overridden codegen options"
      overridden_options.should_not eq(native_options)
      host_features = LLVM.host_cpu_features
      expected_features = host_features.empty? ? "-aes" : "#{host_features},-aes"
      overridden_options.should contain(expected_features)
      Process.capture(output_path).should eq("42\n")
    end
  end
end
