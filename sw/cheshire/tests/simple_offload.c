// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>

#include <stdint.h>
#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"

#include "snitch_cluster_cfg.h"

// Return code array placed at the last 4K page of the L2 SPM region.
// This address scales automatically with the number and size of memory tiles.
#define RETURN_CODE_ADDR \
  (GW_L2_SPM_BASE_ADDR(0) + GW_L2_SPM_TOTAL_SIZE - 0x1000)

// This needs to be in a region which is not cached
volatile uint32_t (*return_code_array)[CFG_CLUSTER_NR_CORES] = (uint32_t (*)[CFG_CLUSTER_NR_CORES])RETURN_CODE_ADDR;

int main() {

  // Write entry point to scratch register 1
  // and return code address to scratch register 0
  // Initalize return address loaction before offloading.
  for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
    *(volatile uint64_t *)&(gwaihir_addrmap.cluster[i].peripheral_reg.scratch[1].w) = (uintptr_t)&gwaihir_addrmap.l2_spm;
    *(volatile uint64_t *)&(gwaihir_addrmap.cluster[i].peripheral_reg.scratch[0].w) = (uintptr_t)&return_code_array[i];
    for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
      return_code_array[i][j] = 0;
    }
  }

  // Start all cores in Cluster 0, which will wake up all other clusters
  *(volatile uint64_t *)&(gwaihir_addrmap.cluster[0].peripheral_reg.cl_clint_set.w) = (1 << CFG_CLUSTER_NR_CORES) - 1;

  // Wait until all cores have finished
  int all_finished = 0;
  while (!all_finished) {
    all_finished = 1;
    for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
      for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
        if ((return_code_array[i][j] & 1) == 0) {
          all_finished = 0;
          break;
        }
      }
    }
  }

  // Sum up the return codes
  uint32_t sum = 0;
  for (int i = 0; i < SNRT_CLUSTER_NUM; i++) {
    for (int j = 0; j < CFG_CLUSTER_NR_CORES; j++) {
      sum += (return_code_array[i][j] >> 1);
    }
  }

  return sum;
}
