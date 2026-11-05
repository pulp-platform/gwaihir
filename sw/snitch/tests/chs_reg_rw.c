// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Cluster write + read of a Cheshire scratch register (nw_join regression). Read-back must work
// since the IOMMU is by default in bare-metal state (i.e. passthrogh: no address translation).
//
// Core 0 of every cluster performs the access, so that every cluster position in the mesh
// drives traffic towards Cheshire. The accesses are serialized through a global mutex in L3
// and each cluster writes a distinct value, so a read-back can only match if the cluster's
// own write and read reached Cheshire. All clusters share scratch[4]: scratch[0..3] are used
// by the Cheshire boot flow and there are not enough spare registers for one per cluster.

#include "snrt.h"

int main() {
    int err = 0;
    if (snrt_cluster_core_idx() == 0) {
        const uint32_t test_value = 0xc0ff0000 | snrt_cluster_idx();
        volatile uint32_t *chs_scratch =
            (volatile uint32_t *)GW_CHESHIRE_INTERNAL_CHESHIRE_REGS_SCRATCH_BASE_ADDR(4);
        snrt_mutex_acquire(snrt_mutex());
        *chs_scratch = test_value;
        err = (*chs_scratch != test_value);
        snrt_mutex_release(snrt_mutex());
    }
    return err;
}
