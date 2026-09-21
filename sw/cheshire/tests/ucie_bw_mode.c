// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Verifies that the UCIe tile's PHY streaming path works both in full
// bandwidth (native PHY width, reset default) and half bandwidth (PHY width
// halved, duplicated across both halves of the bus) mode, by writing a
// distinct pattern through the ucie0 alias window and reading it back
// through the canonical address in each mode.

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

#define TRANSFER_DATA_FULL_BW 0xdeadbeef
#define TRANSFER_DATA_HALF_BW 0xcafef00d

int main() {

  // Enable clk/rst for ucie tiles
  volatile gw_ucie_tile_regs_t *ucie_cfg0 = (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie0_tile_cfg;
  volatile gw_ucie_tile_regs_t *ucie_cfg1 = (volatile gw_ucie_tile_regs_t *)(uintptr_t)&gwaihir_addrmap_64b.ucie1_tile_cfg;

  if ((ucie_tile_enable(ucie_cfg0) && ucie_tile_enable(ucie_cfg1)) == 0) return 1;

#ifdef GW_UCIE_CLOSED_PCS
  if (ucie_link_bringup((uintptr_t)&gwaihir_addrmap_64b.ucie0_ucie_cfg,
                        (uintptr_t)&gwaihir_addrmap_64b.ucie1_ucie_cfg,
                        (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0_axi_serial_cfg,
                        (volatile uint32_t *)&gwaihir_addrmap_64b.ucie1_axi_serial_cfg) != 0u)
    return 1;
#endif

  // Write to chiplet1's L2 through the ucie0 alias window (routed via UCIe).
  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm_0;
  // Read back through the canonical address (routed via the local NoC).
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm_2;

  // Full bandwidth (reset default on both tiles): no explicit mode switch needed.
  if ((ucie_cfg0->phy_mode.f.half_bw_en != 0) || (ucie_cfg1->phy_mode.f.half_bw_en != 0)) return 1;

  (*alias_wr) = TRANSFER_DATA_FULL_BW;
  fence();
  if (*local_rd != TRANSFER_DATA_FULL_BW) return 1;

  // Switch both tiles to half bandwidth mode (both ends of a link must agree).
  if ((ucie_tile_set_half_bw(ucie_cfg0, 1) && ucie_tile_set_half_bw(ucie_cfg1, 1)) == 0) return 1;

  (*alias_wr) = TRANSFER_DATA_HALF_BW;
  fence();
  if (*local_rd != TRANSFER_DATA_HALF_BW) return 1;

  // Switch back to full bandwidth and confirm the path still works afterwards.
  if ((ucie_tile_set_half_bw(ucie_cfg0, 0) && ucie_tile_set_half_bw(ucie_cfg1, 0)) == 0) return 1;

  (*alias_wr) = TRANSFER_DATA_FULL_BW;
  fence();
  if (*local_rd != TRANSFER_DATA_FULL_BW) return 1;

  return 0;
}
