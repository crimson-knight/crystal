require "spec"
require "compiler/requires"

private alias Target = Crystal::Codegen::Target

describe Crystal::Codegen::Target do
  it "parses incomplete triples" do
    target = Target.new("x86_64-linux-gnu")
    target.to_s.should eq("x86_64-unknown-linux-gnu")
    target.pointer_bit_width.should eq(64)
    target.linux?.should be_true
    target.unix?.should be_true
    target.gnu?.should be_true
  end

  it "normalizes triples" do
    Target.new("i686-unknown-linux-gnu").to_s.should eq("i386-unknown-linux-gnu")
    Target.new("amd64-unknown-openbsd").to_s.should eq("x86_64-unknown-openbsd")
    Target.new("arm64-apple-darwin20.2.0").to_s.should eq("aarch64-apple-darwin20.2.0")
    Target.new("x86_64-suse-linux").to_s.should eq("x86_64-suse-linux-gnu")
  end

  it "parses freebsd version" do
    Target.new("x86_64-unknown-linux-gnu").freebsd_version.should be_nil
    Target.new("x86_64-unknown-freebsd8.0").freebsd_version.should eq(8)
    Target.new("x86_64-unknown-freebsd11.0").freebsd_version.should eq(11)
  end

  describe "#to_target_machine" do
    it "uses a portable CPU by default" do
      target = Target.new(LLVM.default_target_triple)
      machine = target.to_target_machine
      machine.cpu.should eq("")
      machine.features.should eq("")
    end

    it "resolves native to the host CPU and detected features" do
      compiler = Crystal::Compiler.new
      compiler.mcpu = "native"
      machine = compiler.create_target_machine
      machine.cpu.should eq(LLVM.host_cpu_name)
      machine.features.should eq(LLVM.host_cpu_features)
    end

    it "applies explicit feature overrides after the native feature set" do
      target = Target.new(LLVM.default_target_triple)
      machine = target.to_target_machine("native", "-aes")
      machine.cpu.should eq(LLVM.host_cpu_name)
      host_features = LLVM.host_cpu_features
      expected_features = host_features.empty? ? "-aes" : "#{host_features},-aes"
      machine.features.should eq(expected_features)
    end
  end
end
