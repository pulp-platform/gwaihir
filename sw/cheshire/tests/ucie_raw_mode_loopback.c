// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Lorenzo Leone <lleone@iis.ee.ethz.ch>

// Two-phase raw-mode SLINK proof:
//
// Phase 1 injects a single AXI write through the UCIe0 raw-mode TX path,
// hand-encoding real `slink_prot_layer` flits so UCIe1's *normal* (non-raw)
// AXI decode path deserializes them into an actual NoC write, verified
// through the local NoC address map. This exercises raw mode purely as a TX
// injection mechanism.
//
// Phase 2 covers what Phase 1 cannot: a real receiver polling
// `raw_mode_in_data_valid[]`/reading `raw_mode_in_data[]` while *it* is in
// raw mode too. It sends one plain (non-AXI) pattern sample UCIe0->UCIe1,
// then repeats UCIe1->UCIe0, comparing the received words verbatim. This is
// the actual diagnostic/calibration use case raw mode exists for.
//
// `build_aw_packet`/`build_w_packet` (Phase 1 only) hand-encode `slink_serializer.sv`'s
// internal `payload_t` (credit/hdr/b/b_valid/axi_ch, LSB-to-MSB) with the
// `axi_ch` field cast to `AXI_DECL_AW_CHAN_T`/`AXI_DECL_W_CHAN_T`
// (`axi/typedef.svh`, packed field order id/addr/len/size/burst/lock/cache/
// prot/qos/region/atop/user for AW; data/strb/last/user for W, MSB-to-LSB as
// listed). The bit offsets below are only valid for the current UCIe join
// parametrization and must be re-derived if any of these change:
//   - credit_t width (4b)   = $clog2(NumCredits)+1, NumCredits=8 (slink_serializer.sv)
//   - hdr width (4b)        = $bits(slink_pkg::tag_e)
//   - b_chan_t width (5b)   = id(2) + resp(2) + user(1), from
//                             AxiCfgUcieJoin = axi_join_cfg(AxiCfgNoAtop, AxiCfgW)
//                             -> OutIdWidth=2 (max(1,1)+1 mux bit), UserWidth=1
//                             (gwaihir_pkg.sv)
//   - axi_ch base (14b)     = credit(4) + hdr(4) + b_valid(1) + b_chan_t(5)
//   - aw addr/id widths     = AxiCfgUcieJoin.AddrWidth=48, OutIdWidth=2
//   - w data/strb widths    = AxiCfgUcieJoin.DataWidth=512 (max of narrow 64b,
//                             wide 512b)
// RAW_WORDS_PER_SAMPLE/RAW_SAMPLES_PER_PKT likewise depend on NumLanes=256,
// EnDdr=0 (one raw sample == one `NumBitsPerCycle`-wide phy_data cycle) and
// on $bits(payload_t) (3 samples needed to fit one AW or W flit).

#include <stdint.h>

#include "params.h"
#include "util.h"
#include "gw_addrmap_64b.h"
#include "gw_raw_addrmap_64b.h"

#define TEST_DATA 0x51a5cafeu
#define POISON_DATA 0x0badf00du

#define RAW_WORDS_PER_SAMPLE 8
#define RAW_SAMPLES_PER_PKT 3
#define PACKET_WORDS (RAW_WORDS_PER_SAMPLE * RAW_SAMPLES_PER_PKT)
#define POLL_TIMEOUT 100000

#define SLINK_TAG_AW 1u
#define SLINK_TAG_W 2u

#define AXI_BURST_INCR 1u
#define AXI_SIZE_64B 6u
#define AXI_CACHE_MODIFIABLE_BUFFERABLE 0x3u

// Phase 2: plain (non-AXI) raw-mode round-trip pattern. One word is
// overwritten with a distinctive marker so a truncated/misaligned readback
// doesn't accidentally look like a match.
#define RAW_PATTERN_MARKER_IDX 4u
#define RAW_PATTERN_MARKER 0xdeadbeefu
#define RAW_PATTERN_SEED_FWD 0xdead0000u  // UCIe0 -> UCIe1
#define RAW_PATTERN_SEED_REV 0xbeef0000u  // UCIe1 -> UCIe0

// Phase 2 exit codes, offset past Phase 1's (1..5) so a failure's phase is
// unambiguous from the return code alone.
#define ERR_FWD_PUSH 6
#define ERR_FWD_RX_TIMEOUT 7
#define ERR_FWD_MISMATCH 8
#define ERR_REV_PUSH 9
#define ERR_REV_RX_TIMEOUT 10
#define ERR_REV_MISMATCH 11

typedef volatile slink_reg_NumLanes_100_EnDdr_0_NumBits_100_RawModeNumWords_8_t slink_regs_t;

static void set_bits(uint32_t *words, uint32_t bit, uint32_t width, uint64_t value) {
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

static void set_u32_words(uint32_t *words, uint32_t bit, const uint32_t *value, uint32_t n_words) {
  for (uint32_t i = 0; i < n_words; i++) {
    set_bits(words, bit + i * 32, 32, value[i]);
  }
}

static void clear_packet(uint32_t *packet) {
  for (uint32_t i = 0; i < PACKET_WORDS; i++) {
    packet[i] = 0;
  }
}

static void build_aw_packet(uint32_t *packet, uintptr_t addr) {
  const uint32_t axi_ch = 14;

  clear_packet(packet);

  set_bits(packet, 0, 4, 0);              // credit
  set_bits(packet, 4, 4, SLINK_TAG_AW);   // hdr
  set_bits(packet, axi_ch + 0, 1, 0);     // aw.user
  set_bits(packet, axi_ch + 1, 6, 0);     // aw.atop
  set_bits(packet, axi_ch + 7, 4, 0);     // aw.region
  set_bits(packet, axi_ch + 11, 4, 0);    // aw.qos
  set_bits(packet, axi_ch + 15, 3, 0);    // aw.prot
  set_bits(packet, axi_ch + 18, 4, AXI_CACHE_MODIFIABLE_BUFFERABLE);
  set_bits(packet, axi_ch + 22, 1, 0);    // aw.lock
  set_bits(packet, axi_ch + 23, 2, AXI_BURST_INCR);
  set_bits(packet, axi_ch + 25, 3, AXI_SIZE_64B);
  set_bits(packet, axi_ch + 28, 8, 0);    // aw.len
  set_bits(packet, axi_ch + 36, 48, addr);
  set_bits(packet, axi_ch + 84, 2, 0);    // aw.id
}

static void build_w_packet(uint32_t *packet, uint32_t data) {
  uint32_t wide_data[16] = {0};
  uint32_t wide_strb[2] = {0xffffffffu, 0xffffffffu};

  clear_packet(packet);
  wide_data[0] = data;

  set_bits(packet, 0, 4, 0);             // credit
  set_bits(packet, 4, 4, SLINK_TAG_W);   // hdr
  set_bits(packet, 14 + 0, 1, 0);        // w.user
  set_bits(packet, 14 + 1, 1, 1);        // w.last
  set_u32_words(packet, 14 + 2, wide_strb, 2);
  set_u32_words(packet, 14 + 66, wide_data, 16);
}

static void slink_raw_configure_tx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  regs->raw_mode_out_ch_mask[0].w = 1;
  regs->raw_mode_out_data_fifo_ctrl.w = 1;
  regs->flow_control_fifo_clear.w = 1;
  regs->raw_mode_out_en.w = 1;
  fence();
}

static void slink_raw_disable(slink_regs_t *regs) {
  regs->raw_mode_out_en.w = 0;
  regs->raw_mode_en.w = 0;
  fence();
}

static int slink_raw_wait_not_full(slink_regs_t *regs) {
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    if (!regs->raw_mode_out_data_fifo_ctrl.f.is_full) {
      return 0;
    }
  }
  return 1;
}

static int slink_raw_push_sample(slink_regs_t *regs, const uint32_t *sample) {
  if (slink_raw_wait_not_full(regs)) {
    return 1;
  }

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    regs->raw_mode_out_data_fifo[i].w = sample[i];
  }

  fence();
  return 0;
}

static int slink_raw_push_packet(slink_regs_t *regs, const uint32_t *packet) {
  for (uint32_t sample = 0; sample < RAW_SAMPLES_PER_PKT; sample++) {
    if (slink_raw_push_sample(regs, &packet[sample * RAW_WORDS_PER_SAMPLE])) {
      return 1;
    }
  }

  return 0;
}

static int slink_raw_wait_rx_valid(slink_regs_t *regs) {
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    if (regs->raw_mode_in_data_valid[0].f.raw_mode_in_data_valid) {
      return 0;
    }
  }
  return 1;
}

static int slink_raw_drop_sample(slink_regs_t *regs) {
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

// Drains the raw-mode RX capture that piles up on the *sender's* own tile.
// `cfg_raw_mode_en_i` gates RX capture unconditionally in slink_link_layer.sv
// (independent of raw_mode_out_en), so while ucie0 is in raw mode its normal
// AXI RX decode is bypassed too: the AXI B response that ucie1 sends back for
// the write above lands in ucie0's raw_mode_in_data instead of being consumed
// by the (bypassed) normal response path. This has to be drained before
// disabling raw mode, or it's left stale for whichever transaction reuses
// this channel next.
static int slink_raw_drop_packet(slink_regs_t *regs) {
  for (uint32_t sample = 0; sample < RAW_SAMPLES_PER_PKT; sample++) {
    if (slink_raw_drop_sample(regs)) {
      return 1;
    }
  }

  return 0;
}

// Minimal raw-mode RX enable: unlike slink_raw_configure_tx, a pure receiver
// never sets raw_mode_out_en, so it never drives phy_data_out.
static void slink_raw_configure_rx(slink_regs_t *regs) {
  regs->raw_mode_en.w = 1;
  regs->raw_mode_in_ch_sel.w = 0;
  fence();
}

static void build_raw_pattern(uint32_t *sample, uint32_t seed) {
  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    sample[i] = seed + i;
  }
  sample[RAW_PATTERN_MARKER_IDX] = RAW_PATTERN_MARKER;
}

// Like slink_raw_drop_sample, but captures the words instead of discarding
// them, so the caller can compare against what was sent.
static int slink_raw_read_sample(slink_regs_t *regs, uint32_t *sample) {
  if (slink_raw_wait_rx_valid(regs)) {
    return 1;
  }

  for (uint32_t i = 0; i < RAW_WORDS_PER_SAMPLE; i++) {
    sample[i] = regs->raw_mode_in_data[i].w;
  }

  fence();
  return 0;
}

// Phase 2 core: enable raw mode on both tiles (tx_regs also as TX, rx_regs as
// a pure receiver), push one plain pattern sample, and check it arrives
// unchanged. Reuses the exact TX-side helpers Phase 1 uses (configure_tx,
// push_sample) — the only new machinery here is the RX-side capture/compare.
// Returns 0 on success, 1 on FIFO-full/push failure, 2 on RX timeout, 3 on
// data mismatch; raw mode is always left disabled on both tiles on return.
static int slink_raw_round_trip(slink_regs_t *tx_regs, slink_regs_t *rx_regs, uint32_t seed) {
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

int main() {
  uint32_t aw_packet[PACKET_WORDS];
  uint32_t w_packet[PACKET_WORDS];

  slink_regs_t *ucie0_slink = &gwaihir_addrmap_64b.ucie0_axi_serial_cfg.regs;
  slink_regs_t *ucie1_slink = &gwaihir_addrmap_64b.ucie1_axi_serial_cfg.regs;

  volatile uint32_t *alias_wr = (volatile uint32_t *)&gwaihir_addrmap_64b.ucie0.l2_spm[0];
  volatile uint32_t *local_rd = (volatile uint32_t *)&gwaihir_addrmap_64b.l2_spm[2];

  *local_rd = POISON_DATA;
  fence();

  slink_raw_disable(ucie1_slink);
  slink_raw_configure_tx(ucie0_slink);

  build_aw_packet(aw_packet, (uintptr_t)alias_wr);
  build_w_packet(w_packet, TEST_DATA);

  if (slink_raw_push_packet(ucie0_slink, aw_packet)) {
    slink_raw_disable(ucie0_slink);
    return 2;
  }

  if (slink_raw_push_packet(ucie0_slink, w_packet)) {
    slink_raw_disable(ucie0_slink);
    return 3;
  }

  int phase1_ok = 0;
  for (uint32_t timeout = 0; timeout < POLL_TIMEOUT; timeout++) {
    fence();
    if (*local_rd == TEST_DATA) {
      phase1_ok = 1;
      break;
    }
  }

  if (!phase1_ok) {
    slink_raw_disable(ucie0_slink);
    return 4;
  }

  if (slink_raw_drop_packet(ucie0_slink)) {
    return 5;
  }
  slink_raw_disable(ucie0_slink);

  // Phase 2: symmetric raw round-trip, exercising the raw_mode_in_data[]/
  // raw_mode_in_data_valid[] RX path that Phase 1's AXI-injection trick never
  // touches (ucie1 there stays in normal mode throughout).
  int rc = slink_raw_round_trip(ucie0_slink, ucie1_slink, RAW_PATTERN_SEED_FWD);
  if (rc) {
    return ERR_FWD_PUSH + (rc - 1);
  }

  rc = slink_raw_round_trip(ucie1_slink, ucie0_slink, RAW_PATTERN_SEED_REV);
  if (rc) {
    return ERR_REV_PUSH + (rc - 1);
  }

  return 0;
}
