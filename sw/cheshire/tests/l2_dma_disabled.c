// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
//
// The small mem tiles (1, 3) are built without an iDMA (mem_tile EnableDma = 0).
// Their iDMA register window stays in the address map and is answered by an
// axi_err_slv. CVA6 does not trap on AXI error responses, so a read returns
// the error slave's data pattern. This test checks that:
//   1. reads and writes to a small tile's iDMA window complete (no hang) and
//      reads return the error pattern;
//   2. the large tiles' iDMA windows still answer with register data;
//   3. the small tiles' L2 SPM still works after the error accesses.
//
// Return: 0 on pass, else STAGE * 100 + tile.

#include <stdint.h>

#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

// RespData of axi_err_slv
#define ERR_SLV_DATA 0xCA11AB1EBADCAB1Eull

#define L2_TEST_WORDS 16

static inline int memtile_has_dma(uint32_t tile) { return (tile == 0) || (tile == 2); }

int main(void) {
    for (uint32_t t = 0; t < GW_L2_SPM_NUM; t++) {
        volatile uint64_t *dma = (volatile uint64_t *)(uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(t);
        if (memtile_has_dma(t)) {
            // conf + status[0] of a live iDMA
            if (dma[0] == ERR_SLV_DATA) return 200 + t;
        } else {
            if (dma[0] != ERR_SLV_DATA) return 100 + t;
            // The write must complete; the read after it must not hang
            dma[0] = 0x1ull;
            if (dma[1] != ERR_SLV_DATA) return 100 + t;
        }
    }

    for (uint32_t t = 0; t < GW_L2_SPM_NUM; t++) {
        if (memtile_has_dma(t)) continue;
        volatile uint32_t *l2 = (volatile uint32_t *)(uintptr_t)GW_L2_SPM_BASE_ADDR(t);
        for (uint32_t i = 0; i < L2_TEST_WORDS; i++) l2[i] = 0xC0DE0000u | (t << 8) | i;
        for (uint32_t i = 0; i < L2_TEST_WORDS; i++)
            if (l2[i] != (0xC0DE0000u | (t << 8) | i)) return 300 + t;
    }

    return 0;
}
