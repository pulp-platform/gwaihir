// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

// Cross-cluster DMOPC transpose over the NoC; needs dma_enable_compute in the cfg

#include <snrt.h>

// Not square, so a swapped tensor_m/tensor_n fails the poison check
#define TP_M 4
#define TP_N 8

#define TP_TAG_CYCLES 0x7A5A0001u
#define TP_TAG_ERRORS 0x7A5A0002u
#define TP_TAG_DIFFER 0x7A5A0003u
#define TP_TAG_BADPOS 0x7A5A0004u
#define TP_TAG_BADGOT 0x7A5A0005u
#define TP_TAG_BADEXP 0x7A5A0006u
#define TP_TAG_PHASE 0x7A5A0007u

// gwaihir's _putchar is a stub, so results go out over the dump CSR
#define TP_DUMP(tag, val)        \
    do {                         \
        DUMP((uint32_t)(tag));   \
        DUMP((uint32_t)(val));   \
    } while (0)

/// in[r][c] as the sender filled it: position-coded, poison outside the tile
template <typename T>
static inline T src_val(uint32_t r, uint32_t c, T poison) {
    return (c < TP_N) ? (T)(r * 100 + c) : poison;
}

/// One transposed tile per cluster: send to `peer`, check what a sender left
template <typename T>
static uint32_t run_remote_transpose(uint32_t phase, uint32_t mode,
                                     int am_sender, uint32_t peer,
                                     int am_receiver, int page_cross = 0,
                                     int hammer = 0) {
    const uint32_t ne = SNRT_DMA_BYTES_PER_BEAT / sizeof(T);
    const size_t tile_bytes = (size_t)ne * SNRT_DMA_BYTES_PER_BEAT;
    const T poison = (T)0xA5A5A5A5u;
    const int dm = snrt_is_dm_core();

    volatile T *src = (volatile T *)snrt_l1_alloc_cluster_local(
        tile_bytes, SNRT_DMA_BYTES_PER_BEAT);

    // page_cross straddles a 4 KiB boundary but stays beat-aligned
    const size_t blk_bytes = page_cross ? 0x1000 + tile_bytes : tile_bytes;
    const size_t blk_align = page_cross ? 0x1000 : tile_bytes;
    const size_t off = page_cross ? (0x1000 - tile_bytes / 2) / sizeof(T) : 0;
    volatile T *blk =
        (volatile T *)snrt_l1_alloc_cluster_local(blk_bytes, blk_align);
    volatile T *dst = blk + off;

    // Per-compute-core hammer line plus the flag that bounds the hammer window.
    volatile uint64_t *ham = (volatile uint64_t *)snrt_l1_alloc_cluster_local(
        (size_t)snrt_cluster_compute_core_num() * 64, 64);
    volatile uint32_t *stop =
        (volatile uint32_t *)snrt_l1_alloc_cluster_local(4, 4);

    if (!dm) {
        // Compute cores only load the destination TCDM; the DM core owns the buffers and checks
        snrt_cluster_hw_barrier();
        if (hammer) {
            volatile uint64_t *line = ham + snrt_cluster_core_idx() * 8;
            while (!*stop)
                for (uint32_t j = 0; j < 8; j++) line[j] = j;
        }
        snrt_cluster_hw_barrier();
        return 0;
    }

    TP_DUMP(TP_TAG_PHASE, (phase << 16) | snrt_cluster_idx());

    *stop = 0;
    for (uint32_t r = 0; r < ne; r++)
        for (uint32_t c = 0; c < ne; c++)
            src[r * ne + c] = src_val<T>(r, c, poison);
    for (size_t i = 0; i < blk_bytes / sizeof(T); i++) blk[i] = poison;

    // Narrow-port poison stores race the wide-port DMA; fence before publishing the tile
    snrt_fence();
    snrt_cluster_hw_barrier();
    snrt_inter_cluster_barrier();

    uint32_t errors = 0;
    if (am_sender) {
        volatile T *remote_dst = (volatile T *)snrt_remote_l1_ptr(
            (void *)dst, snrt_cluster_idx(), peer);
        // Guaranteed by the block alignment, `off` and the cluster stride; assert it anyway
        if ((uintptr_t)remote_dst % SNRT_DMA_BYTES_PER_BEAT) {
            TP_DUMP(TP_TAG_BADPOS, (uintptr_t)remote_dst);
            errors++;
        } else {
            uint32_t c0 = snrt_mcycle();
            snrt_dma_start_transpose((volatile void *)remote_dst,
                                     (volatile void *)src, tile_bytes, mode,
                                     TP_M, TP_N);
            snrt_dma_wait_all();
            TP_DUMP(TP_TAG_CYCLES, snrt_mcycle() - c0);
        }
    }

    snrt_inter_cluster_barrier();
    *stop = 1;
    snrt_fence();
    snrt_cluster_hw_barrier();

    uint32_t differ = 0, reported = 0;
    for (size_t i = 0; i < blk_bytes / sizeof(T); i++) {
        T got = blk[i];
        T exp = poison;
        uint32_t c = 0, r = 0;
        int in_tile = (i >= off) && (i - off < (size_t)ne * ne);
        if (in_tile) {
            c = (uint32_t)((i - off) / ne);
            r = (uint32_t)((i - off) % ne);
        }
        if (am_receiver && in_tile && c < TP_N && r < TP_M)
            exp = src_val<T>(r, c, poison);
        if (got != exp) {
            if (reported++ < 4) {
                TP_DUMP(TP_TAG_BADPOS, i);
                TP_DUMP(TP_TAG_BADGOT, got);
                TP_DUMP(TP_TAG_BADEXP, exp);
            }
            errors++;
        }
        // A plain copy would leave src[c][r], i.e. c * 100 + r.
        if (am_receiver && in_tile && c < TP_N && r < TP_M &&
            got != src_val<T>(c, r, poison))
            differ++;
    }

    // r * 100 + c differs from c * 100 + r off the diagonal; a passthrough copy gives 0
    if (am_receiver) {
        TP_DUMP(TP_TAG_DIFFER, differ);
        if (differ != (uint32_t)(TP_M * TP_N - TP_M)) errors++;
    }

    TP_DUMP(TP_TAG_ERRORS, errors);
    return errors;
}

int main() {
    const uint32_t me = snrt_cluster_idx();
    const uint32_t n = snrt_cluster_num();
    // North neighbour inside a column, wrapping into the next column.
    const uint32_t next = (me + 1) % n;

    uint32_t errors = 0;

    // Phase A: one pair on an idle NoC, one case per DMOPC operand (mode rs1, dims rs2)
    errors += run_remote_transpose<uint32_t>(0, 2, me == 0, 1, me == 1);
    errors += run_remote_transpose<uint16_t>(1, 1, me == 0, 1, me == 1);

    // Phase B: all clusters transpose at once, so each destination TCDM arbitrates W beats
    errors += run_remote_transpose<uint32_t>(2, 2, 1, next, 1);

    // Phase C: same pair as phase A, but the destination tile straddles a 4 KiB boundary
    errors += run_remote_transpose<uint32_t>(3, 2, me == 0, 1, me == 1, 1);

    // Phase D: phase B with every receiver's compute cores hammering its TCDM banks
    errors += run_remote_transpose<uint32_t>(4, 2, 1, next, 1, 0, 1);

    // Phase E: 1 B elements, 64 beats instead of 16, so the destination pushes back longer
    errors += run_remote_transpose<uint8_t>(5, 0, me == 0, 1, me == 1);
    errors += run_remote_transpose<uint8_t>(6, 0, 1, next, 1, 0, 1);

    snrt_cluster_hw_barrier();
    return errors ? 1 : 0;
}
