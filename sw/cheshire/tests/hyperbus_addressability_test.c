// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// HyperBus addressability in every PHY layout, in both LLC out windows. Never touches LPDDR.
// Overwrites what it probes, run from SPM.

#include "addressability.h"

static const struct {
    const char *name;
    hyper_layout_t layout;
} hyper_layouts[] = {
    {"dual-PHY", HYPER_DUAL_PHY},
    {"single-PHY0", HYPER_SINGLE_PHY0},
    {"single-PHY1", HYPER_SINGLE_PHY1},
};

#define NUM_HYPER_LAYOUTS ((int)(sizeof(hyper_layouts) / sizeof(hyper_layouts[0])))

static int run_hyper_case(int idx, uintptr_t base, bool shared) {
    uintptr_t from, to;
    // Map the chips before routing the shared window to HyperBus
    if (hyper_set_layout(hyper_layouts[idx].layout, base, &from, &to))
        return report("HyperBus", hyper_layouts[idx].name, base, base + HYPER_SPAN, 1);
    if (llc_route_shared(shared))
        return report("HyperBus", hyper_layouts[idx].name, from, to, 1);
    int err = probe_wrwr(from, to, PROBE_SEED);
    err |= probe_wwrr(from, to, ~PROBE_SEED);
    return report("HyperBus", hyper_layouts[idx].name, from, to, err);
}

int main(void) {
    int errors = llc_addr_init();

    for (int i = 0; i < NUM_HYPER_LAYOUTS; ++i)
        errors += run_hyper_case(i, LLC_EXCL_BASE, false);

    for (int i = 0; i < NUM_HYPER_LAYOUTS; ++i)
        errors += run_hyper_case(i, LLC_SHARED_BASE, true);

    errors += llc_addr_restore();

    return errors;
}
