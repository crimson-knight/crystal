module Crystal::BigNum
  # :nodoc:
  #
  # Chooses, once when the program starts, which body each hot limb kernel
  # runs on this processor, the way Mica's and Grant's `ProcessorKernels` do.
  # One binary carries every body, and every body gives the same result bit
  # for bit (spec/std/crystal/big_num/processor_kernels_spec.cr runs each one
  # the host supports against the generic body).
  #
  # - x86-64: CPUID leaf 7 says whether the processor has BMI2 (`mulx`) and
  #   ADX (`adcx`/`adox`); with both, `add_n`, `sub_n`, `mul_1`, `addmul_1`
  #   and `submul_1` run bodies compiled for `+bmi2,+adx`; products of up
  #   to four limbs by four run bodies compiled for `+bmi2`, and the 4 by 4
  #   product our own `mulx`/`adcx`/`adox` assembly
  #   (`Multiply.mul_4_by_4_with_assembly`). Every x86-64 processor divides
  #   two limbs by one with one `div` (`Divide.div_2by1_plain`).
  # - AArch64 (Linux `AT_HWCAP`, macOS `sysctl`): `add_n` and `sub_n` run our
  #   own assembly (one `adcs`/`sbcs` chain kept in the flags across the
  #   loop, `limbs_aarch64.cr`), which every AArch64 processor runs; the other
  #   kernels run the generic body, unrolled by four. The features are read
  #   for the report.
  #
  # A program compiled with `-Dbignum_generic_kernels` runs the generic body of
  # every kernel, so a bench can compare both bodies on one host.
  module ProcessorKernels
    {% if flag?(:x86_64) %}
      # Returns EAX, EBX, ECX and EDX for CPUID *leaf*, subleaf 0.
      private def self.processor_identification(leaf : UInt32) : {UInt32, UInt32, UInt32, UInt32}
        eax = 0_u32
        ebx = 0_u32
        ecx = 0_u32
        edx = 0_u32
        # Every x86-64 asm here declares "flags" (scripts/big_num/x86_flags_scan.rb checks it).
        asm("cpuid" : "={eax}"(eax), "={ebx}"(ebx), "={ecx}"(ecx), "={edx}"(edx) : "{eax}"(leaf), "{ecx}"(0_u32) : "flags", "dirflag", "fpsr")
        {eax, ebx, ecx, edx}
      end

      private def self.list_of_x86_features : Array(String)
        list_of_features = [] of String
        return list_of_features if processor_identification(0_u32)[0] < 7
        extended_features = processor_identification(7_u32)[1]
        list_of_features << "bmi2" if extended_features.bit(8) == 1
        list_of_features << "adx" if extended_features.bit(19) == 1
        list_of_features
      end

      FEATURES = list_of_x86_features
    {% elsif flag?(:aarch64) && flag?(:linux) %}
      lib LibAuxiliaryVector
        fun getauxval(type : LibC::ULong) : LibC::ULong
      end

      # `AT_HWCAP` and its bits (Linux `arch/arm64/include/uapi/asm/hwcap.h`).
      private HARDWARE_CAPABILITIES_ENTRY = 16
      private ADVANCED_SIMD_CAPABILITY    = 1_u64 << 1
      private ATOMICS_CAPABILITY          = 1_u64 << 8
      private SVE_CAPABILITY              = 1_u64 << 22

      private def self.list_of_arm_features : Array(String)
        capabilities = LibAuxiliaryVector.getauxval(HARDWARE_CAPABILITIES_ENTRY).to_u64
        list_of_features = [] of String
        list_of_features << "neon" if capabilities & ADVANCED_SIMD_CAPABILITY != 0
        list_of_features << "lse" if capabilities & ATOMICS_CAPABILITY != 0
        list_of_features << "sve" if capabilities & SVE_CAPABILITY != 0
        list_of_features
      end

      FEATURES = list_of_arm_features
    {% elsif flag?(:aarch64) && flag?(:darwin) %}
      lib LibSystemControl
        fun sysctlbyname(name : LibC::Char*, oldp : Void*, oldlenp : LibC::SizeT*, newp : Void*, newlen : LibC::SizeT) : LibC::Int
      end

      # Whether `sysctl` reports the integer *name* as nonzero.
      private def self.has_system_feature?(name : String) : Bool
        value = 0_i32
        length = LibC::SizeT.new(sizeof(Int32))
        LibSystemControl.sysctlbyname(name, pointerof(value).as(Void*), pointerof(length), Pointer(Void).null, LibC::SizeT.zero) == 0 && value != 0
      end

      private def self.list_of_arm_features : Array(String)
        list_of_features = [] of String
        list_of_features << "neon" if has_system_feature?("hw.optional.arm.AdvSIMD")
        list_of_features << "lse" if has_system_feature?("hw.optional.arm.FEAT_LSE")
        list_of_features << "sme" if has_system_feature?("hw.optional.arm.FEAT_SME")
        list_of_features
      end

      FEATURES = list_of_arm_features
    {% else %}
      FEATURES = [] of String
    {% end %}

    # Whether the limb kernels run their `+bmi2,+adx` bodies.
    ADX = {{ flag?(:x86_64) && !flag?(:bignum_generic_kernels) }} && FEATURES.includes?("bmi2") && FEATURES.includes?("adx")

    @[AlwaysInline]
    def self.adx? : Bool
      ADX
    end

    # The lowercase names of the features found on this processor.
    def self.detected_features : Array(String)
      FEATURES.dup
    end

    # Each kernel's name and the body it runs on this processor.
    def self.chosen_variants : Hash(String, String)
      variant = adx? ? "x86-64-bmi2-adx" : "generic"
      carry_chain = {{ flag?(:aarch64) && !flag?(:bignum_generic_kernels) }} ? "aarch64-assembly" : variant
      {
        "add_n"    => carry_chain,
        "sub_n"    => carry_chain,
        "mul_1"    => variant,
        "addmul_1" => variant,
        "submul_1" => variant,
      }
    end
  end

  {% if flag?(:x86_64) %}
    module Limbs
      {% for name in %w(add_n sub_n) %}
        # `{{ name.id }}` compiled for BMI2 and ADX.
        @[TargetFeature("+bmi2,+adx")]
        def self.{{ name.id }}_with_adx(rp : Pointer(Limb), ap : Pointer(Limb), bp : Pointer(Limb), n : Int32) : Limb
          generic_{{ name.id }}(rp, ap, bp, n, Limb.zero)
        end
      {% end %}

      {% for name in %w(mul_1 addmul_1 submul_1) %}
        # `{{ name.id }}` compiled for BMI2 and ADX.
        @[TargetFeature("+bmi2,+adx")]
        def self.{{ name.id }}_with_adx(rp : Pointer(Limb), ap : Pointer(Limb), n : Int32, b : Limb) : Limb
          generic_{{ name.id }}(rp, ap, n, b)
        end
      {% end %}
    end
  {% end %}
end
