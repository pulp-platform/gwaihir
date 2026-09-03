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

// Enable clk/rst cfg regs for tiles
static int tile_clk_rst_enable(gw_tile_regs_t *regs) {
  regs->clk.f.en = 0x1;
  regs->rst.f.n = 0x1;
  return ((regs->clk.f.en != 0x1) | (regs->rst.f.n != 0x1));
}

int main() {

  // Enable clk/rst for ucie tiles
  volatile gw_tile_regs_t *ucie_cfg0 = (volatile gw_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie0_tile_cfg;
  volatile gw_tile_regs_t *ucie_cfg1 = (volatile gw_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie1_tile_cfg;

  if (tile_clk_rst_enable(ucie_cfg0) | (tile_clk_rst_enable(ucie_cfg1))) return 1;

  // Write to chiplet1's L2 through the ucie0 alias window (routed via UCIe).
  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm_0;
  // Read back through the canonical address (routed via the local NoC).
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm_2;

  (*alias_wr) = TRANSFER_DATA;

  fence();

  return (*local_rd != TRANSFER_DATA);

}
