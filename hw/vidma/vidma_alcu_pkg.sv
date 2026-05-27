// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// Shared types, MX constants, and FP conversion functions for the ALCU.
// All numeric functions must be bit-exact with the Rust golden models in
// crates/vidma_new/src/backend/transport/alcu/.

package vidma_alcu_pkg;

  // ── MX Block Constants ──────────────────────────────────────────────
  localparam int unsigned MxBlockSize = 32;
  localparam int unsigned MxFp32BlockBytes = MxBlockSize * 4;  // 128
  localparam int unsigned MxCompressedBlockBytes = MxBlockSize + 1;  // 33

  // ── E5M2 / FP32 Constants ──────────────────────────────────────────
  localparam int E5m2Bias = 15;
  localparam int E5m2ExpMax = 15;
  localparam int E5m2ExpMin = -14;
  localparam int Fp32Bias = 127;

  // ── ALU Opcode Constants ───────────────────────────────────────────
  localparam logic [4:0] OpZeroGen = 5'h00;
  localparam logic [4:0] OpOnesGen = 5'h01;
  localparam logic [4:0] OpPrngGen = 5'h02;
  localparam logic [4:0] OpAccGen = 5'h03;
  localparam logic [4:0] OpPassthrough = 5'h08;
  localparam logic [4:0] OpNot = 5'h09;
  localparam logic [4:0] OpAdd = 5'h0A;
  localparam logic [4:0] OpSub = 5'h0B;
  localparam logic [4:0] OpMul = 5'h0C;
  localparam logic [4:0] OpAxpy = 5'h0D;
  localparam logic [4:0] OpLoadAcc = 5'h0E;
  localparam logic [4:0] OpAnd = 5'h0F;
  localparam logic [4:0] OpSumReduce = 5'h10;
  localparam logic [4:0] OpMaxReduce = 5'h11;
  localparam logic [4:0] OpMinReduce = 5'h12;
  localparam logic [4:0] OpOr = 5'h13;
  localparam logic [4:0] OpXor = 5'h14;

  // ── OTF Opcode Decode ──────────────────────────────────────────────
  localparam logic [7:0] OpcodeMxMask = 8'h20;
  localparam logic [7:0] OpcodeFpcastMask = 8'h40;

  // FpCast opcodes
  localparam logic [7:0] OpcodeFp32ToI8 = 8'h40;
  localparam logic [7:0] OpcodeFp32ToI16 = 8'h42;
  localparam logic [7:0] OpcodeFp32ToBf16 = 8'h44;
  localparam logic [7:0] OpcodeBf16ToI8 = 8'h46;
  localparam logic [7:0] OpcodeBf16ToI16 = 8'h48;
  localparam logic [7:0] OpcodeBf16ToFp32 = 8'h4A;

  // ── Decode signed scale (two's complement) ─────────────────────────
  function automatic int decode_signed_scale(input logic [7:0] scale);
    if (scale < 128) return int'(scale);
    else return int'(scale) - 256;
  endfunction

  // ── Compute block scale with bias ──────────────────────────────────
  function automatic logic [7:0] compute_block_scale_with_bias(
      input logic [31:0] fp32_bits[MxBlockSize], input int bias);
    logic [7:0] max_exp;
    logic [7:0] elem_exp;
    max_exp = 8'd0;
    for (int i = 0; i < MxBlockSize; i++) begin
      elem_exp = fp32_bits[i][30:23];
      if (elem_exp > max_exp) max_exp = elem_exp;
    end
    return 8'((int'(max_exp) - Fp32Bias - bias));
  endfunction

  // ── FP32 → MXFP8 (E5M2) quantization ──────────────────────────────
  // Wrapper that decodes scale internally (for single-call use).
  function automatic logic [7:0] fp32_to_mxfp8_byte(input logic [31:0] fp32_bits,
                                                    input logic [7:0] scale);
    return fp32_to_mxfp8_byte_prescaled(fp32_bits, decode_signed_scale(scale));
  endfunction

  // Pre-scaled variant: call decode_signed_scale once, reuse for all 32 elements.
  // Optimized: pre-classify exp once, merge sub/normal rounding paths.
  function automatic logic [7:0] fp32_to_mxfp8_byte_prescaled(input logic [31:0] fp32_bits,
                                                              input int decoded_scale);
    logic        sign;
    logic [ 7:0] expf;
    logic [22:0] manf;
    int unbiased, scaled_exp;
    logic [23:0] full_mant;
    logic [ 4:0] mexp;
    logic [ 1:0] mmant;

    // Pre-classify (computed once)
    logic exp_is_zero, exp_is_max, mant_is_zero;

    // Unified rounding temporaries
    logic [23:0] round_mant;
    logic [ 3:0] rounded;
    logic guard, sticky, roundup;
    int   out_exp;
    logic carry;

    sign         = fp32_bits[31];
    expf         = fp32_bits[30:23];
    manf         = fp32_bits[22:0];

    exp_is_zero  = (expf == 8'd0);
    exp_is_max   = (expf == 8'hFF);
    mant_is_zero = (manf == 23'd0);

    // Special cases
    if (exp_is_zero && mant_is_zero) begin
      return {sign, 5'd0, 2'd0};  // zero
    end else if (exp_is_max && !mant_is_zero) begin
      return {sign, 5'h1F, 2'd1};  // NaN
    end else if (exp_is_max) begin
      return {sign, 5'h1E, 2'd3};  // Inf (mant_is_zero implied)
    end

    unbiased   = int'(expf) - Fp32Bias;
    scaled_exp = unbiased - decoded_scale;
    full_mant  = {1'b1, manf};

    // Overflow / underflow (no rounding needed)
    if (scaled_exp > E5m2ExpMax) return {sign, 5'h1E, 2'd3};
    if (scaled_exp < E5m2ExpMin) return {sign, 5'd0, 2'd0};

    // Unified rounding: subnormal shifts mantissa >> 1, normal uses it directly.
    // Single sticky OR-reduction shared between both paths.
    round_mant = (scaled_exp == E5m2ExpMin) ? (full_mant >> 1) : full_mant;
    rounded    = {1'b0, round_mant[23:21]};
    guard      = round_mant[20];
    sticky     = (round_mant[19:0] != 20'd0);
    roundup    = guard && (rounded[0] || sticky);
    if (roundup) rounded = rounded + 4'd1;
    carry = rounded[3];

    if (scaled_exp == E5m2ExpMin) begin
      // Subnormal result
      mexp  = 5'd0;
      mmant = rounded[1:0];
    end else begin
      // Normal result
      out_exp = scaled_exp + E5m2Bias + int'(carry);
      mmant   = rounded[1:0];
      if (out_exp > 30) begin
        mexp  = 5'd30;
        mmant = 2'd3;
      end else begin
        mexp = out_exp[4:0];
      end
    end

    return {sign, mexp, mmant};
  endfunction

  // ── MXFP8 (E5M2) → FP32 dequantization ────────────────────────────
  // Wrapper that decodes scale internally (for single-call use).
  function automatic logic [31:0] mxfp8_byte_to_fp32(input logic [7:0] byte_val,
                                                     input logic [7:0] scale);
    return mxfp8_byte_to_fp32_prescaled(byte_val, decode_signed_scale(scale));
  endfunction

  // Pre-scaled variant: call decode_signed_scale once, reuse for all 32 elements.
  // Optimized: pre-classify exp_e5 once, merge sub/norm fp32_exp range checks,
  // replace subnormal case with arithmetic.
  function automatic logic [31:0] mxfp8_byte_to_fp32_prescaled(input logic [7:0] byte_val,
                                                               input int scaled);
    logic        sign;
    logic [ 4:0] exp_e5;
    logic [ 1:0] mant;
    logic [31:0] sign_bit;
    int          fp32_exp;
    logic [22:0] out_mant;

    // Pre-classify (computed once, reused in all branches)
    logic exp_is_zero, exp_is_max;

    sign        = byte_val[7];
    exp_e5      = byte_val[6:2];
    mant        = byte_val[1:0];
    sign_bit    = {sign, 31'd0};

    exp_is_zero = (exp_e5 == 5'd0);
    exp_is_max  = (exp_e5 == 5'h1F);

    // Special cases: zero, inf, nan
    if (exp_is_zero && mant == 2'd0) return sign_bit;
    if (exp_is_max && mant == 2'd0) return sign_bit | 32'h7F800000;
    if (exp_is_max) return 32'h7FC00000;  // mant != 0 implied (zero case returned above)

    // Compute fp32_exp and mantissa for both sub and normal paths
    if (exp_is_zero) begin
      // Subnormal: exp = -16 when mant==1, else -15. Mantissa MSB set when mant==3.
      fp32_exp = (-16 + int'(mant > 2'd1) + scaled) + Fp32Bias;
      out_mant = {mant[1] & mant[0], 22'd0};
    end else begin
      // Normal
      fp32_exp = int'(exp_e5) - E5m2Bias + scaled + Fp32Bias;
      out_mant = {mant, 21'd0};
    end

    // Single range check (shared between sub and normal)
    if (fp32_exp <= 0) return sign_bit;
    else if (fp32_exp >= 255) return sign_bit | {1'b0, 8'hFE, 23'h7FFFFF};
    else return sign_bit | (32'(fp32_exp[7:0]) << 23) | 32'(out_mant);
  endfunction

  // ── FP32 → INT8 with round-to-nearest-even and saturation ─────────
  function automatic logic [7:0] fp32_to_int8_rne_sat(input logic [31:0] fp32_bits);
    logic        sign;
    logic [ 7:0] exp_biased;
    logic [22:0] mantissa;
    logic is_nan, is_inf;
    int          unbiased_exp;
    logic [23:0] full_mant;
    int          shift_right;
    logic [31:0] shifted;
    logic guard, sticky_bit, round_up;
    logic [8:0] magnitude;

    sign       = fp32_bits[31];
    exp_biased = fp32_bits[30:23];
    mantissa   = fp32_bits[22:0];
    is_nan     = (exp_biased == 8'hFF) && (mantissa != 23'd0);
    is_inf     = (exp_biased == 8'hFF) && (mantissa == 23'd0);

    if (is_nan) return 8'd0;
    if (is_inf) return sign ? 8'h80 : 8'h7F;
    if (exp_biased == 8'd0) return 8'd0;

    unbiased_exp = int'(exp_biased) - Fp32Bias;
    full_mant    = {1'b1, mantissa};

    if (unbiased_exp < -1) return 8'd0;
    if (unbiased_exp >= 8) return sign ? 8'h80 : 8'h7F;

    // unbiased_exp in [-1, 7] → shift_right in [16, 24], always positive.
    // Use case mux instead of barrel shifter — shift amount has only 9 values.
    shift_right = 23 - unbiased_exp;
    shifted     = '0;
    sticky_bit  = 1'b0;
    unique case (shift_right)
      16: begin
        shifted    = {8'd0, full_mant} >> 15;
        sticky_bit = |(full_mant[14:0]);
      end
      17: begin
        shifted    = {8'd0, full_mant} >> 16;
        sticky_bit = |(full_mant[15:0]);
      end
      18: begin
        shifted    = {8'd0, full_mant} >> 17;
        sticky_bit = |(full_mant[16:0]);
      end
      19: begin
        shifted    = {8'd0, full_mant} >> 18;
        sticky_bit = |(full_mant[17:0]);
      end
      20: begin
        shifted    = {8'd0, full_mant} >> 19;
        sticky_bit = |(full_mant[18:0]);
      end
      21: begin
        shifted    = {8'd0, full_mant} >> 20;
        sticky_bit = |(full_mant[19:0]);
      end
      22: begin
        shifted    = {8'd0, full_mant} >> 21;
        sticky_bit = |(full_mant[20:0]);
      end
      23: begin
        shifted    = {8'd0, full_mant} >> 22;
        sticky_bit = |(full_mant[21:0]);
      end
      24: begin
        shifted    = {8'd0, full_mant} >> 23;
        sticky_bit = |(full_mant[22:0]);
      end
      default: ;
    endcase
    guard     = shifted[0];
    magnitude = {1'b0, shifted[8:1]};
    round_up  = guard && (sticky_bit || magnitude[0]);
    if (round_up) magnitude = magnitude + 9'd1;

    if (sign) begin
      if (magnitude > 9'd128) return 8'h80;
      else return -$signed(magnitude[7:0]);
    end else begin
      if (magnitude > 9'd127) return 8'h7F;
      else return magnitude[7:0];
    end
  endfunction

  // ── FP32 → INT16 with round-to-nearest-even and saturation ────────
  function automatic logic [15:0] fp32_to_int16_rne_sat(input logic [31:0] fp32_bits);
    logic        sign;
    logic [ 7:0] exp_biased;
    logic [22:0] mantissa;
    logic is_nan, is_inf;
    int          unbiased_exp;
    logic [23:0] full_mant;
    int          shift_right;
    logic [31:0] shifted;
    logic guard, sticky_bit, round_up;
    logic [16:0] magnitude;

    sign       = fp32_bits[31];
    exp_biased = fp32_bits[30:23];
    mantissa   = fp32_bits[22:0];
    is_nan     = (exp_biased == 8'hFF) && (mantissa != 23'd0);
    is_inf     = (exp_biased == 8'hFF) && (mantissa == 23'd0);

    if (is_nan) return 16'd0;
    if (is_inf) return sign ? 16'h8000 : 16'h7FFF;
    if (exp_biased == 8'd0) return 16'd0;

    unbiased_exp = int'(exp_biased) - Fp32Bias;
    full_mant    = {1'b1, mantissa};

    if (unbiased_exp < -1) return 16'd0;
    if (unbiased_exp >= 16) return sign ? 16'h8000 : 16'h7FFF;

    // unbiased_exp in [-1, 15] → shift_right in [8, 24], always positive.
    // Use case mux instead of barrel shifter — shift amount has only 17 values.
    shift_right = 23 - unbiased_exp;
    shifted     = '0;
    sticky_bit  = 1'b0;
    unique case (shift_right)
      8: begin
        shifted    = {8'd0, full_mant} >> 7;
        sticky_bit = |(full_mant[6:0]);
      end
      9: begin
        shifted    = {8'd0, full_mant} >> 8;
        sticky_bit = |(full_mant[7:0]);
      end
      10: begin
        shifted    = {8'd0, full_mant} >> 9;
        sticky_bit = |(full_mant[8:0]);
      end
      11: begin
        shifted    = {8'd0, full_mant} >> 10;
        sticky_bit = |(full_mant[9:0]);
      end
      12: begin
        shifted    = {8'd0, full_mant} >> 11;
        sticky_bit = |(full_mant[10:0]);
      end
      13: begin
        shifted    = {8'd0, full_mant} >> 12;
        sticky_bit = |(full_mant[11:0]);
      end
      14: begin
        shifted    = {8'd0, full_mant} >> 13;
        sticky_bit = |(full_mant[12:0]);
      end
      15: begin
        shifted    = {8'd0, full_mant} >> 14;
        sticky_bit = |(full_mant[13:0]);
      end
      16: begin
        shifted    = {8'd0, full_mant} >> 15;
        sticky_bit = |(full_mant[14:0]);
      end
      17: begin
        shifted    = {8'd0, full_mant} >> 16;
        sticky_bit = |(full_mant[15:0]);
      end
      18: begin
        shifted    = {8'd0, full_mant} >> 17;
        sticky_bit = |(full_mant[16:0]);
      end
      19: begin
        shifted    = {8'd0, full_mant} >> 18;
        sticky_bit = |(full_mant[17:0]);
      end
      20: begin
        shifted    = {8'd0, full_mant} >> 19;
        sticky_bit = |(full_mant[18:0]);
      end
      21: begin
        shifted    = {8'd0, full_mant} >> 20;
        sticky_bit = |(full_mant[19:0]);
      end
      22: begin
        shifted    = {8'd0, full_mant} >> 21;
        sticky_bit = |(full_mant[20:0]);
      end
      23: begin
        shifted    = {8'd0, full_mant} >> 22;
        sticky_bit = |(full_mant[21:0]);
      end
      24: begin
        shifted    = {8'd0, full_mant} >> 23;
        sticky_bit = |(full_mant[22:0]);
      end
      default: ;
    endcase
    guard     = shifted[0];
    magnitude = {1'b0, shifted[16:1]};
    round_up  = guard && (sticky_bit || magnitude[0]);
    if (round_up) magnitude = magnitude + 17'd1;

    if (sign) begin
      if (magnitude > 17'd32768) return 16'h8000;
      else return -$signed(magnitude[15:0]);
    end else begin
      if (magnitude > 17'd32767) return 16'h7FFF;
      else return magnitude[15:0];
    end
  endfunction

  // ── FP32 → BF16 with round-to-nearest-even ────────────────────────
  function automatic logic [15:0] f32_to_bf16_bits_rne(input logic [31:0] fp32_bits);
    logic [ 7:0] exp_biased;
    logic [22:0] mantissa;
    logic        is_nan;
    logic        lsb;
    logic [31:0] rounding_bias;
    logic [31:0] rounded;

    exp_biased = fp32_bits[30:23];
    mantissa   = fp32_bits[22:0];
    is_nan     = (exp_biased == 8'hFF) && (mantissa != 23'd0);

    if (is_nan) begin
      return {fp32_bits[31], 8'hFF, 1'b1, 6'd0};
    end

    lsb           = fp32_bits[16];
    rounding_bias = {16'd0, 15'h7FFF} + {31'd0, lsb};
    rounded       = fp32_bits + rounding_bias;
    return rounded[31:16];
  endfunction

  // ── BF16 → FP32 with NaN canonicalization ──────────────────────────
  function automatic logic [31:0] bf16_bits_to_fp32(input logic [15:0] bf16_bits);
    logic [31:0] fp32_bits;
    logic [ 7:0] exp_bf16;
    logic [ 6:0] mant_bf16;

    fp32_bits = {bf16_bits, 16'd0};
    exp_bf16  = bf16_bits[14:7];
    mant_bf16 = bf16_bits[6:0];

    if (exp_bf16 == 8'hFF && mant_bf16 != 7'd0) return fp32_bits | 32'h00400000;
    else return fp32_bits;
  endfunction

  // ── FP Cast element conversion dispatch ────────────────────────────
  function automatic void fpcast_convert_element(
      input logic [7:0] opcode, input logic [31:0] input_word, output logic [31:0] output_word);
    case (opcode)
      OpcodeFp32ToI8: output_word = {24'd0, fp32_to_int8_rne_sat(input_word)};
      OpcodeFp32ToI16: output_word = {16'd0, fp32_to_int16_rne_sat(input_word)};
      OpcodeFp32ToBf16: output_word = {16'd0, f32_to_bf16_bits_rne(input_word)};
      OpcodeBf16ToI8:
      output_word = {24'd0, fp32_to_int8_rne_sat(bf16_bits_to_fp32(input_word[15:0]))};
      OpcodeBf16ToI16:
      output_word = {16'd0, fp32_to_int16_rne_sat(bf16_bits_to_fp32(input_word[15:0]))};
      OpcodeBf16ToFp32: output_word = bf16_bits_to_fp32(input_word[15:0]);
      default: output_word = input_word;
    endcase
  endfunction

  // ── FpCast element size helpers ────────────────────────────────────
  function automatic int unsigned fpcast_in_elem_bytes(input logic [7:0] opcode);
    case (opcode)
      OpcodeFp32ToI8, OpcodeFp32ToI16, OpcodeFp32ToBf16: return 4;
      OpcodeBf16ToI8, OpcodeBf16ToI16, OpcodeBf16ToFp32: return 2;
      default:                                           return 4;
    endcase
  endfunction

  function automatic int unsigned fpcast_out_elem_bytes(input logic [7:0] opcode);
    case (opcode)
      OpcodeFp32ToI8, OpcodeBf16ToI8:                     return 1;
      OpcodeFp32ToI16, OpcodeBf16ToI16, OpcodeFp32ToBf16: return 2;
      OpcodeBf16ToFp32:                                   return 4;
      default:                                            return 4;
    endcase
  endfunction

endpackage : vidma_alcu_pkg
