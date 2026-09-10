// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Surya MX kernel on the H tile. The workload is one MX GEMM, M=32, N=256,
// P=32, with a BF16 output. `tests/gwaihir.json` of Surya holds the same
// workload, so the golden data comes from the Surya model.
//
// The accelerator sits in the `ext_mem` window of the cluster, after the zero
// memory. `gw_hwpe_subsystem_addrmap.h` holds the map.

#include <stdint.h>
#include <stdio.h>

#include "snrt.h"

// The subsystem answers the control block above both accelerator windows.
#define GW_HWPE_BASE                              \
  ((uintptr_t)snrt_cluster_alias()->zeromem.mem + \
   sizeof(snrt_cluster_alias()->zeromem.mem))

#include "gw_hwpe_subsystem_addrmap.h"

#define SURYA_BASE_ADDR (GW_HWPE_BASE + GW_HWPE_SURYA_OFFS)

#include "surya_hal.h"
#include "surya_workload.h"

static_assert(sizeof(surya_regif_t) <= GW_HWPE_ACC_WINDOW,
              "the Surya register file outgrew the subsystem window");

#define GW_HWPE_WRITE(offs, value) \
  (*(volatile uint32_t *)(GW_HWPE_BASE + (offs)) = (uint32_t)(value))

static const surya_hw_config_t surya_hw_config = {
    SURYA_HW_CIM_INNER, SURYA_HW_CIM_OUTER, SURYA_HW_N_ACCUM,
    SURYA_HW_N_CIM,     SURYA_HW_OPTIMAL_BW,
};

#define TASK_A_BYTES(i)        (TASK##i##_MATRIX_A_SIZE * sizeof(task##i##_matrix_a[0]))
#define TASK_B_BYTES(i)        (TASK##i##_MATRIX_B_SIZE * sizeof(task##i##_matrix_b[0]))
#define TASK_C_BYTES(i)        (TASK##i##_MATRIX_C_SIZE * sizeof(task##i##_matrix_c[0]))
#define TASK_MX_SCALE_A_BYTES(i) (TASK##i##_MX_SCALE_A_SIZE * sizeof(task##i##_mx_scale_a[0]))
#define TASK_MX_SCALE_B_BYTES(i) (TASK##i##_MX_SCALE_B_SIZE * sizeof(task##i##_mx_scale_b[0]))
#define TASK_NQ_BYTES(i)         (TASK##i##_NORMQUANT_SIZE * sizeof(task##i##_normquant[0]))

static uint8_t *local_a[NUM_TASKS];
static uint8_t *local_b[NUM_TASKS];
static uint8_t *local_c[NUM_TASKS];
static uint8_t *local_c_gold[NUM_TASKS];
static uint8_t *local_mx_scale_a[NUM_TASKS];
static uint8_t *local_mx_scale_b[NUM_TASKS];
static uint8_t *local_nq[NUM_TASKS];
static uint32_t task_c_bytes[NUM_TASKS];

static surya_task_config_t surya_tasks[NUM_TASKS];

#define TASK_ALLOC_AND_DMA(i)                                                              \
  do {                                                                                     \
    local_a[i]        = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_A_BYTES(i), 64);       \
    local_b[i]        = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_B_BYTES(i), 64);       \
    local_c[i]        = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_C_BYTES(i), 64);       \
    local_c_gold[i]   = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_C_BYTES(i), 64);       \
    local_mx_scale_a[i] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_MX_SCALE_A_BYTES(i), 64); \
    local_mx_scale_b[i] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_MX_SCALE_B_BYTES(i), 64); \
    local_nq[i]         = (uint8_t *)snrt_l1_alloc_cluster_local(TASK_NQ_BYTES(i), 64);         \
    task_c_bytes[i]   = TASK_C_BYTES(i);                                                   \
    snrt_dma_start_1d(local_a[i], task##i##_matrix_a, TASK_A_BYTES(i));                    \
    snrt_dma_start_1d(local_b[i], task##i##_matrix_b, TASK_B_BYTES(i));                    \
    snrt_dma_start_1d(local_c_gold[i], task##i##_matrix_c, TASK_C_BYTES(i));               \
    snrt_dma_start_1d(local_mx_scale_a[i], task##i##_mx_scale_a, TASK_MX_SCALE_A_BYTES(i)); \
    snrt_dma_start_1d(local_mx_scale_b[i], task##i##_mx_scale_b, TASK_MX_SCALE_B_BYTES(i));   \
    snrt_dma_start_1d(local_nq[i], task##i##_normquant, TASK_NQ_BYTES(i));                    \
  } while (0);

// Assignment, not a designated initializer. The tests compile as C++, which
// accepts a designated initializer only in declaration order.
#define TASK_BUILD_CONFIG(i)                                                  \
  do {                                                                        \
    surya_task_config_t *t = &surya_tasks[i];                                 \
    t->a_ptr           = local_a[i];                                          \
    t->b_ptr           = local_b[i];                                          \
    t->c_ptr           = (int8_t *)local_c[i];                                \
    t->nq_ptr          = (uint32_t *)local_nq[i];                             \
    t->mx_scale_a_ptr  = local_mx_scale_a[i];                                 \
    t->mx_scale_b_ptr  = local_mx_scale_b[i];                                 \
    t->out_dim         = TASK##i##_OUT_DIM;                                   \
    t->mx_out_int8     = TASK##i##_MX_OUT_INT8;                               \
    t->m               = TASK##i##_M;                                         \
    t->n               = TASK##i##_N;                                         \
    t->p               = TASK##i##_P;                                         \
    t->op_mode         = (cim_op_mode_t)TASK##i##_OP_MODE;                    \
    t->norm_mode       = (cim_norm_mode_t)TASK##i##_NORM_MODE;                \
    t->accum_init_mode = (cim_accum_init_mode_t)TASK##i##_ACCUM_INIT_MODE;    \
    t->dw_stride       = TASK##i##_DW_STRIDE;                                 \
    t->nq_dim          = TASK##i##_NQ_DIM;                                    \
    t->a_signed        = TASK##i##_A_SIGNED;                                  \
    t->b_signed        = TASK##i##_B_SIGNED;                                  \
    t->relu            = TASK##i##_RELU;                                      \
    t->out_unsigned    = TASK##i##_OUT_UNSIGNED;                              \
    t->compute         = TASK##i##_COMPUTE;                                   \
    t->streamout       = TASK##i##_STREAMOUT;                                 \
    t->accum_continue  = TASK##i##_ACCUM_CONTINUE;                            \
    t->cim_context     = TASK##i##_CIM_CONTEXT;                               \
    t->c_golden        = (int8_t *)local_c_gold[i];                           \
    t->c_size          = TASK_C_BYTES(i);                                     \
  } while (0);

int main(void) {
  const uint32_t core_idx = snrt_cluster_core_idx();

  snrt_int_clr_mcip();

  if (snrt_is_dm_core()) {
    SURYA_TASKS(TASK_ALLOC_AND_DMA)
    snrt_dma_wait_all();
  }
  snrt_cluster_hw_barrier();

  if (core_idx == 0) {
    GW_HWPE_WRITE(GW_HWPE_MUX_SEL_OFFS, GW_HWPE_MUX_SEL_SURYA);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, GW_HWPE_CLK_EN_SURYA);
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

  if (core_idx != 0) return 0;

  int total_errors = 0;
  for (uint32_t t = 0; t < NUM_TASKS; t++) {
    int errors = 0;
    for (uint32_t i = 0; i < task_c_bytes[t]; i++) {
      if (local_c[t][i] != local_c_gold[t][i]) errors++;
    }
    if (errors) {
      printf("Task %u: FAIL %d/%u bytes\n", (unsigned)t, errors, (unsigned)task_c_bytes[t]);
    } else {
      printf("Task %u: PASS (%u bytes)\n", (unsigned)t, (unsigned)task_c_bytes[t]);
    }
    total_errors += errors;
  }

  return total_errors;
}
