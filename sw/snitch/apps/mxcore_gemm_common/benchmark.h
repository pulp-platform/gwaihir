// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "mxcore.h"

static inline uint32_t mxcore_align64(uint32_t bytes) {
    return (bytes + 63u) & ~63u;
}

// Nonuniform, exactly representable E5M2 values: 1, 2, 3, -1, -2, -3.
static inline int mxcore_factor(uint32_t index) {
    int value = 1 + index % 3;
    return (index / 3) % 2 ? -value : value;
}

static inline uint8_t mxcore_e5m2_integer(int value) {
    uint8_t sign = value < 0 ? 0x80 : 0;
    uint32_t magnitude = value < 0 ? -value : value;
    return sign | (magnitude == 1 ? 0x3c : magnitude == 2 ? 0x40 : 0x42);
}

static inline void mxcore_init_inputs(uint32_t m, uint32_t n, uint32_t k,
                                      const mxcore_buffers_t *b) {
    // X: [M/64][K/32][64][32], SX: [M/64][K/32][64].
    for (uint32_t mt = 0; mt < m / 64; mt++) {
        for (uint32_t kb = 0; kb < k / 32; kb++) {
            for (uint32_t row = 0; row < 64; row++) {
                uint32_t i = mt * 64 + row;
                uint32_t block = (mt * (k / 32) + kb) * 64 + row;
                b->sx[block] = 126 + (i + kb) % 3;
                for (uint32_t q = 0; q < 32; q++) {
                    int value = mxcore_factor(i) * (q % 2 ? -1 : 1);
                    b->x[block * 32 + q] = mxcore_e5m2_integer(value);
                }
            }
        }
    }
    // W: [N/32][K/32][32 columns][32], SW: [N/32][K/32][32].
    for (uint32_t nt = 0; nt < n / 32; nt++) {
        for (uint32_t kb = 0; kb < k / 32; kb++) {
            for (uint32_t col = 0; col < 32; col++) {
                uint32_t j = nt * 32 + col;
                uint32_t block = (nt * (k / 32) + kb) * 32 + col;
                b->sw[block] = 126 + (j + 2 * kb) % 3;
                for (uint32_t q = 0; q < 32; q++) {
                    int value = mxcore_factor(j) * (q % 2 ? -1 : 1);
                    b->w[block * 32 + q] = mxcore_e5m2_integer(value);
                }
            }
        }
    }
    // A 32-byte W-scale matrix is fetched as one full 64-byte beat.
    for (uint32_t i = n * k / 32; i < mxcore_align64(n * k / 32); i++) {
        b->sw[i] = 127;
    }
}

static inline void mxcore_poison_output(const mxcore_buffers_t *b,
                                        uint32_t y_bytes, uint32_t sy_bytes) {
    // Poison Y to detect missing output writes, including after the warm-up.
    volatile uint32_t *y = (volatile uint32_t *)b->y;
    for (uint32_t i = 0; i < y_bytes / 4; i++) y[i] = 0xa5a5a5a5;
    for (uint32_t i = 0; i < sy_bytes; i++) b->sy[i] = 0x55;
}

// Exact integer reference in units of 1/4, avoiding FPU instructions on the DM
// core. The alternating K signs cancel in X*W. Scales vary with row/column/K.
static inline int32_t mxcore_reference(uint32_t i, uint32_t j,
                                      const uint32_t weights[3][3]) {
    return 32 * mxcore_factor(i) * mxcore_factor(j) *
           (int32_t)weights[i % 3][j % 3];
}

static inline uint32_t mxcore_magnitude(int32_t value) {
    return value < 0 ? -value : value;
}

static inline uint32_t mxcore_fp32_bits(int32_t quarters) {
    uint32_t value = mxcore_magnitude(quarters);
    if (!value) return 0;
    uint32_t msb = 31 - __builtin_clz(value);
    // The input pattern and supported K keep the reference below 2^24.
    return (quarters < 0 ? 0x80000000u : 0) | ((msb + 125) << 23) |
           ((value << (23 - msb)) & 0x7fffffu);
}

static inline uint8_t mxcore_quantize(int32_t quarters, int scale) {
    uint32_t value = mxcore_magnitude(quarters);
    if (!value) return 0;
    uint32_t msb = 31 - __builtin_clz(value);
    // This test pattern produces normal E5M2 numbers (no subnormal reference).
    uint32_t shift = msb - 2;
    uint32_t significand = value >> shift;
    uint32_t remainder = value & ((1u << shift) - 1);
    uint32_t half = 1u << (shift - 1);
    if (remainder > half || (remainder == half && (significand & 1))) {
        significand++;
    }
    int exponent = (int)msb - 2 - scale + 15;
    if (significand == 8) {
        significand = 4;
        exponent++;
    }
    // Hardware uses round-to-nearest-even and saturates overflow to max finite.
    uint8_t payload = exponent > 30 ? 0x7b : (exponent << 2) | (significand - 4);
    return (quarters < 0 ? 0x80 : 0) | payload;
}

static inline uint32_t mxcore_check(uint32_t m, uint32_t n, uint32_t k,
                                    const mxcore_buffers_t *b,
                                    mxcore_output_t output) {
    uint32_t weights[3][3] = {{0}};
    for (uint32_t i = 0; i < 3; i++) {
        for (uint32_t j = 0; j < 3; j++) {
            for (uint32_t kb = 0; kb < k / 32; kb++) {
                weights[i][j] += 1u << ((i + kb) % 3 + (j + 2 * kb) % 3);
            }
        }
    }
    uint32_t errors = 0;
    // Y: [M/64][N/32][64][32], SY: [M/64][N/32][64].
    for (uint32_t mt = 0; mt < m / 64; mt++) {
        for (uint32_t nt = 0; nt < n / 32; nt++) {
            for (uint32_t row = 0; row < 64; row++) {
                uint32_t i = mt * 64 + row;
                uint32_t block = (mt * (n / 32) + nt) * 64 + row;
                uint32_t largest = 0;
                for (uint32_t col = 0; col < 32; col++) {
                    uint32_t value = mxcore_magnitude(
                        mxcore_reference(i, nt * 32 + col, weights));
                    if (value > largest) largest = value;
                }
                int scale = (31 - __builtin_clz(largest)) - 17;
                if (output == MXCORE_OUTPUT_MXFP8 && b->sy[block] != scale) {
                    errors++;
                }
                for (uint32_t col = 0; col < 32; col++) {
                    int32_t ref = mxcore_reference(i, nt * 32 + col, weights);
                    uint32_t index = block * 32 + col;
                    if (output == MXCORE_OUTPUT_FP32) {
                        errors += ((const uint32_t *)b->y)[index] != mxcore_fp32_bits(ref);
                    } else {
                        errors += ((const uint8_t *)b->y)[index] != mxcore_quantize(ref, scale);
                    }
                }
            }
        }
    }
    return errors;
}

static inline int mxcore_gemm_benchmark(uint32_t m, uint32_t n, uint32_t k,
                                       mxcore_output_t output) {
    // All other harts return through SNRT's normal barrier/exit protocol.
    if (snrt_cluster_idx() != 0 || !snrt_is_dm_core()) return 0;

    if (!mxcore_shape_valid(m, n, k)) {
        printf("MXCore N.A.: unsupported M=%u N=%u K=%u\r\n", m, n, k);
        return 1;
    }

    uint32_t x_bytes = m * k, w_bytes = n * k;
    uint32_t sx_bytes = x_bytes / 32, sw_bytes = w_bytes / 32;
    uint32_t y_bytes = m * n * (output == MXCORE_OUTPUT_MXFP8 ? 1 : 4);
    uint32_t sy_bytes = output == MXCORE_OUTPUT_MXFP8 ? m * n / 32 : 0;
    uint32_t bytes = x_bytes + w_bytes + sx_bytes + mxcore_align64(sw_bytes) +
                     y_bytes + sy_bytes;
    // SNRT reserves stack/CLS space at the top of L1. Check its actual bounds
    // before allocation; simply comparing against the full 128 KiB is unsafe.
    snrt_allocator_t *allocator = snrt_l1_allocator_v2();
    uint32_t base = mxcore_align64(allocator->next);
    uint32_t available = base < allocator->end ? allocator->end - base : 0;
    if (bytes > available) {
        printf("MXCore N.A.: M=%u N=%u K=%u needs %u B, L1 heap %u B\r\n",
               m, n, k, bytes, available);
        return 1;
    }

    mxcore_buffers_t b;
    b.x = (uint8_t *)snrt_l1_alloc_cluster_local(x_bytes, 64);
    b.w = (uint8_t *)snrt_l1_alloc_cluster_local(w_bytes, 64);
    b.sx = (uint8_t *)snrt_l1_alloc_cluster_local(sx_bytes, 64);
    b.sw = (uint8_t *)snrt_l1_alloc_cluster_local(mxcore_align64(sw_bytes), 64);
    b.y = snrt_l1_alloc_cluster_local(y_bytes, 64);
    b.sy = sy_bytes ? (int8_t *)snrt_l1_alloc_cluster_local(sy_bytes, 64) : NULL;
    mxcore_init_inputs(m, n, k, &b);

    snrt_stop_perf_counter(MXCORE_PERF_COUNTER);
    snrt_cfg_perf_counter(MXCORE_PERF_COUNTER, PERF_METRIC__CYCLE, 0);
    snrt_reset_perf_counter(MXCORE_PERF_COUNTER);
    snrt_start_perf_counter(MXCORE_PERF_COUNTER);
    mxcore_write(MXCORE_CLOCK_ENABLE, 1);
    mxcore_write(MXCORE_MUX, 0);
    mxcore_fence();

    uint32_t cycles = 0;
    int status = 0;
    // One warm-up and one measured launch, with preparation outside the timer.
    for (uint32_t run = 0; run < 2; run++) {
        mxcore_poison_output(&b, y_bytes, sy_bytes);
        status = mxcore_gemm(m, n, k, &b, output, &cycles);
        if (status) break;
    }
    snrt_stop_perf_counter(MXCORE_PERF_COUNTER);
    if (status) mxcore_write(MXCORE_SOFT_CLEAR, 0);
    mxcore_clear_events();
    mxcore_write(MXCORE_CLOCK_ENABLE, 0);
    mxcore_fence();
    if (status || !cycles) {
        printf("MXCore failed: status=%d cycles=%u\r\n", status, cycles);
        return 2;
    }

    uint32_t errors = mxcore_check(m, n, k, &b, output);
    // Account for tile rereads and scale traffic. The single W-scale block is
    // fetched once (only M=64 is supported); others repeat per M tile.
    uint32_t reads = (x_bytes + sx_bytes) * (n / 32) + w_bytes * (m / 64) +
                     (sw_bytes == 32 ? 64 : sw_bytes * (m / 64));
    uint32_t writes = y_bytes + sy_bytes;
    uint32_t util = (uint64_t)m * n * k * 10000 / (1024ull * cycles);
    uint32_t bw = (uint64_t)(reads + writes) * 100 / cycles;
    printf("MXCore %s M=%u N=%u K=%u L1=%u B\r\n",
           output == MXCORE_OUTPUT_MXFP8 ? "MXFP8" : "FP32", m, n, k, bytes);
    printf("cycles=%u util=%u.%02u%% BW(est)=%u.%02u B/cycle R=%u W=%u B errors=%u\r\n",
           cycles, util / 100, util % 100, bw / 100, bw % 100, reads, writes, errors);
    return errors ? 3 : 0;
}
