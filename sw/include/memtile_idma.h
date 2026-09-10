// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// Mem-tile iDMA helpers. Mirrors the helper set of cheshire/sw/include/dif/dma.h,
// but rebased onto Gwaihir's mem-tile DMA region exposed by gw_addrmap_64b.h. A single
// set of inline helpers serves every tile; the target tile's iDMA is selected at
// run time via the SAM index passed as the first argument.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include "regs/idma.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"
#include "idma_compute.h"

// Mem-tile iDMA helpers. The leading `tile` argument is the SAM index of the
// target mem tile; it selects which tile's iDMA register is configured.
// `GW_L2_SPM_DMA_BASE_ADDR(tile)` is the base address of that tile's iDMA registers.
//
//   - memtile_dma_2d_memcpy(...)      — non-blocking 2D issue; returns tf_id
//   - memtile_dma_2d_blk_memcpy(...)  — blocking 2D wrapper (polls done_id)
//   - memtile_dma_blk_memcpy(...)     — blocking 1D wrapper (reps=1, ENABLE_ND clear)
static inline uint64_t memtile_dma_2d_memcpy(uint32_t tile, uint64_t dst,
                                             uint64_t src, uint64_t size,
                                             uint64_t dst_stride,
                                             uint64_t src_stride,
                                             uint64_t num_reps, uint64_t conf) {
    // Base address of this tile's iDMA registers.
    uintptr_t base = (uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(tile);

    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, src_addr)) = src;
    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, dst_addr)) = dst;
    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, length))   = size;
    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, conf))     = conf;
    if (conf & IDMA_REG64_2D__CONF__ENABLE_ND_bm) {
        uintptr_t dim = base + offsetof(idma_reg64_2d_t, dim);
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, src_stride)) =
            src_stride;
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, dst_stride)) =
            dst_stride;
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, reps)) =
            num_reps;
    }
    // Reading next_id both issues the transfer and returns its id.
    return *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, next_id));
}

static inline void memtile_dma_2d_blk_memcpy(uint32_t tile, uint64_t dst,
                                             uint64_t src, uint64_t size,
                                             uint64_t dst_stride,
                                             uint64_t src_stride,
                                             uint64_t num_reps, uint64_t conf) {
    // Base address of this tile's iDMA registers.
    uintptr_t base = (uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(tile);

    uint64_t tf_id = memtile_dma_2d_memcpy(tile, dst, src, size, dst_stride,
                                           src_stride, num_reps, conf);
    while (*(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, done_id)) !=
           tf_id) {
        asm volatile("nop");
    }
}

static inline void memtile_dma_blk_memcpy(uint32_t tile, uint64_t dst,
                                          uint64_t src, uint64_t size,
                                          uint64_t conf) {
    memtile_dma_2d_blk_memcpy(tile, dst, src, size, 0, 0, 1,
                              conf & ~IDMA_REG64_2D__CONF__ENABLE_ND_bm);
}

// The reg file (SystemRDL-generated, same source as the RTL reg block) must fit
// the l2_spm_dma window carved in the Gwaihir address map.
_Static_assert(sizeof(idma_reg64_2d_t) <= GW_L2_SPM_0_DMA_SIZE,
               "iDMA reg file exceeds the Gwaihir l2_spm_dma window");

// Program the tile's compute_cfg register (sticky; sampled when next_id is read
// to launch a transfer, so set it before issuing).
static inline void memtile_dma_set_compute(uint32_t tile, uint32_t op) {
    uintptr_t base = (uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(tile);
    idma_reg64_2d__compute_cfg_t c = { .w = 0 };
    c.f.compute_enable = (op != (uint32_t)COMPUTE_OP__NONE);
    c.f.compute_op     = op;
    *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, compute_cfg)) = c.w;
}

static inline void memtile_dma_passthrough(uint32_t tile) {
    memtile_dma_set_compute(tile, COMPUTE_OP__NONE);
}
