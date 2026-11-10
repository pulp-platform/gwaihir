// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Surya MX kernel on the H tile. The workload is one MX GEMM, M=128, N=256,
// P=128, with an MXINT8 output.
//
// The test does these steps:
//   1. The DM core copies the inputs from L2 to the TCDM.
//   2. Core 0 selects the accelerator, enables its clock and programs each task.
//   3. Core 0 waits until Surya-MX is idle. Then it clears the event and
//      disables the clock.
//   4. The DM core copies the output and the output scales to L2.
//      `experiments/surya_mx/verify.py` compares them with the golden data in
//      the ELF.
//
// Build and run the test on the H tile:
//   make sn-tests chs-sw-tests
//   make vsim-run-batch-verify CHS_BINARY=sw/cheshire/tests/simple_htile_offload.spm.elf \
//     SN_BINARY=sw/snitch/tests/build/surya_mx.elf VERIFY_PY=experiments/surya_mx/verify.py \
//     PRELMODE=3
//
// The Surya-MX model generates `surya_workload.h` and the task data at build
// time, from the test `MX_M128_N256_P128_MXO` in `tests/gwaihir.json` of the
// surya-mx repository.
//
// The accelerator sits in the `ext_mem` window of the cluster, after the zero
// memory. `gw_hwpe_subsystem_addrmap.h` holds the map.

#include <stdint.h>

#include "snrt.h"
#include "gw_hwpe_subsystem_addrmap.h"

#define GW_HWPE_BASE    GW_HWPE_BASE_ADDR(gw_htile())
#define SURYA_BASE_ADDR (GW_HWPE_BASE + GW_HWPE_ACC_OFFS)

#include "surya_hal.h"
#include "surya_workload.h"

static_assert(sizeof(surya_regif_t) <= GW_HWPE_ACC_WINDOW,
              "the Surya register file outgrew the subsystem window");

#define GW_HWPE_WRITE(offs, value) \
  (*(volatile uint32_t *)(GW_HWPE_BASE + (offs)) = (uint32_t)(value))

static const surya_hw_config_t surya_hw_config = {
    SURYA_HW_ARRAY_N,    SURYA_HW_ARRAY_P, SURYA_HW_N_ACCUM,
    SURYA_HW_NUM_ARRAYS, SURYA_HW_OPTIMAL_BW,
};

// The test sets no PACE or accumulator-init buffers.
#define TASK_CHECK(i)                                        \
  static_assert(TASK##i##_OP_MODE == 0 && !TASK##i##_PACE && \
                    !TASK##i##_ACCUM_INIT_MODE,              \
                "surya_mx.c runs plain MX GEMM tasks only");
SURYA_TASKS(TASK_CHECK)

#define TASK_A_BYTES(i)          (TASK##i##_MATRIX_A_SIZE * sizeof(task##i##_matrix_a[0]))
#define TASK_B_BYTES(i)          (TASK##i##_MATRIX_B_SIZE * sizeof(task##i##_matrix_b[0]))
#define TASK_MX_SCALE_A_BYTES(i) (TASK##i##_MX_SCALE_A_SIZE * sizeof(task##i##_mx_scale_a[0]))
#define TASK_MX_SCALE_B_BYTES(i) (TASK##i##_MX_SCALE_B_SIZE * sizeof(task##i##_mx_scale_b[0]))

// The runtime clears .bss at boot with slow core stores to L2. It does not clear .dram.
// A task with a BF16 output has no output scales, so its scale size is 0.
#define L2_OUT __attribute__((section(".dram"), aligned(64)))
#define TASK_L2_OUT(i)                                     \
  L2_OUT uint8_t task##i##_matrix_c_out[TASK##i##_C_SIZE]; \
  L2_OUT uint8_t task##i##_mx_out_scale_buf[TASK##i##_MX_OUT_SCALE_SIZE];
SURYA_TASKS(TASK_L2_OUT)

static uint8_t *local_a[NUM_TASKS];
static uint8_t *local_b[NUM_TASKS];
static uint8_t *local_c[NUM_TASKS];
static uint8_t *local_mx_scale_a[NUM_TASKS];
static uint8_t *local_mx_scale_b[NUM_TASKS];
static uint8_t *local_out_scale[NUM_TASKS];

static surya_task_config_t surya_tasks[NUM_TASKS];

#define TASK_ALLOC_AND_DMA(i)                                                                   \
  do {                                                                                          \
    local_a[i]          = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_A_BYTES(i), 64);          \
    local_b[i]          = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_B_BYTES(i), 64);          \
    local_c[i]          = (uint8_t *)snrt_l1_alloc_cluster_local(TASK##i##_C_BUF_SIZE, 64);     \
    local_mx_scale_a[i] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_MX_SCALE_A_BYTES(i), 64); \
    local_mx_scale_b[i] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_MX_SCALE_B_BYTES(i), 64); \
    local_out_scale[i]  =                                                                       \
        (uint8_t *)snrt_l1_alloc_cluster_local(TASK##i##_MX_OUT_SCALE_SIZE, 64);                \
    snrt_dma_start_1d(local_a[i], task##i##_matrix_a, TASK_A_BYTES(i));                         \
    snrt_dma_start_1d(local_b[i], task##i##_matrix_b, TASK_B_BYTES(i));                         \
    snrt_dma_start_1d(local_mx_scale_a[i], task##i##_mx_scale_a, TASK_MX_SCALE_A_BYTES(i));     \
    snrt_dma_start_1d(local_mx_scale_b[i], task##i##_mx_scale_b, TASK_MX_SCALE_B_BYTES(i));     \
  } while (0);

#define TASK_DMA_OUT(i)                                                      \
  do {                                                                       \
    snrt_dma_start_1d(task##i##_matrix_c_out, local_c[i], TASK##i##_C_SIZE); \
    if (TASK##i##_MX_OUT_SCALE_SIZE)                                         \
      snrt_dma_start_1d(task##i##_mx_out_scale_buf, local_out_scale[i],      \
                        TASK##i##_MX_OUT_SCALE_SIZE);                        \
  } while (0);

// Assignment, not a designated initializer. The tests compile as C++, which
// accepts a designated initializer only in declaration order.
#define TASK_BUILD_CONFIG(i)                                                  \
  do {                                                                        \
    surya_task_config_t *t  = &surya_tasks[i];                                \
    t->a_ptr                = local_a[i];                                     \
    t->b_ptr                = local_b[i];                                     \
    t->c_ptr                = (int8_t *)local_c[i];                           \
    t->mx_scale_a_ptr       = local_mx_scale_a[i];                            \
    t->mx_scale_b_ptr       = local_mx_scale_b[i];                            \
    t->mx_out_scale_ptr     = local_out_scale[i];                             \
    t->mx_out_int8          = TASK##i##_MX_OUT_INT8;                          \
    t->a_mxint4             = TASK##i##_A_MXINT4;                             \
    t->b_mxint4             = TASK##i##_B_MXINT4;                             \
    t->c_mxint4             = TASK##i##_C_MXINT4;                             \
    t->out_dim              = TASK##i##_OUT_DIM;                              \
    t->m                    = TASK##i##_M;                                    \
    t->n                    = TASK##i##_N;                                    \
    t->p                    = TASK##i##_P;                                    \
    t->op_mode              = (surya_op_mode_t)TASK##i##_OP_MODE;             \
    t->pace                 = TASK##i##_PACE;                                 \
    t->accum_init_mode      = (surya_accum_init_mode_t)TASK##i##_ACCUM_INIT_MODE; \
    t->compute              = TASK##i##_COMPUTE;                              \
    t->out_unsigned         = TASK##i##_OUT_UNSIGNED;                         \
    t->force_rr_priority    = TASK##i##_FORCE_RR_PRIORITY;                    \
    t->weight_ctx           = TASK##i##_WEIGHT_CTX;                           \
    t->disable_weight_reuse = TASK##i##_DISABLE_WEIGHT_REUSE;                 \
    t->soft_clear_state     = TASK##i##_SOFT_CLEAR_STATE;                     \
  } while (0);

int main(void) {
  const uint32_t core_idx = snrt_cluster_core_idx();

  snrt_int_clr_mcip();

  // Only the H tile holds Surya.
  if (snrt_cluster_idx() != GW_HTILE_CLUSTER_IDX) return 0;

  if (snrt_is_dm_core()) {
    SURYA_TASKS(TASK_ALLOC_AND_DMA)
    snrt_dma_wait_all();
  }
  snrt_cluster_hw_barrier();

  if (core_idx == 0) {
    GW_HWPE_WRITE(GW_HWPE_MUX_SEL_OFFS, GW_HWPE_MUX_SEL_ACC);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, GW_HWPE_CLK_EN_ACC);
    // The clock gate needs a few cycles before the register file answers.
    for (volatile int k = 0; k < 5; k++);

    SURYA_TASKS(TASK_BUILD_CONFIG)

    surya_soft_clear();

    for (uint32_t t = 0; t < NUM_TASKS; t++) {
      while (surya_acquire() < 0);
      surya_regif__hwpe_ctrl_job_dep_t cfg =
          surya_derive_config(surya_tasks[t], surya_hw_config);
      surya_program(&surya_tasks[t], &cfg);
      surya_trigger();
    }

    while (surya_status() != 0);

    GW_HWPE_WRITE(GW_HWPE_EVT_CLR_OFFS, 1 << core_idx);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, 0);
  }
  snrt_cluster_hw_barrier();

  // The L2 dump starts when all cores return, so the DM core waits for its DMA.
  if (snrt_is_dm_core()) {
    SURYA_TASKS(TASK_DMA_OUT)
    snrt_dma_wait_all();
  }
  return 0;
}
