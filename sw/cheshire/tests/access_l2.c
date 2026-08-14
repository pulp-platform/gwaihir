// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Lorenzo Leone <lleone@iis.ee.ethz.ch>
//
// This test simply read and write from some L2 locations.
// It will read the first uint32 data from each memory bank.

#include <stdint.h>
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"
#include "gw_memtile.h"

#define WIDE_WORD_WIDTH 512
#define NARROW_WORD_WIDTH (sizeof(uint32_t) * 8)
#define L2_SRAM_DATA_WIDTH 128
#define L2_SRAM_NUM_WORDS 1024
#define L2_BANKS_PER_WORD (WIDE_WORD_WIDTH / L2_SRAM_DATA_WIDTH)
#define L2_BANK_ROWS(size) (((size) / (WIDE_WORD_WIDTH / 8)) / L2_SRAM_NUM_WORDS)
// Size the view's per-tile block to the tile-to-tile grid STRIDE, not to any one
// tile's size: the bases sit on a uniform grid, so a block of
// L2_BANK_ROWS(GW_L2_SPM_STRIDE) rows makes (*l2_mem)[i] land exactly on tile i.
#define L2_MAX_BANK_ROWS L2_BANK_ROWS(GW_L2_SPM_STRIDE)
#define L2_TOTAL_BANK_ROWS                                            \
  (L2_BANK_ROWS(GW_L2_SPM_0_SIZE) + L2_BANK_ROWS(GW_L2_SPM_1_SIZE) +  \
   L2_BANK_ROWS(GW_L2_SPM_2_SIZE) + L2_BANK_ROWS(GW_L2_SPM_3_SIZE))

// Tiles are heterogeneous (2 MiB / 1 MiB) but sit on a uniform 2 MiB grid, so a
// single max-row-sized view spans all tiles; each tile is walked up to its
// own row count.
typedef uint32_t l2_mem_t[GW_L2_SPM_NUM][L2_MAX_BANK_ROWS][L2_SRAM_NUM_WORDS][L2_BANKS_PER_WORD][L2_SRAM_DATA_WIDTH / NARROW_WORD_WIDTH];

static_assert((sizeof(l2_mem_t) / GW_L2_SPM_NUM) == GW_L2_SPM_STRIDE, "Packing error");

int main() {

  volatile l2_mem_t *l2_mem = (volatile l2_mem_t *)(uintptr_t)&gwaihir_addrmap_64b.l2_spm_0;

  uint32_t n_errors = L2_TOTAL_BANK_ROWS * L2_BANKS_PER_WORD * 4; // Total number of writes

  // Write to each physical bank
  // One aligned access, one unaligned access
  for (uint32_t i = 0; i < GW_L2_SPM_NUM; i++) {
    for (uint32_t j = 0; j < L2_BANK_ROWS(GW_L2_SPM_SIZE(i)); j++) {
        for (uint32_t k = 0; k < L2_BANKS_PER_WORD; k++) {
          (*l2_mem)[i][j][0][k][0] = i * j * k;
          (*l2_mem)[i][j][0][k][1] = i * j * k + 1;
          (*l2_mem)[i][j][1][k][0] = i * j * k + 2;
          (*l2_mem)[i][j][1][k][1] = i * j * k + 3;
      }
    }
  }

  // Read from each physical bank and check if the value is correct
  for (uint32_t i = 0; i < GW_L2_SPM_NUM; i++) {
    for (uint32_t j = 0; j < L2_BANK_ROWS(GW_L2_SPM_SIZE(i)); j++) {
      for (uint32_t k = 0; k < L2_BANKS_PER_WORD; k++) {
          n_errors -= ((*l2_mem)[i][j][0][k][0] == i * j * k);
          n_errors -= ((*l2_mem)[i][j][0][k][1] == i * j * k + 1);
          n_errors -= ((*l2_mem)[i][j][1][k][0] == i * j * k + 2);
          n_errors -= ((*l2_mem)[i][j][1][k][1] == i * j * k + 3);
      }
    }
  }

  return n_errors;
}
