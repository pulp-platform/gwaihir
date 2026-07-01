// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-device MX quant<->dequant ROUND-TRIP through the mem-tile viDMA, driven by
// CVA6 over the NoC (reg64 frontend). Two chained on-the-fly transforms:
//
//   S (FP16, tile SRC)  --viDMA MX-quant   (opcode 0x22)-->  M (MXFP8, tile MID)
//   M (MXFP8, tile MID) --viDMA MX-dequant (opcode 0x21)-->  D (FP32,  tile SRC)
//
//   MXFP8 block layout: 33B-inline  [1B E8M0 scale][32B E5M2].
//
// Each transform is selected by writing its 8-bit OTF opcode to the DRIVER tile's
// DMA reg file at offset 0x100 (the sticky opcode holding register). Requires the
// RTL built with gwaihir_pkg::EnableOtfTransform = 1'b1.
//
// CVA6 verifies BOTH stages against goldens ported bit-for-bit from vidma_alcu_pkg:
//   - M vs quantize_fp32_e5m2 / block_scale_e5m2  (the quant stage)
//   - D vs mxfp8_byte_to_fp32_prescaled           (the dequant stage)
// so a failure localizes to quant vs dequant. Returns 0 on a byte-exact pass, else:
//   1000000 + block            => M inline SCALE byte mismatch (quant)
//   2000000 + block*32 + elem   => M E5M2 DATA byte mismatch    (quant)
//   3000000 + block*32 + elem   => D FP32 word mismatch         (dequant)

#include <stddef.h>
#include <stdint.h>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"   // GW_L2_SPM_NUM
#include "memtile_idma.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source S (offset 0) and FP32 result D (offset D_OFF)
#define MID_TILE     1   // MXFP8 intermediate M
#define DRIVER_TILE  1   // whose iDMA drives both transfers
#define D_OFF        0x10000u  // D lives well past S inside SRC_TILE's L2 SPM

// ---- OTF trigger -----------------------------------------------------------
#define OTF_OPCODE_OFFSET    0x100u
#define OPCODE_MX_QUANT_FP16 0x22u   // FP16 (E5M10) -> MXFP8 (E5M2)
#define OPCODE_MX_DEQUANT    0x21u   // MXFP8 (E5M2) -> FP32
#define OPCODE_PASSTHROUGH   0x08u

// ---- Geometry --------------------------------------------------------------
// 64 blocks: quant out = 64*33 = 2112 B and dequant out = 64*128 = 8192 B are
// both 64-B beat-aligned. Corner bands (subnormal/flush/saturation/Inf-NaN) live
// in the LAST 6 blocks (see fp16_pattern).
enum { kBlockSize = 32, kTotalBlocks = 64 };
#define MX_BLOCK_OUT_BYTES 33u   // [1B E8M0 scale][32B E5M2]

// ============================================================================
// Golden model — faithful C ports of vidma_alcu_pkg (bit-exact with the RTL).
// ============================================================================

static float fp16_to_fp32(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) & 0x1u;
    uint32_t exp  = (uint32_t)(h >> 10) & 0x1Fu;
    uint32_t mant = (uint32_t)h & 0x3FFu;
    uint32_t out;
    if (exp == 0) {
        if (mant == 0) {
            out = sign << 31;
        } else {
            int e = -1;
            uint32_t m = mant;
            do { m <<= 1; e++; } while ((m & 0x400u) == 0);
            m &= 0x3FFu;
            uint32_t fexp = (uint32_t)(127 - 15 - e);
            out = (sign << 31) | (fexp << 23) | (m << 13);
        }
    } else if (exp == 0x1Fu) {
        out = (sign << 31) | (0xFFu << 23) | (mant << 13);
    } else {
        uint32_t fexp = exp + (127 - 15);
        out = (sign << 31) | (fexp << 23) | (mant << 13);
    }
    union { uint32_t u; float f; } v = { .u = out };
    return v.f;
}

static uint8_t block_scale_e5m2(const float *block, size_t len) {
    uint32_t max_exp = 0;
    for (size_t i = 0; i < len; ++i) {
        union { float f; uint32_t u; } v = { .f = block[i] };
        uint32_t exp = (v.u >> 23) & 0xFFu;
        if (exp > max_exp) max_exp = exp;
    }
    int32_t scaled = (int32_t)max_exp - 127 - 15;
    return (uint8_t)(scaled & 0xFF);
}

// vidma_alcu_pkg::fp32_to_mxfp8_byte_prescaled (E5M2, RNE, full subnormal + sat + Inf/NaN).
static uint8_t quantize_fp32_e5m2(float val, int8_t scale) {
    union { float f; uint32_t u; } v = { .f = val };
    uint32_t sign = v.u >> 31, expf = (v.u >> 23) & 0xFFu, manf = v.u & 0x7FFFFFu;
    if (expf == 0u && manf == 0u) return (uint8_t)(sign << 7);
    if (expf == 0xFFu && manf != 0u) return (uint8_t)((sign << 7) | (0x1Fu << 2) | 0x1u);
    if (expf == 0xFFu) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);
    int unbiased   = (int)expf - 127;
    int scaled_exp = unbiased - (int)scale;
    uint32_t full_mant = (1u << 23) | manf;
    const int EMAX = 15, EMIN = -14, EBIAS = 15;
    if (scaled_exp > EMAX) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);
    if (scaled_exp >= EMIN) {
        uint32_t rounded = (full_mant >> 21) & 0x7u;
        uint32_t guard   = (full_mant >> 20) & 0x1u;
        uint32_t sticky  = (full_mant & 0xFFFFFu) != 0u;
        if (guard && ((rounded & 0x1u) || sticky)) rounded += 1u;
        uint32_t carry = (rounded >> 3) & 0x1u;
        int out_exp = scaled_exp + EBIAS + (int)carry;
        uint32_t mmant = rounded & 0x3u, mexp;
        if (out_exp > 30) { mexp = 30u; mmant = 0x3u; }
        else mexp = (uint32_t)out_exp & 0x1Fu;
        return (uint8_t)((sign << 7) | ((mexp & 0x1Fu) << 2) | (mmant & 0x3u));
    } else {
        if (scaled_exp < (EMIN - 3)) return (uint8_t)(sign << 7);
        uint32_t sh   = (uint32_t)(21 + (EMIN - scaled_exp));
        uint32_t kept = (full_mant >> sh) & 0xFu;
        uint32_t sg   = (full_mant >> (sh - 1u)) & 0x1u;
        uint32_t ss   = (full_mant & ((1u << (sh - 1u)) - 1u)) != 0u;
        if (sg && ((kept & 0x1u) || ss)) kept += 1u;
        if (kept == 0u)     return (uint8_t)(sign << 7);
        else if (kept < 4u) return (uint8_t)((sign << 7) | (kept & 0x3u));
        else                return (uint8_t)((sign << 7) | (0x1u << 2));
    }
}

// vidma_alcu_pkg::mxfp8_byte_to_fp32_prescaled. `scaled` is the signed (int8) block
// scale (== decode_signed_scale). Returns the FP32 bit pattern.
static uint32_t mxfp8_to_fp32_bits(uint8_t byte_val, int scaled) {
    const int Fp32Bias = 127, E5m2Bias = 15;
    uint32_t sign   = (uint32_t)(byte_val >> 7) & 0x1u;
    uint32_t exp_e5 = (uint32_t)(byte_val >> 2) & 0x1Fu;
    uint32_t mant   = (uint32_t)byte_val & 0x3u;
    uint32_t sign_bit = sign << 31;
    int exp_is_zero = (exp_e5 == 0u);
    int exp_is_max  = (exp_e5 == 0x1Fu);

    if (exp_is_zero && mant == 0u) return sign_bit;                 // zero
    if (exp_is_max  && mant == 0u) return sign_bit | 0x7F800000u;   // Inf
    if (exp_is_max)                return 0x7FC00000u;              // NaN

    int fp32_exp;
    uint32_t out_mant;
    if (exp_is_zero) {
        // Subnormal: exp = -16 when mant==1, -15 when mant>=2. MSB set iff mant==3.
        fp32_exp = (-16 + (mant > 1u ? 1 : 0) + scaled) + Fp32Bias;
        out_mant = ((mant & 0x2u) && (mant & 0x1u)) ? (1u << 22) : 0u;
    } else {
        fp32_exp = (int)exp_e5 - E5m2Bias + scaled + Fp32Bias;
        out_mant = mant << 21;
    }
    if (fp32_exp <= 0)    return sign_bit;                          // flush
    if (fp32_exp >= 255)  return sign_bit | 0x7F7FFFFFu;            // max finite
    return sign_bit | ((uint32_t)(fp32_exp & 0xFF) << 23) | out_mant;
}

// Deterministic FP16 generator (corner-case blocks are the LAST 6, relative to
// kTotalBlocks, so a small run still exercises subnormal/flush/saturation/Inf/NaN).
static uint16_t fp16_pattern(size_t blk, size_t lane) {
    const size_t nb = (size_t)kTotalBlocks;
    if (nb >= 6u && (blk == nb - 6u || blk == nb - 5u || blk == nb - 4u)) {
        if (lane == 0u) return 0x7800u;
        static const uint16_t sm[8] = {0x0200u,0x0100u,0x0080u,0x0040u,0x3C00u,0xBC00u,0x0001u,0x0000u};
        return sm[(lane + blk) & 7u];
    }
    if (nb >= 6u && (blk == nb - 3u || blk == nb - 2u)) {
        if (lane == 0u) return (blk == nb - 3u) ? 0x7BFFu : 0xFBFFu;
        return (uint16_t)(0x3C00u + (((lane * 7u) + (blk == nb - 2u ? 1u : 0u)) & 0x3FFu));
    }
    if (nb >= 6u && blk == nb - 1u) {
        if (lane == 0u) return 0x7C00u;
        if (lane == 1u) return 0xFC00u;
        if (lane == 2u) return 0x7E00u;
        return (uint16_t)(0x0200u + (uint16_t)lane);
    }
    uint32_t j    = (uint32_t)((lane + blk * 7u) & 0x1Fu);
    uint32_t sign = (j & 1u) << 15;
    uint32_t exp  = 12u + (j % 8u);
    uint32_t man  = ((j * 53u) + (uint32_t)blk * 11u) & 0x3FFu;
    int      off  = (int)(blk % 9u) - 4;
    int      ne   = (int)exp + off;
    if (ne < 1)  ne = 1;
    if (ne > 30) ne = 30;
    return (uint16_t)(sign | ((uint32_t)ne << 10) | man);
}

// ============================================================================

int main(void) {
    volatile uint16_t *S = (volatile uint16_t *)gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint8_t  *M = (volatile uint8_t  *)gwaihir_addrmap.l2_spm[MID_TILE].mem;
    volatile uint32_t *D = (volatile uint32_t *)((uintptr_t)gwaihir_addrmap.l2_spm[SRC_TILE].mem + D_OFF);
    uintptr_t drv = (uintptr_t)&gwaihir_addrmap.l2_spm_dma[DRIVER_TILE].mem[0];

    const uint32_t s_bytes = (uint32_t)kTotalBlocks * kBlockSize * (uint32_t)sizeof(uint16_t); // 4096
    const uint32_t m_bytes = (uint32_t)kTotalBlocks * MX_BLOCK_OUT_BYTES;                       // 2112
    const uint32_t d_words = (uint32_t)kTotalBlocks * kBlockSize;                               // 2048 (8192 B)

    // 1) Fill FP16 source.
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            S[b * kBlockSize + lane] = fp16_pattern(b, lane);

    // Poison M and D so a no-op transform cannot masquerade as a pass (64-bit stores).
    volatile uint64_t *M64 = (volatile uint64_t *)M;
    for (uint32_t i = 0; i < m_bytes / 8u; ++i) M64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (m_bytes / 8u) * 8u; i < m_bytes; ++i) M[i] = 0xA5u;
    for (uint32_t i = 0; i < d_words; ++i) D[i] = 0xDEADBEEFu;

    // 2) Quant: FP16 S -> MXFP8 M (descriptor LENGTH = READ bytes = s_bytes).
    *(volatile uint32_t *)(drv + OTF_OPCODE_OFFSET) = OPCODE_MX_QUANT_FP16;
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)M, (uint64_t)(uintptr_t)S, s_bytes, 0);

    // 3) Dequant: MXFP8 M -> FP32 D (LENGTH = READ bytes = m_bytes).
    *(volatile uint32_t *)(drv + OTF_OPCODE_OFFSET) = OPCODE_MX_DEQUANT;
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)D, (uint64_t)(uintptr_t)M, m_bytes, 0);

    // 4) Restore passthrough.
    *(volatile uint32_t *)(drv + OTF_OPCODE_OFFSET) = OPCODE_PASSTHROUGH;

    // 5) Verify both stages against the goldens.
    float scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32(S[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        int scaled = (int)(int8_t)scale;

        volatile uint8_t *mblk = M + b * MX_BLOCK_OUT_BYTES;
        if (mblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);                        // quant scale

        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t e5m2 = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (mblk[1 + i] != e5m2)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i)); // quant data

            uint32_t expect = mxfp8_to_fp32_bits(e5m2, scaled);
            if (D[b * kBlockSize + i] != expect)
                return (int)(3000000u + (uint32_t)(b * kBlockSize + i)); // dequant
        }
    }

    return 0;
}
