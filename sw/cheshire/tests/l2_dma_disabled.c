// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
//
// The small mem tiles (1, 3) are built without an iDMA (mem_tile EnableDma = 0).
// Their iDMA register window stays in the address map and is answered by an
// axi_err_slv. CVA6 raises a hardware error exception (mcause 19, mtval = address)
// on a load that receives an AXI error response. This test checks that:
//   1. loads from a small tile's iDMA window trap with that cause and address,
//      and stores to it complete (no hang);
//   2. the large tiles' iDMA windows still answer with register data;
//   3. the small tiles' L2 SPM still works after the error accesses.
//
// Return: 0 on pass, else STAGE * 100 + tile (400: an unexpected trap).

#include <stdint.h>

#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

// RespData of axi_err_slv
#define ERR_SLV_DATA 0xCA11AB1EBADCAB1Eull

#define MCAUSE_HW_ERROR 19

#define L2_TEST_WORDS 16

static volatile uint64_t trap_count;
static volatile uint64_t trap_cause;
static volatile uint64_t trap_tval;

// Called by the crt0 trap wrapper: record the trap and resume after the faulting instruction
void trap_vector(void) {
    uint64_t cause, tval, epc;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mtval" : "=r"(tval));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    trap_cause = cause;
    trap_tval = tval;
    trap_count = trap_count + 1;
    epc += ((*(volatile uint16_t *)epc & 0x3) == 0x3) ? 4 : 2;
    asm volatile("csrw mepc, %0" ::"r"(epc));
}

// Load from an address answered by the error slave; returns 1 if it trapped as expected
static int load_traps(volatile uint64_t *addr) {
    uint64_t count = trap_count;
    (void)*addr;
    return trap_count == count + 1 && trap_cause == MCAUSE_HW_ERROR &&
           trap_tval == (uintptr_t)addr;
}

static inline int memtile_has_dma(uint32_t tile) { return (tile == 0) || (tile == 2); }

int main(void) {
    uint64_t traps = 0;
    for (uint32_t t = 0; t < GW_L2_SPM_NUM; t++) {
        volatile uint64_t *dma = (volatile uint64_t *)(uintptr_t)GW_L2_SPM_DMA_BASE_ADDR(t);
        if (memtile_has_dma(t)) {
            // conf + status[0] of a live iDMA
            uint64_t count = trap_count;
            if (dma[0] == ERR_SLV_DATA || trap_count != count) return 200 + t;
        } else {
            if (!load_traps(&dma[0])) return 100 + t;
            // The write must complete; the load after it must trap, not hang
            dma[0] = 0x1ull;
            if (!load_traps(&dma[1])) return 100 + t;
            traps += 2;
        }
    }

    for (uint32_t t = 0; t < GW_L2_SPM_NUM; t++) {
        if (memtile_has_dma(t)) continue;
        volatile uint32_t *l2 = (volatile uint32_t *)(uintptr_t)GW_L2_SPM_BASE_ADDR(t);
        for (uint32_t i = 0; i < L2_TEST_WORDS; i++) l2[i] = 0xC0DE0000u | (t << 8) | i;
        for (uint32_t i = 0; i < L2_TEST_WORDS; i++)
            if (l2[i] != (0xC0DE0000u | (t << 8) | i)) return 300 + t;
    }

    // No other access may trap
    return trap_count == traps ? 0 : 400;
}
