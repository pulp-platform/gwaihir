// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Cyrill Durrer <cdurrer@iis.ee.ethz.ch>

#include "gw_addrmap.h"

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

    // Write all 1s and check again
    gw_soc_regs->cluster_clk_enables.f.clk_en = 0x0000FFFF;
    gw_soc_regs->mem_tile_clk_enables.f.clk_en = 0x000000FF;
    gw_soc_regs->cluster_rsts.f.rst = 0x0000FFFF;
    gw_soc_regs->mem_tile_rsts.f.rst = 0x000000FF;

    n_errors -= (gw_soc_regs->cluster_clk_enables.f.clk_en == 0x0000FFFF);
    n_errors -= (gw_soc_regs->mem_tile_clk_enables.f.clk_en == 0x000000FF);
    n_errors -= (gw_soc_regs->cluster_rsts.f.rst == 0x0000FFFF);
    n_errors -= (gw_soc_regs->mem_tile_rsts.f.rst == 0x000000FF);

    // Write all 1s and check again
    gw_soc_regs->cluster_clk_enables.f.clk_en = 0x0000AAAA;
    gw_soc_regs->mem_tile_clk_enables.f.clk_en = 0x000000AA;
    gw_soc_regs->cluster_rsts.f.rst = 0x00005555;
    gw_soc_regs->mem_tile_rsts.f.rst = 0x00000055;

    n_errors -= (gw_soc_regs->cluster_clk_enables.f.clk_en == 0x0000AAAA);
    n_errors -= (gw_soc_regs->mem_tile_clk_enables.f.clk_en == 0x000000AA);
    n_errors -= (gw_soc_regs->cluster_rsts.f.rst == 0x00005555);
    n_errors -= (gw_soc_regs->mem_tile_rsts.f.rst == 0x00000055);

    return n_errors;
}
