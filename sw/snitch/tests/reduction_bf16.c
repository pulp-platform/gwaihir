// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// BF16 (FP16ALT) sum reduction offloaded from the NoC to the cluster DCA.
// Every cluster reduces its row into column 0, then column 0 reduces into
// cluster 0. Inputs are small integers so every partial sum is exact in BF16.

#include "snrt.h"

#define SIZE 4096
#define N_ELEMS (SIZE / sizeof(uint16_t))
#define N_ROWS 4

// Small integers are exact in BF16, which is the upper half of an FP32
static inline uint16_t bf16_from_uint(uint32_t x) {
    float f = (float)x;
    uint32_t bits;
    __builtin_memcpy(&bits, &f, sizeof(bits));
    return (uint16_t)(bits >> 16);
}

// Global variables for verification script
uint16_t output[N_ELEMS];
extern const uint32_t n_clusters = N_ROWS * gw_cluster_num_in_row();
extern const uint32_t length = N_ELEMS;

int main(void) {
    uintptr_t src = (uintptr_t)snrt_l1_alloc_cluster_local(SIZE, 4096);
    uintptr_t dst = (uintptr_t)snrt_l1_alloc_cluster_local(SIZE, 4096);

    snrt_comm_t comm;
    gw_create_mesh_comm(&comm, N_ROWS, gw_cluster_num_in_row());
    if (!comm->is_participant) return 0;

    snrt_comm_t row_comm[N_ROWS];
    for (int i = 0; i < N_ROWS; i++)
        gw_create_mesh_comm(&row_comm[i], 1, gw_cluster_num_in_row(), i, 0,
                            comm);
    snrt_comm_t col_comm;
    gw_create_mesh_comm(&col_comm, N_ROWS, 1, 0, 0, comm);

    if (snrt_is_dm_core()) {
        uint32_t row_major_cluster_idx =
            gw_cluster_col_idx() + gw_cluster_row_idx() * gw_cluster_num_in_row();
        for (uint32_t i = 0; i < N_ELEMS; i++)
            ((uint16_t *)src)[i] = bf16_from_uint(row_major_cluster_idx + i % 8);
    }
    snrt_global_barrier(comm);

    if (snrt_is_dm_core()) {
        snrt_collective_opcode_t op =
            snrt_reduction_op(SNRT_REDUCTION_SUM, SNRT_REDUCTION_FP16ALT);

        // Reduction across rows (destination: first cluster in row)
        uint32_t remote_cluster =
            gw_calculate_cluster_idx(gw_cluster_row_idx(), 0);
        uintptr_t remote_dst = (uintptr_t)snrt_remote_l1_ptr(
            (void *)dst, snrt_cluster_idx(), remote_cluster);
        snrt_dma_start_1d_reduction(remote_dst, src, SIZE,
                                    row_comm[gw_cluster_row_idx()], op);
        snrt_dma_wait_all();

        // Only one outstanding reduction per router
        snrt_inter_cluster_barrier(comm);

        // Reduction across first column (destination: cluster 0)
        if (col_comm->is_participant) {
            remote_dst = (uintptr_t)snrt_remote_l1_ptr((void *)src,
                                                       snrt_cluster_idx(), 0);
            snrt_dma_start_1d_reduction(remote_dst, dst, SIZE, col_comm, op);
            snrt_dma_wait_all();
        }
    }
    snrt_global_barrier(comm);

    // Writeback to L3
    if (snrt_is_dm_core() && snrt_cluster_idx() == 0) {
        snrt_dma_start_1d((uintptr_t)output, src, SIZE);
        snrt_dma_wait_all();
    }
    return 0;
}
