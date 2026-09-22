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
//
// These helpers own all knowledge of the iDMA register layout: callers pass
// addresses, byte counts and ops, never register offsets or field positions.
// The register definitions come from iDMA's own generated headers.

#pragma once

#include <stdint.h>
#include <stddef.h>
#include "idma_reg64_2d_regs.h"       // idma_reg64_2d_t and its field structs
#include "idma_reg64_2d_raw_regs.h"   // COMPUTE_OP__* encoding
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

// Mem-tile iDMA helpers. The leading `tile` argument is the SAM index of the
// target mem tile; it selects which tile's iDMA register file is configured.
// `GW_L2_SPM_DMA_BASE_ADDR(tile)` is the base address of that tile's iDMA registers.
//
//   - memtile_dma_memcpy(...)         — non-blocking 1D issue; returns tf_id
//   - memtile_dma_blk_memcpy(...)     — blocking 1D wrapper (polls done_id)
//   - memtile_dma_2d_blk_memcpy(...)  — blocking 2D wrapper (ND enabled)
//   - memtile_dma_is_done(...)        — completion test for a returned tf_id
//   - memtile_dma_set_compute(...)    — select an on-the-fly compute op
//   - memtile_dma_set_transpose(...)  — select transpose and its tile geometry
//   - memtile_dma_passthrough(...)    — clear the sticky compute op

static inline uintptr_t memtile_dma_base(uint32_t tile) {
    return (uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(tile);
}

// Program the common descriptor fields and launch. `reps` > 1 enables the ND
// path and programs the strides; otherwise the transfer is a plain 1D copy.
// Reading next_id both issues the transfer and returns its id.
static inline uint32_t memtile_dma_issue(uint32_t tile, uint64_t dst, uint64_t src,
                                         uint64_t size, uint64_t dst_stride,
                                         uint64_t src_stride, uint64_t num_reps) {
    uintptr_t base = memtile_dma_base(tile);
    idma_reg64_2d__conf_t conf = { .w = 0 };
    conf.f.enable_nd = (num_reps > 1);

    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, src_addr)) = src;
    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, dst_addr)) = dst;
    *(volatile uint64_t *)(base + offsetof(idma_reg64_2d_t, length))   = size;
    *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, conf))     = conf.w;
    if (conf.f.enable_nd) {
        uintptr_t dim = base + offsetof(idma_reg64_2d_t, dim);
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, src_stride)) =
            src_stride;
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, dst_stride)) =
            dst_stride;
        *(volatile uint64_t *)(dim + offsetof(idma_reg64_2d__dimx_t, reps)) =
            num_reps;
    }
    return *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, next_id));
}

// Non-blocking 1D issue. Returns the transfer id to poll with memtile_dma_is_done.
static inline uint32_t memtile_dma_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                          uint64_t size) {
    return memtile_dma_issue(tile, dst, src, size, 0, 0, 1);
}

// True once the transfer that returned `tf_id` has retired.
static inline int memtile_dma_is_done(uint32_t tile, uint32_t tf_id) {
    uintptr_t base = memtile_dma_base(tile);
    return *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, done_id)) == tf_id;
}

static inline void memtile_dma_wait(uint32_t tile, uint32_t tf_id) {
    while (!memtile_dma_is_done(tile, tf_id)) {
        asm volatile("nop");
    }
}

static inline void memtile_dma_blk_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                          uint64_t size) {
    memtile_dma_wait(tile, memtile_dma_memcpy(tile, dst, src, size));
}

// Blocking 2D copy: `num_reps` rows of `size` bytes at the given strides.
static inline void memtile_dma_2d_blk_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                             uint64_t size, uint64_t dst_stride,
                                             uint64_t src_stride, uint64_t num_reps) {
    memtile_dma_wait(tile, memtile_dma_issue(tile, dst, src, size, dst_stride,
                                             src_stride, num_reps));
}

// The reg file (SystemRDL-generated, same source as the RTL reg block) must fit
// the l2_spm_dma window carved in the Gwaihir address map.
_Static_assert(sizeof(idma_reg64_2d_t) <= GW_L2_SPM_0_DMA_SIZE,
               "iDMA reg file exceeds the Gwaihir l2_spm_dma window");

// Program the tile's compute_cfg register (sticky; sampled when next_id is read
// to launch a transfer, so set it before issuing).
static inline void memtile_dma_set_compute(uint32_t tile, uint32_t op) {
    uintptr_t base = memtile_dma_base(tile);
    idma_reg64_2d__compute_cfg_t c = { .w = 0 };
    c.f.compute_enable = (op != (uint32_t)COMPUTE_OP__NONE);
    c.f.compute_op     = op;
    *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, compute_cfg)) = c.w;
}

// Select the transpose op together with its geometry: the element size is
// 1 << mode bytes, and the engine transposes an `m` x `n` element sub-tile.
static inline void memtile_dma_set_transpose(uint32_t tile, uint32_t mode,
                                             uint32_t m, uint32_t n) {
    uintptr_t base = memtile_dma_base(tile);
    idma_reg64_2d__compute_cfg_t c = { .w = 0 };
    c.f.compute_enable     = 1;
    c.f.compute_op         = COMPUTE_OP__TRANSPOSE;
    c.f.transpose_mode     = mode;
    c.f.transpose_tensor_m = m;
    c.f.transpose_tensor_n = n;
    *(volatile uint32_t *)(base + offsetof(idma_reg64_2d_t, compute_cfg)) = c.w;
}

static inline void memtile_dma_passthrough(uint32_t tile) {
    memtile_dma_set_compute(tile, COMPUTE_OP__NONE);
}
