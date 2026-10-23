// Copyright 2023-2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Datamover HWPE on the H tile. The test does these steps:
//   1. The DM core copies the input and the golden outputs from L2 to the TCDM.
//   2. Core 0 selects the datamover, enables its clock and starts four chained
//      jobs on a 64 x 64 byte matrix: an 8-bit transpose, a 16-bit and a 32-bit
//      transpose of the result, and a copy.
//   3. Core 0 waits until the datamover is idle, clears the event and disables
//      the clock. It returns the number of wrong 64-bit words.
//
// Build and run the test on the H tile:
//   make sn-tests
//   make vsim-run-batch SN_BINARY=sw/snitch/tests/build/htile/datamover.elf \
//     PRELMODE=5 OFFLOAD_HTILE=1

#include <stdint.h>

#include "snrt.h"
#include "gw_hwpe_subsystem_addrmap.h"

#define GW_HWPE_BASE        GW_HWPE_BASE_ADDR(gw_htile())
#define DATAMOVER_BASE_ADDR (GW_HWPE_BASE + GW_HWPE_DATAMOVER_OFFS)

#include "datamover_hal.h"

#include "data/datamover_data.h"

static_assert(sizeof(datamover_regif_t) <= GW_HWPE_ACC_WINDOW,
              "the datamover register file outgrew the subsystem window");

#define GW_HWPE_WRITE(offs, value) \
  (*(volatile uint32_t *)(GW_HWPE_BASE + (offs)) = (uint32_t)(value))

#define IN_BYTES (SIZE * SIZE)

static uint8_t *local_in;
static uint8_t *local_out;
static uint8_t *local_out2;
static uint8_t *local_out3bis;
static uint8_t *local_out3;
static uint8_t *local_gold;
static uint8_t *local_gold2;
static uint8_t *local_gold3;

// A 64-bit compare of two loads becomes vcpop.m on RV32, which Spatz does not implement.
static int compare_words(const uint8_t *actual, const uint8_t *golden, uint32_t bytes) {
  const uint32_t *a = (const uint32_t *)actual;
  const uint32_t *g = (const uint32_t *)golden;
  int errors = 0;
  for (uint32_t i = 0; i < bytes / sizeof(uint64_t); i++) {
    errors += (a[2 * i] != g[2 * i]) | (a[2 * i + 1] != g[2 * i + 1]);
  }
  return errors;
}

int main(void) {
  const uint32_t core_idx = snrt_cluster_core_idx();

  snrt_int_clr_mcip();

  // Only the H tile holds the datamover.
  if (snrt_cluster_idx() != GW_HTILE_CLUSTER_IDX) return 0;

  if (snrt_is_dm_core()) {
    local_in      = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES, 64);
    local_out     = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES, 64);
    local_gold    = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES, 64);
    local_out2    = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES / 2, 64);
    local_gold2   = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES / 2, 64);
    local_out3    = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES / 4, 64);
    local_out3bis = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES / 4, 64);
    local_gold3   = (uint8_t *)snrt_l1_alloc_cluster_local(IN_BYTES / 4, 64);
    snrt_dma_start_1d(local_in, golden_in, IN_BYTES);
    snrt_dma_start_1d(local_gold, golden_out, IN_BYTES);
    snrt_dma_start_1d(local_gold2, golden_out2, IN_BYTES / 2);
    snrt_dma_start_1d(local_gold3, golden_out3, IN_BYTES / 4);
    snrt_dma_wait_all();
  }
  snrt_cluster_hw_barrier();

  if (core_idx == 0) {
    GW_HWPE_WRITE(GW_HWPE_MUX_SEL_OFFS, GW_HWPE_MUX_SEL_DATAMOVER);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, GW_HWPE_CLK_EN_DATAMOVER);
    // The clock gate needs a few cycles before the register file answers.
    for (volatile int k = 0; k < 5; k++);

    datamover_soft_clear();

    // Each job reads the output of the job before it. The datamover runs the jobs in order.
    datamover_transpose(local_in, local_out, SIZE, SIZE, DATAMOVER_TRANSP_1ELEM);
    datamover_transpose(local_out, local_out2, SIZE / 2, SIZE, DATAMOVER_TRANSP_2ELEM);
    datamover_transpose(local_out2, local_out3bis, SIZE / 4, SIZE, DATAMOVER_TRANSP_4ELEM);
    datamover_copy(local_out3bis, local_out3, SIZE / 4, SIZE);

    datamover_wait();

    GW_HWPE_WRITE(GW_HWPE_EVT_CLR_OFFS, 1 << core_idx);
    GW_HWPE_WRITE(GW_HWPE_CLK_EN_OFFS, 0);
  }
  snrt_cluster_hw_barrier();

  if (core_idx != 0) return 0;

  int errors = compare_words(local_out, local_gold, IN_BYTES);
  errors += compare_words(local_out2, local_gold2, IN_BYTES / 2);
  errors += compare_words(local_out3, local_gold3, IN_BYTES / 4);
  return errors;
}
