// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// MX quant then dequant through a mem-tile iDMA, driven by CVA6 over the NoC:
// FP16 S -> MXFP8 data plane M + E8M0 scale plane SC -> FP32 D, both 2D with a
// scale stride. Both stages are checked against the iDMA goldens, so a failure
// localizes to quant or dequant. Returns 0 on a byte-exact pass, else
// 1000000 + block (SC scale), 2000000 + element (M data), 3000000 + element
// (D word) or 4000000 + byte (SC byte past a row's group).

#include <stddef.h>
#include <stdint.h>

#include "memtile_idma.h"   // gw_addrmap_64b.h, gw_memtile.h, iDMA reg headers
#include "idma_mx_golden.h" // shipped by iDMA, see CHS_SW_INCLUDES in sw/sw.mk

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3   // FP16 source S (offset 0) and FP32 result D (D_OFF)
#define MID_TILE     1   // MXFP8 data plane M (offset 0) and scale plane SC (SC_OFF)
#define DRIVER_TILE  1   // whose iDMA drives both transfers
#define D_OFF        0x10000u  // D lives well past S inside SRC_TILE's L2 SPM
#define SC_OFF       0x1000u   // SC past M, on a 64 B scale line

// ---- Geometry --------------------------------------------------------------
// 2 rows of one g32 scale group each; each row's 32 scale bytes start on their
// own 64 B line. mx_stim_fp16 puts the corner bands in the last 6 blocks, the
// last one with Inf/NaN, so it is poisoned.
enum { kBlockSize = 32, kRows = 2, kRowBlocks = 32 };
enum { kTotalBlocks = kRows * kRowBlocks };
enum { kDataBlockBytes = 32, kScaleLine = 64 };

int main(void) {
    volatile uint16_t *S = (volatile uint16_t *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile uint8_t  *M = (volatile uint8_t  *)GW_L2_SPM_BASE_ADDR(MID_TILE);
    volatile uint8_t  *SC =
        (volatile uint8_t *)(GW_L2_SPM_BASE_ADDR(MID_TILE) + SC_OFF);
    volatile uint32_t *D =
        (volatile uint32_t *)(GW_L2_SPM_BASE_ADDR(SRC_TILE) + D_OFF);

    const uint32_t s_elems   = (uint32_t)kTotalBlocks * kBlockSize;
    const uint32_t s_row     = (uint32_t)kRowBlocks * kBlockSize * sizeof(uint16_t);
    const uint32_t m_row     = (uint32_t)kRowBlocks * kDataBlockBytes;
    const uint32_t d_row     = (uint32_t)kRowBlocks * kBlockSize * sizeof(uint32_t);
    const uint32_t m_bytes   = (uint32_t)kRows * m_row;
    const uint32_t sc_bytes  = (uint32_t)kRows * kScaleLine;

    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b)
        for (size_t lane = 0; lane < (size_t)kBlockSize; ++lane)
            S[b * kBlockSize + lane] =
                mx_stim_fp16((uint32_t)(b * kBlockSize + lane), s_elems, 0);

    // Poison M, SC and D so a no-op transform cannot masquerade as a pass
    for (uint32_t i = 0; i < m_bytes / 8u; ++i)
        ((volatile uint64_t *)M)[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = 0; i < sc_bytes / 8u; ++i)
        ((volatile uint64_t *)SC)[i] = 0xA5A5A5A5A5A5A5A5ull;
    for (uint32_t i = 0; i < s_elems; ++i) D[i] = 0xDEADBEEFu;

    // LENGTH is the read row length of each stage; the compute and MX config are sticky
    idma_reg64_2d__mx_cfg_t mx = { .w = 0 };
    mx.f.mx_elem_fmt = MX_ELEM_E5M2;
    mx.f.mx_group    = MX_GROUP__G32;
    memtile_dma_set_mx(DRIVER_TILE, mx.w, (uint64_t)(uintptr_t)SC, kScaleLine);

    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXQUANT_FP16);
    memtile_dma_2d_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)M,
                              (uint64_t)(uintptr_t)S, s_row, m_row, s_row, kRows);
    memtile_dma_set_compute(DRIVER_TILE, COMPUTE_OP__MXDEQUANT);
    memtile_dma_2d_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)D,
                              (uint64_t)(uintptr_t)M, m_row, d_row, m_row, kRows);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t scratch[kBlockSize];
    uint8_t data[kBlockSize];
    for (size_t b = 0; b < (size_t)kTotalBlocks; ++b) {
        for (size_t i = 0; i < (size_t)kBlockSize; ++i)
            scratch[i] = fp16_to_fp32_bits(S[b * kBlockSize + i]);
        uint8_t scale;
        quantize_block_mx(scratch, data, &scale, MX_ELEM_E5M2, 0, 0);

        size_t row = b / kRowBlocks, col = b % kRowBlocks;
        if (SC[row * kScaleLine + col] != scale)
            return (int)(1000000u + (uint32_t)b);

        for (size_t i = 0; i < (size_t)kBlockSize; ++i) {
            if (M[b * kDataBlockBytes + i] != data[i])
                return (int)(2000000u + (uint32_t)(b * kBlockSize + i));
            if (D[b * kBlockSize + i] != dequant_mx_fp32(data[i], scale, MX_ELEM_E5M2))
                return (int)(3000000u + (uint32_t)(b * kBlockSize + i));
        }
    }

    // Quant writes only each row's scale bytes and leaves the rest of the line
    for (size_t r = 0; r < (size_t)kRows; ++r)
        for (size_t k = kRowBlocks; k < (size_t)kScaleLine; ++k)
            if (SC[r * kScaleLine + k] != 0xA5u)
                return (int)(4000000u + (uint32_t)(r * kScaleLine + k));

    return 0;
}
