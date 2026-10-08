// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>

#include "snrt.h"
#include "gw_addrmap_32b.h"
#include "gw_raw_addrmap_32b.h"
#include "gw_host.h"

// Chip-to-chip multicast through the ucie0 fork.
//
// The DM core of cluster 0 issues ONE wide DMA write into the ucie0 alias window.
// The AW carries a multicast mask but a UNICAST opcode.
// ucie0 should fork it into:
// - the remote branch, towards the peer chiplet (clusters 8-15 in the loopback),
// - the local branch, back into this chiplet (clusters 0-7).
// At the exit of the ucie0 fork, the opcode is set to MULTICAST, so both
// branches are then multicast by their chimney. The DMA completes once both
// branches have returned their B response.
//
// Every cluster then checks its destination buffer.

#define NUM_ELEM 64  // One wide burst of 4 beats (512-bit each)
#define TESTVAL_BASE 0xABCD0000
#define DST_INIT 0x5A5A5A5A

// Number of chiplets in the loopback (this one and its peer)
#define NUM_CHIPLETS 2

#define SENDER_CLUSTER 0

// Mask selecting all clusters of a chiplet (cluster index bits of the address)
// plus the bit distinguishing the ucie0 and ucie1 alias windows
static inline uint64_t ucie_mcast_mask() {
    uintptr_t cluster_stride = (uintptr_t)&gwaihir_addrmap_32b.cluster[1] -
                               (uintptr_t)&gwaihir_addrmap_32b.cluster[0];
    uintptr_t clusters_per_chiplet = snrt_cluster_num() / NUM_CHIPLETS;
    uintptr_t cluster_mask = (clusters_per_chiplet - 1) * cluster_stride;
    uintptr_t window_mask = (uintptr_t)&gwaihir_addrmap_32b.ucie0 ^
                            (uintptr_t)&gwaihir_addrmap_32b.ucie1;
    return cluster_mask | window_mask;
}

// Program the DMA AW user field with a collective mask but a UNICAST opcode.
static inline void snrt_dma_set_unicast_with_mask(uint64_t mask) {
    snrt_collective_t op;
    op.f.opcode = SNRT_COLLECTIVE_UNICAST;
    op.f.mask = mask;
    snrt_dma_set_awuser(op.w);
}

int main() {
    uint32_t errors = 0;

    snrt_global_barrier();

    if (!snrt_is_dm_core()) return 0;

    // Same allocation order in every cluster, so the buffers sit at the same
    // TCDM offset everywhere
    uint32_t *src = (uint32_t *)snrt_l1_alloc_cluster_local(NUM_ELEM * sizeof(uint32_t), 64);
    uint32_t *dst = (uint32_t *)snrt_l1_alloc_cluster_local(NUM_ELEM * sizeof(uint32_t), 64);

    for (uint32_t i = 0; i < NUM_ELEM; i++) {
        src[i] = TESTVAL_BASE + i;
        dst[i] = DST_INIT;
    }

    snrt_inter_cluster_barrier();

    if (snrt_cluster_idx() == SENDER_CLUSTER) {
        // Enable clk/rst for both ucie tiles
        volatile gw_ucie_tile_regs_t *ucie_cfg0 =
            (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_32b.ucie0_tile_cfg;
        volatile gw_ucie_tile_regs_t *ucie_cfg1 =
            (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_32b.ucie1_tile_cfg;
        if ((ucie_tile_enable(ucie_cfg0) && ucie_tile_enable(ucie_cfg1)) == 0) errors++;

        // Destination buffer of cluster 0 as seen through the ucie0 alias window
        uintptr_t dst_off = (uintptr_t)dst - (uintptr_t)&gwaihir_addrmap_32b.cluster[0].tcdm.mem[0];
        uintptr_t dst_alias = (uintptr_t)&gwaihir_addrmap_32b.ucie0.cluster[0].tcdm.mem[0] + dst_off;

        snrt_dma_set_unicast_with_mask(ucie_mcast_mask());
        snrt_dma_start_1d((void *)dst_alias, (void *)src, NUM_ELEM * sizeof(uint32_t));
        snrt_dma_set_awuser(0);
        snrt_dma_wait_all();
    }

    snrt_inter_cluster_barrier();

    for (uint32_t i = 0; i < NUM_ELEM; i++) {
        errors += (dst[i] != TESTVAL_BASE + i);
    }

    return errors;
}
