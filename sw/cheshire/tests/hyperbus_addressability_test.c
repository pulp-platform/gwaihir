// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// LLC out addressability: HyperBus via [0x7000_0000, 0x8000_0000), LPDDR and HyperBus via
// [0x8000_0000, 0x1_0000_0000), and isolation between the two. Overwrites both, run from SPM.

#include <stdbool.h>
#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"
#include "printf.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"

// Errors always print; VERBOSE also prints passes. Returns the number of failed cases.
#ifdef VERBOSE
#define LOG(...) printf(__VA_ARGS__)
#else
#define LOG(...) do { if (0) printf(__VA_ARGS__); } while (0)
#endif

// Stride between probed addresses
#ifndef PROBE_STRIDE
#define PROBE_STRIDE 0x80000
#endif
_Static_assert(PROBE_STRIDE > 0 && PROBE_STRIDE % 8 == 0, "PROBE_STRIDE must be a multiple of 8");

// LFSR seed and 64-bit feedback polynomial
#ifndef PROBE_SEED
#define PROBE_SEED 0xCACA5A5ADEADBEEF
#endif
#define LFSR_FEEDBACK 0x6C0000397F000032

// HyperBus IP config registers, not in the RDL map
#define HYPER_CFG_BASE             0x18004000
#define HYPER_CFG_PHYS_IN_USE      0x20
#define HYPER_CFG_WHICH_PHY        0x24
#define HYPER_CFG_CHIP_START(chip) (0x38 + 8 * (chip))
#define HYPER_CFG_CHIP_END(chip)   (0x3C + 8 * (chip))

// Two PHYs, two 8 MiB S27KS0641 each
#define HYPER_NUM_CHIPS 2
#define HYPER_CHIP_SIZE 0x800000
#define HYPER_SPAN      (2 * HYPER_NUM_CHIPS * HYPER_CHIP_SIZE)

#define LLC_EXCL_BASE   0x70000000
#define LLC_SHARED_BASE 0x80000000
#define LLC_SHARED_END  0x100000000

typedef enum { HYPER_DUAL_PHY, HYPER_SINGLE_PHY0, HYPER_SINGLE_PHY1 } hyper_layout_t;

static const struct {
    const char *name;
    hyper_layout_t layout;
} hyper_layouts[] = {
    {"dual-PHY", HYPER_DUAL_PHY},
    {"single-PHY0", HYPER_SINGLE_PHY0},
    {"single-PHY1", HYPER_SINGLE_PHY1},
};

static uint64_t lfsr_next(uint64_t lfsr) {
    for (int i = 0; i < 64; ++i)
        lfsr = (lfsr & 1) ? ((lfsr >> 1) ^ LFSR_FEEDBACK) : (lfsr >> 1);
    return lfsr;
}

static void pattern_write(uintptr_t from, uintptr_t to, uint64_t seed) {
    uint64_t lfsr = seed;
    for (uintptr_t addr = from; addr < to; addr += PROBE_STRIDE) {
        lfsr = lfsr_next(lfsr);
        *(volatile uint64_t *)addr = lfsr;
    }
    fence();
}

static int pattern_check(uintptr_t from, uintptr_t to, uint64_t seed) {
    uint64_t lfsr = seed;
    for (uintptr_t addr = from; addr < to; addr += PROBE_STRIDE) {
        lfsr = lfsr_next(lfsr);
        uint64_t r = *(volatile uint64_t *)addr;
        if (r != lfsr) {
            printf("[ERROR] addr=0x%lx exp=0x%016lx read=0x%016lx\n", addr, lfsr, r);
            return 1;
        }
    }
    return 0;
}

// Write and read back each location
static int probe_wrwr(uintptr_t from, uintptr_t to, uint64_t seed) {
    uint64_t lfsr = seed;
    for (uintptr_t addr = from; addr < to; addr += PROBE_STRIDE) {
        lfsr = lfsr_next(lfsr);
        *(volatile uint64_t *)addr = lfsr;
        fence();
        uint64_t r = *(volatile uint64_t *)addr;
        if (r != lfsr) {
            printf("[ERROR] addr=0x%lx wrote=0x%016lx read=0x%016lx\n", addr, lfsr, r);
            return 1;
        }
    }
    return 0;
}

// Write all, then read all. Use a different seed than a prior probe_wrwr on the same range.
static int probe_wwrr(uintptr_t from, uintptr_t to, uint64_t seed) {
    pattern_write(from, to, seed);
    return pattern_check(from, to, seed);
}

static int report(const char *mem, const char *layout, uintptr_t from, uintptr_t to, int err) {
    if (err)
        printf("[FAIL] %s %s [0x%lx, 0x%lx)\n", mem, layout, from, to);
    else
        LOG("[PASS] %s %s [0x%lx, 0x%lx)\n", mem, layout, from, to);
    return err;
}

// Route the shared window; switch only while idle. Raw address, as member access through the
// null-based gwaihir_addrmap_64b accessor is UB and GCC emits a trap.
static void llc_route_shared(bool to_hyper) {
    volatile gw_hyperbus_regs__shared_t *shared =
        (volatile gw_hyperbus_regs__shared_t *)(uintptr_t)GW_CHESHIRE_INTERNAL_GW_HYPERBUS_REGS_SHARED_BASE_ADDR;
    fence();
    shared->f.to_hyper = to_hyper;
    fence();
}

// HyperRAM clock targets by preference and tolerance; S27KS0641 is rated for 166 MHz max
static const uint64_t hyper_ck_targets_hz[] = {166000000, 100000000};
#define HYPER_CK_TOL_ABOVE_PCT 2
#define HYPER_CK_TOL_BELOW_PCT 10

// HyperRAM clock is soc_freq / (2 * div): the PHY halves the divided clock
static int hyper_set_clk_div(uint64_t soc_freq) {
    volatile gw_hyperbus_regs__clk_div_t *clk_div =
        (volatile gw_hyperbus_regs__clk_div_t *)(uintptr_t)GW_CHESHIRE_INTERNAL_GW_HYPERBUS_REGS_CLK_DIV_BASE_ADDR;
    int num_targets = sizeof(hyper_ck_targets_hz) / sizeof(hyper_ck_targets_hz[0]);

    for (int i = 0; i < num_targets; ++i) {
        uint64_t target = hyper_ck_targets_hz[i];
        // Nearest integer divider
        uint64_t div = (soc_freq + target) / (2 * target);
        if (div < 1)
            div = 1;
        if (div > GW_HYPERBUS_REGS__CLK_DIV__VALUE_bm)
            continue;
        uint64_t ck = soc_freq / (2 * div);
        if (ck * 100 > target * (100 + HYPER_CK_TOL_ABOVE_PCT) ||
            ck * 100 < target * (100 - HYPER_CK_TOL_BELOW_PCT))
            continue;
        // Value and valid pulse in one write
        clk_div->w = (div << GW_HYPERBUS_REGS__CLK_DIV__VALUE_bp) | GW_HYPERBUS_REGS__CLK_DIV__VALID_bm;
        LOG("[INFO] SoC clock %lu Hz, HyperBus divider %lu, HyperRAM clock %lu Hz\n", soc_freq, div,
            ck);
        return 0;
    }

    printf("[ERROR] No HyperBus clock divider reaches a HyperRAM clock target from %lu Hz\n",
           soc_freq);
    return 1;
}

// Set PHY mode and chip ranges at base, return the covered range. In dual-PHY mode, a chip range
// spans one chip per PHY.
static int hyper_set_layout(hyper_layout_t layout, uintptr_t base, uintptr_t *from,
                            uintptr_t *to) {
    void *cfg = (void *)HYPER_CFG_BASE;
    bool dual = (layout == HYPER_DUAL_PHY);
    uint32_t chip_span = dual ? 2 * HYPER_CHIP_SIZE : HYPER_CHIP_SIZE;
    uint32_t start = base + (layout == HYPER_SINGLE_PHY1 ? HYPER_SPAN / 2 : 0);

    *reg32(cfg, HYPER_CFG_PHYS_IN_USE) = dual;
    *reg32(cfg, HYPER_CFG_WHICH_PHY) = (layout == HYPER_SINGLE_PHY1);
    if (*reg32(cfg, HYPER_CFG_PHYS_IN_USE) != dual ||
        *reg32(cfg, HYPER_CFG_WHICH_PHY) != (layout == HYPER_SINGLE_PHY1)) {
        printf("[ERROR] HyperBus PHY configuration mismatch\n");
        return 1;
    }

    for (int c = 0; c < HYPER_NUM_CHIPS; ++c) {
        uint32_t s = start + c * chip_span;
        uint32_t e = s + chip_span;
        // Keep start <= end across writes
        *reg32(cfg, HYPER_CFG_CHIP_START(c)) = 0;
        *reg32(cfg, HYPER_CFG_CHIP_END(c)) = e;
        *reg32(cfg, HYPER_CFG_CHIP_START(c)) = s;
        if (*reg32(cfg, HYPER_CFG_CHIP_START(c)) != s || *reg32(cfg, HYPER_CFG_CHIP_END(c)) != e) {
            printf("[ERROR] HyperBus chip %d range mismatch\n", c);
            return 1;
        }
    }

    *from = start;
    *to = start + HYPER_NUM_CHIPS * chip_span;
    return 0;
}

static int run_hyper_case(int idx, uintptr_t base, bool shared) {
    uintptr_t from, to;
    // Map the chips before routing the shared window to HyperBus
    if (hyper_set_layout(hyper_layouts[idx].layout, base, &from, &to))
        return report("HyperBus", hyper_layouts[idx].name, base, base + HYPER_SPAN, 1);
    llc_route_shared(shared);
    int err = probe_wrwr(from, to, PROBE_SEED);
    err |= probe_wwrr(from, to, ~PROBE_SEED);
    return report("HyperBus", hyper_layouts[idx].name, from, to, err);
}

static int run_lpddr_case(uintptr_t from, uintptr_t to) {
    llc_route_shared(false);
    int err = probe_wrwr(from, to, PROBE_SEED);
    err |= probe_wwrr(from, to, ~PROBE_SEED);
    return report("LPDDR", "shared", from, to, err);
}

// Different patterns to LPDDR and HyperBus at the same addresses; each must keep its own
static int run_isolation_case(void) {
    uintptr_t from, to;
    if (hyper_set_layout(HYPER_DUAL_PHY, LLC_SHARED_BASE, &from, &to))
        return report("LPDDR/HyperBus", "isolation", LLC_SHARED_BASE, LLC_SHARED_BASE, 1);

    llc_route_shared(false);
    pattern_write(from, to, PROBE_SEED);
    llc_route_shared(true);
    pattern_write(from, to, ~PROBE_SEED);

    llc_route_shared(false);
    int err = pattern_check(from, to, PROBE_SEED);
    llc_route_shared(true);
    err |= pattern_check(from, to, ~PROBE_SEED);
    return report("LPDDR/HyperBus", "isolation", from, to, err);
}

int main(void) {
    uint32_t rtc_freq = CHS_REGS->rtc_freq.f.ref_freq;
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__uart_base_addr__, reset_freq, __BOOT_BAUDRATE);

    // Before any HyperBus access; keeps the reset divider on failure
    int errors = hyper_set_clk_div(reset_freq);
    int num_layouts = sizeof(hyper_layouts) / sizeof(hyper_layouts[0]);

    for (int i = 0; i < num_layouts; ++i)
        errors += run_hyper_case(i, LLC_EXCL_BASE, false);

    errors += run_lpddr_case(LLC_SHARED_BASE, LLC_SHARED_BASE + HYPER_SPAN);
    errors += run_lpddr_case(LLC_SHARED_END - HYPER_SPAN, LLC_SHARED_END);

    for (int i = 0; i < num_layouts; ++i)
        errors += run_hyper_case(i, LLC_SHARED_BASE, true);

    errors += run_isolation_case();

    // Restore reset routing and chip ranges
    uintptr_t from, to;
    llc_route_shared(false);
    errors += hyper_set_layout(HYPER_DUAL_PHY, LLC_EXCL_BASE, &from, &to);

    return errors;
}
