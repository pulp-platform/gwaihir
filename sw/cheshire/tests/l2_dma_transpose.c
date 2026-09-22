// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-device check of the mem-tile iDMA transpose path (COMPUTE_OP__TRANSPOSE),
// driven by CVA6 over the NoC (reg64 frontend).
//
// Geometry, derived from idma_legalizer's ComputeTransposeShape and
// idma_otf_transpose.sv:
//  - The element size is 1 << mode bytes and the engine works on NE x NE
//    element tiles, NE = StrbWidth / element bytes.
//  - ComputeTransposeShape accepts one whole padded tile in a single burst
//    (length == NE * StrbWidth) to a beat-aligned destination, with
//    tensor_m and tensor_n <= NE. The register frontend has no transpose
//    midend, so that whole-tile shape is the only one available here.
//  - The engine reads the full tile and masks the padding with its output
//    strobe, so no byte outside the TP_N x TP_M result may be written.
//
// Source and result: NE rows of NE elements, row pitch NE elements.
//   out[c][r] == in[r][c] for r < TP_M, c < TP_N; every other element must
//   still hold the poison value.
//
// Return encoding: 0 on pass, else
//   mode*1000000 + 1000 + (c*NE + r)  => wrong element at out[c][r]
//   mode*1000000 + 2000               => result equals a plain copy (the op
//                                        never latched)

#include <stddef.h>
#include <stdint.h>

#include "memtile_idma.h"

// ---- Topology --------------------------------------------------------------
#define SRC_TILE     3
#define DST_TILE     1
#define DRIVER_TILE  1

// The mem-tile DMA is 512b wide (see gwaihir_pkg AxiCfgW), so one beat is 64 B.
#define BEAT_BYTES   64u

// Deliberately not square: a frontend that swapped tensor_m and tensor_n would
// mask an 8x4 result instead of a 4x8 one and fail the poison check.
#define TP_M 4u
#define TP_N 8u

#define POISON32 0xA5A5A5A5u
#define POISON16 0xA5A5u

// Transpose one TP_M x TP_N tile of 32b elements (mode 2).
static int run_transpose_u32(void) {
    const uint32_t ne = BEAT_BYTES / sizeof(uint32_t);   // 16
    const uint32_t elems = ne * ne;

    volatile uint32_t *src = (volatile uint32_t *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile uint32_t *dst = (volatile uint32_t *)GW_L2_SPM_BASE_ADDR(DST_TILE);

    // in[r][c] = r * 100 + c: every element is recoverable from its position,
    // and the transpose of this matrix is nowhere equal to the matrix itself.
    for (uint32_t i = 0; i < elems; i++) src[i] = POISON32;
    for (uint32_t r = 0; r < ne; r++)
        for (uint32_t c = 0; c < TP_N; c++) src[r * ne + c] = r * 100u + c;
    for (uint32_t i = 0; i < elems; i++) dst[i] = POISON32;

    memtile_dma_set_transpose(DRIVER_TILE, /*mode=*/2, TP_M, TP_N);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)dst,
                           (uint64_t)(uintptr_t)src, (uint64_t)ne * BEAT_BYTES);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t differ = 0;
    for (uint32_t c = 0; c < ne; c++) {
        for (uint32_t r = 0; r < ne; r++) {
            uint32_t got = dst[c * ne + r];
            uint32_t exp = (c < TP_N && r < TP_M) ? src[r * ne + c] : POISON32;
            if (got != exp) return (int)(2000000u + 1000u + c * ne + r);
            // A plain copy would leave src[c * ne + r], i.e. c * 100 + r.
            if (c < TP_N && r < TP_M && got != src[c * ne + r]) differ++;
        }
    }
    // r * 100 + c differs from c * 100 + r everywhere but the diagonal.
    if (differ != TP_M * TP_N - TP_M) return (int)(2000000u + 2000u);
    return 0;
}

// Same tile through the 16b element mode (mode 1), which doubles NE.
static int run_transpose_u16(void) {
    const uint32_t ne = BEAT_BYTES / sizeof(uint16_t);   // 32
    const uint32_t elems = ne * ne;

    volatile uint16_t *src = (volatile uint16_t *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile uint16_t *dst = (volatile uint16_t *)GW_L2_SPM_BASE_ADDR(DST_TILE);

    for (uint32_t i = 0; i < elems; i++) src[i] = POISON16;
    for (uint32_t r = 0; r < ne; r++)
        for (uint32_t c = 0; c < TP_N; c++)
            src[r * ne + c] = (uint16_t)(r * 100u + c);
    for (uint32_t i = 0; i < elems; i++) dst[i] = POISON16;

    memtile_dma_set_transpose(DRIVER_TILE, /*mode=*/1, TP_M, TP_N);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)dst,
                           (uint64_t)(uintptr_t)src, (uint64_t)ne * BEAT_BYTES);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t differ = 0;
    for (uint32_t c = 0; c < ne; c++) {
        for (uint32_t r = 0; r < ne; r++) {
            uint16_t got = dst[c * ne + r];
            uint16_t exp = (c < TP_N && r < TP_M) ? src[r * ne + c] : POISON16;
            if (got != exp) return (int)(1000000u + 1000u + c * ne + r);
            if (c < TP_N && r < TP_M && got != src[c * ne + r]) differ++;
        }
    }
    if (differ != TP_M * TP_N - TP_M) return (int)(1000000u + 2000u);
    return 0;
}

int main(void) {
    int rc = run_transpose_u32();
    if (rc) return rc;
    return run_transpose_u16();
}
