// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

// UCIe serial-link raw-mode loopback: send one plain 256-bit payload from
// UCIe0's raw-mode TX path to UCIe1's raw-mode RX path (an AW-mode raw write
// on one side, a raw read on the other) and verify it arrives unchanged.
// This is exactly the sequence that will bring the physical link up once the
// two UCIe tiles sit on separate dies: raw mode is a link bring-up/
// calibration mechanism, decoupled from and independent of AXI, used to
// prove the serial link itself works before trusting AXI traffic over it.

#include <stdint.h>

#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"

#define RAW_WORDS_PER_SAMPLE 8
#define POLL_TIMEOUT 100000

// Nontrivial pattern with one distinctive word, so a truncated/misaligned
// readback can't accidentally look like a match.
#define PATTERN_SEED 0xdead0000u
#define PATTERN_MARKER_IDX 4u
#define PATTERN_MARKER 0xdeadbeefu

typedef volatile slink_reg_NumLanes_100_EnDdr_0_NumBits_100_RawModeNumWords_8_t slink_regs_t;

static void slink_raw_configure_tx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  regs->raw_mode_out_ch_mask[0].w = 1;
  // Clear TX FIFO before transmitting
  regs->raw_mode_out_data_fifo_ctrl.w = 1;
  fence();
}

static void slink_raw_configure_rx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  fence();
}

static void slink_raw_disable(slink_regs_t *regs) {
  regs->raw_mode_out_en.w = 0;
  regs->raw_mode_en.w = 0;
  fence();
}

static int slink_raw_wait_rx_valid(slink_regs_t *regs) {
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    if (regs->raw_mode_in_data_valid[0].f.raw_mode_in_data_valid) {
      return 0;
    }
  }
  return 1;
}

int main() {
  uint32_t tx_sample[RAW_WORDS_PER_SAMPLE];
  uint32_t rx_sample[RAW_WORDS_PER_SAMPLE];

  slink_regs_t *ucie0_slink = &gwaihir_addrmap_64b.ucie0_axi_serial_cfg;
  slink_regs_t *ucie1_slink = &gwaihir_addrmap_64b.ucie1_axi_serial_cfg;

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    tx_sample[i] = PATTERN_SEED + i;
  }
  tx_sample[PATTERN_MARKER_IDX] = PATTERN_MARKER;

  slink_raw_configure_rx(ucie1_slink);
  slink_raw_configure_tx(ucie0_slink);

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    ucie0_slink->raw_mode_out_data_fifo[i].w = tx_sample[i];
  }
  ucie0_slink->raw_mode_push.w = 1;
  ucie0_slink->raw_mode_out_en.w = 1;
  fence();

  // RX: wait for a valid read data
  if (slink_raw_wait_rx_valid(ucie1_slink)) {
    slink_raw_disable(ucie0_slink);
    slink_raw_disable(ucie1_slink);
    return 2;
  }

  // Pop word by word form teh RAW data in register
  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    rx_sample[i] = ucie1_slink->raw_mode_in_data[i].w;
  }
  ucie1_slink->raw_mode_pop.w = 1;
  fence();

  slink_raw_disable(ucie0_slink);
  slink_raw_disable(ucie1_slink);

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    if (rx_sample[i] != tx_sample[i]) {
      return 3;
    }
  }

  return 0;
}
