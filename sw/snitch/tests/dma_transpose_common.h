// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Shared by dma_transpose_l1.c and dma_transpose_l2.c: transpose matrices with
// the cluster DMA into the L1 and check every byte, including the memory around
// the destination, which the DMA must leave untouched.

#include <snrt.h>

#ifdef SNRT_SUPPORTS_DMA_COMPUTE

// Room for the largest case below: 8-bit elements, 67 x 123
#define BUF_BYTES (16 * 1024)

// Source padding and destination background. They differ, so a masked byte that
// leaks from the source shows up in the destination.
#define SRC_PAD 0x5A
#define DST_PAD 0xA5

// A value with every byte set to `byte`
template <typename T>
static T pad(uint8_t byte) {
    T value = 0;
    for (size_t i = 0; i < sizeof(T); i++) value = (value << 8) | byte;
    return value;
}

// Not symmetric, so a plain copy of the matrix fails the check
template <typename T>
static T pattern(uint32_t r, uint32_t c) {
    return (T)(r * 7 + c * 13 + 1);
}

static uint32_t round_up(uint32_t x, uint32_t to) { return (x + to - 1) / to * to; }

// Transpose an m x n matrix; src and dst are buffers of BUF_BYTES
template <typename T>
static uint32_t run_case(volatile T *src, volatile T *dst, uint32_t mode, uint32_t m,
                         uint32_t n) {
    const uint32_t ne = SNRT_DMA_BYTES_PER_BEAT / sizeof(T);
    // A tile reads and writes whole rows, so the buffers reach past the matrix
    const size_t src_elems = (size_t)round_up(m, ne) * n + ne;
    const size_t dst_elems = (size_t)round_up(n, ne) * m + ne;

    for (size_t i = 0; i < src_elems; i++) src[i] = pad<T>(SRC_PAD);
    for (uint32_t r = 0; r < m; r++)
        for (uint32_t c = 0; c < n; c++) src[r * n + c] = pattern<T>(r, c);
    for (size_t i = 0; i < dst_elems; i++) dst[i] = pad<T>(DST_PAD);
    // The stores must land before the DMA reads
    snrt_fence();
    (void)src[src_elems - 1];

    gw_dma_start_transpose(dst, src, m, n, mode);
    snrt_dma_wait_all();

    // dst is n rows of m elements. Beyond that nothing may have changed.
    uint32_t errors = 0;
    for (size_t i = 0; i < dst_elems; i++) {
        uint32_t row = i / m, col = i % m;
        T expected = (row < n) ? pattern<T>(col, row) : pad<T>(DST_PAD);
        if (dst[i] != expected) errors++;
    }
    return errors;
}

// A full tile, a tile with edges, several tiles with edges, and rows that do
// not start on a beat
template <typename T>
static uint32_t run_mode(volatile T *src, volatile T *dst, uint32_t mode) {
    const uint32_t ne = SNRT_DMA_BYTES_PER_BEAT / sizeof(T);
    uint32_t errors = 0;
    errors += run_case<T>(src, dst, mode, ne, ne);
    errors += run_case<T>(src, dst, mode, 4, 8);
    errors += run_case<T>(src, dst, mode, ne + 3, 2 * ne - 5);
    errors += run_case<T>(src, dst, mode, 5, 37);
    return errors;
}

// All element sizes; src and dst are buffers of BUF_BYTES
static uint32_t run_all(void *src, void *dst) {
    uint32_t errors = 0;
    errors += run_mode<uint8_t>((uint8_t *)src, (uint8_t *)dst, 0);
    errors += run_mode<uint16_t>((uint16_t *)src, (uint16_t *)dst, 1);
    errors += run_mode<uint32_t>((uint32_t *)src, (uint32_t *)dst, 2);
    errors += run_mode<uint64_t>((uint64_t *)src, (uint64_t *)dst, 3);
    return errors;
}

#endif
