// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Luca Colagrande <colluca@iis.ee.ethz.ch>

#pragma once
#include <stdint.h>

typedef struct {
    uint32_t num_vertices;
    uint32_t load_graph;
    uint64_t graph_offsets_addr;
    uint64_t graph_adjacencies_addr;
    uint64_t frontier_addr;
    uint64_t dist_addr;
    uint64_t out_frontier_addr;
    uint64_t out_dist_addr;
} bfs_args_t;
