// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// MX quant then dequant through a mem-tile iDMA, driven by CVA6 over the NoC:
// FP16 S -> MXFP8 M -> FP32 D. Both stages are checked against the iDMA
// goldens, so a failure localizes to quant or dequant. Returns 0 on a
// byte-exact pass, else 1000000 + block (M scale), 2000000 + element (M data)
// or 3000000 + element (D word).

#include <stddef.h>
#include <stdint.h>

#include "memtile_idma.h"   // gw_addrmap_64b.h, gw_memtile.h, iDMA reg headers
#include "idma_mx_golden.h" // shipped by iDMA, see CHS_SW_INCLUDES in sw/sw.mk

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source S (offset 0) and FP32 result D (D_OFF)
#define MID_TILE     1   // MXFP8 intermediate M
#define DRIVER_TILE  1   // whose iDMA drives both transfers
#define D_OFF        0x10000u  // D lives well past S inside SRC_TILE's L2 SPM

// ---- Geometry --------------------------------------------------------------
// 64 blocks: quant out 2112 B and dequant out 8192 B are both beat-aligned, and
// 2112 B satisfies the dequant read-length fence (a multiple of 33*StrbWidth).
// mx_stim_fp16 puts the corner bands in the last 6 blocks.
enum { kBlockSize = 32, kTotalBlocks = 64 };
enum { kMxBlockOutBytes = 33 };   // [1B E8M0 scale][32B E5M2]

int main(void) {
    volatile uint16_t *S = (volatile uint16_t *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile uint8_t  *M = (volatile uint8_t  *)GW_L2_SPM_BASE_ADDR(MID_TILE);
    volatile uint32_t *D =
        (volatile uint32_t *)(GW_L2_SPM_BASE_ADDR(SRC_TILE) + D_OFF);

    const uint32_t s_elems = (uint32_t)kTotalBlocks * kBlockSize;
    const uint32_t s_bytes = s_elems * (uint32_t)sizeof(uint16_t);
    const uint32_t m_bytes = (uint32_t)kTotalBlocks * kMxBlockOutBytes;
    const uint32_t d_words = s_elems;

    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            S[b * kBlockSize + lane] =
                mx_stim_fp16((uint32_t)(b * kBlockSize + lane), s_elems, 0);

    // Poison M and D so a no-op transform cannot masquerade as a pass
    volatile uint64_t *M64 = (volatile uint64_t *)M;
    for (uint32_t i = 0; i < m_bytes / 8u; ++i) M64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (m_bytes / 8u) * 8u; i < m_bytes; ++i) M[i] = 0xA5u;
    for (uint32_t i = 0; i < d_words; ++i) D[i] = 0xDEADBEEFu;

    // LENGTH is the READ byte count for both stages; compute_cfg is sticky
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXQUANT_FP16);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)M,
                           (uint64_t)(uintptr_t)S, s_bytes, 0);
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXDEQUANT);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)D,
                           (uint64_t)(uintptr_t)M, m_bytes, 0);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32_bits(S[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        int scaled = (int)(int8_t)scale;

        volatile uint8_t *mblk = M + b * kMxBlockOutBytes;
        if (mblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);

        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t e5m2 = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (mblk[1 + i] != e5m2)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i));
            uint32_t expect = dequant_e5m2_fp32(e5m2, scaled);
            if (D[b * kBlockSize + i] != expect)
                return (int)(3000000u + (uint32_t)(b * kBlockSize + i));
        }
    }

    return 0;
}
