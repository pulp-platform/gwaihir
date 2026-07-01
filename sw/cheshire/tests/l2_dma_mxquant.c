// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-device check of the mem-tile viDMA FP16 MX-quant path (OTF opcode 0x22),
// driven by CVA6 over the NoC (reg64 frontend), Gwaihir port of the Snitch
// self-test sw/kernels/misc/dma_mxquant_fp16 from the viDMA repo.
//
//   FP16 (E5M10) source in SRC_TILE's L2 SPM  --viDMA MX-quant-->  MXFP8 (E5M2)
//   in DST_TILE's L2 SPM, one 33B-inline block per 32 elements:
//   [1B E8M0 scale][32B E5M2].
//
// DRIVER_TILE's iDMA does the transfer. The on-the-fly transform is selected by
// writing the 8-bit OTF opcode (0x22 = FP16->MXFP8) to that tile's DMA reg file
// at offset 0x100 (the sticky opcode holding register spliced onto addr[8] in
// mem_tile_dma_wrap); it then rides along with the subsequent transfer. Requires
// the RTL built with gwaihir_pkg::EnableOtfTransform = 1'b1.
//
// CVA6 verifies every output byte against a golden that mirrors the RTL exactly
// (widen FP16->FP32, derive the block scale from the FP32 exponents, run the same
// fp32->e5m2 quantizer). Returns 0 on a byte-exact pass, else a debug code:
//   1000000 + block            => inline SCALE byte mismatch at that block
//   2000000 + block*32 + elem   => E5M2 DATA byte mismatch at that element

#include <stddef.h>
#include <stdint.h>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"   // GW_L2_SPM_NUM
#include "memtile_idma.h"
#include "regs/idma.h"

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source buffer
#define DST_TILE     1   // MXFP8 destination buffer
#define DRIVER_TILE  1   // whose iDMA drives the transfer

// ---- OTF trigger -----------------------------------------------------------
// The OTF opcode holding register lives at addr[8] (byte offset 0x100) of the
// mem-tile DMA reg region; reset value 0x08 == ALU passthrough.
#define OTF_OPCODE_OFFSET      0x100u
#define OPCODE_MX_QUANT_FP16   0x22u   // FP16 (E5M10) -> MXFP8 (E5M2)
#define OPCODE_PASSTHROUGH     0x08u

// ---- Geometry --------------------------------------------------------------
// 16 blocks keeps CVA6's per-element NoC init/verify traffic small (fast sim);
// the corner-case bands live in the LAST 6 blocks (see fp16_pattern), so even a
// small run exercises subnormal / flush / saturation / Inf-NaN. Raise for a more
// exhaustive normal-band sweep (cost is ~linear in CVA6 NoC round-trips).
enum { kBlockSize = 32, kTotalBlocks = 64 };  // 64*33=2112 B dst (64-B beat-aligned)
#define MX_BLOCK_OUT_BYTES 33u   // [1B E8M0 scale][32B E5M2]

// ============================================================================
// Golden model — faithful C port of vidma_alcu_pkg (bit-exact with the RTL).
// ============================================================================

// Exact FP16 (E5M10) -> FP32 widen (lossless; matches fp16_bits_to_fp32).
static float fp16_to_fp32(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) & 0x1u;
    uint32_t exp  = (uint32_t)(h >> 10) & 0x1Fu;
    uint32_t mant = (uint32_t)h & 0x3FFu;
    uint32_t out;
    if (exp == 0) {
        if (mant == 0) {
            out = sign << 31;                 // signed zero
        } else {
            int e = -1;                       // subnormal FP16 -> normalized FP32
            uint32_t m = mant;
            do { m <<= 1; e++; } while ((m & 0x400u) == 0);
            m &= 0x3FFu;
            uint32_t fexp = (uint32_t)(127 - 15 - e);
            out = (sign << 31) | (fexp << 23) | (m << 13);
        }
    } else if (exp == 0x1Fu) {
        out = (sign << 31) | (0xFFu << 23) | (mant << 13);  // Inf / NaN
    } else {
        uint32_t fexp = exp + (127 - 15);
        out = (sign << 31) | (fexp << 23) | (mant << 13);
    }
    union { uint32_t u; float f; } v = { .u = out };
    return v.f;
}

// Block scale = max FP32 exponent in the block, rebiased to E5M2 (two's-comp int8).
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

// FAITHFUL C port of vidma_alcu_pkg::fp32_to_mxfp8_byte_prescaled (E5M2, RNE,
// full subnormal + saturation + Inf/NaN).
static uint8_t quantize_fp32_e5m2(float val, int8_t scale) {
    union { float f; uint32_t u; } v = { .f = val };
    uint32_t sign = v.u >> 31, expf = (v.u >> 23) & 0xFFu, manf = v.u & 0x7FFFFFu;
    if (expf == 0u && manf == 0u) return (uint8_t)(sign << 7);                          // zero
    if (expf == 0xFFu && manf != 0u) return (uint8_t)((sign << 7) | (0x1Fu << 2) | 0x1u); // NaN
    if (expf == 0xFFu) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);             // Inf
    int unbiased   = (int)expf - 127;
    int scaled_exp = unbiased - (int)scale;
    uint32_t full_mant = (1u << 23) | manf;
    const int EMAX = 15, EMIN = -14, EBIAS = 15;
    if (scaled_exp > EMAX) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);         // saturate
    if (scaled_exp >= EMIN) {
        uint32_t rounded = (full_mant >> 21) & 0x7u;     // {implicit, m1, m0}
        uint32_t guard   = (full_mant >> 20) & 0x1u;
        uint32_t sticky  = (full_mant & 0xFFFFFu) != 0u;
        if (guard && ((rounded & 0x1u) || sticky)) rounded += 1u;
        uint32_t carry = (rounded >> 3) & 0x1u;          // mantissa overflow -> exp+1
        int out_exp = scaled_exp + EBIAS + (int)carry;
        uint32_t mmant = rounded & 0x3u, mexp;
        if (out_exp > 30) { mexp = 30u; mmant = 0x3u; }  // top-of-range saturation
        else mexp = (uint32_t)out_exp & 0x1Fu;
        return (uint8_t)((sign << 7) | ((mexp & 0x1Fu) << 2) | (mmant & 0x3u));
    } else {
        if (scaled_exp < (EMIN - 3)) return (uint8_t)(sign << 7);                       // flush
        uint32_t sh   = (uint32_t)(21 + (EMIN - scaled_exp));
        uint32_t kept = (full_mant >> sh) & 0xFu;
        uint32_t sg   = (full_mant >> (sh - 1u)) & 0x1u;
        uint32_t ss   = (full_mant & ((1u << (sh - 1u)) - 1u)) != 0u;
        if (sg && ((kept & 0x1u) || ss)) kept += 1u;
        if (kept == 0u)     return (uint8_t)(sign << 7);                                // flush
        else if (kept < 4u) return (uint8_t)((sign << 7) | (kept & 0x3u));              // subnormal
        else                return (uint8_t)((sign << 7) | (0x1u << 2));                // smallest normal
    }
}

// Deterministic FP16 generator (verbatim from dma_mxquant_fp16): 250 distinct
// NORMAL blocks + blocks 250-255 driving subnormal / flush / saturation / Inf/NaN.
static uint16_t fp16_pattern(size_t blk, size_t lane) {
    // Corner-case blocks are the LAST 6 (relative to kTotalBlocks): [nb-6..nb-4]
    // wide dynamic range (subnormal/flush), [nb-3,nb-2] saturation, [nb-1] Inf/NaN.
    const size_t nb = (size_t)kTotalBlocks;
    if (nb >= 6u && (blk == nb - 6u || blk == nb - 5u || blk == nb - 4u)) {
        if (lane == 0u) return 0x7800u;                                  // 2^15 block max
        static const uint16_t sm[8] = {0x0200u,0x0100u,0x0080u,0x0040u,0x3C00u,0xBC00u,0x0001u,0x0000u};
        return sm[(lane + blk) & 7u];
    }
    if (nb >= 6u && (blk == nb - 3u || blk == nb - 2u)) {
        if (lane == 0u) return (blk == nb - 3u) ? 0x7BFFu : 0xFBFFu;     // +/- max finite
        return (uint16_t)(0x3C00u + (((lane * 7u) + (blk == nb - 2u ? 1u : 0u)) & 0x3FFu));
    }
    if (nb >= 6u && blk == nb - 1u) {
        if (lane == 0u) return 0x7C00u;                                  // +Inf
        if (lane == 1u) return 0xFC00u;                                  // -Inf
        if (lane == 2u) return 0x7E00u;                                  // NaN
        return (uint16_t)(0x0200u + (uint16_t)lane);                     // tiny -> flush
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
    volatile uint16_t *src = (volatile uint16_t *)gwaihir_addrmap.l2_spm[SRC_TILE].mem;
    volatile uint8_t  *dst = (volatile uint8_t  *)gwaihir_addrmap.l2_spm[DST_TILE].mem;
    uintptr_t drv_base = (uintptr_t)&gwaihir_addrmap.l2_spm_dma[DRIVER_TILE].mem[0];

    const uint32_t src_bytes = (uint32_t)kTotalBlocks * kBlockSize * (uint32_t)sizeof(uint16_t); // 16384
    const uint32_t dst_bytes = (uint32_t)kTotalBlocks * MX_BLOCK_OUT_BYTES;                       // 8448

    // 1) Fill the FP16 source in SRC_TILE's L2 SPM.
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            src[b * kBlockSize + lane] = fp16_pattern(b, lane);

    // Poison the destination so a no-op DMA cannot masquerade as a pass.
    // 64-bit stores keep the NoC round-trip count low (dst_bytes is 8-aligned here).
    volatile uint64_t *dst64 = (volatile uint64_t *)dst;
    for (uint32_t i = 0; i < dst_bytes / 8u; ++i) dst64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (dst_bytes / 8u) * 8u; i < dst_bytes; ++i) dst[i] = 0xA5u;

    // 2) Select the FP16 MX-quant transform on the driver tile's viDMA (sticky).
    *(volatile uint32_t *)(drv_base + OTF_OPCODE_OFFSET) = OPCODE_MX_QUANT_FP16;

    // 3) Issue the transfer: read src_bytes of FP16 from SRC_TILE, quantize
    //    on the fly, write the 33B-inline MXFP8 blocks to DST_TILE. The reg64
    //    LENGTH is the READ (input) byte count; the legalizer derives the write
    //    length (src_bytes * 33/64). Blocking (polls done_id).
    memtile_dma_blk_memcpy(
        /*tile=*/ DRIVER_TILE,
        /*dst=*/  (uint64_t)(uintptr_t)dst,
        /*src=*/  (uint64_t)(uintptr_t)src,
        /*size=*/ src_bytes,
        /*conf=*/ 0);

    // 4) Restore passthrough so the sticky opcode does not leak to later users.
    *(volatile uint32_t *)(drv_base + OTF_OPCODE_OFFSET) = OPCODE_PASSTHROUGH;

    // 5) Verify every output byte against the golden.
    float scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32(src[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        volatile uint8_t *oblk = dst + b * MX_BLOCK_OUT_BYTES;
        if (oblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);                  // inline scale mismatch
        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t expect = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (oblk[1 + i] != expect)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i)); // data mismatch
        }
    }

    return 0;
}
