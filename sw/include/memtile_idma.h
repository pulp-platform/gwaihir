// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// Mem-tile iDMA helpers. Mirrors the helper set of cheshire/sw/include/dif/dma.h,
// but rebased onto Gwaihir's mem-tile DMA region exposed by gw_addrmap.h. A single
// set of inline helpers serves every tile; the target tile's iDMA is selected at
// run time via the SAM index passed as the first argument.

#pragma once

#include <stdint.h>
#include "regs/idma.h"
#include "gw_addrmap.h"
#include "vidma_reg.h"   // generated: viDMA OTF compute-options register

// Mem-tile iDMA helpers. The leading `tile` argument is the SAM index of the
// target mem tile; it selects which tile's iDMA register is configured.
// `(uintptr_t)&gwaihir_addrmap.l2_spm_dma[tile].mem[0]` is the base address of
// that tile's iDMA registers (the DMA reg file is modeled as a mem{} region in
// the address map, hence the `.mem[0]`).
//
//   - memtile_dma_2d_memcpy(...)      — non-blocking 2D issue; returns tf_id
//   - memtile_dma_2d_blk_memcpy(...)  — blocking 2D wrapper (polls done_id_0)
//   - memtile_dma_blk_memcpy(...)     — blocking 1D wrapper (reps=1, ENABLE_ND clear)
static inline uint64_t memtile_dma_2d_memcpy(uint32_t tile, uint64_t dst,
                                             uint64_t src, uint64_t size,
                                             uint64_t dst_stride,
                                             uint64_t src_stride,
                                             uint64_t num_reps, uint64_t conf) {
    // Base address of this tile's iDMA registers.
    uintptr_t base = (uintptr_t)&gwaihir_addrmap.l2_spm_dma[tile].mem[0];

    *(volatile uint64_t *)(base + IDMA_REG64_2D_SRC_ADDR_LOW_REG_OFFSET) = src;
    *(volatile uint64_t *)(base + IDMA_REG64_2D_DST_ADDR_LOW_REG_OFFSET) = dst;
    *(volatile uint64_t *)(base + IDMA_REG64_2D_LENGTH_LOW_REG_OFFSET)   = size;
    *(volatile uint64_t *)(base + IDMA_REG64_2D_CONF_REG_OFFSET)         = conf;
    if (conf & (1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT)) {
        *(volatile uint64_t *)(base + IDMA_REG64_2D_SRC_STRIDE_2_LOW_REG_OFFSET) =
            src_stride;
        *(volatile uint64_t *)(base + IDMA_REG64_2D_DST_STRIDE_2_LOW_REG_OFFSET) =
            dst_stride;
        *(volatile uint64_t *)(base + IDMA_REG64_2D_REPS_2_LOW_REG_OFFSET) =
            num_reps;
    }
    // Reading NEXT_ID_0 both issues the transfer and returns its id.
    return *(volatile uint64_t *)(base + IDMA_REG64_2D_NEXT_ID_0_REG_OFFSET);
}

static inline void memtile_dma_2d_blk_memcpy(uint32_t tile, uint64_t dst,
                                             uint64_t src, uint64_t size,
                                             uint64_t dst_stride,
                                             uint64_t src_stride,
                                             uint64_t num_reps, uint64_t conf) {
    // Base address of this tile's iDMA registers.
    uintptr_t base = (uintptr_t)&gwaihir_addrmap.l2_spm_dma[tile].mem[0];

    uint64_t tf_id = memtile_dma_2d_memcpy(tile, dst, src, size, dst_stride,
                                           src_stride, num_reps, conf);
    while (*(volatile uint64_t *)(base + IDMA_REG64_2D_DONE_ID_0_REG_OFFSET) !=
           tf_id) {
        asm volatile("nop");
    }
}

static inline void memtile_dma_blk_memcpy(uint32_t tile, uint64_t dst,
                                          uint64_t src, uint64_t size,
                                          uint64_t conf) {
    memtile_dma_2d_blk_memcpy(tile, dst, src, size, 0, 0, 1,
                              conf & ~(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));
}

// viDMA OTF compute ops (compute_op_e; aligned to iDMA idma_pkg::compute_op_e,
// extended with the MX ops). `variant` carries per-op params.
enum {
    VIDMA_COMPUTE_NONE      = 0,
    VIDMA_COMPUTE_TRANSPOSE = 1,
    VIDMA_COMPUTE_MXQUANT   = 2,
    VIDMA_COMPUTE_MXDEQUANT = 3,
    VIDMA_COMPUTE_FPCAST    = 4,
};
#define VIDMA_MXQUANT_VARIANT_FP16 0x1u   // MXQUANT variant: FP16 source (else FP32)

// Program the mem-tile viDMA OTF compute options (sticky until changed). Writes the
// RDL-generated compute register (offset/fields from vidma_reg.h) in one store.
static inline void memtile_vidma_set_compute(uint32_t tile, uint32_t op,
                                             uint32_t variant) {
    volatile vidma_reg_t *r =
        (volatile vidma_reg_t *)&gwaihir_addrmap.l2_spm_dma[tile].mem[0];
    vidma_reg__compute_t c = { .w = 0 };
    c.f.enable  = (op != (uint32_t)VIDMA_COMPUTE_NONE);
    c.f.op      = op;
    c.f.variant = variant;
    r->compute.w = c.w;
}

static inline void memtile_vidma_passthrough(uint32_t tile) {
    memtile_vidma_set_compute(tile, VIDMA_COMPUTE_NONE, 0);
}
