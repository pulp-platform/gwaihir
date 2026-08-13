// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

#include "axpy.h"
#include "data.h"

#define N_ROWS 4

// Number of L2 SPM tiles to distribute data across:
//   1  - all 16 clusters share a single tile (baseline, max contention)
//   4  - one tile per cluster row (4 clusters per tile)
//   8  - one tile per half-row: col 0-1 share one tile, col 2-3 share another
//        (2 clusters per tile, 8 independent AXI ports)
#define MEM_TILES 1
#define DOT_PRODUCT 0
#define READ_ONLY 0
#define ACTIVE_CLUSTERS 16

static inline uint32_t gw_active_clusters() {
    return (ACTIVE_CLUSTERS > 16) ? 16 : ACTIVE_CLUSTERS;
}

static inline uint32_t gw_cluster_rank_row_major() {
    return gw_cluster_row_idx() * N_ROWS + gw_cluster_col_idx();
}

static inline uint32_t gw_cluster_is_active() {
    return gw_cluster_rank_row_major() < gw_active_clusters();
}

int main() {
#if DOT_PRODUCT
#if MEM_TILES == 1
    axpy_args_t local_args = args;
    if (!gw_cluster_is_active()) {
        local_args.repetitions = 0;
    }
    dot_job(&local_args);
    return 0;

#elif MEM_TILES == 4
    {
        uint32_t row = gw_cluster_row_idx();
        uint32_t col = gw_cluster_col_idx();
        uint32_t cluster_active = gw_cluster_is_active();
        uint32_t n = args.n;
        uint32_t array_bytes = n * sizeof(double);

        // tile_idx 4=row0, 5=row1, 6=row2, 7=row3
        // Tiles 0-3 are occupied by the ELF, so offset into tiles 4-7.
        uint32_t tile_idx = N_ROWS + row;
        uintptr_t base = gw_l2_tile_address(tile_idx);
        uintptr_t row_x_addr = ALIGN_UP_AXI_BURST(base);
        uintptr_t row_y_addr = ALIGN_UP_AXI_BURST(row_x_addr + array_bytes);
        uintptr_t row_z_addr = ALIGN_UP_AXI_BURST(row_y_addr + array_bytes);
        if ((row_z_addr + array_bytes) > (base + GWAIHIR_ADDRMAP_L2_SPM_SIZE)) {
            return 1;
        }
        double *row_x = (double *)(row_x_addr);
        double *row_y = (double *)(row_y_addr);
        double *row_z = (double *)(row_z_addr);

        // One cluster per row (col==0) copies x and y into the row-local tile.
        if (cluster_active && snrt_is_dm_core() && col == 0) {
            snrt_dma_start_1d(row_x, args.x, array_bytes);
            snrt_dma_start_1d(row_y, args.y, array_bytes);
            snrt_dma_wait_all();
        }
        snrt_cluster_hw_barrier();
        snrt_global_sw_barrier();

        axpy_args_t local_args = args;
        local_args.x = row_x;
        local_args.y = row_y;
        local_args.z = row_z;
        if (!cluster_active) {
            local_args.repetitions = 0;
        }
        dot_job(&local_args);
        snrt_global_sw_barrier();

        // Write one reduced dot value back to the canonical output location.
        if (cluster_active && snrt_is_dm_core() && col == 0 && row == 0) {
            snrt_dma_start_1d(args.z, row_z, sizeof(double));
            snrt_dma_wait_all();
        }
        snrt_cluster_hw_barrier();
        return 0;
    }

#else
#error "For DOT_PRODUCT, MEM_TILES must be 1 or 4"
#endif

#elif READ_ONLY
#if MEM_TILES == 1
    axpy_args_t local_args = args;
    if (!gw_cluster_is_active()) {
        local_args.repetitions = 0;
    }
    read_only(&local_args);
    return 0;

#elif MEM_TILES == 4
    {
        uint32_t row = gw_cluster_row_idx();
        uint32_t col = gw_cluster_col_idx();
        uint32_t cluster_active = gw_cluster_is_active();
        uint32_t n = args.n;
        uint32_t array_bytes = n * sizeof(double);

        // tile_idx 4=row0, 5=row1, 6=row2, 7=row3
        // Tiles 0-3 are occupied by the ELF, so offset into tiles 4-7.
        uint32_t tile_idx = N_ROWS + row;
        uintptr_t base = gw_l2_tile_address(tile_idx);
        uintptr_t row_x_addr = ALIGN_UP_AXI_BURST(base);
        uintptr_t row_y_addr = ALIGN_UP_AXI_BURST(row_x_addr + array_bytes);
        uintptr_t row_z_addr = ALIGN_UP_AXI_BURST(row_y_addr + array_bytes);
        if ((row_z_addr + array_bytes) > (base + GWAIHIR_ADDRMAP_L2_SPM_SIZE)) {
            return 1;
        }
        double *row_x = (double *)(row_x_addr);
        double *row_y = (double *)(row_y_addr);
        double *row_z = (double *)(row_z_addr);

        // One cluster per row (col==0) copies x and y into the row-local tile.
        if (cluster_active && snrt_is_dm_core() && col == 0) {
            snrt_dma_start_1d(row_x, args.x, array_bytes);
            snrt_dma_start_1d(row_y, args.y, array_bytes);
            snrt_dma_wait_all();
        }
        snrt_cluster_hw_barrier();
        snrt_global_sw_barrier();

        axpy_args_t local_args = args;
        local_args.x = row_x;
        local_args.y = row_y;
        local_args.z = row_z;
        if (!cluster_active) {
            local_args.repetitions = 0;
        }
        read_only(&local_args);
        snrt_global_sw_barrier();
        return 0;
    }

#else
#error "For READ_ONLY, MEM_TILES must be 1 or 4"
#endif

#else
#if MEM_TILES == 1
        // Baseline: all clusters read from the original args.x/y in tile 0.
        // if(gw_cluster_row_idx() == 0 && (gw_cluster_col_idx() == 0) || (gw_cluster_col_idx() == 1)) {
        //     axpy_job(&args);
        // } else {
        //     // Other clusters wait for the first cluster to finish writing to args.z
        //     snrt_global_sw_barrier();
        // }
        axpy_args_t local_args = args;
        if (!gw_cluster_is_active()) {
            local_args.repetitions = 0;
        }
        axpy_job(&local_args);
        return 0;

    #elif MEM_TILES == 4
        {
            uint32_t row = gw_cluster_row_idx();
            uint32_t col = gw_cluster_col_idx();
            uint32_t cluster_active = gw_cluster_is_active();
            uint32_t n = args.n;
            uint32_t array_bytes = n * sizeof(double);

            // tile_idx 4=row0, 5=row1, 6=row2, 7=row3
            // Tiles 0-3 are occupied by the ELF, so offset into tiles 4-7.
            uint32_t tile_idx = N_ROWS + row;
            uintptr_t base = gw_l2_tile_address(tile_idx);
            uintptr_t row_x_addr = ALIGN_UP_AXI_BURST(base);
            uintptr_t row_y_addr = ALIGN_UP_AXI_BURST(row_x_addr + array_bytes);
            uintptr_t row_z_addr = ALIGN_UP_AXI_BURST(row_y_addr + array_bytes);
            if ((row_z_addr + array_bytes) > (base + GWAIHIR_ADDRMAP_L2_SPM_SIZE)) {
                return 1;
            }
            double *row_x = (double *)(row_x_addr);
            double *row_y = (double *)(row_y_addr);
            double *row_z = (double *)(row_z_addr);

            // One cluster per row (col==0) copies x and y into the row-local tile.
            if (cluster_active && snrt_is_dm_core() && col == 0) {
                snrt_dma_start_1d(row_x, args.x, array_bytes);
                snrt_dma_start_1d(row_y, args.y, array_bytes);
                snrt_dma_wait_all();
            }
            snrt_cluster_hw_barrier();
            snrt_global_sw_barrier();  // ensure col=0 DMA is done before other cols read;


            axpy_args_t local_args = args;
            local_args.x = row_x;
            local_args.y = row_y;
            local_args.z = row_z;
            if (!cluster_active) {
                local_args.repetitions = 0;
            }
            axpy_job(&local_args);
            snrt_global_sw_barrier();
            // Write z back to args.z (original location in tile 0) so the
            // verify script can read it from the ELF symbol.
            if (cluster_active && snrt_is_dm_core() && col == 0 && row == 0) {
                snrt_dma_start_1d(args.z, row_z, array_bytes);
                snrt_dma_wait_all();
            }
            snrt_cluster_hw_barrier();
            return 0;
        }

    #elif MEM_TILES == 8
        {
            uint32_t row = gw_cluster_row_idx();
            uint32_t col = gw_cluster_col_idx();
            uint32_t cluster_active = gw_cluster_is_active();
            uint32_t n = args.n;
            uint32_t array_bytes = n * sizeof(double);
            // col 0,1 → tiles 0-3 (router_left); col 2,3 → tiles 4-7 (router_right).
            // Tile 0 holds the ELF (x/y/z arrays at 0x70007000, ~800 KB total).
            // tile_idx==0: use the ELF arrays in-place (no copy, no collision).
            // tile_idx 1-7: place copies at offset 0 (3*array_bytes must fit in
            //               1 MiB, i.e. n <= 43690; for n=32768: 768 KB <= 1 MiB ✓).
            uint32_t half     = (col < 2) ? 0 : 1;
            uint32_t tile_idx = half * N_ROWS + row;

            double *row_x, *row_y, *row_z;

            if (tile_idx == 0) {
                // Tile 0 holds the ELF: x/y/z arrays are already there, reuse
                // them directly — no DMA copy needed, no collision possible.
                row_x = args.x;
                row_y = args.y;
                row_z = args.z;
            } else {
                // All other tiles are free of ELF data. Place copies at offset 0.
                // Fits as long as 3*array_bytes <= tile_size (768 KB <= 1 MiB ✓).
                uintptr_t base = gw_l2_tile_address(tile_idx);
                row_x = (double *)(base);
                row_y = (double *)(base + array_bytes);
                row_z = (double *)(base + 2 * array_bytes);

                // One cluster per tile (col 0 or col 2) loads x and y in parallel.
                if (cluster_active && snrt_is_dm_core() && (col == 0 || col == 2)) {
                    snrt_dma_start_1d(row_x, args.x, array_bytes);
                    snrt_dma_start_1d(row_y, args.y, array_bytes);
                    snrt_dma_wait_all();
                }
            }
            snrt_cluster_hw_barrier();
            snrt_global_sw_barrier();  // ensure DMAs are done before other cols read
            axpy_args_t local_args = args;
            local_args.x = row_x;
            local_args.y = row_y;
            local_args.z = row_z;
            if (!cluster_active) {
                local_args.repetitions = 0;
            }
            axpy_job(&local_args);
            snrt_global_sw_barrier();

            // Write z back to args.z for the verify script.
            // tile_idx==0: row_z already IS args.z, nothing to do.
            // tile_idx==4 (right-half row 0): write back the right-half result.
            if (cluster_active && snrt_is_dm_core() && col == 2 && row == 0) {
                snrt_dma_start_1d(args.z, row_z, array_bytes);
                snrt_dma_wait_all();
            }
            snrt_cluster_hw_barrier();
            return 0;
        }

    #else
    #error "MEM_TILES must be 1, 4, or 8"
    #endif
#endif
}