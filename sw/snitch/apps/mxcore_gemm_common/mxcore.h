// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "snrt.h"

typedef enum {
    MXCORE_OUTPUT_FP32,
    MXCORE_OUTPUT_MXFP8
} mxcore_output_t;

typedef struct {
    uint8_t *x;
    uint8_t *w;
    uint8_t *sx;
    uint8_t *sw;
    void *y;
    int8_t *sy;
} mxcore_buffers_t;

enum {
    MXCORE_TRIGGER = 0x00,
    MXCORE_ACQUIRE = 0x04,
    MXCORE_STATUS = 0x0c,
    MXCORE_SOFT_CLEAR = 0x14,
    MXCORE_EVENTS = 0x94,
    MXCORE_MUX = 0x98,
    MXCORE_CLOCK_ENABLE = 0x9c,
    MXCORE_PERF_COUNTER = 15,
    MXCORE_TIMEOUT_CYCLES = 1000000
};

static inline volatile uint32_t *mxcore_reg(uint32_t offset) {
    uintptr_t base = (uintptr_t)snrt_cluster_alias()->zeromem.mem +
                     sizeof(snrt_cluster_alias()->zeromem.mem);
    return (volatile uint32_t *)(base + offset);
}

static inline void mxcore_write(uint32_t offset, uint32_t value) {
    *mxcore_reg(offset) = value;
}

static inline uint32_t mxcore_read(uint32_t offset) {
    return *mxcore_reg(offset);
}

static inline void mxcore_fence(void) {
    asm volatile("fence iorw, iorw" ::: "memory");
}

static inline void mxcore_clear_events(void) {
    // Clear each sticky core event with a separate write.
    for (uint32_t i = 0; i < snrt_cluster_core_num(); i++) {
        mxcore_write(MXCORE_EVENTS, 1u << i);
    }
}

static inline uint32_t mxcore_cycle(void) {
    return snrt_get_perf_counter(MXCORE_PERF_COUNTER);
}

static inline int mxcore_shape_valid(uint32_t m, uint32_t n, uint32_t k) {
    // Native tile sizes and widths of the tile-count register fields.
    if (!m || !n || !k || m % 64 || n % 32 || k % 32 ||
        m / 64 > 15 || n / 32 > 31 || k / 32 > 127) {
        return 0;
    }
    // The W-scale streamer has no partial final beat, except for its special
    // single-block (32-byte) mode. That mode fetches once and consumes the
    // block after 64 rows, so it cannot supply a second M tile.
    uint32_t sw_bytes = n * (k / 32);
    return sw_bytes == 32 ? m == 64 : sw_bytes % 64 == 0;
}

/**
 * Execute Y = XW with FP32 accumulation on the calling core's local MXCore.
 * All buffers must be distinct, 64-byte aligned, and resident in local TCDM.
 * See README.md for packed layouts, padding, and native output-scale encoding.
 * The caller owns MXCore and a running CYCLE performance counter 15 exclusively.
 * Returns 0 on success, 1 for an invalid shape, or 2 on timeout.
 * cycles measures trigger through observed completion; configuration is excluded.
 */
static inline int mxcore_gemm(uint32_t m, uint32_t n, uint32_t k,
                              const mxcore_buffers_t *b, mxcore_output_t output,
                              uint32_t *cycles) {
    if (!mxcore_shape_valid(m, n, k)) return 1;

    mxcore_write(MXCORE_SOFT_CLEAR, 0);
    mxcore_clear_events();
    uint32_t start = mxcore_cycle();
    while ((int32_t)mxcore_read(MXCORE_ACQUIRE) < 0) {
        if (mxcore_cycle() - start > MXCORE_TIMEOUT_CYCLES) return 2;
    }

    mxcore_write(0x20, (uintptr_t)b->x);
    mxcore_write(0x24, (uintptr_t)b->w);
    mxcore_write(0x28, (uintptr_t)b->sx);
    mxcore_write(0x2c, (uintptr_t)b->sw);
    mxcore_write(0x30, (uintptr_t)b->y);
    mxcore_write(0x34, (uintptr_t)b->sy);
    mxcore_write(0x38, m | (k << 10) | (n << 22));
    // E5M2 inputs, E8M0 input scales, FP32 accumulation, optional E5M2 output.
    mxcore_write(0x3c, output == MXCORE_OUTPUT_MXFP8 ? 0x00200678 : 0x678);
    mxcore_write(0x40, m / 64 | ((n / 32) << 4) | ((k / 32) << 9) |
                           ((k / 32) << 16));
    mxcore_write(0x44, 64 * 32 * 8);
    mxcore_write(0x48, 32 * 32 * 8);
    mxcore_write(0x4c, 64 * 32 * (output == MXCORE_OUTPUT_MXFP8 ? 8 : 32));
    mxcore_write(0x50, k * 2);
    mxcore_fence();

    start = mxcore_cycle();
    mxcore_write(MXCORE_TRIGGER, 0);
    mxcore_fence();
    // The peripheral bridge does not forward the offloading-core ID. Poll
    // status so this also works on the DM core, whose MX interrupt is not set.
    while (mxcore_read(MXCORE_STATUS)) {
        if (mxcore_cycle() - start > MXCORE_TIMEOUT_CYCLES) return 2;
    }
    *cycles = mxcore_cycle() - start;
    mxcore_fence();
    mxcore_clear_events();
    return 0;
}
