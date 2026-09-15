// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Cluster write + read of a Cheshire scratch register (nw_join regression). Read-back value is
// intentionally unchecked: cluster accesses to Cheshire regs go through Cheshire's IOMMU, which
// resets with translation off and faults every transaction until configured. Nothing configures
// it yet, so reads currently come back as a fixed poison value. Fix: program the IOMMU (e.g.
// ddtp = Bare/pass-through) during boot, before cluster code runs.

#include "snrt.h"

int main() {
    if (snrt_global_core_idx() == 0) {
        volatile uint32_t *chs_scratch =
            (volatile uint32_t *)GW_CHESHIRE_INTERNAL_CHESHIRE_REGS_SCRATCH_BASE_ADDR(4);
        *chs_scratch = 0x00c0ffee;
        uint32_t v = *chs_scratch;
        (void)v;
    }
    return 0;
}
