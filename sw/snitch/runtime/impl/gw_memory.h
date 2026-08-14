// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stddef.h>
#include <stdint.h>

// TODO(colluca): add alias to addrmap so this can be properly implemented
// Must return a pointer to the snitch_cluster_t struct
// of the cluster alias.
inline volatile snitch_cluster_t* snrt_cluster_alias() {
    return snrt_cluster();
}

// Must return a pointer to the snitch_cluster_t struct
// of the cluster selected by cluster_idx.
inline volatile snitch_cluster_t* snrt_cluster(int cluster_idx) {
#ifdef GW_HTILE_RUNTIME
    (void)cluster_idx;
    return (volatile snitch_cluster_t *)(uintptr_t)GW_HTILE_BASE_ADDR;
#else
#ifdef GW_HTILE_BASE_ADDR
    if (cluster_idx == SNRT_CLUSTER_NUM) {
        return (volatile snitch_cluster_t *)(uintptr_t)GW_HTILE_BASE_ADDR;
    }
#endif
    return &(gwaihir_addrmap_32b.cluster[cluster_idx]);
#endif
}
// Must return a pointer to the snitch_cluster_t struct
// of the cluster invoking the function.
inline volatile snitch_cluster_t* snrt_cluster() {
    return snrt_cluster(snrt_cluster_idx());
}
