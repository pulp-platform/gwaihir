// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// LPDDR addressability in the shared LLC out window, and isolation from HyperBus at the same
// addresses. Needs a brought-up LPDDR. Overwrites what it probes, run from SPM.

#include "addressability.h"

static int run_lpddr_case(uintptr_t from, uintptr_t to) {
    if (llc_route_shared(false))
        return report("LPDDR", "shared", from, to, 1);
    int err = probe_wrwr(from, to, PROBE_SEED);
    err |= probe_wwrr(from, to, ~PROBE_SEED);
    return report("LPDDR", "shared", from, to, err);
}

// Different patterns to LPDDR and HyperBus at the same addresses; each must keep its own
static int run_isolation_case(void) {
    uintptr_t from, to;
    if (hyper_set_layout(HYPER_DUAL_PHY, LLC_SHARED_BASE, &from, &to))
        return report("LPDDR/HyperBus", "isolation", LLC_SHARED_BASE, LLC_SHARED_BASE, 1);

    // Read back before each switch: drains posted writes, which fence() alone does not
    if (llc_route_shared(false))
        return report("LPDDR/HyperBus", "isolation", from, to, 1);
    int err = probe_wwrr(from, to, PROBE_SEED);

    if (llc_route_shared(true))
        return report("LPDDR/HyperBus", "isolation", from, to, 1);
    err |= probe_wwrr(from, to, ~PROBE_SEED);

    if (llc_route_shared(false))
        return report("LPDDR/HyperBus", "isolation", from, to, 1);
    err |= pattern_check(from, to, PROBE_SEED);

    if (llc_route_shared(true))
        return report("LPDDR/HyperBus", "isolation", from, to, 1);
    err |= pattern_check(from, to, ~PROBE_SEED);

    return report("LPDDR/HyperBus", "isolation", from, to, err);
}

int main(void) {
    int errors = llc_addr_init();

    errors += run_lpddr_case(LLC_SHARED_BASE, LLC_SHARED_BASE + HYPER_SPAN);
    errors += run_lpddr_case(LLC_SHARED_END - HYPER_SPAN, LLC_SHARED_END);

    errors += run_isolation_case();

    errors += llc_addr_restore();

    return errors;
}
