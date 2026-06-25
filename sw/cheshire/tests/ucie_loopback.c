// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "params.h"
#include "util.h"
#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"


int main() {

  volatile uintptr_t TileUcie0BaseAddr = 0x100000000ULL;
  volatile uint64_t *l2_mem_w = (volatile uint64_t *)((uintptr_t)&gwaihir_addrmap.l2_spm + TileUcie0BaseAddr);
  (*l2_mem_w) = 0xdeadbeefULL;

  fencei();

  return 0;

}