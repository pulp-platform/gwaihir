// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Chen Wu <chenwu@iis.ee.ethz.ch>

#include <stdint.h>
#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_host.h"

#if defined(__has_include)
#if __has_include("ucie_closed_pcs.h")
#define GW_UCIE_CLOSED_PCS 1
#include "ucie_closed_pcs.h"
#endif
#endif

#define TRANSFER_DATA 0xdeadbeef


int main() {

  // Enable clk/rst for ucie tiles
  volatile gw_ucie_tile_regs_t *ucie_cfg0 = (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie0_tile_cfg;
  volatile gw_ucie_tile_regs_t *ucie_cfg1 = (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie1_tile_cfg;

  if ( (ucie_tile_enable(ucie_cfg0) && (ucie_tile_enable(ucie_cfg1))) == 0) return 1;

#ifdef GW_UCIE_CLOSED_PCS
  uintptr_t ucie0_csr = (uintptr_t)&gwaihir_addrmap_64b.ucie0_ucie_cfg;
  uintptr_t ucie1_csr = (uintptr_t)&gwaihir_addrmap_64b.ucie1_ucie_cfg;

  if (ucie_pcs_bringup(ucie0_csr) != 0u) return 1;
  if (ucie_pcs_bringup(ucie1_csr) != 0u) return 1;

  volatile uint32_t *slink0 = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0_axi_serial_cfg;
  volatile uint32_t *slink1 = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie1_axi_serial_cfg;
  slink0[0] = 0x00000003u;
  slink1[0] = 0x00000003u;
  for (volatile uint64_t d = 0; d < 64; d++) { }

  ucie_pcs_bridge_enable(ucie0_csr, ucie1_csr);
#endif

  // Write to chiplet1's L2 through the ucie0 alias window (routed via UCIe).
  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm_0;
  // Read back through the canonical address (routed via the local NoC).
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm_2;

  (*alias_wr) = TRANSFER_DATA;

  fence();

  return (*local_rd != TRANSFER_DATA);

}
