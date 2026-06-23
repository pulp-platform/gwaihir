// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// Per-tile iDMA helpers for mem tiles. Mirrors the X-macro pattern
// of cheshire/sw/include/dif/dma.h, but rebased onto Gwaihir's mem-tile
// DMA region exposed by gw_addrmap.h. One set of inline helpers is emitted
// per tile (memtile0..memtile7).

#pragma once

#include <stdint.h>
#include "regs/idma.h"
#include "gw_addrmap.h"

#define NUM_L2_MEM_TILES 2

// Per-tile DMA register base, derived from the generated address map.
#define MEMTILE_IDMA_BASE(i) \
    ((uintptr_t)&gwaihir_addrmap.l2_spm_dma[(i)].mem[0])

// X-macro: emit inline DMA helpers for one tile.
//
//   NAME   — prefix used for the emitted function names (e.g. memtile1)
//   BASE   — uintptr_t expression yielding the iDMA reg base for that tile
//
// The helpers are deliberately a small superset of cheshire's dif/dma.h:
//   - <NAME>_dma_2d_memcpy(...)         — non-blocking 2D issue; returns tf_id
//   - <NAME>_dma_2d_blk_memcpy(...)     — blocking 2D wrapper (polls done_id_0)
//   - <NAME>_dma_blk_memcpy(...)        — blocking 1D wrapper (reps=1, ENABLE_ND clear)
#define MEMTILE_IDMA_X(NAME, BASE)                                                 \
    static inline uint64_t NAME##_dma_2d_memcpy(uint64_t dst, uint64_t src,        \
                                                uint64_t size,                     \
                                                uint64_t dst_stride,               \
                                                uint64_t src_stride,               \
                                                uint64_t num_reps,                 \
                                                uint64_t conf) {                   \
        *(volatile uint64_t *)((BASE) + IDMA_REG64_2D_SRC_ADDR_LOW_REG_OFFSET)     \
            = src;                                                                 \
        *(volatile uint64_t *)((BASE) + IDMA_REG64_2D_DST_ADDR_LOW_REG_OFFSET)     \
            = dst;                                                                 \
        *(volatile uint64_t *)((BASE) + IDMA_REG64_2D_LENGTH_LOW_REG_OFFSET)       \
            = size;                                                                \
        *(volatile uint64_t *)((BASE) + IDMA_REG64_2D_CONF_REG_OFFSET)             \
            = conf;                                                                \
        if (conf & (1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT)) {                     \
            *(volatile uint64_t *)((BASE)                                          \
                + IDMA_REG64_2D_SRC_STRIDE_2_LOW_REG_OFFSET) = src_stride;         \
            *(volatile uint64_t *)((BASE)                                          \
                + IDMA_REG64_2D_DST_STRIDE_2_LOW_REG_OFFSET) = dst_stride;         \
            *(volatile uint64_t *)((BASE)                                          \
                + IDMA_REG64_2D_REPS_2_LOW_REG_OFFSET) = num_reps;                 \
        }                                                                          \
        /* Reading NEXT_ID_0 both issues the transfer and returns its id. */       \
        return *(volatile uint64_t *)((BASE)                                       \
            + IDMA_REG64_2D_NEXT_ID_0_REG_OFFSET);                                 \
    }                                                                              \
                                                                                   \
    static inline void NAME##_dma_2d_blk_memcpy(uint64_t dst, uint64_t src,        \
                                                uint64_t size,                     \
                                                uint64_t dst_stride,               \
                                                uint64_t src_stride,               \
                                                uint64_t num_reps,                 \
                                                uint64_t conf) {                   \
        uint64_t tf_id = NAME##_dma_2d_memcpy(dst, src, size, dst_stride,          \
                                              src_stride, num_reps, conf);         \
        while (*(volatile uint64_t *)((BASE)                                       \
               + IDMA_REG64_2D_DONE_ID_0_REG_OFFSET) != tf_id) {                   \
            asm volatile("nop");                                                   \
        }                                                                          \
    }                                                                              \
                                                                                   \
    static inline void NAME##_dma_blk_memcpy(uint64_t dst, uint64_t src,           \
                                             uint64_t size, uint64_t conf) {       \
        NAME##_dma_2d_blk_memcpy(dst, src, size, 0, 0, 1,                          \
            conf & ~(1u << IDMA_REG64_2D_CONF_ENABLE_ND_BIT));                     \
    }

MEMTILE_IDMA_X(memtile0, MEMTILE_IDMA_BASE(0))
MEMTILE_IDMA_X(memtile1, MEMTILE_IDMA_BASE(1))

#undef MEMTILE_IDMA_X
