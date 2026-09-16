// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Cluster write + read of a Cheshire scratch register (nw_join regression). Read-back must work
// since the IOMMU is by default in bare-metal state (i.e. passthrogh: no address translation).

#include "snrt.h"

int main() {
    int err = 0;
    if (snrt_global_core_idx() == 0) {
        const uint32_t test_value = 0x00c0ffee;
        volatile uint32_t *chs_scratch =
            (volatile uint32_t *)GW_CHESHIRE_INTERNAL_CHESHIRE_REGS_SCRATCH_BASE_ADDR(4);
        *chs_scratch = test_value;
        err = (*chs_scratch != test_value);
    }
    return err;
}
