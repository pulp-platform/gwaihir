// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Gabriele Lodi <galodi@ethz.ch>
//
// This header file is used to collect host-related common functions and parameters

#pragma once

// Ungate a tile's clock and release its reset, then read both bits back.
// `clk_rst_bypass_i` is tied low in simulation, so a tile stays clock-gated and
// held in reset until software does this. The clock is enabled first, so the
// tile leaves reset with a running clock.
static int tile_enable(volatile gw_tile_regs_t *cfg) {
  cfg->clk.f.en = 0x1;
  cfg->rst.f.n = 0x1;
  return (cfg->clk.f.en == 0x1) && (cfg->rst.f.n == 0x1);
}

static int ucie_tile_enable(volatile gw_ucie_tile_regs_t *cfg) {
  cfg->clk.f.en = 0x1;
  cfg->rst_axi.f.n = 0x1;
  cfg->rst_apb.f.n = 0x1;
  return (cfg->clk.f.en == 0x1) && (cfg->rst_axi.f.n == 0x1) && (cfg->rst_apb.f.n == 0x1);
}

// Select the PHY streaming bandwidth mode: `half_bw` = 0 selects full
// bandwidth
static int ucie_tile_set_half_bw(volatile gw_ucie_tile_regs_t *cfg, int half_bw) {
  cfg->phy_mode.f.half_bw_en = half_bw ? 0x1 : 0x0;
  return cfg->phy_mode.f.half_bw_en == (half_bw ? 0x1 : 0x0);
}
