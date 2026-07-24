// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>
#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

#define TRANSFER_DATA 0xdeadbeef

int main() {

  // Write to the chiplet's L2 through the ucie0 alias window (routed via UCIe).
  // NOTE(rebase): endpoint split renamed the inner array field l2_spm[0] -> l2_spm_0.
  // CONFIRM after regenerating the addrmap that ucie0 (rdl_name "chiplet") exposes
  // `l2_spm_0`, and that ucie0.l2_spm_0 still loops back to local tile 2 (see read).
  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm_0;
  // Read back through the canonical local address (routed via the local NoC).
  volatile uint32_t *local_rd = (volatile uint32_t *)(uintptr_t)GW_L2_SPM_BASE_ADDR(2);

  (*alias_wr) = TRANSFER_DATA;

  fence();

  return (*local_rd != TRANSFER_DATA);

}
