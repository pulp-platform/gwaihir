// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// Mem-tile iDMA transpose (COMPUTE_OP__TRANSPOSE), driven by CVA6 over the NoC.
// One transfer carries one padded NE x NE tile, NE = StrbWidth / element bytes;
// idma_legalizer's ComputeTransposeShape holds the contract, and the register
// frontend has no transpose midend, so that whole-tile shape is all there is.
// Returns 0 on a pass, else mode*1000000 + 1000 + (c*NE + r) for a wrong
// element, or mode*1000000 + 2000 if the result is a plain copy.

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

// Element access by width, so one body covers both element-size modes
static inline uint32_t tp_ld(volatile void *p, uint32_t i, uint32_t sz) {
    return sz == 4u ? ((volatile uint32_t *)p)[i] : ((volatile uint16_t *)p)[i];
}

static inline void tp_st(volatile void *p, uint32_t i, uint32_t sz, uint32_t v) {
    if (sz == 4u)
        ((volatile uint32_t *)p)[i] = v;
    else
        ((volatile uint16_t *)p)[i] = (uint16_t)v;
}

// Transpose one TP_M x TP_N tile of sz-byte elements and check every element
static int run_transpose(uint32_t mode, uint32_t sz) {
    const uint32_t ne = BEAT_BYTES / sz;
    const uint32_t elems = ne * ne;
    const uint32_t poison = (sz == 4u) ? 0xA5A5A5A5u : 0xA5A5u;

    volatile void *src = (volatile void *)GW_L2_SPM_BASE_ADDR(SRC_TILE);
    volatile void *dst = (volatile void *)GW_L2_SPM_BASE_ADDR(DST_TILE);

    // Position-coded: in[r][c] = r * 100 + c is nowhere equal to its transpose
    for (uint32_t i = 0; i < elems; i++) tp_st(src, i, sz, poison);
    for (uint32_t r = 0; r < ne; r++)
        for (uint32_t c = 0; c < TP_N; c++)
            tp_st(src, r * ne + c, sz, r * 100u + c);
    for (uint32_t i = 0; i < elems; i++) tp_st(dst, i, sz, poison);

    memtile_dma_set_transpose(DRIVER_TILE, mode, TP_M, TP_N);
    memtile_dma_blk_memcpy(DRIVER_TILE, (uint64_t)(uintptr_t)dst,
                           (uint64_t)(uintptr_t)src, (uint64_t)ne * BEAT_BYTES);
    memtile_dma_passthrough(DRIVER_TILE);

    uint32_t differ = 0;
    for (uint32_t c = 0; c < ne; c++) {
        for (uint32_t r = 0; r < ne; r++) {
            uint32_t got = tp_ld(dst, c * ne + r, sz);
            uint32_t exp =
                (c < TP_N && r < TP_M) ? tp_ld(src, r * ne + c, sz) : poison;
            if (got != exp) return (int)(mode * 1000000u + 1000u + c * ne + r);
            // A plain copy would leave src[c][r], i.e. c * 100 + r
            if (c < TP_N && r < TP_M && got != tp_ld(src, c * ne + r, sz))
                differ++;
        }
    }

    // Catches a DMOPC that never latched: passthrough leaves differ == 0
    if (differ != TP_M * TP_N - TP_M) return (int)(mode * 1000000u + 2000u);
    return 0;
}

int main(void) {
    int rc = run_transpose(/*mode=*/2, /*sz=*/4);
    if (rc) return rc;
    return run_transpose(/*mode=*/1, /*sz=*/2);
}
