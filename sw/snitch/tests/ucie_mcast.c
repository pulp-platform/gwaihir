// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>

#include "snrt.h"
#include "gw_addrmap_32b.h"
#include "gw_raw_addrmap_32b.h"
#include "gw_host.h"

// Waveform probe: does a unicast request carrying a multicast mask reach ucie0?
//
// Cluster 0, core 0 issues ONE narrow store to a cluster TCDM behind the ucie0
// alias window. The AW user field carries a non-zero collective mask, but the
// opcode is left at UNICAST, so the NoC routes it as a plain unicast to ucie0
// while the payload user field still carries the mask.
//
// Nothing is checked in software, not even the response. After the store the
// core just idles for a while so the flit has time to show up at the ucie0
// chimney before the simulation ends. Inspect payload.user of the narrow AW/W
// flits there.

#define TESTVAL 0xABCD0001
#define IDLE_ITERS 20000

#define TARGET_CLUSTER 0

// Address mask carried in the AW user field. The low bits [21:18] select
// clusters (x bits [21:20], y bits [19:18]); bit 25 is meant to let the
// ucie0 endpoint fork the request into the two alias windows 0x3200_0000
// (ucie0) and 0x3000_0000 (ucie1).
#define MCAST_MASK 0x022C0000

#define MAILBOX_IDX 0

// Program the AW user CSR with a collective mask but a UNICAST opcode.
// `snrt_enable_multicast` would set SNRT_COLLECTIVE_MULTICAST instead.
static inline void snrt_set_unicast_with_mask(uint64_t mask) {
    snrt_collective_t op;
    op.f.opcode = SNRT_COLLECTIVE_UNICAST;
    op.f.mask = mask;
    snrt_set_awuser(op.w);
}

int main() {
    if (snrt_cluster_idx() != 0 || snrt_cluster_core_idx() != 0) return 0;

    // Enable clk/rst for both ucie tiles
    volatile gw_ucie_tile_regs_t *ucie_cfg0 =
        (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_32b.ucie0_tile_cfg;
    volatile gw_ucie_tile_regs_t *ucie_cfg1 =
        (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_32b.ucie1_tile_cfg;
    if ((ucie_tile_enable(ucie_cfg0) && ucie_tile_enable(ucie_cfg1)) == 0) return 1;

    // Target as seen through the ucie0 alias window
    volatile uint32_t *dst =
        (volatile uint32_t *)&gwaihir_addrmap_32b.ucie0.cluster[TARGET_CLUSTER].tcdm.mem[MAILBOX_IDX];

    // The one request under test: unicast opcode, non-zero multicast mask
    snrt_set_unicast_with_mask(MCAST_MASK);
    *dst = TESTVAL;
    snrt_set_awuser(0);

    // Idle so the flit has time to reach ucie0 before the simulation ends
    for (volatile uint32_t i = 0; i < IDLE_ITERS; i++);

    return 0;
}
