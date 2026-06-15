// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Cyrill Durrer <cdurrer@iis.ee.ethz.ch>

#include "gw_addrmap.h"
#include "gw_raw_addrmap.h"

// The clock-gating and reset control are now per-tile registers, exposed via
// the per-tile config blocks. Each tile holds a single clock-enable bit
// (clk.en) and a single active-low reset bit (rst.n).

int main(void) {

    uint32_t n_errors = 2 * (GW_CLUSTER_NUM + GW_L2_SPM_NUM);

    volatile gw_tile_regs__stride1000_t *cluster_cfg = gwaihir_addrmap.cluster_config;
    volatile gw_tile_regs__stride1000_t *mem_cfg = gwaihir_addrmap.l2_spm_config;

    // Write and read back the clock-enable and reset bits of every cluster tile
    for (int i = 0; i < GW_CLUSTER_NUM; i++) {
        cluster_cfg[i].clk.f.en = 0x1;
        cluster_cfg[i].rst.f.n = 0x1;
        n_errors -= (cluster_cfg[i].clk.f.en == 0x1);
        n_errors -= (cluster_cfg[i].rst.f.n == 0x1);
    }

    // Write and read back the clock-enable and reset bits of every memory tile
    for (int i = 0; i < GW_L2_SPM_NUM; i++) {
        mem_cfg[i].clk.f.en = 0x1;
        mem_cfg[i].rst.f.n = 0x1;
        n_errors -= (mem_cfg[i].clk.f.en == 0x1);
        n_errors -= (mem_cfg[i].rst.f.n == 0x1);
    }

    return n_errors;
}
