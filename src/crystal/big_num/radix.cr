module Crystal::BigNum
  # :nodoc:
  #
  # Conversion between magnitudes and digit strings (BIGNUM.md 4.6), by the
  # basecase methods of Knuth, *The Art of Computer Programming* vol. 2,
  # section 4.4:
  #
  # * Output in a power-of-two base slices the bits directly.
  # * Output in another base divides the magnitude repeatedly by the largest
  #   power of the base that fits a limb (10**19 for base 10), Method 1a, and
  #   prints each remainder; decimal remainders print from a two-digit table.
  # * Input in a power-of-two base packs the bits directly.
  # * Input in another base reads as many digits as fit a limb, then
  #   multiplies the result by that power of the base and adds them,
  #   Method 2a. Decimal digits are read eight at a time from one 64-bit
  #   load.
  #
  # The accepted syntax is exactly that of GMP's `mpz_set_str`, which
  # `BigInt.new(String, Int32)` calls after stripping a leading `+` and every
  # `_`: see `Integer.parse?`.
  #
  # The kernels assume 64-bit limbs.
  module Radix
    # What the chunked conversions need to know about a non-power-of-two
    # base: a limb holds `digits_per_limb` digits, `big_base` is
    # `base ** digits_per_limb`, `big_base << shift` has its top bit set and
    # `reciprocal` is its Möller-Granlund reciprocal, and `log2_fraction` is
    # `floor(2**64 * log(2) / log(base))`, from which `size_in_base` gives
    # the same bound as GMP's `mpz_sizeinbase`. The constants were computed
    # with exact integer arithmetic and 80-digit logarithms.
    record BaseFacts, digits_per_limb : Int32, big_base : UInt64, shift : Int32, reciprocal : UInt64, log2_fraction : UInt64

    # The facts for *base*, which must be 3 to 62 and not a power of two.
    def self.facts(base : Int32) : BaseFacts
      case base
      when  3 then BaseFacts.new(40, 0xa8b8_b452_291f_e821_u64, 0, 0x846d_550e_37b5_063d_u64, 0xa184_9cc1_a9a9_e94e_u64)
      when  5 then BaseFacts.new(27, 0x6765_c793_fa10_079d_u64, 1, 0x3ce9_a36f_23c0_fc90_u64, 0x6e40_d1a4_143d_cb94_u64)
      when  6 then BaseFacts.new(24, 0x41c2_1cb8_e100_0000_u64, 1, 0xf24f_6233_5024_a295_u64, 0x6308_c91b_702a_7cf4_u64)
      when  7 then BaseFacts.new(22, 0x3642_7987_5022_6111_u64, 2, 0x2df4_95cc_aa57_147b_u64, 0x5b30_64eb_3aa6_d388_u64)
      when  9 then BaseFacts.new(20, 0xa8b8_b452_291f_e821_u64, 0, 0x846d_550e_37b5_063d_u64, 0x50c2_4e60_d4d4_f4a7_u64)
      when 10 then BaseFacts.new(19, 0x8ac7_2304_89e8_0000_u64, 0, 0xd83c_94fb_6d2a_c34a_u64, 0x4d10_4d42_7de7_fbcc_u64)
      when 11 then BaseFacts.new(18, 0x4d28_cb56_c33f_a539_u64, 1, 0xa8ad_f7ae_45e7_577b_u64, 0x4a00_2707_7591_4e88_u64)
      when 12 then BaseFacts.new(17, 0x1eca_170c_0000_0000_u64, 3, 0x0a10_c2be_c5da_8f8f_u64, 0x4768_ce0d_0581_8e12_u64)
      when 13 then BaseFacts.new(17, 0x780c_7372_621b_d74d_u64, 1, 0x10f4_beca_fe41_2ec3_u64, 0x452e_53e3_6590_7bda_u64)
      when 14 then BaseFacts.new(16, 0x1e39_a505_7d81_0000_u64, 3, 0x0f08_480f_672b_4e86_u64, 0x433c_fffb_4b5a_ae55_u64)
      when 15 then BaseFacts.new(16, 0x5b27_ac99_3df9_7701_u64, 1, 0x6779_c7f9_0dc4_2f48_u64, 0x4186_7711_b4f8_5355_u64)
      when 17 then BaseFacts.new(15, 0x27b9_5e99_7e21_d9f1_u64, 2, 0x9c71_e11b_ab27_9323_u64, 0x3ea1_6afd_58b1_0966_u64)
      when 18 then BaseFacts.new(15, 0x5da0_e1e5_3c5c_8000_u64, 1, 0x5dfa_a697_ec6f_6a1c_u64, 0x3d64_598d_154d_c4de_u64)
      when 19 then BaseFacts.new(15, 0xd2ae_3299_c1c4_aedb_u64, 0, 0x3711_783f_6be7_e9ec_u64, 0x3c43_c230_18bb_5563_u64)
      when 20 then BaseFacts.new(14, 0x16bc_c41e_9000_0000_u64, 3, 0x6849_b86a_12b9_b01e_u64, 0x3b3b_9a42_8730_69c7_u64)
      when 21 then BaseFacts.new(14, 0x2d04_b7fd_d9c0_ef49_u64, 2, 0x6bf0_97ba_5ca5_e239_u64, 0x3a48_98f0_6cf4_1ac9_u64)
      when 22 then BaseFacts.new(14, 0x5658_597b_caa2_4000_u64, 1, 0x7b80_15c8_d7af_8f08_u64, 0x3968_0b13_582e_7c18_u64)
      when 23 then BaseFacts.new(14, 0xa0e2_0737_3760_9371_u64, 0, 0x975a_24b3_a315_1b38_u64, 0x3897_b2b7_51ae_561a_u64)
      when 24 then BaseFacts.new(13, 0x0c29_e980_0000_0000_u64, 4, 0x50bd_3679_7268_9db1_u64, 0x37d5_aed1_31f1_9c98_u64)
      when 25 then BaseFacts.new(13, 0x14ad_f4b7_3203_34b9_u64, 3, 0x8c24_0c4a_ecb1_3bb5_u64, 0x3720_68d2_0a1e_e5ca_u64)
      when 26 then BaseFacts.new(13, 0x226e_d364_78bf_a000_u64, 2, 0xdbd2_e568_54e1_18c9_u64, 0x3676_867e_5d60_de29_u64)
      when 27 then BaseFacts.new(13, 0x383d_9170_b85f_f80b_u64, 2, 0x2351_ffca_a9c7_c4ae_u64, 0x35d6_deeb_388d_f86f_u64)
      when 28 then BaseFacts.new(13, 0x5a3c_23e3_9c00_0000_u64, 1, 0x6b24_188c_a33b_0636_u64, 0x3540_71d6_1c77_fa2e_u64)
      when 29 then BaseFacts.new(13, 0x8e65_1373_8812_2bcd_u64, 0, 0xcc3d_ceaf_2b8b_a99d_u64, 0x34b2_60c5_671b_18ac_u64)
      when 30 then BaseFacts.new(13, 0xdd41_bb36_d259_e000_u64, 0, 0x2832_e835_c6c7_d6b6_u64, 0x342b_e986_572b_45cc_u64)
      when 31 then BaseFacts.new(12, 0x0aee_5720_ee83_0681_u64, 4, 0x76b6_aa27_2e18_73c5_u64, 0x33ac_61b9_98fb_bdf2_u64)
      when 33 then BaseFacts.new(12, 0x1725_88ad_4f5f_0981_u64, 3, 0x61ea_f5d4_02c7_bf4f_u64, 0x32bf_d901_14c1_2861_u64)
      when 34 then BaseFacts.new(12, 0x211e_44f7_d02c_1000_u64, 2, 0xeeb6_5812_3ffb_27ec_u64, 0x3251_dcf6_169e_45f2_u64)
      when 35 then BaseFacts.new(12, 0x2ee5_6725_f06e_5c71_u64, 2, 0x5d5e_3762_e6fd_f509_u64, 0x31e8_d59f_180d_c630_u64)
      when 36 then BaseFacts.new(12, 0x41c2_1cb8_e100_0000_u64, 1, 0xf24f_6233_5024_a295_u64, 0x3184_648d_b815_3e7a_u64)
      when 37 then BaseFacts.new(12, 0x5b5b_57f8_a98a_5dd1_u64, 1, 0x66ae_7831_762e_fb6f_u64, 0x3124_34e8_9c35_dacd_u64)
      when 38 then BaseFacts.new(12, 0x7dcf_f898_6ea3_1000_u64, 1, 0x0473_8886_5a00_f544_u64, 0x30c7_fa34_9460_a541_u64)
      when 39 then BaseFacts.new(12, 0xabd4_2116_62a6_b2a1_u64, 0, 0x7d67_3c33_a123_b54c_u64, 0x306f_6f4c_8432_bc6d_u64)
      when 40 then BaseFacts.new(12, 0xe8d4_a510_0000_0000_u64, 0, 0x1979_9812_dea1_1197_u64, 0x301a_557f_fbfd_d252_u64)
      when 41 then BaseFacts.new(11, 0x07a3_2956_ad08_1b79_u64, 5, 0x0c27_e62e_0686_feae_u64, 0x2fc8_73d1_fda5_5f3b_u64)
      when 42 then BaseFacts.new(11, 0x09f4_9aaf_f0e8_6800_u64, 4, 0x9b6e_7507_064c_e7c7_u64, 0x2f79_9652_a4e6_dc49_u64)
      when 43 then BaseFacts.new(11, 0x0ce5_83bb_812d_37b3_u64, 4, 0x3d9a_c2bf_66cf_ed94_u64, 0x2f2d_8d8f_6446_0aad_u64)
      when 44 then BaseFacts.new(11, 0x109b_79a6_54c0_0000_u64, 3, 0xed46_bc50_ce59_712a_u64, 0x2ee4_2e16_4e8f_53a4_u64)
      when 45 then BaseFacts.new(11, 0x1543_beff_214c_8b95_u64, 3, 0x813d_97e2_c89b_8d46_u64, 0x2e9d_5009_8404_1dbd_u64)
      when 46 then BaseFacts.new(11, 0x1b14_9a79_459a_3800_u64, 3, 0x2e81_7519_56af_8083_u64, 0x2e58_cec0_5a6a_8144_u64)
      when 47 then BaseFacts.new(11, 0x224e_dfb5_434a_830f_u64, 2, 0xdd8e_0a95_e30c_0988_u64, 0x2e16_8874_3ef9_104c_u64)
      when 48 then BaseFacts.new(11, 0x2b3f_b000_0000_0000_u64, 2, 0x7ad4_dd48_a0b5_b167_u64, 0x2dd6_5df7_a583_598f_u64)
      when 49 then BaseFacts.new(11, 0x3642_7987_5022_6111_u64, 2, 0x2df4_95cc_aa57_147b_u64, 0x2d98_3275_9d53_69c4_u64)
      when 50 then BaseFacts.new(11, 0x43c3_3c19_3756_4800_u64, 1, 0xe392_0101_75ee_5962_u64, 0x2d5b_eb38_dcd1_394c_u64)
      when 51 then BaseFacts.new(11, 0x5441_1b24_41c3_cd8b_u64, 1, 0x84ea_f11b_2fe7_738e_u64, 0x2d21_6f79_43e2_ba6a_u64)
      when 52 then BaseFacts.new(11, 0x6851_455a_cd40_0000_u64, 1, 0x3a1e_3971_e008_995d_u64, 0x2ce8_a82e_fbb3_ff2c_u64)
      when 53 then BaseFacts.new(11, 0x80a2_3b11_7c8f_eb6d_u64, 0, 0xfd7a_4623_44ff_ce25_u64, 0x2cb1_7fea_7ad7_e332_u64)
      when 54 then BaseFacts.new(11, 0x9dff_7d32_d5dc_1800_u64, 0, 0x9eca_40b4_0ebc_ef8a_u64, 0x2c7b_e2b0_cfa1_ba50_u64)
      when 55 then BaseFacts.new(11, 0xc155_af6f_aeff_e6a7_u64, 0, 0x52fa_161a_4a48_e43d_u64, 0x2c47_bddb_a92d_7463_u64)
      when 56 then BaseFacts.new(11, 0xebb7_392e_0000_0000_u64, 0, 0x1607_a2cb_acf9_30c1_u64, 0x2c14_fffc_aa8b_131e_u64)
      when 57 then BaseFacts.new(10, 0x0506_3365_9656_d971_u64, 5, 0x97a0_14f8_e3be_55f1_u64, 0x2be3_98c3_a38b_e053_u64)
      when 58 then BaseFacts.new(10, 0x05fa_8624_c7fb_a400_u64, 5, 0x568d_f8b7_6cbf_212c_u64, 0x2bb3_78e7_5845_1068_u64)
      when 59 then BaseFacts.new(10, 0x0717_d9fa_a73c_5679_u64, 5, 0x20ba_7c4b_4e6e_f492_u64, 0x2b84_9210_8be5_e5f7_u64)
      when 60 then BaseFacts.new(10, 0x0864_30aa_c610_0000_u64, 4, 0xe81e_e46b_9ef4_92f5_u64, 0x2b56_d6c7_0d55_481b_u64)
      when 61 then BaseFacts.new(10, 0x09e6_4d99_44b5_7f29_u64, 4, 0x9dc0_d10d_5194_0416_u64, 0x2b2a_3a60_8c72_ddd5_u64)
      when 62 then BaseFacts.new(10, 0x0ba5_ca53_92cb_0400_u64, 4, 0x5fa8_ed2f_4502_72a5_u64, 0x2afe_b0f1_060c_7e41_u64)
      else
        raise ArgumentError.new("No chunked conversion for base #{base}")
      end
    end

    TEN_19            = 10_000_000_000_000_000_000_u64
    TEN_19_RECIPROCAL =      0xd83c_94fb_6d2a_c34a_u64

    # Returned by a conversion kernel: the digits hold a byte that is not a
    # digit of the base.
    INVALID = -1
    # Returned by a conversion kernel: the digits hold whitespace or a NUL
    # byte, so they must be compacted first (see `compact`).
    COMPACT = -2

    # Digit values for bases up to 36 (case-insensitive), indexed by byte:
    # 0xFE marks whitespace and NUL, 0xFF any other byte that is no digit.
    private def self.digit_values_ignoring_case : Pointer(UInt8)
      (
        "\xFE\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFE\xFE\xFE\xFE\xFE\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFE\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18" \
        "\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18" \
        "\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
      ).to_unsafe
    end

    # Digit values for bases 37 to 62: `0-9` are 0 to 9, `A-Z` 10 to 35
    # and `a-z` 36 to 61, as GMP reads them.
    private def self.digit_values_with_case : Pointer(UInt8)
      (
        "\xFE\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFE\xFE\xFE\xFE\xFE\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFE\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18" \
        "\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\x24\x25\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x30\x31\x32" \
        "\x33\x34\x35\x36\x37\x38\x39\x3A\x3B\x3C\x3D\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" \
        "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
      ).to_unsafe
    end

    # The digit-value table GMP uses for *base*.
    def self.digit_values(base : Int32) : Pointer(UInt8)
      base > 36 ? digit_values_with_case : digit_values_ignoring_case
    end

    # Whether *byte* is whitespace in the C locale (`isspace`).
    @[AlwaysInline]
    def self.space?(byte : UInt8) : Bool
      byte == 0x20 || (byte &- 9) < 5
    end

    # The digits `00` to `99`, two characters each.
    private def self.digit_pairs : Pointer(UInt8)
      {{ (0..99).map { |i| (i < 10 ? "0" : "") + i.stringify }.join("") }}.to_unsafe
    end

    # Digits for output: `upcase` selects `0-9A-Z` for bases up to 36, and
    # base 62 uses `0-9a-zA-Z` (GMP's order with the case swapped, as
    # `BigInt#to_s` presents it).
    def self.alphabet(base : Int32, upcase : Bool) : Pointer(UInt8)
      if base == 62
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".to_unsafe
      elsif upcase
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".to_unsafe
      else
        "0123456789abcdefghijklmnopqrstuvwxyz".to_unsafe
      end
    end

    # Each byte `00` to `ff` as two hexadecimal digits, lowercase or
    # uppercase.
    private def self.hex_pairs(upcase : Bool) : Pointer(UInt8)
      if upcase
        {{ (0..255).map { |i| "0123456789ABCDEF"[i // 16..i // 16] + "0123456789ABCDEF"[i % 16..i % 16] }.join("") }}.to_unsafe
      else
        {{ (0..255).map { |i| "0123456789abcdef"[i // 16..i // 16] + "0123456789abcdef"[i % 16..i % 16] }.join("") }}.to_unsafe
      end
    end

    # Whether *base* is a power of two (2, 4, 8, 16 or 32 here).
    @[AlwaysInline]
    def self.power_of_two?(base : Int32) : Bool
      base & (base - 1) == 0
    end

    # The digit count GMP's `mpz_sizeinbase` gives for the *count* limbs at
    # *ap* (normalized): exact for a power-of-two base, and the exact count
    # or one more otherwise. Zero gives 1.
    def self.size_in_base(ap : Pointer(Limb), count : Int32, base : Int32) : Int64
      return 1_i64 if count == 0
      bits = count.to_i64 * LIMB_BITS - ap[count - 1].leading_zeros_count
      if power_of_two?(base)
        per_digit = base.trailing_zeros_count
        (bits + per_digit - 1) // per_digit
      else
        (((facts(base).log2_fraction.to_u128 + 1) &* bits.to_u128) >> 64).to_i64 + 1
      end
    end

    # ---- Division by a limb-sized constant ----

    # The quotient and remainder of the two-limb number *high*:*low* by the
    # normalized *divisor* (top bit set), where `high < divisor`, with the
    # reciprocal `floor((2**128 - 1) / divisor) - 2**64`. Möller and
    # Granlund, "Improved division by invariant integers" (2011),
    # Algorithm 4.
    @[AlwaysInline]
    def self.divide_two_by_one(high : UInt64, low : UInt64, divisor : UInt64, reciprocal : UInt64) : {UInt64, UInt64}
      product = high.to_u128! &* reciprocal &+ ((high.to_u128! << 64) | low)
      quotient = (product >> 64).to_u64! &+ 1
      remainder = low &- quotient &* divisor
      # The first correction is taken about half the time, so it is done
      # with a mask instead of a branch; the second is rare.
      mask = remainder > product.to_u64! ? UInt64::MAX : 0_u64
      quotient &+= mask
      remainder &+= mask & divisor
      if remainder >= divisor
        quotient &+= 1
        remainder &-= divisor
      end
      {quotient, remainder}
    end

    # Divides the *count* limbs at *ap* in place by `divisor >> shift` (the
    # *divisor* is normalized and *reciprocal* is its reciprocal) and
    # returns the remainder.
    @[AlwaysInline]
    def self.divide_in_place(ap : Pointer(Limb), count : Int32, divisor : UInt64, reciprocal : UInt64, shift : Int32) : UInt64
      index = count &- 1
      if shift == 0
        remainder = 0_u64
        top = ap[index]
        if top < divisor
          ap[index] = 0_u64
          remainder = top
          index &-= 1
        end
        while index >= 0
          quotient, remainder = divide_two_by_one(remainder, ap[index], divisor, reciprocal)
          ap[index] = quotient
          index &-= 1
        end
        remainder
      else
        # Divide the magnitude shifted left by *shift*: the quotient is the
        # same, and the remainder comes out shifted.
        back = LIMB_BITS &- shift
        remainder = ap[index] >> back
        high = ap[index]
        while index >= 0
          low = index > 0 ? ap[index &- 1] : 0_u64
          quotient, remainder = divide_two_by_one(remainder, (high << shift) | (low >> back), divisor, reciprocal)
          ap[index] = quotient
          high = low
          index &-= 1
        end
        remainder >> shift
      end
    end

    # Splits the *count* limbs at *scratch* (destroyed) into chunks below
    # `divisor >> shift`, least significant first, written to *chunks*;
    # returns how many. Knuth 4.4, Method 1a.
    @[AlwaysInline]
    def self.split(chunks : Pointer(UInt64), scratch : Pointer(Limb), count : Int32, divisor : UInt64, reciprocal : UInt64, shift : Int32) : Int32
      big_base = divisor >> shift
      used = 0
      while count > 1 || (count == 1 && scratch[0] >= big_base)
        chunks[used] = divide_in_place(scratch, count, divisor, reciprocal, shift)
        used &+= 1
        count &-= 1 if scratch[count &- 1] == 0
      end
      if count == 1
        chunks[used] = scratch[0]
        used &+= 1
      end
      used
    end

    # ---- Output ----

    # The digits of the *count* limbs at *ap* in *base* (2 to 36, or 62),
    # as a new string: see `render`.
    def self.to_s(ap : Pointer(Limb), count : Int32, negative : Bool, base : Int32, upcase : Bool, precision : Int32) : String
      string = ""
      render(ap, count, negative, base, upcase, precision) do |length|
        # The string is allocated at its exact length, and `render` fills
        # it before it is returned to anyone.
        string = String.new(length) { {length, length} }
        string.to_unsafe
      end
      string
    end

    # Writes the digits to *io*, through a buffer on the stack when they
    # fit 160 bytes (512 bits in decimal).
    def self.to_s(io : IO, ap : Pointer(Limb), count : Int32, negative : Bool, base : Int32, upcase : Bool, precision : Int32) : Nil
      stack = uninitialized StaticArray(UInt8, 160)
      buffer = stack.to_unsafe
      written = 0
      render(ap, count, negative, base, upcase, precision) do |length|
        written = length
        buffer = Pointer(UInt8).malloc(length) if length > 160
        buffer
      end
      io.write_string(Slice.new(buffer, written))
    end

    # Renders the *count* limbs at *ap* in *base* (2 to 36, or 62), with a
    # `-` when *negative* and leading zeros up to *precision* digits: yields
    # the exact byte length once it is known, and writes the bytes to the
    # buffer the block returns. Zero has no digits of its own, so precision
    # 0 renders it as "".
    @[AlwaysInline]
    def self.render(ap : Pointer(Limb), count : Int32, negative : Bool, base : Int32, upcase : Bool, precision : Int32, & : Int32 -> Pointer(UInt8)) : Nil
      sign = negative ? 1 : 0
      if count == 0
        buffer = yield precision
        buffer.fill(precision, 0x30_u8)
        return
      end

      if power_of_two?(base)
        digits = size_in_base(ap, count, base).to_i32
        buffer = pad(yield(sign &+ Math.max(digits, precision)), negative, precision &- digits)
        if base == 16
          write_hexadecimal(buffer, ap, count, digits, upcase)
        else
          write_power_of_two(buffer, ap, count, digits, base.trailing_zeros_count, alphabet(base, upcase))
        end
        return
      end

      # Room for every chunk: a chunk holds at least 58 bits.
      if count <= 32
        scratch_storage = uninitialized StaticArray(Limb, 32)
        chunk_storage = uninitialized StaticArray(UInt64, 38)
        scratch = scratch_storage.to_unsafe
        chunks = chunk_storage.to_unsafe
      else
        scratch = Limbs.allocate(count)
        chunks = Limbs.allocate(count &+ (count >> 3) &+ 2)
      end
      index = 0
      while index < count
        scratch[index] = ap[index]
        index &+= 1
      end

      if base == 10
        used = split(chunks, scratch, count, TEN_19, TEN_19_RECIPROCAL, 0)
        top = chunks[used &- 1]
        top_digits = decimal_digit_count(top)
        digits = top_digits &+ (used &- 1) &* 19
        buffer = pad(yield(sign &+ Math.max(digits, precision)), negative, precision &- digits)
        write_top_decimal(buffer, top, top_digits)
        buffer += top_digits
        index = used &- 2
        while index >= 0
          write_19_decimal(buffer, chunks[index])
          buffer += 19
          index &-= 1
        end
      else
        facts = facts(base)
        per_chunk = facts.digits_per_limb
        alphabet = alphabet(base, upcase)
        used = split(chunks, scratch, count, facts.big_base << facts.shift, facts.reciprocal, facts.shift)
        top = chunks[used &- 1]
        top_digits = digit_count(top, base)
        digits = top_digits &+ (used &- 1) &* per_chunk
        buffer = pad(yield(sign &+ Math.max(digits, precision)), negative, precision &- digits)
        write_padded(buffer, top, top_digits, base, alphabet)
        buffer += top_digits
        index = used &- 2
        while index >= 0
          write_padded(buffer, chunks[index], per_chunk, base, alphabet)
          buffer += per_chunk
          index &-= 1
        end
      end
    end

    # Writes the sign and *zeros* (when positive) leading zeros at *buffer*
    # and returns where the digits start.
    @[AlwaysInline]
    private def self.pad(buffer : Pointer(UInt8), negative : Bool, zeros : Int32) : Pointer(UInt8)
      if negative
        buffer.value = 0x2D_u8
        buffer += 1
      end
      if zeros > 0
        buffer.fill(zeros, 0x30_u8)
        buffer += zeros
      end
      buffer
    end

    # The count of decimal digits of *value* (`0 < value < 10**19`): the
    # bit length times log10(2) (1233 / 4096) is the count or one less.
    @[AlwaysInline]
    def self.decimal_digit_count(value : UInt64) : Int32
      estimate = ((LIMB_BITS &- value.leading_zeros_count.to_i32) &* 1233) >> 12
      estimate &+ (value >= power_of_ten(estimate) ? 1 : 0)
    end

    # 10 ** *exponent*, for 0 to 19.
    @[AlwaysInline]
    private def self.power_of_ten(exponent : Int32) : UInt64
      {1_u64, 10_u64, 100_u64, 1_000_u64, 10_000_u64, 100_000_u64, 1_000_000_u64, 10_000_000_u64,
       100_000_000_u64, 1_000_000_000_u64, 10_000_000_000_u64, 100_000_000_000_u64,
       1_000_000_000_000_u64, 10_000_000_000_000_u64, 100_000_000_000_000_u64,
       1_000_000_000_000_000_u64, 10_000_000_000_000_000_u64, 100_000_000_000_000_000_u64,
       1_000_000_000_000_000_000_u64, TEN_19}[exponent]
    end

    # The count of digits of *value* (> 0) in *base*.
    private def self.digit_count(value : UInt64, base : Int32) : Int32
      count = 0
      while value > 0
        value //= base.to_u64!
        count &+= 1
      end
      count
    end

    # Writes the two digits of *value* (< 100) at *buffer*.
    @[AlwaysInline]
    private def self.write_pair(buffer : Pointer(UInt8), value : UInt32) : Nil
      buffer.copy_from(digit_pairs + (value &* 2), 2)
    end

    # Writes the eight decimal digits of *value* (< 10**8), zero-padded.
    @[AlwaysInline]
    private def self.write_8_decimal(buffer : Pointer(UInt8), value : UInt32) : Nil
      high = value // 10_000
      low = value % 10_000
      write_pair(buffer, high // 100)
      write_pair(buffer + 2, high % 100)
      write_pair(buffer + 4, low // 100)
      write_pair(buffer + 6, low % 100)
    end

    # Writes the 19 decimal digits of *value* (< 10**19), zero-padded.
    @[AlwaysInline]
    private def self.write_19_decimal(buffer : Pointer(UInt8), value : UInt64) : Nil
      top = (value // 10_000_000_000_000_000_u64).to_u32!
      rest = value % 10_000_000_000_000_000_u64
      buffer.value = 0x30_u8 &+ (top // 100).to_u8!
      write_pair(buffer + 1, top % 100)
      write_8_decimal(buffer + 3, (rest // 100_000_000).to_u32!)
      write_8_decimal(buffer + 11, (rest % 100_000_000).to_u32!)
    end

    # Writes the *digits* decimal digits of *value* (`0 < value < 10**19`).
    @[AlwaysInline]
    private def self.write_top_decimal(buffer : Pointer(UInt8), value : UInt64, digits : Int32) : Nil
      padded = uninitialized StaticArray(UInt8, 19)
      write_19_decimal(padded.to_unsafe, value)
      buffer.copy_from(padded.to_unsafe + (19 &- digits), digits)
    end

    # Writes the *digits* least significant digits of *value* in *base*,
    # zero-padded.
    private def self.write_padded(buffer : Pointer(UInt8), value : UInt64, digits : Int32, base : Int32, alphabet : Pointer(UInt8)) : Nil
      divisor = base.to_u64!
      index = digits &- 1
      while index >= 0
        buffer[index] = alphabet[value % divisor]
        value //= divisor
        index &-= 1
      end
    end

    # Writes the *digits* hexadecimal digits of the *count* limbs at *ap*.
    private def self.write_hexadecimal(buffer : Pointer(UInt8), ap : Pointer(Limb), count : Int32, digits : Int32, upcase : Bool) : Nil
      pairs = hex_pairs(upcase)
      top_digits = digits &- (count &- 1) &* 16
      top = ap[count &- 1]
      # The top limb two digits (one byte) at a time from its low end, and
      # a lone high digit when the count is odd.
      index = top_digits &- 2
      while index >= 0
        (buffer + index).copy_from(pairs + (top & 255) &* 2, 2)
        top >>= 8
        index &-= 2
      end
      buffer.value = pairs[((top & 15) << 1) | 1] if index == -1
      buffer += top_digits
      limb_index = count &- 2
      while limb_index >= 0
        limb = ap[limb_index]
        {% for byte in 0..7 %}
          buffer.copy_from(pairs + ((limb >> {{ 56 - byte * 8 }}) & 255) &* 2, 2)
          buffer += 2
        {% end %}
        limb_index &-= 1
      end
    end

    # Writes the *digits* digits of *bits* bits each of the *count* limbs at
    # *ap*, most significant first.
    private def self.write_power_of_two(buffer : Pointer(UInt8), ap : Pointer(Limb), count : Int32, digits : Int32, bits : Int32, alphabet : Pointer(UInt8)) : Nil
      mask = (1_u64 << bits) &- 1
      position = (digits &- 1) &* bits
      index = 0
      while index < digits
        limb_index = position >> 6
        offset = position & 63
        value = ap[limb_index] >> offset
        if offset &+ bits > LIMB_BITS && limb_index &+ 1 < count
          value |= ap[limb_index &+ 1] << (LIMB_BITS &- offset)
        end
        buffer[index] = alphabet[value & mask]
        position &-= bits
        index &+= 1
      end
    end

    # ---- Input ----

    # Where the digits of a string start once GMP's prefix is read: leading
    # whitespace, a `-`, the base prefix when the base is 0, and leading
    # zeros and whitespace.
    record Prefix, start : Int32, base : Int32, negative : Bool, zero : Bool

    # Reads the front of *bytesize* bytes at *pointer* the way
    # `mpz_set_str` does in *base*, or returns nil when that already shows
    # the string is invalid. A NUL byte ends the string, as in C.
    def self.prefix(pointer : Pointer(UInt8), bytesize : Int32, base : Int32) : Prefix?
      return nil if base < 0 || base > 62
      values = digit_values(base)
      index = 0
      byte = bytesize > 0 ? pointer[0] : 0_u8
      while byte != 0 && space?(byte)
        index &+= 1
        byte = index < bytesize ? pointer[index] : 0_u8
      end
      negative = false
      if byte == 0x2D
        negative = true
        index &+= 1
        byte = index < bytesize ? pointer[index] : 0_u8
      end
      return nil if values[byte] >= (base == 0 ? 10 : base)
      if base == 0
        base = 10
        if byte == 0x30
          base = 8
          index &+= 1
          byte = index < bytesize ? pointer[index] : 0_u8
          if byte == 0x78 || byte == 0x58 # x, X
            base = 16
            index &+= 1
            byte = index < bytesize ? pointer[index] : 0_u8
          elsif byte == 0x62 || byte == 0x42 # b, B
            base = 2
            index &+= 1
            byte = index < bytesize ? pointer[index] : 0_u8
          end
        end
      end
      while byte == 0x30 || (byte != 0 && space?(byte))
        index &+= 1
        byte = index < bytesize ? pointer[index] : 0_u8
      end
      Prefix.new(index, base, negative, byte == 0)
    end

    # The limbs a conversion of *length* digits (with no leading zero) in
    # *base* can need.
    def self.capacity(length : Int32, base : Int32) : Int32
      if power_of_two?(base)
        ((length.to_i64 * base.trailing_zeros_count + LIMB_BITS - 1) // LIMB_BITS).to_i32
      else
        per_chunk = base == 10 ? 19 : facts(base).digits_per_limb
        (length &+ per_chunk &- 1) // per_chunk
      end
    end

    # Converts the *length* digit characters at *chars* (the first one not a
    # zero) in *base* (2 to 62) into the limbs at *rp* (room for `capacity`)
    # and returns how many it wrote, or `INVALID` or `COMPACT`.
    def self.convert(rp : Pointer(Limb), chars : Pointer(UInt8), length : Int32, base : Int32) : Int32
      return INVALID if base < 2
      status = if base == 10
                 convert_decimal(rp, chars, length)
               elsif base == 16
                 convert_hexadecimal(rp, chars, length, digit_values(base))
               elsif power_of_two?(base)
                 convert_power_of_two(rp, chars, length, base.trailing_zeros_count, digit_values(base))
               else
                 convert_chunked(rp, chars, length, base, facts(base), digit_values(base))
               end
      status >= 0 ? status : classify(chars, length)
    end

    # Why a run of digits failed: `COMPACT` when it holds whitespace or a
    # NUL (compacting decides), `INVALID` otherwise.
    private def self.classify(chars : Pointer(UInt8), length : Int32) : Int32
      index = 0
      while index < length
        byte = chars[index]
        return COMPACT if byte == 0 || space?(byte)
        index &+= 1
      end
      INVALID
    end

    # Copies the *length* bytes at *chars* to *target* without whitespace,
    # stopping at a NUL, as `mpz_set_str` reads them; returns the count.
    def self.compact(target : Pointer(UInt8), chars : Pointer(UInt8), length : Int32) : Int32
      written = 0
      index = 0
      while index < length
        byte = chars[index]
        break if byte == 0
        unless space?(byte)
          target[written] = byte
          written &+= 1
        end
        index &+= 1
      end
      written
    end

    # The value of the eight decimal digit characters loaded little-endian
    # in *word*, or nil when one of them is not a digit. Lemire's SWAR
    # parsing (simdjson's `parse_eight_digits_unrolled`).
    @[AlwaysInline]
    private def self.eight_decimal_digits(word : UInt64) : UInt64?
      return nil unless ((word & 0xF0F0F0F0F0F0F0F0_u64) | (((word &+ 0x0606060606060606_u64) & 0xF0F0F0F0F0F0F0F0_u64) >> 4)) == 0x3333333333333333_u64
      word = ((word & 0x0F0F0F0F0F0F0F0F_u64) &* 2561) >> 8
      word = ((word & 0x00FF00FF00FF00FF_u64) &* 6553601) >> 16
      ((word & 0x0000FFFF0000FFFF_u64) &* 42949672960001_u64) >> 32
    end

    # The value of the *count* (at most 19) decimal digit characters at
    # *chars*, or nil when one is not a digit.
    @[AlwaysInline]
    private def self.read_decimal(chars : Pointer(UInt8), count : Int32) : UInt64?
      value = 0_u64
      while count >= 8
        word = 0_u64
        pointerof(word).as(UInt8*).copy_from(chars, 8)
        eight = eight_decimal_digits(word)
        return nil unless eight
        value = value &* 100_000_000 &+ eight
        chars += 8
        count &-= 8
      end
      while count > 0
        digit = chars.value &- 0x30
        return nil if digit > 9
        value = value &* 10 &+ digit
        chars += 1
        count &-= 1
      end
      value
    end

    # Method 2a for base 10: 19 digits per limb.
    private def self.convert_decimal(rp : Pointer(Limb), chars : Pointer(UInt8), length : Int32) : Int32
      chunks = (length &+ 18) // 19
      first = length &- (chunks &- 1) &* 19
      value = read_decimal(chars, first)
      return INVALID unless value
      rp[0] = value
      size = 1
      position = first
      while position < length
        chunk = read_decimal(chars + position, 19)
        return INVALID unless chunk
        high = Limbs.mul_1(rp, rp, size, TEN_19)
        high &+= Limbs.add_1(rp, rp, size, chunk)
        if high != 0
          rp[size] = high
          size &+= 1
        end
        position &+= 19
      end
      size
    end

    # Method 2a for a base that is not a power of two.
    private def self.convert_chunked(rp : Pointer(Limb), chars : Pointer(UInt8), length : Int32, base : Int32, facts : BaseFacts, values : Pointer(UInt8)) : Int32
      per_chunk = facts.digits_per_limb
      chunks = (length &+ per_chunk &- 1) // per_chunk
      first = length &- (chunks &- 1) &* per_chunk
      value = read_chunk(chars, first, base, values)
      return INVALID unless value
      rp[0] = value
      size = 1
      position = first
      while position < length
        chunk = read_chunk(chars + position, per_chunk, base, values)
        return INVALID unless chunk
        high = Limbs.mul_1(rp, rp, size, facts.big_base)
        high &+= Limbs.add_1(rp, rp, size, chunk)
        if high != 0
          rp[size] = high
          size &+= 1
        end
        position &+= per_chunk
      end
      size
    end

    # The value of the *count* digit characters at *chars* in *base*, or
    # nil when one is not a digit of the base.
    @[AlwaysInline]
    private def self.read_chunk(chars : Pointer(UInt8), count : Int32, base : Int32, values : Pointer(UInt8)) : UInt64?
      value = 0_u64
      index = 0
      while index < count
        digit = values[chars[index]]
        return nil if digit >= base
        value = value &* base &+ digit
        index &+= 1
      end
      value
    end

    # Packs the *length* hexadecimal digits at *chars* into *rp*, sixteen
    # to a limb: each limb's digits are looked up and shifted in with no
    # branch, and checked once, by the OR of their values.
    private def self.convert_hexadecimal(rp : Pointer(Limb), chars : Pointer(UInt8), length : Int32, values : Pointer(UInt8)) : Int32
      written = 0
      finish = length
      while finish >= 16
        start = chars + (finish &- 16)
        limb = 0_u64
        seen = 0_u8
        {% for index in 0..15 %}
          digit{{ index }} = values[start[{{ index }}]]
          seen |= digit{{ index }}
          limb |= digit{{ index }}.to_u64! << {{ 60 - index * 4 }}
        {% end %}
        return INVALID if seen >= 16
        rp[written] = limb
        written &+= 1
        finish &-= 16
      end
      if finish > 0
        limb = 0_u64
        index = 0
        while index < finish
          digit = values[chars[index]]
          return INVALID if digit >= 16
          limb = (limb << 4) | digit
          index &+= 1
        end
        rp[written] = limb
        written &+= 1
      end
      written
    end

    # Packs the *length* digits of *bits* bits each at *chars* into *rp*,
    # from the least significant digit (the last character) up.
    private def self.convert_power_of_two(rp : Pointer(Limb), chars : Pointer(UInt8), length : Int32, bits : Int32, values : Pointer(UInt8)) : Int32
      base = 1 << bits
      limb = 0_u64
      filled = 0
      written = 0
      index = length &- 1
      while index >= 0
        digit = values[chars[index]]
        return INVALID if digit >= base
        limb |= digit.to_u64! << filled
        filled &+= bits
        if filled >= LIMB_BITS
          rp[written] = limb
          written &+= 1
          filled &-= LIMB_BITS
          limb = filled > 0 ? digit.to_u64! >> (bits &- filled) : 0_u64
        end
        index &-= 1
      end
      if filled > 0
        rp[written] = limb
        written &+= 1
      end
      written
    end
  end

  struct Integer
    # Parses *str* in *base* (0 or 2 to 62) with exactly the syntax of GMP's
    # `mpz_set_str`, which `BigInt.new(str, base)` calls after removing a
    # leading `+` and every `_`; raises `ArgumentError` as `BigInt` does.
    def self.parse(str : String, base : Int32) : Integer
      parse?(str, base) || raise ArgumentError.new("Invalid BigInt: #{str}")
    end

    # Parses *str* in *base* as `mpz_set_str` reads it, or returns nil when
    # it is not valid:
    #
    # * Whitespace (C's `isspace`: space, `\t`, `\n`, `\v`, `\f`, `\r`) may
    #   lead the string and appear anywhere after its first digit, and a NUL
    #   byte ends it.
    # * A `-` may come first, directly followed by a digit.
    # * Base 0 reads a `0x`/`0X` prefix as base 16, `0b`/`0B` as base 2, a
    #   leading `0` as base 8, and base 10 otherwise.
    # * Bases up to 36 ignore case; bases 37 to 62 read `A-Z` as 10 to 35
    #   and `a-z` as 36 to 61.
    #
    # Up to 38 decimal digits (two limbs) parse with no heap allocation.
    def self.parse?(str : String, base : Int32) : Integer?
      prefix = Radix.prefix(str.to_unsafe, str.bytesize, base)
      return nil unless prefix
      return zero if prefix.zero
      chars = str.to_unsafe + prefix.start
      length = str.bytesize &- prefix.start
      result = convert_digits(chars, length, prefix.base, prefix.negative)
      return result if result.is_a?(Integer)
      return nil if result == Radix::INVALID
      compacted = Pointer(UInt8).malloc(length)
      length = Radix.compact(compacted, chars, length)
      result = convert_digits(compacted, length, prefix.base, prefix.negative)
      result.is_a?(Integer) ? result : nil
    end

    # Converts the digits into a value, or returns the kernel's failure.
    private def self.convert_digits(chars : Pointer(UInt8), length : Int32, base : Int32, negative : Bool) : Integer | Int32
      capacity = Radix.capacity(length, base)
      if capacity <= 2
        buffer = uninitialized StaticArray(Limb, 2)
        used = Radix.convert(buffer.to_unsafe, chars, length, base)
        used < 0 ? used : from_buffer(buffer.to_unsafe, used, negative, false)
      else
        heap = Limbs.allocate(capacity)
        used = Radix.convert(heap, chars, length, base)
        used < 0 ? used : from_buffer(heap, used, negative, true)
      end
    end

    # The value in *base* (2 to 36, or 62), as `BigInt#to_s(base, upcase:,
    # precision:)`: lowercase digits unless *upcase*, base 62 as
    # `0-9a-zA-Z`, and at least *precision* digits.
    def to_s(base : Int = 10, upcase : Bool = false, *, precision : Int = 1) : String
      raise ArgumentError.new("Invalid base #{base}") unless 2 <= base <= 36 || base == 62
      raise ArgumentError.new("upcase must be false for base 62") if upcase && base == 62
      raise ArgumentError.new("Precision must be non-negative") unless precision >= 0
      Radix.to_s(limb_pointer, size, negative?, base.to_i32, upcase, precision.to_i32)
    end

    # :ditto:
    def to_s(io : IO, base : Int = 10, upcase : Bool = false, *, precision : Int = 1) : Nil
      raise ArgumentError.new("Invalid base #{base}") unless 2 <= base <= 36 || base == 62
      raise ArgumentError.new("upcase must be false for base 62") if upcase && base == 62
      raise ArgumentError.new("Precision must be non-negative") unless precision >= 0
      Radix.to_s(io, limb_pointer, size, negative?, base.to_i32, upcase, precision.to_i32)
    end

    # The digit count of the value in *base* (2 to 62) that GMP's
    # `mpz_sizeinbase` gives: exact for a power-of-two base, and possibly
    # one more than exact otherwise. Zero gives 1.
    def size_in_base(base : Int) : Int64
      raise ArgumentError.new("Invalid base #{base}") unless 2 <= base <= 62
      Radix.size_in_base(limb_pointer, size, base.to_i32)
    end
  end
end
