// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// Mem-tile iDMA helpers; `tile` is the SAM index selecting which tile to configure

#pragma once

#include <stdint.h>
#include "regs/idma.h"                // idma_reg64_2d_t and its field structs
#include "idma_reg64_2d_raw_regs.h"   // COMPUTE_OP__* encoding
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

// iDMA register file of `tile`
static inline volatile idma_reg64_2d_t *memtile_dma(uint32_t tile) {
    return (volatile idma_reg64_2d_t *)(uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(tile);
}

// The RDL structs are packed; access whole regs so no member splits into byte loads
static inline void memtile_dma_wr32(volatile void *reg, uint32_t val) {
    *(volatile uint32_t *)reg = val;
}

static inline void memtile_dma_wr64(volatile void *reg, uint64_t val) {
    *(volatile uint64_t *)reg = val;
}

static inline uint32_t memtile_dma_rd32(volatile void *reg) {
    return *(volatile uint32_t *)reg;
}

// Program the descriptor and launch; reading next_id issues it and returns the id
static inline uint32_t memtile_dma_issue(uint32_t tile, uint64_t dst, uint64_t src,
                                         uint64_t size, uint64_t dst_stride,
                                         uint64_t src_stride, uint64_t num_reps,
                                         uint64_t extra_conf) {
    volatile idma_reg64_2d_t *dma = memtile_dma(tile);
    idma_reg64_2d__conf_t conf = { .w = (uint32_t)extra_conf };
    conf.f.enable_nd = (num_reps > 1);

    memtile_dma_wr64(dma->src_addr, src);
    memtile_dma_wr64(dma->dst_addr, dst);
    memtile_dma_wr64(dma->length, size);
    memtile_dma_wr32(&dma->conf, conf.w);
    if (conf.f.enable_nd) {
        memtile_dma_wr64(dma->dim[0].src_stride, src_stride);
        memtile_dma_wr64(dma->dim[0].dst_stride, dst_stride);
        memtile_dma_wr64(dma->dim[0].reps, num_reps);
    }
    return memtile_dma_rd32(dma->next_id);
}

// Non-blocking 1D issue. Returns the transfer id to poll with memtile_dma_is_done.
static inline uint32_t memtile_dma_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                          uint64_t size) {
    return memtile_dma_issue(tile, dst, src, size, 0, 0, 1, 0);
}

// True once the transfer that returned `tf_id` has retired.
static inline int memtile_dma_is_done(uint32_t tile, uint32_t tf_id) {
    return memtile_dma_rd32(memtile_dma(tile)->done_id) == tf_id;
}

static inline void memtile_dma_wait(uint32_t tile, uint32_t tf_id) {
    while (!memtile_dma_is_done(tile, tf_id)) {
        asm volatile("nop");
    }
}

// Blocking 1D copy; `conf` sets extra idma conf bits, 0 for a plain transfer.
static inline void memtile_dma_blk_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                          uint64_t size, uint64_t conf) {
    memtile_dma_wait(tile, memtile_dma_issue(tile, dst, src, size, 0, 0, 1, conf));
}

// Blocking 2D copy: `num_reps` rows of `size` bytes at the given strides.
static inline void memtile_dma_2d_blk_memcpy(uint32_t tile, uint64_t dst, uint64_t src,
                                             uint64_t size, uint64_t dst_stride,
                                             uint64_t src_stride, uint64_t num_reps) {
    memtile_dma_wait(tile, memtile_dma_issue(tile, dst, src, size, dst_stride,
                                             src_stride, num_reps, 0));
}

// The generated reg file must fit the l2_spm_dma window in the address map
_Static_assert(sizeof(idma_reg64_2d_t) <= GW_L2_SPM_0_DMA_SIZE,
               "iDMA reg file exceeds the Gwaihir l2_spm_dma window");

// Sticky; sampled when next_id is read, so set it before issuing
static inline void memtile_dma_set_compute(uint32_t tile, uint32_t op) {
    idma_reg64_2d__compute_cfg_t c = { .w = 0 };
    c.f.compute_enable = (op != (uint32_t)COMPUTE_OP__NONE);
    c.f.compute_op     = op;
    memtile_dma_wr32(&memtile_dma(tile)->compute_cfg, c.w);
}

static inline void memtile_dma_passthrough(uint32_t tile) {
    memtile_dma_set_compute(tile, COMPUTE_OP__NONE);
}
