// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Luca Colagrande <colluca@iis.ee.ethz.ch>

#include "gemv.h"

#include "data.h"
#include "snrt.h"

#define N_ROWS 4
#define ACTIVE_CLUSTERS 16
#define ACTIVE_COMPUTE_CORES 8
#define DOUBLE_BUFFER 1

#define BANK_ALIGNMENT 8
#define TCDM_ALIGNMENT (24 * BANK_ALIGNMENT)
#define AXI_BURST_ALIGNMENT 4096
#define ALIGN_NEXT_FROM_BASE(addr, base, size) \
    (((((addr) - (base)) + (size)-1) / (size)) * (size) + (base))
#define ALIGN_UP_TCDM(addr) \
    ALIGN_NEXT_FROM_BASE(addr, SNRT_TCDM_START_ADDR, TCDM_ALIGNMENT)
#define ALIGN_UP_AXI_BURST(addr) ALIGN_NEXT_FROM_BASE(addr, 0, AXI_BURST_ALIGNMENT)

static inline uint32_t gw_active_clusters() {
    return (ACTIVE_CLUSTERS > 16) ? 16 : ACTIVE_CLUSTERS;
}

static inline uint32_t gw_cluster_rank_row_major() {
    return gw_cluster_row_idx() * N_ROWS + gw_cluster_col_idx();
}

static inline uint32_t gw_cluster_is_active() {
    return gw_cluster_rank_row_major() < gw_active_clusters();
}

static inline uint32_t gw_active_compute_cores() {
    uint32_t n_compute = snrt_cluster_compute_core_num();
    return (ACTIVE_COMPUTE_CORES > n_compute) ? n_compute : ACTIVE_COMPUTE_CORES;
}

static inline uint32_t gw_compute_core_is_active() {
    if (!snrt_is_compute_core()) {
        return 0;
    }
    return snrt_cluster_core_idx() < gw_active_compute_cores();
}

int main() {
    uint32_t trans = args.trans;
    uint32_t m = args.m;
    uint32_t n = args.n;
    uint32_t repetitions = args.repetitions;
    double alpha = args.alpha;
    double *a = args.a;
    double *x = args.x;
    double *y = args.y;

    uint32_t size_a = m * n * sizeof(double);
    uint32_t size_x = n * sizeof(double);
    uint32_t size_y = m * sizeof(double);

    uint32_t cluster_active = gw_cluster_is_active();
    uint32_t iterations, i, i_dma_in, i_compute, i_dma_out, buff_idx;
    uint32_t start_cycle = 0;
    uint32_t end_cycle = 0;
    uint32_t loop_cycles = 0;
    uint64_t local_a_addr[2] = {0, 0};
    uint64_t local_x_addr[2] = {0, 0};
    uint64_t local_y_addr[2] = {0, 0};
    uint64_t local_a_addr_fallback[2] = {0, 0};
    uint64_t local_x_addr_fallback[2] = {0, 0};
    uint64_t local_y_addr_fallback[2] = {0, 0};
    uint32_t used_fallback_layout = 0;
    double *local_a[2] = {(double *)0, (double *)0};
    double *local_x[2] = {(double *)0, (double *)0};
    double *local_y[2] = {(double *)0, (double *)0};

    if (cluster_active) {
        uint64_t l1_base = (uint64_t)snrt_l1_next();

        // Preferred layout: 4KB-align DMA destinations to reduce burst splits.
        local_a_addr[0] = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(l1_base));
        local_x_addr[0] = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_a_addr[0] + size_a));
        local_y_addr[0] = ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_x_addr[0] + size_x));
        if (DOUBLE_BUFFER) {
            local_a_addr[1] =
                ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_y_addr[0] + size_y));
            local_x_addr[1] =
                ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_a_addr[1] + size_a));
            local_y_addr[1] =
                ALIGN_UP_AXI_BURST(ALIGN_UP_TCDM(local_x_addr[1] + size_x));
        }

        // Fallback layout: TCDM alignment only.
        local_a_addr_fallback[0] = ALIGN_UP_TCDM(l1_base);
        local_x_addr_fallback[0] =
            ALIGN_UP_TCDM(local_a_addr_fallback[0] + size_a);
        local_y_addr_fallback[0] =
            ALIGN_UP_TCDM(local_x_addr_fallback[0] + size_x);
        if (DOUBLE_BUFFER) {
            local_a_addr_fallback[1] =
                ALIGN_UP_TCDM(local_y_addr_fallback[0] + size_y);
            local_x_addr_fallback[1] =
                ALIGN_UP_TCDM(local_a_addr_fallback[1] + size_a);
            local_y_addr_fallback[1] =
                ALIGN_UP_TCDM(local_x_addr_fallback[1] + size_x);
        }

        {
            uint64_t tcdm_start =
                (l1_base / (uint64_t)SNRT_TCDM_SIZE) * (uint64_t)SNRT_TCDM_SIZE;
            uint64_t tcdm_end = tcdm_start + (uint64_t)SNRT_TCDM_SIZE;
            uint64_t highest_addr =
                DOUBLE_BUFFER ? (local_y_addr[1] + size_y) : (local_y_addr[0] + size_y);
            if (highest_addr > tcdm_end) {
                used_fallback_layout = 1;
                local_a_addr[0] = local_a_addr_fallback[0];
                local_x_addr[0] = local_x_addr_fallback[0];
                local_y_addr[0] = local_y_addr_fallback[0];
                if (DOUBLE_BUFFER) {
                    local_a_addr[1] = local_a_addr_fallback[1];
                    local_x_addr[1] = local_x_addr_fallback[1];
                    local_y_addr[1] = local_y_addr_fallback[1];
                }
                highest_addr = DOUBLE_BUFFER ? (local_y_addr[1] + size_y)
                                             : (local_y_addr[0] + size_y);
                if (highest_addr > tcdm_end) {
                    return 1;
                }
            }
        }

        local_a[0] = (double *)local_a_addr[0];
        local_x[0] = (double *)local_x_addr[0];
        local_y[0] = (double *)local_y_addr[0];
        if (DOUBLE_BUFFER) {
            local_a[1] = (double *)local_a_addr[1];
            local_x[1] = (double *)local_x_addr[1];
            local_y[1] = (double *)local_y_addr[1];
        }
        if (snrt_cluster_core_idx() == 0 && used_fallback_layout) {
            DUMP(used_fallback_layout);
        }
        if (snrt_cluster_core_idx() == 0) {
            DUMP(local_a_addr[0]);
            DUMP(local_x_addr[0]);
            DUMP(local_y_addr[0]);
            DUMP(local_a_addr[1]);
            DUMP(local_x_addr[1]);
            DUMP(local_y_addr[1]);
        }
    }

    // Align start across clusters before any timed work.
    snrt_global_sw_barrier();

    // AXPY-style scheduling: load next, compute current, store previous.
    iterations = repetitions;
    if (DOUBLE_BUFFER) iterations += 2;

    // Match AXPY-style timing: DMA core reports cycles for the repeated loop.
    if (cluster_active && snrt_is_dm_core()) {
        start_cycle = snrt_mcycle();
    }

    for (i = 0; i < iterations; ++i) {
        if (cluster_active && snrt_is_dm_core()) {
            // DMA in
            if (!DOUBLE_BUFFER || (i < repetitions)) {
                i_dma_in = i;
                buff_idx = DOUBLE_BUFFER ? i_dma_in % 2 : 0;
                snrt_dma_start_1d(local_a[buff_idx], a, size_a);
                snrt_dma_start_1d(local_x[buff_idx], x, size_x);
                snrt_dma_wait_all();
            }

            // Additional barriers required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            // DMA out
            if (!DOUBLE_BUFFER || (i > 1)) {
                i_dma_out = DOUBLE_BUFFER ? i - 2 : i;
                buff_idx = DOUBLE_BUFFER ? i_dma_out % 2 : 0;
                snrt_dma_start_1d(y, local_y[buff_idx], size_y);
                snrt_dma_wait_all();
            }
        }

        if (cluster_active && gw_compute_core_is_active()) {
            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();

            if (!DOUBLE_BUFFER || (i > 0 && i < (repetitions + 1))) {
                i_compute = DOUBLE_BUFFER ? i - 1 : i;
                buff_idx = DOUBLE_BUFFER ? i_compute % 2 : 0;
                gemv(trans, m, n, alpha, local_a[buff_idx], local_x[buff_idx],
                     1, local_y[buff_idx]);
            }

            // Additional barrier required when not double buffering
            if (!DOUBLE_BUFFER) snrt_cluster_hw_barrier();
        }

        snrt_cluster_hw_barrier();
    }

    if (cluster_active && snrt_is_dm_core()) {
        end_cycle = snrt_mcycle();
        loop_cycles = end_cycle - start_cycle;
        DUMP(loop_cycles);
    }

    snrt_global_sw_barrier();

    return 0;
}
