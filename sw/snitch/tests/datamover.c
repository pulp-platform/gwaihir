// Copyright 2023-2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Datamover HWPE on the H tile. The datamover model generates the tasks in
// `datamover_workload.h` from `tests/gwaihir.json` in the datamover repository.
// The tasks are an 8-bit, a 16-bit and a 32-bit transpose and a copy. Each task
// reads the output of the task before it. Three more 8-bit transposes read the
// input in the shapes of the packed MXINT4 V blocks of Surya-MX.
//
// The test does these steps:
//   1. The DM core copies the input from L2 to the TCDM.
//   2. Core 0 selects the datamover, enables its clock and starts the tasks
//      and the V block transposes. Guard bytes around each V block must not
//      change.
//   3. Core 0 waits until the datamover is idle, clears the event and disables
//      the clock.
//   4. The DM core copies the outputs to L2. `experiments/datamover/verify.py`
//      compares them with the golden data in the ELF.
//
// Build and run the test on the H tile:
//   make sn-tests chs-sw-tests
//   make vsim-run-batch-verify CHS_BINARY=sw/cheshire/tests/simple_htile_offload.spm.elf \
//     SN_BINARY=sw/snitch/tests/build/datamover.elf VERIFY_PY=experiments/datamover/verify.py \
//     PRELMODE=3

#include <stdint.h>

#include "snrt.h"
#include "gw_hwpe_subsystem_addrmap.h"

#define GW_HWPE_BASE        GW_HWPE_BASE_ADDR(gw_htile())
#define DATAMOVER_BASE_ADDR (GW_HWPE_BASE + GW_HWPE_DATAMOVER_OFFS)

#include "datamover_hal.h"
#include "datamover_workload.h"

static_assert(sizeof(datamover_regif_t) <= GW_HWPE_ACC_WINDOW,
              "the datamover register file outgrew the subsystem window");

#define GW_HWPE_WRITE(offs, value) \
  (*(volatile uint32_t *)(GW_HWPE_BASE + (offs)) = (uint32_t)(value))

// The runtime clears .bss at boot with slow core stores to L2. It does not clear .dram.
#define L2_OUT __attribute__((section(".dram"), aligned(64)))
#define TASK_L2_OUT(i) L2_OUT uint8_t task##i##_result[TASK##i##_OUT_SIZE];
DATAMOVER_TASKS(TASK_L2_OUT)

// Rows x columns of the packed MXINT4 V block of the 1k, 2k and 4k MAC Surya-MX. The 64 B guard
// aligns each block to a superbank: the H tile TCDM port does not realign across superbanks.
// `experiments/datamover/verify.py` uses the same values.
#define V_BLOCKS(X) X(32, 16) X(32, 32) X(64, 32)
#define V_GUARD     64
#define V_FILL      0xa5
#define V_BUF_BYTES(m, n) ((m) * (n) + 2 * V_GUARD)
#define V_L2_OUT(m, n)    L2_OUT uint8_t v_result_##m##x##n[V_BUF_BYTES(m, n)];
V_BLOCKS(V_L2_OUT)

// local_buf[0] is the input. local_buf[i + 1] is the output of task i.
static uint8_t *local_buf[NUM_TASKS + 1];
#define V_LOCAL(m, n) static uint8_t *local_v_##m##x##n;
V_BLOCKS(V_LOCAL)

#define TASK_ALLOC(i) \
  local_buf[i + 1] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK##i##_OUT_SIZE, 64);

#define TASK_CONFIG(i)                                               \
  {                                                                  \
      .in_ptr      = local_buf[i],                                   \
      .out_ptr     = local_buf[i + 1],                               \
      .out_size    = TASK##i##_OUT_SIZE,                             \
      .mode        = (datamover_mode_t)TASK##i##_DATAMOVER_MODE,     \
      .transp_mode = (datamover_transp_mode_t)TASK##i##_TRANSP_MODE, \
      .block_mode  = TASK##i##_BLOCK_MODE,                           \
      .size_c      = TASK##i##_SIZE_C,                               \
      .size_m      = TASK##i##_SIZE_M,                               \
      .size_n      = TASK##i##_SIZE_N,                               \
      .kernel_h    = TASK##i##_KERNEL_SIZE_H,                        \
      .kernel_w    = TASK##i##_KERNEL_SIZE_W,                        \
      .conv_stride = TASK##i##_CONV_STRIDE,                          \
      .conv_pad    = TASK##i##_CONV_PAD,                             \
      .layout      = TASK##i##_LAYOUT,                               \
      .im2col_in   = TASK##i##_IM2COL_IN,                            \
      .im2col_out  = TASK##i##_IM2COL_OUT,                           \
  },

#define TASK_DMA_OUT(i) snrt_dma_start_1d(task##i##_result, local_buf[i + 1], TASK##i##_OUT_SIZE);

#define V_ALLOC(m, n) \
  local_v_##m##x##n = (uint8_t *)snrt_l1_alloc_cluster_local(V_BUF_BYTES(m, n), 64);

// Volatile stores keep LLVM from a vector fill.
#define V_TRANSPOSE(m, n)                                                \
  {                                                                      \
    volatile uint8_t *guard = local_v_##m##x##n;                         \
    for (uint32_t k = 0; k < V_GUARD; k++) {                             \
      guard[k]                       = V_FILL;                           \
      guard[V_GUARD + (m) * (n) + k] = V_FILL;                           \
    }                                                                    \
    datamover_transpose(local_buf[0], local_v_##m##x##n + V_GUARD, m, n, \
                        DATAMOVER_TRANSP_1ELEM);                         \
  }

#define V_DMA_OUT(m, n) \
  snrt_dma_start_1d(v_result_##m##x##n, local_v_##m##x##n, V_BUF_BYTES(m, n));

int main(void) {
  const uint32_t core_idx = snrt_cluster_core_idx();

  snrt_int_clr_mcip();

  // Only the H tile holds the datamover.
  if (snrt_cluster_idx() != GW_HTILE_CLUSTER_IDX) return 0;

  if (snrt_is_dm_core()) {
    local_buf[0] = (uint8_t *)snrt_l1_alloc_cluster_local(TASK0_IN_SIZE, 64);
    DATAMOVER_TASKS(TASK_ALLOC)
    V_BLOCKS(V_ALLOC)
    snrt_dma_start_1d(local_buf[0], task0_golden_in, TASK0_IN_SIZE);
    snrt_dma_wait_all();
  }
  snrt_cluster_hw_barrier();

  if (core_idx == 0) {
    GW_HWPE_WRITE(GW_HWPE_MUX_SEL_OFFS, GW_HWPE_MUX_SEL_DATAMOVER);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, GW_HWPE_CLK_EN_DATAMOVER);
    // The clock gate needs a few cycles before the register file answers.
    for (volatile int k = 0; k < 5; k++);

    datamover_soft_clear();

    const datamover_task_config_t tasks[NUM_TASKS] = {DATAMOVER_TASKS(TASK_CONFIG)};
    // The datamover runs the jobs in order.
    for (uint32_t i = 0; i < NUM_TASKS; i++) datamover_run(&tasks[i]);
    V_BLOCKS(V_TRANSPOSE)

    datamover_wait();

    GW_HWPE_WRITE(GW_HWPE_EVT_CLR_OFFS, 1 << core_idx);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, 0);
  }
  snrt_cluster_hw_barrier();

  // The L2 dump starts when all cores return, so the DM core waits for its DMA.
  if (snrt_is_dm_core()) {
    DATAMOVER_TASKS(TASK_DMA_OUT)
    V_BLOCKS(V_DMA_OUT)
    snrt_dma_wait_all();
  }
  return 0;
}
