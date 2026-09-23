// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Cross-cluster DMOPC transpose: a cluster's DM core transposes a tile out of
// its own L1 into a neighbour cluster's L1 over the NoC. Requires
// `dma_enable_compute` in cfg/snitch_cluster.json. See idma_legalizer's
// ComputeTransposeShape for the whole-padded-tile, beat-aligned shape contract.
//
// Destinations are allocated with tile-size alignment, a power of two <= 4 KiB,
// which gives beat alignment and keeps the burst inside one page; phase C
// deliberately gives up the page alignment to cover the split.
//
// Every cluster poisons its own destination tile, so a misrouted write shows up
// as a poison miss in an uninvolved cluster.
//
// gwaihir's `_putchar` is a stub, so results go out over the dump CSR, which
// the Snitch RTL $displays as "[Dump Core <hart>] ... = 0x<value>". Records
// are DUMP(tag) followed by DUMP(value); the hart id keeps pairs apart.

#include <snrt.h>

// Deliberately not square: a swapped tensor_m/tensor_n would mask an 8x4
// result instead of a 4x8 one and fail the poison check.
#define TP_M 4
#define TP_N 8

#define TP_TAG_CYCLES 0x7A5A0001u
#define TP_TAG_ERRORS 0x7A5A0002u
#define TP_TAG_DIFFER 0x7A5A0003u
#define TP_TAG_BADPOS 0x7A5A0004u
#define TP_TAG_BADGOT 0x7A5A0005u
#define TP_TAG_BADEXP 0x7A5A0006u
#define TP_TAG_PHASE 0x7A5A0007u

#define TP_DUMP(tag, val)        \
    do {                         \
        DUMP((uint32_t)(tag));   \
        DUMP((uint32_t)(val));   \
    } while (0)

/// in[r][c] as filled by the sender: position-coded, poison outside the tile.
/// At 1 B elements r * 100 + c wraps and aliases the poison for a couple of
/// padding positions; a real leak covers far more cells than that.
template <typename T>
static inline T src_val(uint32_t r, uint32_t c, T poison) {
    return (c < TP_N) ? (T)(r * 100 + c) : poison;
}

/// One transposed tile per cluster: send to `peer`, check what a sender left.
/// EVERY core of EVERY cluster must call this: the L1 allocator is thread-local
/// and initialised identically per core, so an identical call sequence hands
/// every core of a cluster the same addresses, and the clusters stay aligned.
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

    // page_cross straddles the tile across a 4 KiB boundary: still beat-
    // aligned, so `ComputeTransposeShape` accepts it, but the AXI page rule
    // makes the legalizer emit two bursts for one compute transfer. The block
    // is poisoned and checked whole, so a shifted or overrunning tile shows.
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
        // Compute cores only load the destination TCDM; the DM core owns the
        // buffers and every check.
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

    // The poison stores go out on the narrow port, the remote DMA writes on
    // the wide one: fence before publishing the tile to the other clusters.
    snrt_fence();
    snrt_cluster_hw_barrier();
    snrt_inter_cluster_barrier();

    uint32_t errors = 0;
    if (am_sender) {
        volatile T *remote_dst = (volatile T *)snrt_remote_l1_ptr(
            (void *)dst, snrt_cluster_idx(), peer);
        // Structurally guaranteed: the block alignment and `off` are both beat
        // multiples, as is the cluster stride. Assert it anyway.
        if ((uintptr_t)remote_dst % SNRT_DMA_BYTES_PER_BEAT) {
            TP_DUMP(TP_TAG_BADPOS, (uintptr_t)remote_dst);
            errors++;
        } else {
            snrt_dma_set_transpose(mode, TP_M, TP_N);
            uint32_t c0 = snrt_mcycle();
            snrt_dma_start_1d((volatile void *)remote_dst, (volatile void *)src,
                              tile_bytes);
            snrt_dma_wait_all();
            TP_DUMP(TP_TAG_CYCLES, snrt_mcycle() - c0);
            snrt_dma_clear_opcode();
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

    // r * 100 + c differs from c * 100 + r everywhere but the diagonal; a
    // DMOPC that never latched leaves a passthrough copy and differ == 0.
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

    // Phase A: one pair on an otherwise idle NoC, one case per DMOPC operand
    // (the element-size mode rides rs1, the dimensions ride rs2).
    errors += run_remote_transpose<uint32_t>(0, 2, me == 0, 1, me == 1);
    errors += run_remote_transpose<uint16_t>(1, 1, me == 0, 1, me == 1);

    // Phase B: every cluster transposes into its neighbour at once, so each
    // destination TCDM arbitrates incoming W beats against its own traffic.
    errors += run_remote_transpose<uint32_t>(2, 2, 1, next, 1);

    // Phase C: same pair as phase A, but the destination tile straddles a
    // 4 KiB boundary. The legalizer splits the transfer into two bursts while
    // the compute engine keeps one tile's state across them.
    errors += run_remote_transpose<uint32_t>(3, 2, me == 0, 1, me == 1, 1);

    // Phase D: phase B again, but every receiver's eight compute cores hammer
    // their own TCDM throughout, so the incoming W beats lose bank arbitration.
    errors += run_remote_transpose<uint32_t>(4, 2, 1, next, 1, 0, 1);

    // Phase E: 1 B elements, the longest tile the shape assertion allows at
    // 64 beats instead of 16, so the destination has four times as long to
    // push back on the compute engine. Once quiet, once with every cluster
    // sending and every receiver hammering.
    errors += run_remote_transpose<uint8_t>(5, 0, me == 0, 1, me == 1);
    errors += run_remote_transpose<uint8_t>(6, 0, 1, next, 1, 0, 1);

    snrt_cluster_hw_barrier();
    return errors ? 1 : 0;
}
