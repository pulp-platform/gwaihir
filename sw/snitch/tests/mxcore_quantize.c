// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Jayanth Jonnalagadda <jjonnalagadd@iis.ee.ethz.ch>

#include "snrt.h"

#define OUT_MXFP8    0
#define OUT_MXFP8ALT 1
#define OUT_MXFP4    2
#define OUT_BF16     3

#define OUTPUT_FORMAT OUT_MXFP8 // OUTPUT_FORMAT OUT_MXFP8/OUT_MXFP8ALT/OUT_MXFP4/OUT_BF16

#include "data/mxcore_quantize_data.h"
#include "gw_hwpe_subsystem_addrmap.h"

#include <stdio.h>
#include <stdint.h>

// MXCore Configuration
#define VS      32
#define MXU     32
#define OBuff   64
#define BW      512

// Input Matrix Configuration
#define M       128
#define K       VS
#define N       128

// MX Parameters
#define BLOCK_SIZE      32
#define SRC_WIDTH       8
#define FP32_WIDTH      32
#define BF16_WIDTH      16
#define SCALE_WIDTH     8

#if OUTPUT_FORMAT == OUT_MXFP8ALT
#define QUANTIZE_BIT    22
#define RESULT_WIDTH    8
#elif OUTPUT_FORMAT == OUT_MXFP4
#define QUANTIZE_BIT    21
#define RESULT_WIDTH    4
#elif OUTPUT_FORMAT == OUT_BF16
#define QUANTIZE_BIT    24
#define RESULT_WIDTH    16
#else
#define QUANTIZE_BIT    23
#define RESULT_WIDTH    8
#endif

#define STANDALONE_BIT       27
#define STANDALONE_BF16_BIT  28

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

static inline void mxcore_cg_enable() { HWPE_WRITE(GW_HWPE_CLK_EN_ACC, MXCORE_CK_GATE_OFFS); }

static inline void mxcore_cg_disable() { HWPE_WRITE(0, MXCORE_CK_GATE_OFFS); }

inline void snrt_hwpe_clr_mxip(uint32_t core_idx) {
    * (volatile uint32_t*)HWPE_MXIP_ADDR = (1 << core_idx);
}

static inline void mxcore_submit_quantize(void *input, void *scale, const mxcore_job_cfg_t *cfg) {
    volatile int mxstatus;
    do {
        mxstatus = hwpe_acquire_job();
    } while (mxstatus < 0);

    mxcore_cfg(0, 0, 0, 0, (unsigned int) input, (unsigned int) input, (unsigned int) scale, cfg->gemm_size, cfg->engine_ctrl, cfg->tile_counts, cfg->a_tile_size, cfg->b_tile_size, cfg->preload_tile_size, cfg->result_tile_size, cfg->result_scale_tile_size, cfg->iter_count);

    hwpe_trigger_job();
}

static inline void mxcore_wait_job_done(uint32_t core_idx) {
    while (!(read_csr(mip) & MIP_MXIP)) snrt_wfi();

    snrt_hwpe_clr_mxip(core_idx);

    while (read_csr(mip) & MIP_MXIP);
}

int main() {
    if (snrt_cluster_idx() != 0) return 0;

    uint32_t core_idx = snrt_cluster_core_idx();

    // Clear Interrupt from Host
    snrt_int_clr_mcip();

    // Input/Output Sizes
    uint32_t fp32_size = (M*N*FP32_WIDTH)/8;
    uint32_t bf16_size = (M*N*BF16_WIDTH)/8;
    uint32_t result_size = (M*N*RESULT_WIDTH)/8;
    uint32_t result_scale_size = ((M*N/BLOCK_SIZE)*SCALE_WIDTH)/8;

    mxcore_job_cfg_t cfg_fp32, cfg_bf16;

    // Control Engine Register Value
    cfg_fp32.engine_ctrl = 0x00000678 | (1u << QUANTIZE_BIT) | (1u << STANDALONE_BIT);

    // REG_GEMM_SIZE: [9:0] M, [21:10] K, [31:22] N
    cfg_fp32.gemm_size = ((uint32_t)M & 0x3FF) | (((uint32_t)K & 0xFFF) << 10) | (((uint32_t)N & 0x3FF) << 22);

    // REG_TILE_COUNTS: [3:0] A_ROW_TILES, [8:4] B_COL_TILES, [15:9] INNER_TILES, [22:16] INNER_BLOCKS, [28:23] SA_VEC_PER_BLOCK
    uint32_t a_row_tiles      = M / OBuff;
    uint32_t b_col_tiles      = N / MXU;
    uint32_t inner_tiles      = K / VS;
    uint32_t inner_blocks     = (K + BLOCK_SIZE - 1) / BLOCK_SIZE;
    uint32_t sa_vec_per_block = (inner_tiles < (BLOCK_SIZE / VS)) ? inner_tiles : (BLOCK_SIZE / VS);
    cfg_fp32.tile_counts      = (a_row_tiles & 0xF) | ((b_col_tiles & 0x1F) << 4) |
                                ((inner_tiles & 0x7F) << 9) | ((inner_blocks & 0x7F) << 16) |
                                ((sa_vec_per_block & 0x3F) << 23);

    cfg_fp32.a_tile_size            = OBuff * VS * SRC_WIDTH;
    cfg_fp32.b_tile_size            = VS * MXU * SRC_WIDTH;
    cfg_fp32.preload_tile_size      = MXU * OBuff * FP32_WIDTH;
    cfg_fp32.result_tile_size       = MXU * OBuff * RESULT_WIDTH;
    cfg_fp32.result_scale_tile_size = (MXU / BLOCK_SIZE) * OBuff * SCALE_WIDTH;
    cfg_fp32.iter_count             = ((uint32_t)K * OBuff) / VS;

    cfg_bf16                   = cfg_fp32;
    cfg_bf16.engine_ctrl       = cfg_fp32.engine_ctrl | (1u << STANDALONE_BF16_BIT);
    cfg_bf16.preload_tile_size = MXU * OBuff * BF16_WIDTH;

    void *local_fp32, *local_bf16, *local_scale_fp32, *local_scale_bf16;

    // Allocate space and Copy Data into TCDM
    local_fp32 = snrt_l1_alloc_cluster_local(fp32_size, 64);
    local_bf16 = snrt_l1_alloc_cluster_local(bf16_size, 64);
    local_scale_fp32 = snrt_l1_alloc_cluster_local(result_scale_size, 64);
    local_scale_bf16 = snrt_l1_alloc_cluster_local(result_scale_size, 64);

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_fp32, input_fp32, fp32_size);
        snrt_dma_start_1d(local_bf16, input_bf16, bf16_size);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    // Compute
    if (core_idx == 0) {
        mxcore_cg_enable();

        hwpe_soft_clear();

        snrt_interrupt_enable(IRQ_M_ACC);

        mxcore_submit_quantize(local_fp32, local_scale_fp32, &cfg_fp32);
        mxcore_submit_quantize(local_bf16, local_scale_bf16, &cfg_bf16);

        mxcore_wait_job_done(core_idx);
        mxcore_wait_job_done(core_idx);

        snrt_interrupt_disable(IRQ_M_ACC);

        mxcore_cg_disable();
    }
    snrt_cluster_hw_barrier();

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_start_1d((volatile void *)result_mx_fp32, (volatile void *)local_fp32, result_size);
        snrt_dma_start_1d((volatile void *)result_mx_bf16, (volatile void *)local_bf16, result_size);
#if OUTPUT_FORMAT != OUT_BF16
        snrt_dma_start_1d((volatile void *)scale_result_mx_fp32, (volatile void *)local_scale_fp32, result_scale_size);
        snrt_dma_start_1d((volatile void *)scale_result_mx_bf16, (volatile void *)local_scale_bf16, result_scale_size);
#endif
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    return 0;
}
