// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// A cluster core reads a Cheshire SoC scratch register. Regression for the nw_join ID width:
// with a truncated mux select the response was routed to the wide branch and the load never returned.

#include "snrt.h"

int main() {
    if (snrt_global_core_idx() == 0) {
        volatile uint32_t *chs_scratch =
            (volatile uint32_t *)GW_CHESHIRE_INTERNAL_CHESHIRE_REGS_SCRATCH_BASE_ADDR(4);
        uint32_t v = *chs_scratch;
        (void)v;
    }
    return 0;
}
