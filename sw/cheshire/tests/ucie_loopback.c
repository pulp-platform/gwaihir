// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"

#define TRANSFER_DATA 0xdeadbeef

int main() {

  // TODO: OR-ing ucie0's base hardcodes chiplet-select bit 25 = 1 (only chiplet0->chiplet1); 
  //       a correct alias derives bit 25 from the destination chiplet.
  volatile uint32_t *l2_chiplet1 = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_64b.l2_spm | (uintptr_t)&gwaihir_addrmap_64b.ucie0);
  (*l2_chiplet1) = TRANSFER_DATA;

  fencei();

  return (*l2_chiplet1 != TRANSFER_DATA);

}