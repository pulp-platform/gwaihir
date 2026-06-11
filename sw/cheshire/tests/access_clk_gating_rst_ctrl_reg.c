// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Cyrill Durrer <cdurrer@iis.ee.ethz.ch>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"

#define CLUSTER_MASK  ((1u << GWAIHIR_ADDRMAP_CLUSTER_NUM) - 1u)
#define MEM_TILE_MASK ((1u << GWAIHIR_ADDRMAP_L2_SPM_NUM)  - 1u)

int main(void) {

    uint32_t n_errors = 3 * 4; // 3 tests, 4 registers each

    volatile gw_soc_regs_t *gw_soc_regs = &gwaihir_addrmap.cheshire_internal.gw_soc_regs;

    // Write all 0s and check
    gw_soc_regs->cluster_clk_enables.f.clk_en = 0x00000000;
    gw_soc_regs->mem_tile_clk_enables.f.clk_en = 0x00000000;
    gw_soc_regs->cluster_rsts.f.rst = 0x00000000;
    gw_soc_regs->mem_tile_rsts.f.rst = 0x00000000;

    n_errors -= (gw_soc_regs->cluster_clk_enables.f.clk_en == 0x00000000);
    n_errors -= (gw_soc_regs->mem_tile_clk_enables.f.clk_en == 0x00000000);
    n_errors -= (gw_soc_regs->cluster_rsts.f.rst == 0x00000000);
    n_errors -= (gw_soc_regs->mem_tile_rsts.f.rst == 0x00000000);

    // Write all 1s and check
    gw_soc_regs->cluster_clk_enables.f.clk_en = CLUSTER_MASK;
    gw_soc_regs->mem_tile_clk_enables.f.clk_en = MEM_TILE_MASK;
    gw_soc_regs->cluster_rsts.f.rst = CLUSTER_MASK;
    gw_soc_regs->mem_tile_rsts.f.rst = MEM_TILE_MASK;

    n_errors -= (gw_soc_regs->cluster_clk_enables.f.clk_en == CLUSTER_MASK);
    n_errors -= (gw_soc_regs->mem_tile_clk_enables.f.clk_en == MEM_TILE_MASK);
    n_errors -= (gw_soc_regs->cluster_rsts.f.rst == CLUSTER_MASK);
    n_errors -= (gw_soc_regs->mem_tile_rsts.f.rst == MEM_TILE_MASK);

    // Write alternating pattern and check
    gw_soc_regs->cluster_clk_enables.f.clk_en = 0xAAAAAAAAu & CLUSTER_MASK;
    gw_soc_regs->mem_tile_clk_enables.f.clk_en = 0xAAAAAAAAu & MEM_TILE_MASK;
    gw_soc_regs->cluster_rsts.f.rst = 0x55555555u & CLUSTER_MASK;
    gw_soc_regs->mem_tile_rsts.f.rst = 0x55555555u & MEM_TILE_MASK;

    n_errors -= (gw_soc_regs->cluster_clk_enables.f.clk_en == (0xAAAAAAAAu & CLUSTER_MASK));
    n_errors -= (gw_soc_regs->mem_tile_clk_enables.f.clk_en == (0xAAAAAAAAu & MEM_TILE_MASK));
    n_errors -= (gw_soc_regs->cluster_rsts.f.rst == (0x55555555u & CLUSTER_MASK));
    n_errors -= (gw_soc_regs->mem_tile_rsts.f.rst == (0x55555555u & MEM_TILE_MASK));

    return n_errors;
}
