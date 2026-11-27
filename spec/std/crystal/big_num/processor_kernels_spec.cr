require "spec"
require "crystal/big_num"

private alias ProcessorKernels = Crystal::BigNum::ProcessorKernels
private alias Limbs = Crystal::BigNum::Limbs
private alias Limb = Crystal::BigNum::Limb

private alias TwoRunKernel = Proc(Pointer(Limb), Pointer(Limb), Pointer(Limb), Int32, Limb)
private alias OneLimbKernel = Proc(Pointer(Limb), Pointer(Limb), Int32, Limb, Limb)

# Every variant of each kernel this host can run, beside the generic body.
private def list_of_two_run_variants : Array({String, TwoRunKernel, TwoRunKernel})
  list_of_variants = [] of {String, TwoRunKernel, TwoRunKernel}
  {% if flag?(:x86_64) %}
    if ProcessorKernels::FEATURES.includes?("bmi2") && ProcessorKernels::FEATURES.includes?("adx")
      list_of_variants << {"add_n bmi2-adx", TwoRunKernel.new { |r, a, b, n| Limbs.add_n_with_adx(r, a, b, n) }, TwoRunKernel.new { |r, a, b, n| Limbs.generic_add_n(r, a, b, n) }}
      list_of_variants << {"sub_n bmi2-adx", TwoRunKernel.new { |r, a, b, n| Limbs.sub_n_with_adx(r, a, b, n) }, TwoRunKernel.new { |r, a, b, n| Limbs.generic_sub_n(r, a, b, n) }}
    else
      STDERR.puts "processor kernels: bmi2-adx skipped (this processor lacks BMI2 or ADX)"
    end
  {% elsif flag?(:aarch64) %}
    list_of_variants << {"add_n aarch64-assembly", TwoRunKernel.new { |r, a, b, n| Limbs.add_n_with_assembly(r, a, b, n) }, TwoRunKernel.new { |r, a, b, n| Limbs.generic_add_n(r, a, b, n) }}
    list_of_variants << {"sub_n aarch64-assembly", TwoRunKernel.new { |r, a, b, n| Limbs.sub_n_with_assembly(r, a, b, n) }, TwoRunKernel.new { |r, a, b, n| Limbs.generic_sub_n(r, a, b, n) }}
  {% end %}
  list_of_variants
end

private def list_of_one_limb_variants : Array({String, OneLimbKernel, OneLimbKernel})
  list_of_variants = [] of {String, OneLimbKernel, OneLimbKernel}
  {% if flag?(:x86_64) %}
    if ProcessorKernels::FEATURES.includes?("bmi2") && ProcessorKernels::FEATURES.includes?("adx")
      list_of_variants << {"mul_1 bmi2-adx", OneLimbKernel.new { |r, a, n, b| Limbs.mul_1_with_adx(r, a, n, b) }, OneLimbKernel.new { |r, a, n, b| Limbs.generic_mul_1(r, a, n, b) }}
      list_of_variants << {"addmul_1 bmi2-adx", OneLimbKernel.new { |r, a, n, b| Limbs.addmul_1_with_adx(r, a, n, b) }, OneLimbKernel.new { |r, a, n, b| Limbs.generic_addmul_1(r, a, n, b) }}
      list_of_variants << {"submul_1 bmi2-adx", OneLimbKernel.new { |r, a, n, b| Limbs.submul_1_with_adx(r, a, n, b) }, OneLimbKernel.new { |r, a, n, b| Limbs.generic_submul_1(r, a, n, b) }}
    end
  {% end %}
  list_of_variants
end

private def random_limbs(random : Random, count : Int32) : Slice(Limb)
  Slice(Limb).new(count) { random.rand(3) == 0 ? {Limb::MAX, Limb.zero}.sample(random) : random.rand(Limb) }
end

describe Crystal::BigNum::ProcessorKernels do
  it "names the features it found and a body for every kernel" do
    STDERR.puts "processor kernels: features #{ProcessorKernels.detected_features.join(' ')}"
    STDERR.puts "processor kernels: chosen #{ProcessorKernels.chosen_variants}"
    ProcessorKernels.detected_features.each { |name| name.should eq(name.downcase) }
    ProcessorKernels.chosen_variants.keys.should eq(%w(add_n sub_n mul_1 addmul_1 submul_1))
    {% if flag?(:bignum_generic_kernels) %}
      ProcessorKernels.chosen_variants.values.uniq.should eq(["generic"])
    {% elsif flag?(:aarch64) %}
      ProcessorKernels.chosen_variants.values.should eq(%w(aarch64-assembly aarch64-assembly generic generic generic))
    {% end %}
    {% if flag?(:aarch64) %}
      ProcessorKernels.detected_features.should contain("neon")
    {% end %}
  end

  it "gives the generic body's result, bit for bit, in every variant on random inputs" do
    random = Random::PCG32.new(20261127)
    two_run_variants = list_of_two_run_variants
    one_limb_variants = list_of_one_limb_variants
    STDERR.puts "processor kernels: ran generic#{(two_run_variants + one_limb_variants).map { |variant| ", #{variant[0]}" }.join}"
    checked = 0
    3_000.times do
      count = random.rand(0..80)
      a = random_limbs(random, count)
      b = random_limbs(random, count)
      r = random_limbs(random, count)
      limb = random.rand(4) == 0 ? Limb::MAX : random.rand(Limb)
      two_run_variants.each do |name, variant, generic|
        expected = Slice(Limb).new(count)
        actual = Slice(Limb).new(count)
        generic_out = generic.call(expected.to_unsafe, a.to_unsafe, b.to_unsafe, count)
        variant.call(actual.to_unsafe, a.to_unsafe, b.to_unsafe, count).should eq(generic_out), name
        actual.should eq(expected), name
        checked += 1
      end
      one_limb_variants.each do |name, variant, generic|
        expected = r.dup
        actual = r.dup
        generic_out = generic.call(expected.to_unsafe, a.to_unsafe, count, limb)
        variant.call(actual.to_unsafe, a.to_unsafe, count, limb).should eq(generic_out), name
        actual.should eq(expected), name
        checked += 1
      end
    end
    STDERR.puts "processor kernels: compared #{checked} kernel calls"
  end
end

describe "Crystal::BigNum::Multiply.mul_4_by_4_with_assembly" do
  it "gives the schoolbook rows' product, bit for bit, where the processor has BMI2 and ADX" do
    {% if flag?(:x86_64) %}
      if ProcessorKernels.adx?
        random = Random::PCG32.new(20261128)
        200_000.times do
          a = random_limbs(random, 4)
          b = random_limbs(random, 4)
          expected = Slice(Limb).new(8)
          expected[4] = Limbs.generic_mul_1(expected.to_unsafe, a.to_unsafe, 4, b[0])
          (1..3).each { |row| expected[4 + row] = Limbs.generic_addmul_1(expected.to_unsafe + row, a.to_unsafe, 4, b[row]) }
          actual = Slice(Limb).new(8, Limb::MAX)
          Crystal::BigNum::Multiply.mul_4_by_4_with_assembly(actual.to_unsafe, a.to_unsafe, b.to_unsafe)
          actual.should eq(expected)
        end
      else
        STDERR.puts "processor kernels: mul_4_by_4 assembly skipped (this processor lacks BMI2 or ADX)"
      end
    {% else %}
      STDERR.puts "processor kernels: mul_4_by_4 assembly is x86-64 only"
    {% end %}
  end
end
