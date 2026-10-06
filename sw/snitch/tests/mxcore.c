// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Jayanth Jonnalagadda <jjonnalagadd@student.ethz.ch>

#include "snrt.h"

#define PRELOAD   0 // PRELOAD Enable/Disable
#define MULTI_JOB 0 // MULTI_JOB Enable/Disable
#define TIMING    0 // TIMING Enable/Disable

#if MULTI_JOB && PRELOAD
#include "data/mxcore_multi_preload_data.h"
#elif MULTI_JOB
#include "data/mxcore_multi_data.h"
#elif PRELOAD
#include "data/mxcore_preload_data.h"
#else
#include "data/mxcore_data.h"
#endif

#include <stdio.h>
#include <stdint.h>

// MXCore Configuration
#define VS      32
#define MXU     32
#define OBuff   64
#define BW      512

// Input Matrices Configuration
#if MULTI_JOB && PRELOAD
#define M       64
#define K       64
#define N       32
#elif MULTI_JOB
#define M       64
#define K       64
#define N       64
#else
#define M       128
#define K       128
#define N       128
#endif

// MX Parameters
#define BLOCK_SIZE      32
#define QUANTIZE_OUTPUT 1
#define SRC_WIDTH       8
#define DST_WIDTH       32
#define SCALE_WIDTH     8

#if TIMING
#define TIMING_ROWS       16
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

#define HWPE_ADDR_BASE ((unsigned long)snrt_cluster_alias()->zeromem.mem + sizeof(snrt_cluster_alias()->zeromem.mem))
#define MXCORE_TRIGGER 0x00
#define MXCORE_ACQUIRE 0x04
#define MXCORE_STATUS 0x0C
#define MXCORE_SOFT_CLEAR 0x14
#define MXCORE_EVT_OFFS 0x94
#define MXCORE_CK_GATE_OFFS 0x9C
#define HWPE_MXIP_ADDR (HWPE_ADDR_BASE + MXCORE_EVT_OFFS)
#define HWPE_WRITE(value, offset) *(volatile int *)(HWPE_ADDR_BASE + offset) = value
#define HWPE_READ(offset) *(volatile int *)(HWPE_ADDR_BASE + offset)

typedef struct {
  uint32_t gemm_size;
  uint32_t engine_ctrl;
  uint32_t tile_counts;
  uint32_t a_tile_size;
  uint32_t b_tile_size;
  uint32_t preload_tile_size;
  uint32_t result_tile_size;
  uint32_t result_scale_tile_size;
  uint32_t iter_count;
} mxcore_job_cfg_t;

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

static inline void mxcore_cg_enable() { HWPE_WRITE(1, MXCORE_CK_GATE_OFFS); }

static inline void mxcore_cg_disable() { HWPE_WRITE(0, MXCORE_CK_GATE_OFFS); }

inline void snrt_hwpe_clr_mxip(uint32_t core_idx) {
    * (volatile uint32_t*)HWPE_MXIP_ADDR = (1 << core_idx);
}

static inline void mxcore_submit_job(void *a, void *b, void *scale_a, void *scale_b, void *c, void *scale_c, const mxcore_job_cfg_t *cfg) {
    volatile int mxstatus;
    do {
        mxstatus = hwpe_acquire_job();
    } while (mxstatus < 0);

    mxcore_cfg((unsigned int) a, (unsigned int) b, (unsigned int) scale_a, (unsigned int) scale_b, (unsigned int) c, (unsigned int) c, (unsigned int) scale_c, cfg->gemm_size, cfg->engine_ctrl, cfg->tile_counts, cfg->a_tile_size, cfg->b_tile_size, cfg->preload_tile_size, cfg->result_tile_size, cfg->result_scale_tile_size, cfg->iter_count);

    hwpe_trigger_job();
}

#if TIMING
static inline void mxcore_timestamp(uint32_t *ts, uint32_t row, uint32_t col) {
    if (row < TIMING_ROWS) ts[row * TIMING_COLS + col] = snrt_mcycle();
}

static inline void mxcore_timing_init(uint32_t *ts) {
    const uint32_t info[TIMING_INFO_LEN] = {TIMING_ROWS, TIMING_COLS, M, K, N, VS, MXU, OBuff, PRELOAD, MULTI_JOB};
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

static inline void mxcore_wait_job_done(uint32_t core_idx) {
    while (!(read_csr(mip) & MIP_MXIP)) snrt_wfi();

    snrt_hwpe_clr_mxip(core_idx);

    while (read_csr(mip) & MIP_MXIP);
}

int main() {
#if MULTI_JOB
    if (snrt_cluster_idx() != 0) return 0;
#endif

    uint32_t core_idx = snrt_cluster_core_idx();

    // Clear Interrupt from Host
    snrt_int_clr_mcip();

    // Size Parameters
    uint32_t NBYTES_VEC = sizeof(int8_t);
    uint32_t NBYTES_SCALE = sizeof(uint8_t);
    uint32_t NBYTES_RESULT = (QUANTIZE_OUTPUT == 1) ? sizeof(uint8_t) : sizeof(float);

    // Input/Output Sizes
    uint32_t a_size = M*K*NBYTES_VEC;
    uint32_t b_size = K*N*NBYTES_VEC;
    uint32_t scale_a_size = (M*K/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t scale_b_size = (K*N/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t result_size = M*N*NBYTES_RESULT;
    uint32_t result_scale_size = (M*N/BLOCK_SIZE)*NBYTES_SCALE;
    uint32_t c_size = (PRELOAD == 1) ? (M*N*sizeof(float)) : result_size;

    mxcore_job_cfg_t cfg;

    // Control Engine Register Value
    cfg.engine_ctrl = 0x00400678 | ((uint32_t)PRELOAD << 24);

    // REG_GEMM_SIZE: [9:0] M, [21:10] K, [31:22] N
    cfg.gemm_size = ((uint32_t)M & 0x3FF) | (((uint32_t)K & 0xFFF) << 10) | (((uint32_t)N & 0x3FF) << 22);

    // REG_TILE_COUNTS: [3:0] A_ROW_TILES, [8:4] B_COL_TILES, [15:9] INNER_TILES, [22:16] INNER_BLOCKS, [28:23] SA_VEC_PER_BLOCK
    uint32_t a_row_tiles      = M / OBuff;
    uint32_t b_col_tiles      = N / MXU;
    uint32_t inner_tiles      = K / VS;
    uint32_t inner_blocks     = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;
    uint32_t sa_vec_per_block = (inner_tiles < (BLOCK_SIZE / VS)) ? inner_tiles : (BLOCK_SIZE / VS);
    cfg.tile_counts           = (a_row_tiles & 0xF) | ((b_col_tiles & 0x1F) << 4) |
                                ((inner_tiles & 0x7F) << 9) | ((inner_blocks & 0x7F) << 16) |
                                ((sa_vec_per_block & 0x3F) << 23);

    cfg.a_tile_size            = OBuff * VS * SRC_WIDTH;
    cfg.b_tile_size            = VS * MXU * SRC_WIDTH;
    cfg.preload_tile_size      = MXU * OBuff * DST_WIDTH;
    cfg.result_tile_size       = (QUANTIZE_OUTPUT == 1) ? (MXU * OBuff * SRC_WIDTH) : (MXU * OBuff * DST_WIDTH);
    cfg.result_scale_tile_size = (MXU / BLOCK_SIZE) * OBuff * SCALE_WIDTH;
    cfg.iter_count             = ((uint32_t)K * OBuff) / VS;

#if MULTI_JOB
    void *local_a[2], *local_b[2], *local_scale_a[2], *local_scale_b[2], *local_result[2], *local_result_scale[2];
    uint32_t num_jobs = NUM_CLUSTERS;

    // Allocate space and Copy Data into TCDM
    for (uint32_t h = 0; h < 2; h++) {
        local_a[h] = snrt_l1_alloc_cluster_local(a_size, 64);
        local_b[h] = snrt_l1_alloc_cluster_local(b_size, 64);
        local_scale_a[h] = snrt_l1_alloc_cluster_local(scale_a_size, 64);
        local_scale_b[h] = snrt_l1_alloc_cluster_local(scale_b_size, 64);
        local_result[h] = snrt_l1_alloc_cluster_local(c_size, 64);
        local_result_scale[h] = snrt_l1_alloc_cluster_local(result_scale_size, 64);
    }
#if TIMING
    uint32_t *ts = (uint32_t *)snrt_l1_alloc_cluster_local((TIMING_ROWS * TIMING_COLS + TIMING_INFO_LEN) * sizeof(uint32_t), 64);
    if (core_idx == 0) mxcore_timing_init(ts);
#endif

    if (snrt_is_dm_core()) {
        for (uint32_t job = 0; (job < 2) && (job < num_jobs); job++) {
            MXCORE_TIMESTAMP(job, TS_DMA_IN_START);
            snrt_dma_start_1d(local_a[job], vector_a[job], a_size);
            snrt_dma_start_1d(local_b[job], vectors_b[job], b_size);
            snrt_dma_start_1d(local_scale_a[job], scale_a[job], scale_a_size);
            snrt_dma_start_1d(local_scale_b[job], scale_b[job], scale_b_size);
#if PRELOAD
            snrt_dma_start_1d(local_result[job], preload_acc[job], c_size);
#endif
            snrt_dma_wait_all();
            MXCORE_TIMESTAMP(job, TS_DMA_IN_END);
        }
    }
    snrt_cluster_hw_barrier();

    // Compute
    if (core_idx == 0) {
        mxcore_cg_enable();

        hwpe_soft_clear();

        snrt_interrupt_enable(IRQ_M_ACC);

        for (uint32_t job = 0; (job < 2) && (job < num_jobs); job++) {
            MXCORE_TIMESTAMP(job, TS_SUBMIT);
            mxcore_submit_job(local_a[job], local_b[job], local_scale_a[job], local_scale_b[job], local_result[job], local_result_scale[job], &cfg);
            MXCORE_TIMESTAMP(job, TS_TRIGGER);
        }
    }

    for (uint32_t job = 0; job < num_jobs; job++) {
        uint32_t h = job % 2;
        uint32_t next = job + 2;

        if (core_idx == 0) {
            mxcore_wait_job_done(core_idx);
            MXCORE_TIMESTAMP(job, TS_DONE);
        }
        snrt_cluster_hw_barrier();

        // Copy data out of TCDM
        if (snrt_is_dm_core()) {
            MXCORE_TIMESTAMP(job, TS_DMA_OUT_START);
            snrt_dma_start_1d((volatile void *)result_mx[job], (volatile void *)local_result[h], result_size);
            snrt_dma_start_1d((volatile void *)scale_result_mx[job], (volatile void *)local_result_scale[h], result_scale_size);
            snrt_dma_wait_all();
            MXCORE_TIMESTAMP(job, TS_DMA_OUT_END);
            if (next < num_jobs) {
                MXCORE_TIMESTAMP(next, TS_DMA_IN_START);
                snrt_dma_start_1d(local_a[h], vector_a[next], a_size);
                snrt_dma_start_1d(local_b[h], vectors_b[next], b_size);
                snrt_dma_start_1d(local_scale_a[h], scale_a[next], scale_a_size);
                snrt_dma_start_1d(local_scale_b[h], scale_b[next], scale_b_size);
#if PRELOAD
                snrt_dma_start_1d(local_result[h], preload_acc[next], c_size);
#endif
                snrt_dma_wait_all();
                MXCORE_TIMESTAMP(next, TS_DMA_IN_END);
            }
        }
        snrt_cluster_hw_barrier();

        if ((core_idx == 0) && (next < num_jobs)) {
            MXCORE_TIMESTAMP(next, TS_SUBMIT);
            mxcore_submit_job(local_a[h], local_b[h], local_scale_a[h], local_scale_b[h], local_result[h], local_result_scale[h], &cfg);
            MXCORE_TIMESTAMP(next, TS_TRIGGER);
        }
    }

    if (core_idx == 0) {
        snrt_interrupt_disable(IRQ_M_ACC);

        mxcore_cg_disable();
    }
    snrt_cluster_hw_barrier();

#if TIMING
    if (snrt_is_dm_core()) mxcore_timing_store(ts, 0, num_jobs);
#endif
#else
    void *local_a, *local_b, *local_scale_a, *local_scale_b, *local_result, *local_result_scale;

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

    uint32_t cluster_idx = snrt_cluster_idx();
#endif

    if (snrt_is_dm_core()) {
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_IN_START);
        snrt_dma_start_1d(local_a, vector_a, a_size);
        snrt_dma_start_1d(local_b, vectors_b, b_size);
        snrt_dma_start_1d(local_scale_a, scale_a, scale_a_size);
        snrt_dma_start_1d(local_scale_b, scale_b, scale_b_size);
#if PRELOAD
        snrt_dma_start_1d(local_result, preload_acc, c_size);
#endif
        snrt_dma_wait_all();
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_IN_END);
    }
    snrt_cluster_hw_barrier();

    // Compute
    if (core_idx == 0) {
        mxcore_cg_enable();

        hwpe_soft_clear();

        snrt_interrupt_enable(IRQ_M_ACC);

        MXCORE_TIMESTAMP(cluster_idx, TS_SUBMIT);
        mxcore_submit_job(local_a, local_b, local_scale_a, local_scale_b, local_result, local_result_scale, &cfg);
        MXCORE_TIMESTAMP(cluster_idx, TS_TRIGGER);

        mxcore_wait_job_done(core_idx);
        MXCORE_TIMESTAMP(cluster_idx, TS_DONE);

        snrt_interrupt_disable(IRQ_M_ACC);

        mxcore_cg_disable();
    }
    snrt_cluster_hw_barrier();

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        size_t res_bytes = (QUANTIZE_OUTPUT == 1) ? sizeof(golden_result_mx) : sizeof(golden_result);
        size_t res_scale_bytes = sizeof(golden_scale_result_mx);
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_OUT_START);
        snrt_dma_start_1d((volatile void *)result_mx, (volatile void *)local_result, res_bytes);
        snrt_dma_start_1d((volatile void *)scale_result_mx, (volatile void *)local_result_scale, res_scale_bytes);
        snrt_dma_wait_all();
        MXCORE_TIMESTAMP(cluster_idx, TS_DMA_OUT_END);
    }
    snrt_cluster_hw_barrier();

#if TIMING
    if (snrt_is_dm_core()) mxcore_timing_store(ts, cluster_idx, 1);
#endif
#endif

    return 0;
}
