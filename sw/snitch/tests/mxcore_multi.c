// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Jayanth Jonnalagadda <jjonnalagadd@iis.ee.ethz.ch>

#include "snrt.h"

#define PRELOAD 0 // PRELOAD Enable/Disable
#define TIMING  0 // TIMING Enable/Disable

#if PRELOAD
#include "data/mxcore_multi_preload_data.h"
#else
#include "data/mxcore_multi_data.h"
#endif
#include "gw_hwpe_subsystem_addrmap.h"

#include <stdio.h>
#include <stdint.h>

// MXCore Configuration
#define VS      32
#define MXU     32
#define OBuff   64
#define BW      512

// Per-Cluster Input Matrices Configuration
// Global logical GEMM is M=256, K=64, N=256 (PRELOAD: N=128), decomposed into a 4x4 grid of
// 64x64x64 (PRELOAD: 64x64x32) tiles (K stays untiled, so no partial-tile reduction across
// clusters is needed): one tile per cluster, on a 4x4 = 16 cluster mesh.
#if PRELOAD
#define M       64
#define K       64
#define N       32
#else
#define M       64
#define K       64
#define N       64
#endif

// MX Parameters
#define BLOCK_SIZE      32
#define QUANTIZE_OUTPUT 1
#define SRC_WIDTH       8
#define DST_WIDTH       32
#define SCALE_WIDTH     8

#if TIMING
#define TIMING_ROWS       NUM_CLUSTERS
#define TIMING_COLS       7
#define TS_DMA_IN_START   0
#define TS_DMA_IN_END     1
#define TS_SUBMIT         2
#define TS_TRIGGER        3
#define TS_DONE           4
#define TS_DMA_OUT_START  5
#define TS_DMA_OUT_END    6

#define TIMING_INFO_LEN   10

uint32_t mxcore_timing[TIMING_ROWS][TIMING_COLS];
uint32_t mxcore_timing_info[TIMING_INFO_LEN];
#endif

#define HWPE_ADDR_BASE GW_HWPE_BASE_ADDR(snrt_cluster_alias())
#define MXCORE_TRIGGER 0x00
#define MXCORE_ACQUIRE 0x04
#define MXCORE_STATUS 0x0C
#define MXCORE_SOFT_CLEAR 0x14
#define MXCORE_EVT_OFFS GW_HWPE_EVT_CLR_OFFS
#define MXCORE_CK_GATE_OFFS GW_HWPE_CLK_EN_OFFS
#define HWPE_MXIP_ADDR (HWPE_ADDR_BASE + MXCORE_EVT_OFFS)
#define HWPE_WRITE(value, offset) *(volatile int *)(HWPE_ADDR_BASE + offset) = value
#define HWPE_READ(offset) *(volatile int *)(HWPE_ADDR_BASE + offset)

void mxcore_cfg (unsigned int vector_a_ptr, unsigned int vectors_b_ptr, unsigned int scale_a_ptr, unsigned int scale_b_ptr, unsigned int preload_bias_ptr, unsigned int result_ptr, unsigned int result_scale_ptr, uint32_t gemm_size, uint32_t engine_ctrl_reg, uint32_t tile_counts, uint32_t a_tile_size, uint32_t b_tile_size, uint32_t preload_tile_size, uint32_t result_tile_size, uint32_t result_scale_tile_size, uint32_t iter_count) {
  HWPE_WRITE(vector_a_ptr,            0x20);
  HWPE_WRITE(vectors_b_ptr,           0x24);
  HWPE_WRITE(scale_a_ptr,             0x28);
  HWPE_WRITE(scale_b_ptr,             0x2C);
  HWPE_WRITE(preload_bias_ptr,        0x30);
  HWPE_WRITE(result_ptr,              0x34);
  HWPE_WRITE(result_scale_ptr,        0x38);
  HWPE_WRITE(gemm_size,               0x3C);
  HWPE_WRITE(engine_ctrl_reg,         0x40);
  HWPE_WRITE(tile_counts,             0x44);
  HWPE_WRITE(a_tile_size,             0x48);
  HWPE_WRITE(b_tile_size,             0x4C);
  HWPE_WRITE(preload_tile_size,       0x50);
  HWPE_WRITE(result_tile_size,        0x54);
  HWPE_WRITE(result_scale_tile_size,  0x58);
  HWPE_WRITE(iter_count,              0x5C);
}

static inline void hwpe_trigger_job() { HWPE_WRITE(0, MXCORE_TRIGGER); }

static inline int hwpe_acquire_job() { return HWPE_READ(MXCORE_ACQUIRE); }

static inline unsigned int hwpe_get_status() { return HWPE_READ(MXCORE_STATUS); }

static inline void hwpe_soft_clear() { HWPE_WRITE(0, MXCORE_SOFT_CLEAR); }

static inline void mxcore_cg_enable() { HWPE_WRITE(GW_HWPE_CLK_EN_ACC, MXCORE_CK_GATE_OFFS); }

static inline void mxcore_cg_disable() { HWPE_WRITE(0, MXCORE_CK_GATE_OFFS); }

inline void snrt_hwpe_clr_mxip(uint32_t core_idx) {
    * (volatile uint32_t*)HWPE_MXIP_ADDR = (1 << core_idx);
}

#if TIMING
static inline void mxcore_timestamp(uint32_t *ts, uint32_t row, uint32_t col) {
    if (row < TIMING_ROWS) ts[row * TIMING_COLS + col] = snrt_mcycle();
}

static inline void mxcore_timing_init(uint32_t *ts) {
    const uint32_t info[TIMING_INFO_LEN] = {TIMING_ROWS, TIMING_COLS, M, K, N, VS, MXU, OBuff, PRELOAD, 0};
    for (uint32_t i = 0; i < TIMING_INFO_LEN; i++) ts[TIMING_ROWS * TIMING_COLS + i] = info[i];
}

static inline void mxcore_timing_store(uint32_t *ts, uint32_t first_row, uint32_t num_rows) {
    snrt_dma_start_1d(&mxcore_timing[first_row][0], &ts[first_row * TIMING_COLS], num_rows * TIMING_COLS * sizeof(uint32_t));
    if (snrt_cluster_idx() == 0)
        snrt_dma_start_1d(mxcore_timing_info, &ts[TIMING_ROWS * TIMING_COLS], TIMING_INFO_LEN * sizeof(uint32_t));
    snrt_dma_wait_all();
}

#define MXCORE_TIMESTAMP(row, col) mxcore_timestamp(ts, row, col)
#else
#define MXCORE_TIMESTAMP(row, col)
#endif

int main() {
    void *local_a, *local_b, *local_scale_a, *local_scale_b, *local_result, *local_result_scale;

    uint32_t core_idx = snrt_cluster_core_idx();
    uint32_t cluster_idx = snrt_cluster_idx();

    // Clear Interrupt from Host
    snrt_int_clr_mcip();

    // Size Parameters
    uint32_t NBYTES_VEC = sizeof(int8_t);
    uint32_t NBYTES_SCALE = sizeof(uint8_t);
    uint32_t NBYTES_RESULT = sizeof(uint8_t);

    // Input/Output Sizes (per-cluster tile)
    uint32_t a_size = M*K*NBYTES_VEC;
    uint32_t b_size = K*N*NBYTES_VEC;
    uint32_t scale_a_size = (M*K/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t scale_b_size = (K*N/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t result_size = M*N*NBYTES_RESULT;
    uint32_t result_scale_size = (M*N/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t c_size = (PRELOAD == 1) ? (M*N*sizeof(float)) : result_size;

    // Control Engine Register Value
    uint32_t engine_ctrl = 0x00400678 | ((uint32_t)PRELOAD << 24);

    // REG_GEMM_SIZE: [9:0] M, [21:10] K, [31:22] N
    uint32_t gemm_size = ((uint32_t)M & 0x3FF) | (((uint32_t)K & 0xFFF) << 10) | (((uint32_t)N & 0x3FF) << 22);

    // REG_TILE_COUNTS: [3:0] A_ROW_TILES, [8:4] B_COL_TILES, [15:9] INNER_TILES, [22:16] INNER_BLOCKS, [28:23] SA_VEC_PER_BLOCK
    uint32_t a_row_tiles      = M / OBuff;
    uint32_t b_col_tiles      = N / MXU;
    uint32_t inner_tiles      = K / VS;
    uint32_t inner_blocks     = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;
    uint32_t sa_vec_per_block = (inner_tiles < (BLOCK_SIZE / VS)) ? inner_tiles : (BLOCK_SIZE / VS);
    uint32_t tile_counts      = (a_row_tiles & 0xF) | ((b_col_tiles & 0x1F) << 4) |
                                ((inner_tiles & 0x7F) << 9) | ((inner_blocks & 0x7F) << 16) |
                                ((sa_vec_per_block & 0x3F) << 23);

    uint32_t a_tile_size            = OBuff * VS * SRC_WIDTH;
    uint32_t b_tile_size            = VS * MXU * SRC_WIDTH;
    uint32_t preload_tile_size      = MXU * OBuff * DST_WIDTH;
    uint32_t result_tile_size       = MXU * OBuff * SRC_WIDTH; // QUANTIZE_OUTPUT == 1
    uint32_t result_scale_tile_size = (MXU / BLOCK_SIZE) * OBuff * SCALE_WIDTH;
    uint32_t iter_count             = ((uint32_t)K * OBuff) / VS;

    // Allocate space and Copy Data into TCDM
    local_a = snrt_l1_alloc_cluster_local(a_size, 4096);
    local_b = snrt_l1_alloc_cluster_local(b_size, 4096);
    local_scale_a = snrt_l1_alloc_cluster_local(scale_a_size, 4096);
    local_scale_b = snrt_l1_alloc_cluster_local(scale_b_size, 4096);
    local_result = snrt_l1_alloc_cluster_local(c_size, 4096);
    local_result_scale = snrt_l1_alloc_cluster_local(result_scale_size, 4096);
#if TIMING
    uint32_t *ts = (uint32_t *)snrt_l1_alloc_cluster_local((TIMING_ROWS * TIMING_COLS + TIMING_INFO_LEN) * sizeof(uint32_t), 64);
    if (core_idx == 0) mxcore_timing_init(ts);
#endif

    if (snrt_is_dm_core()) {
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_IN_START);
        snrt_dma_start_1d(local_a, vector_a[cluster_idx], a_size);
        snrt_dma_start_1d(local_b, vectors_b[cluster_idx], b_size);
        snrt_dma_start_1d(local_scale_a, scale_a[cluster_idx], scale_a_size);
        snrt_dma_start_1d(local_scale_b, scale_b[cluster_idx], scale_b_size);
#if PRELOAD
        snrt_dma_start_1d(local_result, preload_acc[cluster_idx], c_size);
#endif
        snrt_dma_wait_all();
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_IN_END);
    }
    snrt_cluster_hw_barrier();

    // Compute
    if (snrt_cluster_core_idx() == 0) {
        mxcore_cg_enable();

        hwpe_soft_clear();

        MXCORE_TIMESTAMP(cluster_idx, TS_SUBMIT);

        volatile int mxstatus;
        do {
            mxstatus = hwpe_acquire_job();
        } while (mxstatus < 0);

        mxcore_cfg((unsigned int) local_a, (unsigned int) local_b, (unsigned int) local_scale_a, (unsigned int) local_scale_b, (unsigned int) local_result, (unsigned int) local_result, (unsigned int) local_result_scale, gemm_size, engine_ctrl, tile_counts, a_tile_size, b_tile_size, preload_tile_size, result_tile_size, result_scale_tile_size, iter_count);

        hwpe_trigger_job();

        MXCORE_TIMESTAMP(cluster_idx, TS_TRIGGER);

        snrt_interrupt_enable(IRQ_M_ACC);
        while (!(read_csr(mip) & MIP_MXIP)) snrt_wfi();

        MXCORE_TIMESTAMP(cluster_idx, TS_DONE);

        snrt_hwpe_clr_mxip(core_idx);

        snrt_interrupt_disable(IRQ_M_ACC);

        mxcore_cg_disable();
    }
    snrt_cluster_hw_barrier();

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_OUT_START);
        snrt_dma_start_1d((volatile void *)result_mx[cluster_idx], (volatile void *)local_result, sizeof(golden_result_mx[0]));
        snrt_dma_start_1d((volatile void *)scale_result_mx[cluster_idx], (volatile void *)local_result_scale, sizeof(golden_scale_result_mx[0]));
        snrt_dma_wait_all();
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_OUT_END);
    }
    snrt_cluster_hw_barrier();

#if TIMING
    if (snrt_is_dm_core()) mxcore_timing_store(ts, cluster_idx, 1);
#endif

    return 0;
}
