// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>
#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"

#define TRANSFER_DATA 0xdeadbeef

int main() {

  // Write to chiplet1's L2 through the ucie0 alias window (routed via UCIe).
  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm[0];
  // Read back through the canonical address (routed via the local NoC).
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm[2];

  (*alias_wr) = TRANSFER_DATA;

  fence();

  return (*local_rd != TRANSFER_DATA);

}