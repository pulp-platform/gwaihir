// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

// UCIe serial-link raw-mode software ABI: a thin, hardware-parametrization-
// aware driver over the generated `ucie_slink_reg` register file's raw-mode
// controls. Raw mode bypasses ordinary AXI packet transport inside the link
// layer entirely — software writes a complete physical/link payload directly
// into `raw_mode_out_data_fifo[]`; the link layer sends it on the selected
// output channel(s); a receiver polls `raw_mode_in_data_valid[]` and reads
// `raw_mode_in_data[]`. This is the diagnostic/calibration path a real UCIe
// link bring-up would use before the AXI path is usable.
//
// Everything here is scenario-agnostic (register-file pointers + plain data
// in, plain data / status codes out) so it's shared by any raw-mode test —
// Cheshire or Snitch — rather than duplicated per test.

#pragma once

#include <stdint.h>

#include "params.h"
#include "util.h"
#include "gw_raw_addrmap_64b.h"

// With Gwaihir's current UCIe dummy transport parameters (NumLanes=256,
// EnDdr=0), one raw sample is exactly one `NumBitsPerCycle`-wide phy_data
// cycle: 256 bits, exposed to software as eight 32-bit words. One full AXI
// flit (as reconstructed from `slink_serializer.sv`'s `payload_t`) takes 3
// such samples — see `ucie_raw_mode_loopback.c`'s header comment for the
// derivation. Both values are ABI facts of the current RDL generation
// (`cfg/ucie_slink_reg.mk`'s `NumLanes`/`EnDdr`), not test-specific.
#define RAW_WORDS_PER_SAMPLE 8
#define RAW_SAMPLES_PER_PKT 3
#define PACKET_WORDS (RAW_WORDS_PER_SAMPLE * RAW_SAMPLES_PER_PKT)
#define POLL_TIMEOUT 100000

typedef volatile slink_reg_NumLanes_100_EnDdr_0_NumBits_100_RawModeNumWords_8_t slink_regs_t;

static inline void set_bits(uint32_t *words, uint32_t bit, uint32_t width, uint64_t value) {
  for (uint32_t i = 0; i < width; i++) {
    uint32_t word = (bit + i) >> 5;
    uint32_t pos = (bit + i) & 31;
    uint32_t mask = 1u << pos;

    if ((value >> i) & 1u) {
      words[word] |= mask;
    } else {
      words[word] &= ~mask;
    }
  }
}

static inline void set_u32_words(uint32_t *words, uint32_t bit, const uint32_t *value,
                                  uint32_t n_words) {
  for (uint32_t i = 0; i < n_words; i++) {
    set_bits(words, bit + i * 32, 32, value[i]);
  }
}

static inline void clear_packet(uint32_t *packet) {
  for (uint32_t i = 0; i < PACKET_WORDS; i++) {
    packet[i] = 0;
  }
}

static inline void slink_raw_configure_tx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  regs->raw_mode_out_ch_mask[0].w = 1;
  regs->raw_mode_out_data_fifo_ctrl.w = 1;
  regs->flow_control_fifo_clear.w = 1;
  regs->raw_mode_out_en.w = 1;
  fence();
}

// Minimal raw-mode RX enable: unlike slink_raw_configure_tx, a pure receiver
// never sets raw_mode_out_en, so it never drives phy_data_out.
static inline void slink_raw_configure_rx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  fence();
}

static inline void slink_raw_disable(slink_regs_t *regs) {
  regs->raw_mode_out_en.w = 0;
  regs->raw_mode_en.w = 0;
  fence();
}

static inline int slink_raw_wait_not_full(slink_regs_t *regs) {
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    if (!regs->raw_mode_out_data_fifo_ctrl.f.is_full) {
      return 0;
    }
  }
  return 1;
}

static inline int slink_raw_push_sample(slink_regs_t *regs, const uint32_t *sample) {
  if (slink_raw_wait_not_full(regs)) {
    return 1;
  }

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    regs->raw_mode_out_data_fifo[i].w = sample[i];
  }

  fence();
  return 0;
}

static inline int slink_raw_push_packet(slink_regs_t *regs, const uint32_t *packet) {
  for (uint32_t sample = 0; sample < RAW_SAMPLES_PER_PKT; sample++) {
    if (slink_raw_push_sample(regs, &packet[sample * RAW_WORDS_PER_SAMPLE])) {
      return 1;
    }
  }

  return 0;
}

static inline int slink_raw_wait_rx_valid(slink_regs_t *regs) {
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    if (regs->raw_mode_in_data_valid[0].f.raw_mode_in_data_valid) {
      return 0;
    }
  }
  return 1;
}

static inline int slink_raw_drop_sample(slink_regs_t *regs) {
  volatile uint32_t drop;

  if (slink_raw_wait_rx_valid(regs)) {
    return 1;
  }

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    drop = regs->raw_mode_in_data[i].w;
  }

  (void)drop;
  fence();
  return 0;
}

// Drains the raw-mode RX capture that piles up on a raw-mode-enabled tile
// that just transmitted. `cfg_raw_mode_en_i` gates RX capture unconditionally
// in slink_link_layer.sv (independent of raw_mode_out_en), so while a tile is
// in raw mode its normal AXI RX decode is bypassed too: any AXI response
// traffic addressed back to it (e.g. a B response, if it just smuggled an AXI
// write through the raw TX path) lands in its own raw_mode_in_data instead of
// being consumed by the (bypassed) normal response path. This has to be
// drained before disabling raw mode, or it's left stale for whichever
// transaction reuses this channel next.
static inline int slink_raw_drop_packet(slink_regs_t *regs) {
  for (uint32_t sample = 0; sample < RAW_SAMPLES_PER_PKT; sample++) {
    if (slink_raw_drop_sample(regs)) {
      return 1;
    }
  }

  return 0;
}

// Plain (non-AXI) raw-mode round-trip pattern. One word is overwritten with a
// distinctive marker so a truncated/misaligned readback doesn't accidentally
// look like a match.
#define RAW_PATTERN_MARKER_IDX 4u
#define RAW_PATTERN_MARKER 0xdeadbeefu

static inline void build_raw_pattern(uint32_t *sample, uint32_t seed) {
  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    sample[i] = seed + i;
  }
  sample[RAW_PATTERN_MARKER_IDX] = RAW_PATTERN_MARKER;
}

// Like slink_raw_drop_sample, but captures the words instead of discarding
// them, so the caller can compare against what was sent.
static inline int slink_raw_read_sample(slink_regs_t *regs, uint32_t *sample) {
  if (slink_raw_wait_rx_valid(regs)) {
    return 1;
  }

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    sample[i] = regs->raw_mode_in_data[i].w;
  }

  fence();
  return 0;
}

// Symmetric raw-mode round trip: enable raw mode on both tiles (tx_regs also
// as TX, rx_regs as a pure receiver), push one plain pattern sample built
// from `seed`, and check it arrives at rx_regs unchanged. Returns 0 on
// success, 1 on FIFO-full/push failure, 2 on RX timeout, 3 on data mismatch;
// raw mode is always left disabled on both tiles on return.
static inline int slink_raw_round_trip(slink_regs_t *tx_regs, slink_regs_t *rx_regs,
                                        uint32_t seed) {
  uint32_t tx_sample[RAW_WORDS_PER_SAMPLE];
  uint32_t rx_sample[RAW_WORDS_PER_SAMPLE];
  int result = 0;

  build_raw_pattern(tx_sample, seed);

  slink_raw_configure_rx(rx_regs);
  slink_raw_configure_tx(tx_regs);

  if (slink_raw_push_sample(tx_regs, tx_sample)) {
    result = 1;
  } else if (slink_raw_read_sample(rx_regs, rx_sample)) {
    result = 2;
  } else {
    for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
      if (rx_sample[i] != tx_sample[i]) {
        result = 3;
        break;
      }
    }
  }

  slink_raw_disable(tx_regs);
  slink_raw_disable(rx_regs);
  return result;
}
