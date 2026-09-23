// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// FP16 -> MXFP8 quantization through a mem-tile iDMA, driven by CVA6 over the
// NoC. CVA6 checks every output byte against the iDMA golden.
// Returns 0 on a byte-exact pass, else 1000000 + block (scale byte) or
// 2000000 + element (data byte).

#include <stddef.h>
#include <stdint.h>

#include "memtile_idma.h"   // gw_addrmap_64b.h, gw_memtile.h, iDMA reg headers
#include "idma_mx_golden.h" // shipped by iDMA, see CHS_SW_INCLUDES in sw/sw.mk

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source buffer
#define DST_TILE     1   // MXFP8 destination buffer
#define DRIVER_TILE  1   // whose iDMA drives the transfer

// ---- Geometry --------------------------------------------------------------
// mx_stim_fp16 puts the subnormal / flush / saturation / Inf-NaN corners in the
// last 6 blocks, so even a small run hits them. 64*33 = 2112 B is beat-aligned.
enum { kBlockSize = 32, kTotalBlocks = 64 };
enum { kMxBlockOutBytes = 33 };   // [1B E8M0 scale][32B E5M2]

int main(void) {
    volatile uint16_t *src = (volatile uint16_t *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile uint8_t  *dst = (volatile uint8_t  *)GW_L2_SPM_BASE_ADDR(DST_TILE);

    const uint32_t src_elems = (uint32_t)kTotalBlocks * kBlockSize;
    const uint32_t src_bytes = src_elems * (uint32_t)sizeof(uint16_t);
    const uint32_t dst_bytes = (uint32_t)kTotalBlocks * kMxBlockOutBytes;

    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            src[b * kBlockSize + lane] =
                mx_stim_fp16((uint32_t)(b * kBlockSize + lane), src_elems, 0);

    // Poison the destination so a no-op DMA cannot masquerade as a pass.
    // 64-bit stores keep the NoC round-trip count low.
    volatile uint64_t *dst64 = (volatile uint64_t *)dst;
    for (uint32_t i = 0; i < dst_bytes / 8u; ++i) dst64[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = (dst_bytes / 8u) * 8u; i < dst_bytes; ++i) dst[i] = 0xA5u;

    // The reg64 LENGTH is the READ byte count; the legalizer derives the write
    // length (src_bytes * 33/64). compute_cfg is sticky, so restore it after.
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXQUANT_FP16);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)dst,
                           (uint64_t)(uintptr_t)src, src_bytes);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t scratch[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32_bits(src[b * kBlockSize + i]);
        uint8_t scale = block_scale_e5m2(scratch, kBlockSize);
        volatile uint8_t *oblk = dst + b * kMxBlockOutBytes;
        if (oblk[0] != scale)
            return (int)(1000000u + (uint32_t)b);
        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            uint8_t expect = quantize_fp32_e5m2(scratch[i], (int8_t)scale);
            if (oblk[1 + i] != expect)
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i));
        }
    }

    return 0;
}
