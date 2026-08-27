// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Jayanth Jonnalagadda <jjonnalagadd@student.ethz.ch>

#include "snrt.h"
#include "data/mxcore_data.h"

#include <stdio.h>
#include <stdint.h>

// MXCore Configuration
#define VS      32
#define MXU     32
#define OBuff   64
#define BW      512

// Input Matrices Configuration
#define M       128
#define K       128
#define N       128

// MX Parameters
#define BLOCK_SIZE      32
#define QUANTIZE_OUTPUT 1

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

void mxcore_cfg (unsigned int vector_a_ptr, unsigned int vectors_b_ptr, unsigned int scale_a_ptr, unsigned int scale_b_ptr, unsigned int result_ptr, unsigned int result_scale_ptr, uint16_t m, uint16_t k, uint16_t n, uint32_t engine_ctrl_reg) {
  uint32_t nm = ((uint32_t)n << 16) | (uint32_t)m;
  HWPE_WRITE(vector_a_ptr,      0x20);
  HWPE_WRITE(vectors_b_ptr,     0x24);
  HWPE_WRITE(scale_a_ptr,       0x28);
  HWPE_WRITE(scale_b_ptr,       0x2C);
  HWPE_WRITE(result_ptr,        0x30);
  HWPE_WRITE(result_scale_ptr,  0x34);
  HWPE_WRITE(k,                 0x38);
  HWPE_WRITE(nm,                0x3C);
  HWPE_WRITE(engine_ctrl_reg,   0x40);
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

int main() {
    // if (snrt_cluster_idx() != 7) return 0;

    void *local_a, *local_b, *local_scale_a, *local_scale_b, *local_result, *local_result_scale;

    uint32_t core_idx = snrt_cluster_core_idx();

    // Clear Interrupt from Host
    snrt_int_clr_mcip();

    // Size Parameters
    uint32_t NBYTES_VEC = sizeof(int8_t);
    uint32_t NBYTES_SCALE = sizeof(uint8_t);
    uint32_t NBYTES_RESULT = (QUANTIZE_OUTPUT == 1) ? sizeof(uint8_t) : sizeof(float);

    // Input/Output Sizes
    uint16_t a_size = M*K*NBYTES_VEC;
    uint16_t b_size = K*N*NBYTES_VEC;
    uint16_t scale_a_size = (M*K/BLOCK_SIZE)*NBYTES_SCALE;
    uint16_t scale_b_size = (K*N/BLOCK_SIZE)*NBYTES_SCALE;
    uint16_t result_size = M*N*NBYTES_RESULT;
    uint16_t result_scale_size = (M*N/BLOCK_SIZE)*NBYTES_SCALE;

    // Control Engine Register Value
    uint32_t engine_ctrl = 0x00200678;

    // Allocate space and Copy Data into TCDM
    local_a = snrt_l1_alloc_cluster_local(a_size, 4096);
    local_b = snrt_l1_alloc_cluster_local(b_size, 4096);
    local_scale_a = snrt_l1_alloc_cluster_local(scale_a_size, 4096);
    local_scale_b = snrt_l1_alloc_cluster_local(scale_b_size, 4096);
    local_result = snrt_l1_alloc_cluster_local(result_size, 4096);
    local_result_scale = snrt_l1_alloc_cluster_local(result_scale_size, 4096);

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_a, vector_a, a_size);
        snrt_dma_start_1d(local_b, vectors_b, b_size);
        snrt_dma_start_1d(local_scale_a, scale_a, scale_a_size);
        snrt_dma_start_1d(local_scale_b, scale_b, scale_b_size);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    // Compute
    if (snrt_cluster_core_idx() == 0) {
        mxcore_cg_enable();

        hwpe_soft_clear();

        volatile int mxstatus;
        do {
            mxstatus = hwpe_acquire_job();
        } while (mxstatus < 0);

        mxcore_cfg((unsigned int) local_a, (unsigned int) local_b, (unsigned int) local_scale_a, (unsigned int) local_scale_b, (unsigned int) local_result, (unsigned int) local_result_scale, M, K, N, engine_ctrl);

        hwpe_trigger_job();

        int hwpe_status;
        snrt_interrupt_enable(IRQ_M_ACC);
        while ((hwpe_status = hwpe_get_status()) != 0) snrt_wfi();

        snrt_hwpe_clr_mxip(core_idx);

        snrt_interrupt_disable(IRQ_M_ACC);

        mxcore_cg_disable();
    }
    snrt_cluster_hw_barrier();

    // Copy data out of TCDM
    if (snrt_is_dm_core()) {
        size_t res_bytes = (QUANTIZE_OUTPUT == 1) ? sizeof(golden_result_mx) : sizeof(golden_result);
        size_t res_scale_bytes = sizeof(golden_scale_result_mx);
        snrt_dma_start_1d((volatile void *)result_mx, (volatile void *)local_result, res_bytes);
        snrt_dma_start_1d((volatile void *)scale_result_mx, (volatile void *)local_result_scale, res_scale_bytes);
        snrt_dma_wait_all();
    }
    snrt_cluster_hw_barrier();

    return 0;
}
