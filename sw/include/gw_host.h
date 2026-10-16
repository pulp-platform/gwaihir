// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Gabriele Lodi <galodi@ethz.ch>
//
// This header file is used to collect host-related common functions and parameters

#pragma once

// Pull in the closed-source UCIe PCS driver when it is on the include path
// (i.e. when the closed UCIe dependency is checked out). Tests can then guard
// PCS-specific link bring-up with `#ifdef GW_UCIE_CLOSED_PCS`.
#if defined(__has_include)
#if __has_include("ucie_closed_pcs.h")
#define GW_UCIE_CLOSED_PCS 1
#include "ucie_closed_pcs.h"
#endif
#endif

// Ungate a tile's clock and release its reset, then read both bits back.
// `clk_rst_bypass_i` is tied low in simulation, so a tile stays clock-gated and
// held in reset until software does this. The clock is enabled first, so the
// tile leaves reset with a running clock.
static int tile_enable(volatile gw_tile_regs_t *cfg) {
  cfg->clk.f.en = 0x1;
  cfg->rst.f.n = 0x1;
  return (cfg->clk.f.en == 0x1) && (cfg->rst.f.n == 0x1);
}

// Ungate the UCIe tile clock and release the macro (PHY + PCS) reset. The
// serial link stays in reset, so the PCS can be configured before any traffic.
static int ucie_tile_enable_macro(volatile gw_ucie_tile_regs_t *cfg) {
  cfg->clk.f.en = 0x1;
  cfg->rst_apb.f.n = 0x1;
  return (cfg->clk.f.en == 0x1) && (cfg->rst_apb.f.n == 0x1);
}

// Release the serial link and RDI adapter reset
static int ucie_tile_enable_link(volatile gw_ucie_tile_regs_t *cfg) {
  cfg->rst_axi.f.n = 0x1;
  return cfg->rst_axi.f.n == 0x1;
}

static int ucie_tile_enable(volatile gw_ucie_tile_regs_t *cfg) {
  return ucie_tile_enable_macro(cfg) && ucie_tile_enable_link(cfg);
}

// Enable a pair of linked UCIe tiles. With the closed-source PCS, the link is
// configured between macro and serial link release.
static int ucie_tiles_enable(volatile gw_ucie_tile_regs_t *cfg0, volatile gw_ucie_tile_regs_t *cfg1,
                             uintptr_t pcs0, uintptr_t pcs1) {
  if (!(ucie_tile_enable_macro(cfg0) && ucie_tile_enable_macro(cfg1))) return 0;
#ifdef GW_UCIE_CLOSED_PCS
  if (ucie_link_bringup(pcs0, pcs1) != 0u) return 0;
#else
  (void)pcs0;
  (void)pcs1;
#endif
  return ucie_tile_enable_link(cfg0) && ucie_tile_enable_link(cfg1);
}

// Select the PHY streaming bandwidth mode: `half_bw` = 0 selects full
// bandwidth
static int ucie_tile_set_half_bw(volatile gw_ucie_tile_regs_t *cfg, int half_bw) {
  cfg->phy_mode.f.half_bw_en = half_bw ? 0x1 : 0x0;
  return cfg->phy_mode.f.half_bw_en == (half_bw ? 0x1 : 0x0);
}
