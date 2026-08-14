// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "gw_addrmap_64b.h"
#include "gw_memtile.h"
#include "gw_raw_addrmap_64b.h"

#include "snitch_cluster_cfg.h"

// Return code array placed at the last 4K page of the L2 SPM region.
// This address scales automatically with the number and size of memory tiles.
#define RETURN_CODE_ADDR \
  (GW_L2_SPM_BASE_ADDR(0) + GW_L2_SPM_TOTAL_SIZE - 0x1000)

#ifndef GW_HTILE_BASE_ADDR
int main() { return 1; }
#else

// This needs to be in a region which is not cached.
volatile uint32_t *return_code_array = (volatile uint32_t *)RETURN_CODE_ADDR;

static int htile_finished(void) {
  for (int i = 0; i < CFG_CLUSTER_NR_CORES; i++) {
    if ((return_code_array[i] & 1) == 0) {
      return 0;
    }
  }
  return 1;
}

int main() {
  // Write entry point to scratch register 1 and return code address to scratch
  // register 0. The h-tile is started directly by Cheshire in this test.
  *(volatile uint64_t *)GW_HTILE_PERIPHERAL_REG_SCRATCH_BASE_ADDR(1) =
      (uintptr_t)&gwaihir_addrmap_64b.l2_spm_0;
  *(volatile uint64_t *)GW_HTILE_PERIPHERAL_REG_SCRATCH_BASE_ADDR(0) =
      (uintptr_t)return_code_array;

  for (int i = 0; i < CFG_CLUSTER_NR_CORES; i++) {
    return_code_array[i] = 0;
  }

  *(volatile uint64_t *)GW_HTILE_PERIPHERAL_REG_CL_CLINT_SET_BASE_ADDR =
      (1 << CFG_CLUSTER_NR_CORES) - 1;

  while (!htile_finished()) {
  }

  uint32_t sum = 0;
  for (int i = 0; i < CFG_CLUSTER_NR_CORES; i++) {
    sum += (return_code_array[i] >> 1);
  }

  return sum;
}

#endif
