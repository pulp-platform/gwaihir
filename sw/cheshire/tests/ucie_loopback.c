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

  volatile uint32_t *l2_mem = (volatile uint32_t *)((uintptr_t)&gwaihir_addrmap_64b.l2_spm + (uintptr_t)&gwaihir_addrmap_64b.ucie);
  (*l2_mem) = TRANSFER_DATA;

  fencei();

  return (*l2_mem != TRANSFER_DATA);

}