// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Hong Pang <hopang@iis.ee.ethz.ch>
//
// Tile-indexed L2 mem-tile accessors, shared by the 64b (Cheshire) and 32b
// (Snitch) address maps. The four L2 SPM tiles are four individual address-map
// endpoints with heterogeneous sizes (tiles 0,2 = 2 MiB, tiles 1,3 = 1 MiB), so
// the generated headers expose only per-tile macros (GW_L2_SPM_<i>_*); these
// re-create the tile-indexed accessors on top of them.
//
// This header is address-map-agnostic: the includer MUST already have the
// per-tile GW_L2_SPM_<i>_* macros in scope (from gw_raw_addrmap_64b.h for the
// Cheshire 64b map, or gw_raw_addrmap_32b.h for the Snitch 32b map). Index i is
// the tile index 0..GW_L2_SPM_NUM-1.

#pragma once

#define GW_L2_SPM_NUM 4

// L2 SPM memory window of tile i (base) and its size.
#define GW_L2_SPM_BASE_ADDR(i) \
    ((i) == 0 ? GW_L2_SPM_0_BASE_ADDR : (i) == 1 ? GW_L2_SPM_1_BASE_ADDR : \
     (i) == 2 ? GW_L2_SPM_2_BASE_ADDR :            GW_L2_SPM_3_BASE_ADDR)
#define GW_L2_SPM_SIZE(i) \
    ((i) == 0 ? GW_L2_SPM_0_SIZE : (i) == 1 ? GW_L2_SPM_1_SIZE : \
     (i) == 2 ? GW_L2_SPM_2_SIZE :            GW_L2_SPM_3_SIZE)

// iDMA register window of tile i.
#define GW_L2_SPM_DMA_BASE_ADDR(i) \
    ((i) == 0 ? GW_L2_SPM_0_DMA_BASE_ADDR : (i) == 1 ? GW_L2_SPM_1_DMA_BASE_ADDR : \
     (i) == 2 ? GW_L2_SPM_2_DMA_BASE_ADDR :            GW_L2_SPM_3_DMA_BASE_ADDR)

// Tile config (gw_tile_regs) window of tile i, plus its clk-enable / reset regs.
#define GW_L2_SPM_CONFIG_BASE_ADDR(i) \
    ((i) == 0 ? GW_L2_SPM_0_CONFIG_BASE_ADDR : (i) == 1 ? GW_L2_SPM_1_CONFIG_BASE_ADDR : \
     (i) == 2 ? GW_L2_SPM_2_CONFIG_BASE_ADDR :            GW_L2_SPM_3_CONFIG_BASE_ADDR)
#define GW_L2_SPM_CONFIG_CLK_BASE_ADDR(i) \
    ((i) == 0 ? GW_L2_SPM_0_CONFIG_CLK_BASE_ADDR : (i) == 1 ? GW_L2_SPM_1_CONFIG_CLK_BASE_ADDR : \
     (i) == 2 ? GW_L2_SPM_2_CONFIG_CLK_BASE_ADDR :            GW_L2_SPM_3_CONFIG_CLK_BASE_ADDR)
#define GW_L2_SPM_CONFIG_RST_BASE_ADDR(i) \
    ((i) == 0 ? GW_L2_SPM_0_CONFIG_RST_BASE_ADDR : (i) == 1 ? GW_L2_SPM_1_CONFIG_RST_BASE_ADDR : \
     (i) == 2 ? GW_L2_SPM_2_CONFIG_RST_BASE_ADDR :            GW_L2_SPM_3_CONFIG_RST_BASE_ADDR)

// Uniform tile-to-tile stride (bases sit on a fixed grid even though sizes differ).
#define GW_L2_SPM_STRIDE (GW_L2_SPM_1_BASE_ADDR - GW_L2_SPM_0_BASE_ADDR)

// Total L2 address SPAN (first tile base .. end of last tile) = top of L2.
// NOTE: this includes the 1 MiB "Free" gaps above the half-size tiles; it is NOT
// the sum of the mapped tile sizes.
#define GW_L2_SPM_TOTAL_SIZE \
    (GW_L2_SPM_3_BASE_ADDR + GW_L2_SPM_3_SIZE - GW_L2_SPM_0_BASE_ADDR)


// Ungate a tile's clock and release its reset, then read both bits back.
// `clk_rst_bypass_i` is tied low in simulation, so a tile stays clock-gated and
// held in reset until software does this. The clock is enabled first, so the
// tile leaves reset with a running clock.
static int tile_enable(volatile gw_tile_regs_t *cfg) {
  cfg->clk.f.en = 0x1;
  cfg->rst.f.n = 0x1;
  return (cfg->clk.f.en == 0x1) && (cfg->rst.f.n == 0x1);
}
