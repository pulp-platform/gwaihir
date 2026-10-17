// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Luca Colagrande <colluca@iis.ee.ethz.ch>
// Author: Pius Sieber <psieber@iis.ee.ethz.ch>

// Settings
//#define RUN_ON_SINGLE_CLUSTER
#define RUN_ON_SINGLE_CORE


#ifdef RUN_ON_SINGLE_CORE // Single core also requires only a single cluster
    #define RUN_ON_SINGLE_CLUSTER
#endif

#include <stdint.h>

#include "data.h"

#include "bfs.h"

int main() {
    bfs_args_t args = {
        .num_vertices = num_vertices,
        .load_graph = 1,
        .graph_offsets_addr = (uint64_t)offsets,
        .graph_adjacencies_addr = (uint64_t)adjacencies,
        .frontier_addr = (uint64_t)frontier,
        .dist_addr = (uint64_t)dist,
        .out_frontier_addr = (uint64_t)out_frontier,
        .out_dist_addr = (uint64_t)out_dist
    };
    snrt_global_barrier();
    snrt_mcycle();
    #ifdef RUN_ON_SINGLE_CLUSTER
        if (snrt_cluster_idx() == 0) { // only run on cluster 0 for this test
            #ifdef RUN_ON_SINGLE_CORE
                if((snrt_cluster_core_idx() == 0) || (snrt_cluster_core_idx() == 8)) { // only run on single core and dma
                    bfs_job(&args);
                }else{
                    snrt_cluster_hw_barrier();
                    snrt_cluster_hw_barrier();
                    snrt_cluster_hw_barrier();
                    snrt_global_barrier();
                    snrt_cluster_hw_barrier();
                    snrt_cluster_hw_barrier();
                    snrt_global_barrier();
                    snrt_cluster_hw_barrier();
                }
            #else
                bfs_job(&args);
            #endif
        }else{
            snrt_global_barrier();
            snrt_global_barrier();
        }
    #else
        bfs_job(&args);
    #endif
    return 0;
}
