// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stddef.h>
#include <stdint.h>

// The H tile takes the cluster slot after the cluster array.
#define GW_HTILE_CLUSTER_IDX SNRT_CLUSTER_NUM

inline volatile htile_t* gw_htile() {
    return &(gwaihir_addrmap_32b.htile);
}

inline volatile snitch_cluster__stride40000_t* gw_cluster(int cluster_idx) {
    return &(gwaihir_addrmap_32b.cluster[cluster_idx]);
}

// TODO(colluca): add alias to addrmap so this can be properly implemented
// Must return a pointer to the snitch_cluster_t struct
// of the cluster alias.
inline volatile snitch_cluster_t* snrt_cluster_alias() {
    return snrt_cluster();
}

// Must return a pointer to the snitch_cluster_t struct
// of the cluster selected by cluster_idx.
inline volatile snitch_cluster_t* snrt_cluster(int cluster_idx) {
    return (volatile snitch_cluster_t*)&(gwaihir_addrmap_32b.cluster[cluster_idx]);
}

// Must return a pointer to the snitch_cluster_t struct
// of the cluster invoking the function.
inline volatile snitch_cluster_t* snrt_cluster() {
#ifdef GW_HTILE_RUNTIME
    return gw_htile();
#else
    return gw_cluster(snrt_cluster_idx());
#endif
}
